#!/usr/bin/env escript
%% Uncalibrated UWB ranging measurements between two GRiSP boards, at
%% distances measured by hand, driven from this host over distributed
%% Erlang.
%%
%% One board is the tag (initiator), the other the anchor (responder).
%% For each distance you type, the host asks the tag for N DS-TWR ranges
%% (uwb_twr:range/2) and, after each successful one, fetches the raw
%% DW1000 timestamps (uwb_twr:last_exchange/0). Nothing is corrected: the
%% distance is uwb_twr's raw output, with the antenna delays that are in
%% the DW1000 registers (read back and saved in meta.json).
%%
%% Usage: uwb_ranging.escript [Option...]
%%   --tag Node           tag board          (board@grisp-001021)
%%   --anchor Node        anchor board       (board@grisp-002075)
%%   --n N                ranges per distance               (100)
%%   --timeout Ms         max wait for the anchor's report  (500)
%%   --period Ms          pause between two ranges          (0)
%%   --antd V             tx/rx antenna delay, used only if the radio
%%                        is not started yet on a board     (16450)
%%   --tag-addr A, --anchor-addr A   short addresses (1, 2)
%%   --cookie C                                             (grisp)
%%   --comment Text       saved in meta.json
%%   --out Dir            output folder (data/uwb_ranging/<date>)
%%
%% The boards must run the hera release with no hera_measure started
%% (reboot them first). If uwb_twr already runs on a board with the
%% expected address, it is reused as is.
%%
%% Output, written as it goes (an interrupted session keeps its data):
%%   ranges.csv  one row per range attempt, failures included
%%   points.csv  one row per distance: statistics and your note
%%   meta.json   boards, releases, addresses, antenna delays, options,
%%               and uwb_twr's counters at the end

-define(TS_MASK, 16#FFFFFFFFFF).
-define(MAX_BADRPC, 3).
-define(PMSC_RX, 5).                   % sys_state pmsc_state while receiving

-define(RANGES_HEADER,
        "point,true_distance_m,sample,host_time_ms,range_ms,status,raw_distance_m,"
        "poll_tx,resp_rx,final_tx,poll_rx,resp_tx,final_rx,"
        "round1,reply1,round2,reply2\n").
-define(POINTS_HEADER,
        "point,true_distance_m,n,ok,failed,mean_m,std_m,median_m,min_m,max_m,"
        "error_m,start_time_ms,end_time_ms,note\n").

main(Args) ->
    Opts = try parse(Args, defaults())
           catch throw:{usage, Msg} -> usage(Msg), halt(2)
           end,
    try run(Opts) of
        ok -> halt(0)
    catch
        throw:{abort, Fmt, FArgs} ->
            io:format(standard_error, "uwb_ranging: " ++ Fmt ++ "~n", FArgs),
            halt(1)
    end.

defaults() ->
    #{tag => 'board@grisp-002075', anchor => 'board@grisp-002010',
      tag_addr => 16#0001, anchor_addr => 16#0002, pan_id => 16#CAFE,
      n => 100, timeout => 500, period => 0, antd => 16450,
      cookie => grisp, comment => "", out => undefined}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Session
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

run(O = #{tag := Tag, anchor := Anchor}) ->
    Name = list_to_atom("uwb_ranging_" ++ os:getpid()),
    % net_kernel:start/2, unlike erl -sname, doesn't start epmd itself.
    _ = os:cmd("epmd -daemon"),
    {ok, _} = net_kernel:start(Name, #{name_domain => shortnames, hidden => true}),
    erlang:set_cookie(maps:get(cookie, O)),
    [connect(N) || N <- [Tag, Anchor]],
    [check_idle(N) || N <- [Tag, Anchor]],
    % The anchor first, so that it already answers when the tag starts.
    AnchorInfo = setup(Anchor, anchor, maps:get(anchor_addr, O), O),
    TagInfo = setup(Tag, tag, maps:get(tag_addr, O), O),

    Dir = out_dir(O),
    ok = filelib:ensure_path(Dir),
    Meta0 = #{started => iso_now(), tag => TagInfo, anchor => AnchorInfo,
              host_otp => list_to_binary(erlang:system_info(otp_release)),
              options => maps:map(fun(_, V) -> jsonable(V) end,
                                  maps:without([cookie, out], O))},
    write_meta(Dir, Meta0),
    {ok, Ranges} = file:open(filename:join(Dir, "ranges.csv"), [write]),
    {ok, Points} = file:open(filename:join(Dir, "points.csv"), [write]),
    ok = file:write(Ranges, ?RANGES_HEADER),
    ok = file:write(Points, ?POINTS_HEADER),
    log("writing to ~s", [Dir]),

    % A uwb_twr reused from an earlier session may sit on a reset chip.
    {Summaries, O1} = case ensure_radios(O#{ranges => Ranges, points => Points,
                                            events => []}) of
        {ok, O0} -> test_range(O0), points(1, O0, []);
        {quit, O0} -> {[], O0}
    end,
    ok = file:close(Ranges),
    ok = file:close(Points),

    Stats = #{tag => jsonable(rpc:call(Tag, uwb_twr, stats, [], 5000)),
              anchor => jsonable(rpc:call(Anchor, uwb_twr, stats, [], 5000))},
    write_meta(Dir, Meta0#{finished => iso_now(), points => length(Summaries),
                           uwb_twr_stats => Stats,
                           events => lists:reverse(maps:get(events, O1))}),
    print_table(lists:reverse(Summaries)),
    log("data in ~s", [Dir]),
    ok.

%% One range before the session, so a radio problem shows up now and not
%% at the first distance.
test_range(#{tag := Tag, anchor_addr := Addr, timeout := Timeout}) ->
    case rpc:call(Tag, uwb_twr, range, [Addr, Timeout], Timeout + 10000) of
        {ok, D} -> log("test range: ~.3f m (raw)", [D]);
        Other -> log("WARNING: test range failed: ~0p", [Other])
    end.

points(P, O, Acc) ->
    case prompt(P) of
        done ->
            {Acc, O};
        {Dist, Note} ->
            case ensure_radios(O) of
                {ok, O1} ->
                    {Summary = #{n := N, ok := Ok}, O2} = measure_point(P, Dist, Note, O1),
                    Ok * 2 < N andalso radio_problems(O2) =/= [] andalso
                        log("WARNING: a DW1000 lost its configuration during "
                            "this point (see above): its ranges are unusable", []),
                    points(P + 1, O2, [Summary | Acc]);
                {quit, O1} ->
                    {Acc, O1}
            end
    end.

%% The DW1000 keeps its configuration only while powered. A glitch on the
%% Pmod (e.g. when a board is moved) resets it to its defaults while the
%% GRiSP keeps running, and nothing in the software notices: uwb_twr still
%% runs, but the chip has address 0xFFFF and auto-ACK off, so every POLL
%% ends in no_ack. The chip's own address register shows it.
radio_problems(#{tag := Tag, anchor := Anchor, tag_addr := TA, anchor_addr := AA,
                 pan_id := Pan}) ->
    [{Role, Node, Got} || {Role, Node, Addr} <- [{tag, Tag, TA}, {anchor, Anchor, AA}],
                          Got <- [rpc:call(Node, pmod_uwb, read, [panadr], 5000)],
                          not radio_configured(Got, Addr, Pan)].

radio_configured(#{short_addr := <<Addr:16>>, pan_id := <<Pan:16>>}, Addr, Pan) -> true;
radio_configured(_, _, _) -> false.

%% Before each point: if a radio lost its configuration, the board must
%% be rebooted (that resets and configures the chip again); the session
%% then sets uwb_twr up again on it and goes on.
ensure_radios(O) ->
    case radio_problems(O) of
        [] ->
            {ok, unstick(O)};
        Bad ->
            [log("ERROR: the DW1000 of the ~s (~s) lost its configuration "
                 "(address register: ~s). Usually a power glitch on the "
                 "Pmod, e.g. when the board is moved.", [Role, Node, panadr_str(Got)])
             || {Role, Node, Got} <- Bad],
            Events = [#{time => iso_now(), node => Node, role => Role,
                        event => dw1000_reset, panadr => jsonable(Got)}
                      || {Role, Node, Got} <- Bad],
            recover(Bad, O#{events := Events ++ maps:get(events, O)})
    end.

recover(Bad, O) ->
    Boards = lists:join(" ", [tl(lists:dropwhile(fun(C) -> C =/= $@ end, atom_to_list(N)))
                              || {_, N, _} <- Bad]),
    Q = io_lib:format("Reboot it (make reboot BOARDS=\"~s\"), wait until it answers "
                      "(make info BOARDS=\"~s\"), then press Enter here, or q to "
                      "finish the session~n> ", [Boards, Boards]),
    case io:get_line(Q) of
        "q" ++ _ ->
            {quit, O};
        eof ->
            {quit, O};
        _ ->
            Up = [N || {_, N, _} <- Bad, net_adm:ping(N) =:= pong],
            case length(Up) =:= length(Bad) of
                false ->
                    log("not reachable yet", []),
                    recover(Bad, O);
                true ->
                    [begin check_idle(N), setup(N, Role, role_addr(Role, O), O) end
                     || {Role, N, _} <- Bad],
                    case radio_problems(O) of
                        [] ->
                            test_range(O),
                            Ev = [#{time => iso_now(), node => N, role => Role,
                                    event => uwb_twr_restarted} || {Role, N, _} <- Bad],
                            {ok, O#{events := Ev ++ maps:get(events, O)}};
                        Still ->
                            log("still not configured (not rebooted?)", []),
                            recover(Still, O)
                    end
            end
    end.

%% The DW1000 has also been seen stuck in PMSC state 2 (a wait state)
%% with its configuration intact: it ignores RXENAB, so it never
%% receives, while pmod_uwb's rx loop waits forever for a status flag.
%% TRXOFF gets it out, RXENAB turns the receiver on again, and the rx
%% loop, still waiting, picks up the next frame. Checked before each
%% point and after every POLL that got no ACK.
unstick(O = #{tag := Tag, anchor := Anchor}) ->
    lists:foldl(fun({Role, Node}, Acc) -> unstick(Role, Node, Acc) end, O,
                [{anchor, Anchor}, {tag, Tag}]).

unstick(Role, Node, O) ->
    % Right after a range the tag's rx loop is restarting: look twice.
    case receiving(Node) orelse (ok =:= timer:sleep(50) andalso receiving(Node)) of
        true ->
            O;
        false ->
            Before = pmsc_state(Node),
            _ = rpc:call(Node, pmod_uwb, write, [sys_ctrl, #{trxoff => 1}], 5000),
            _ = rpc:call(Node, pmod_uwb, write, [sys_ctrl, #{rxenab => 1}], 5000),
            After = pmsc_state(Node),
            io:format("~n"),
            log("~s (~s): receiver was off (PMSC state ~0p), turned it on again "
                "(now ~0p)", [Role, Node, Before, After]),
            Ev = #{time => iso_now(), node => Node, role => Role, event => rx_restarted,
                   pmsc_state_before => Before, pmsc_state_after => After},
            O#{events := [Ev | maps:get(events, O)]}
    end.

receiving(Node) ->
    pmsc_state(Node) =:= ?PMSC_RX.

pmsc_state(Node) ->
    case rpc:call(Node, pmod_uwb, read, [sys_state], 5000) of
        #{pmsc_state := P} -> P;
        Other -> jsonable(Other)
    end.

panadr_str(#{pan_id := <<Pan:16>>, short_addr := <<Addr:16>>}) ->
    io_lib:format("PAN 16#~.16B, short address 16#~.16B", [Pan, Addr]);
panadr_str(Other) ->
    io_lib:format("~0p", [Other]).

role_addr(tag, #{tag_addr := A}) -> A;
role_addr(anchor, #{anchor_addr := A}) -> A.

prompt(P) ->
    Q = io_lib:format("~nPoint ~p: true distance in m, then an optional note "
                      "(empty line or q to finish)~n> ", [P]),
    case io:get_line(Q) of
        eof -> done;
        {error, _} -> done;
        Line ->
            case string:trim(Line) of
                "" -> done;
                "q" -> done;
                Trimmed ->
                    [DistStr | Rest] = string:split(Trimmed, " "),
                    case to_number(lists:flatten(string:replace(DistStr, ",", ".", all))) of
                        {ok, D} when D >= 0 ->
                            {D, string:trim(lists:flatten(Rest))};
                        _ ->
                            io:format("Not a distance: ~s~n", [DistStr]),
                            prompt(P)
                    end
            end
    end.

measure_point(P, Dist, Note, O = #{n := N}) ->
    log("point ~p at ~.3f m: ~p ranges", [P, Dist, N]),
    Start = erlang:system_time(millisecond),
    {Results, O1} = samples(P, Dist, 1, O, 0, []),
    End = erlang:system_time(millisecond),
    io:format("~n"),
    Summary = summarise(P, Dist, Note, Results, Start, End),
    ok = file:write(maps:get(points, O), points_row(Summary)),
    print_summary(Summary),
    {Summary, O1}.

samples(_P, _Dist, I, O = #{n := N}, _Bad, Acc) when I > N ->
    {lists:reverse(Acc), O};
samples(_P, _Dist, _I, O, Bad, Acc) when Bad >= ?MAX_BADRPC ->
    io:format("~n"),
    log("WARNING: ~p RPC failures in a row, point stopped early", [Bad]),
    {lists:reverse(Acc), O};
samples(P, Dist, I, O, Bad, Acc) ->
    T = erlang:system_time(millisecond),
    R = sample(O),
    Ms = erlang:system_time(millisecond) - T,
    ok = file:write(maps:get(ranges, O), ranges_row(P, Dist, I, T, Ms, R)),
    progress(I, R),
    timer:sleep(maps:get(period, O)),
    NewBad = case R of {badrpc, _} -> Bad + 1; _ -> 0 end,
    O1 = case R of {error, {poll, no_ack}} -> unstick(O); _ -> O end,
    samples(P, Dist, I + 1, O1, NewBad, [R | Acc]).

sample(#{tag := Tag, anchor_addr := Addr, timeout := Timeout}) ->
    case rpc:call(Tag, uwb_twr, range, [Addr, Timeout], Timeout + 10000) of
        {ok, D} ->
            % last_exchange/0 is the exchange that gave D only if its
            % distance is the same; otherwise the timestamps are left out.
            Ts = case rpc:call(Tag, uwb_twr, last_exchange, [], 5000) of
                #{distance := {ok, D}, tag_ts := TagTs, anchor_ts := AncTs} ->
                    {TagTs, AncTs};
                _ ->
                    undefined
            end,
            {ok, D, Ts};
        {error, Reason} ->
            {error, Reason};
        {badrpc, Reason} ->
            {badrpc, Reason}
    end.

progress(I, R) ->
    C = case R of {ok, _, _} -> "."; {error, timeout} -> "t"; _ -> "x" end,
    io:format("~s", [C]),
    I rem 50 =:= 0 andalso io:format(" ~p~n", [I]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Boards
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect(Node) ->
    case net_adm:ping(Node) of
        pong -> log("connected to ~s", [Node]);
        pang -> abort("cannot reach ~s (board off, wrong name, or not on the hotspot?)", [Node])
    end.

%% A running hera_measure (e.g. hera_uwb) would use uwb_twr at the same time.
check_idle(Node) ->
    case rpc:call(Node, supervisor, which_children, [hera_measure_sup], 5000) of
        [] -> ok;
        L when is_list(L) ->
            abort("~p hera_measure(s) running on ~s, reboot it first "
                  "(make reboot BOARDS=...)", [length(L), Node]);
        Other ->
            log("WARNING: cannot check the measures on ~s: ~0p", [Node, Other])
    end.

%% Starts uwb_twr on Node unless it already runs, then returns what is
%% needed to interpret the ranges later.
setup(Node, Role, Addr, #{pan_id := Pan, antd := Antd}) ->
    case rpc:call(Node, erlang, whereis, [uwb_twr], 5000) of
        undefined ->
            Start = case Role of tag -> start_tag; anchor -> start_anchor end,
            Cfg = #{short_addr => Addr, pan_id => Pan, tx_antd => Antd, rx_antd => Antd},
            case rpc:call(Node, uwb_twr, Start, [Cfg], 30000) of
                {ok, _} -> log("~s: started uwb_twr as ~s, address ~.16#", [Node, Role, Addr]);
                Err -> abort("~s: cannot start uwb_twr: ~0p", [Node, Err])
            end;
        Pid when is_pid(Pid) ->
            case rpc:call(Node, sys, get_state, [uwb_twr], 5000) of
                {_, #{addr := <<Addr:16>>}} ->
                    log("~s: uwb_twr already running, address ~.16#, reused", [Node, Addr]);
                {_, #{addr := <<Other:16>>}} ->
                    abort("~s: uwb_twr already runs with address ~.16#, not ~.16#; "
                          "reboot the board", [Node, Other, Addr]);
                Err ->
                    abort("~s: cannot read uwb_twr's state: ~0p", [Node, Err])
            end;
        Err ->
            abort("~s: ~0p", [Node, Err])
    end,
    TxAntd = case rpc:call(Node, pmod_uwb, read, [tx_antd], 5000) of
        #{tx_antd := <<V:16>>} -> V;
        #{tx_antd := V} when is_integer(V) -> V;
        _ -> null
    end,
    RxAntd = case rpc:call(Node, pmod_uwb, read, [lde_if], 5000) of
        #{lde_rxantd := V2} -> V2;
        _ -> null
    end,
    {RelName, RelVsn} = rpc:call(Node, init, script_id, [], 5000),
    log("~s: antenna delays tx ~p, rx ~p", [Node, TxAntd, RxAntd]),
    #{node => Node, role => Role, short_addr => Addr, pan_id => Pan,
      tx_antd => TxAntd, rx_antd => RxAntd,
      release => list_to_binary(RelName ++ "-" ++ RelVsn),
      uwb_arx2init => jsonable(rpc:call(Node, application, get_env,
                                        [hera, uwb_arx2init, false], 5000)),
      uwb_twr_md5 => case rpc:call(Node, uwb_twr, module_info, [md5], 5000) of
                         Md5 when is_binary(Md5) -> binary:encode_hex(Md5);
                         _ -> null
                     end}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Statistics and output
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

summarise(P, Dist, Note, Results, Start, End) ->
    Ds = [D || {ok, D, _} <- Results],
    Base = #{point => P, dist => Dist, note => Note, n => length(Results),
             ok => length(Ds), start => Start, 'end' => End},
    case Ds of
        [] ->
            Base;
        _ ->
            K = length(Ds),
            Mean = lists:sum(Ds) / K,
            Std = case K of
                1 -> 0.0;
                _ -> math:sqrt(lists:sum([(D - Mean) * (D - Mean) || D <- Ds]) / (K - 1))
            end,
            Base#{mean => Mean, std => Std, median => median(Ds),
                  min => lists:min(Ds), max => lists:max(Ds)}
    end.

median(L) ->
    S = lists:sort(L),
    K = length(S),
    case K rem 2 of
        1 -> lists:nth(K div 2 + 1, S);
        0 -> (lists:nth(K div 2, S) + lists:nth(K div 2 + 1, S)) / 2
    end.

print_summary(S = #{point := P, dist := Dist, n := N, ok := Ok}) ->
    case S of
        #{mean := M, std := Sd, median := Med} ->
            log("point ~p at ~.3f m: ~p/~p ok, mean ~.3f m, median ~.3f m, "
                "std ~.1f cm, error (mean - true) ~s cm",
                [P, Dist, Ok, N, M, Med, Sd * 100, signed((M - Dist) * 100)]);
        _ ->
            log("point ~p at ~.3f m: no successful range (~p attempts)", [P, Dist, N])
    end.

print_table([]) ->
    ok;
print_table(Summaries) ->
    io:format("~n~6s ~9s ~9s ~9s ~8s ~9s~n",
              ["point", "true m", "ok/n", "mean m", "std cm", "err cm"]),
    lists:foreach(fun(S = #{point := P, dist := D, n := N, ok := Ok}) ->
        OkN = io_lib:format("~p/~p", [Ok, N]),
        case S of
            #{mean := M, std := Sd} ->
                io:format("~6w ~9.3f ~9s ~9.3f ~8.1f ~9s~n",
                          [P, D, OkN, M, Sd * 100, signed((M - D) * 100)]);
            _ ->
                io:format("~6w ~9.3f ~9s ~9s ~8s ~9s~n", [P, D, OkN, "-", "-", "-"])
        end
    end, Summaries).

ranges_row(P, Dist, I, T, Ms, R) ->
    {Status, D, Ts} = case R of
        {ok, D0, Ts0} -> {"ok", fmt(D0), timestamps(Ts0)};
        {error, Reason} -> {term(Reason), "", timestamps(undefined)};
        {badrpc, Reason} -> {"badrpc:" ++ term(Reason), "", timestamps(undefined)}
    end,
    csv([integer_to_list(P), fmt(Dist), integer_to_list(I), integer_to_list(T),
         integer_to_list(Ms), Status, D] ++ Ts).

%% The six raw 40-bit timestamps, then the DS-TWR intervals in DW1000
%% time units (as uwb_twr:intervals/2).
timestamps(undefined) ->
    lists:duplicate(10, "");
timestamps({{PollTx, RespRx, FinalTx}, {PollRx, RespTx, FinalRx}}) ->
    Iv = fun(A, B) -> (B - A) band ?TS_MASK end,
    [integer_to_list(X) || X <- [PollTx, RespRx, FinalTx, PollRx, RespTx, FinalRx,
                                 Iv(PollTx, RespRx), Iv(PollRx, RespTx),
                                 Iv(RespTx, FinalRx), Iv(RespRx, FinalTx)]].

points_row(S = #{point := P, dist := Dist, n := N, ok := Ok, start := T0, 'end' := T1,
                 note := Note}) ->
    Stats = case S of
        #{mean := M, std := Sd, median := Med, min := Mn, max := Mx} ->
            [fmt(X) || X <- [M, Sd, Med, Mn, Mx, M - Dist]];
        _ ->
            lists:duplicate(6, "")
    end,
    csv([integer_to_list(P), fmt(Dist), integer_to_list(N), integer_to_list(Ok),
         integer_to_list(N - Ok)] ++ Stats ++
        [integer_to_list(T0), integer_to_list(T1), quote(Note)]).

write_meta(Dir, Meta) ->
    ok = file:write_file(filename:join(Dir, "meta.json"),
                         [json:format(Meta), "\n"]).

out_dir(#{out := undefined}) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
    Stamp = io_lib:format("~2..0w-~2..0w-~4w_~2..0w-~2..0w-~2..0w", [D, Mo, Y, H, Mi, S]),
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    filename:join([Root, "data", "uwb_ranging", lists:flatten(Stamp)]);
out_dir(#{out := Dir}) ->
    Dir.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse([], O) -> O;
parse(["--tag", V | R], O) -> parse(R, O#{tag := list_to_atom(V)});
parse(["--anchor", V | R], O) -> parse(R, O#{anchor := list_to_atom(V)});
parse(["--n", V | R], O) -> parse(R, O#{n := pos_int(V)});
parse(["--timeout", V | R], O) -> parse(R, O#{timeout := pos_int(V)});
parse(["--period", V | R], O) -> parse(R, O#{period := int(V)});
parse(["--antd", V | R], O) -> parse(R, O#{antd := int(V)});
parse(["--tag-addr", V | R], O) -> parse(R, O#{tag_addr := int(V)});
parse(["--anchor-addr", V | R], O) -> parse(R, O#{anchor_addr := int(V)});
parse(["--cookie", V | R], O) -> parse(R, O#{cookie := list_to_atom(V)});
parse(["--comment", V | R], O) -> parse(R, O#{comment := V});
parse(["--out", V | R], O) -> parse(R, O#{out := V});
parse([A | _], _) -> throw({usage, "unknown or incomplete option " ++ A}).

int("0x" ++ Hex) -> list_to_integer(Hex, 16);
int(S) ->
    try list_to_integer(S) catch error:badarg -> throw({usage, "not an integer: " ++ S}) end.

pos_int(S) ->
    case int(S) of
        N when N > 0 -> N;
        _ -> throw({usage, "not a positive integer: " ++ S})
    end.

to_number(S) ->
    case string:to_float(S) of
        {F, ""} -> {ok, F};
        _ ->
            case string:to_integer(S) of
                {I, ""} -> {ok, float(I)};
                _ -> error
            end
    end.

usage(Msg) ->
    io:format(standard_error, "uwb_ranging: ~s~n", [Msg]),
    io:format(standard_error,
              "Usage: uwb_ranging.escript [--tag Node] [--anchor Node] [--n N] "
              "[--timeout Ms] [--period Ms] [--antd V] [--tag-addr A] "
              "[--anchor-addr A] [--cookie C] [--comment Text] [--out Dir]~n", []).

csv(Fields) -> [lists:join(",", Fields), "\n"].

quote(S) -> [$", string:replace(S, "\"", "\"\"", all), $"].

signed(X) when X >= 0 -> io_lib:format("+~.1f", [X]);
signed(X) -> io_lib:format("~.1f", [X]).

fmt(F) when is_float(F) -> float_to_list(F, [short]);
fmt(I) when is_integer(I) -> integer_to_list(I).

%% An Erlang term as one CSV-safe field.
term(T) -> lists:flatten(string:replace(io_lib:format("~0p", [T]), ",", ";", all)).

%% Converts terms read from the boards into something json:format accepts.
jsonable(M) when is_map(M) -> maps:from_list([{jkey(K), jsonable(V)} || K := V <- M]);
jsonable(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> [jsonable(X) || X <- L]
    end;
jsonable(X) when is_atom(X); is_number(X) -> X;
jsonable(X) when is_binary(X) ->
    % Raw register bytes are not text: hex them.
    case unicode:characters_to_binary(X) of
        X -> X;
        _ -> binary:encode_hex(X)
    end;
jsonable(X) -> iolist_to_binary(io_lib:format("~0p", [X])).

jkey(K) when is_atom(K); is_binary(K) -> K;
jkey(K) -> iolist_to_binary(io_lib:format("~0p", [K])).

iso_now() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))).

log(Fmt, Args) ->
    io:format("[uwb_ranging] " ++ Fmt ++ "~n", Args).

abort(Fmt, Args) ->
    throw({abort, Fmt, Args}).
