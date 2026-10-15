-module(sim_board).

-export([main/1, run/2]).

%% Host side of a simulation run on two GRiSP boards (mode board), started
%% by sim/run.py:
%%   erl -sname sim_host_<pid> -hidden -setcookie grisp -noshell \
%%       -run sim_board main <RunDir> <MasterNode> <TagNode> [load] [root=<Dir>]
%% root is the folder on the boards' SD card (default ?BOARD_ROOT).
%%
%% The run directory already holds the generated scenario (sim/generate.py).
%% The boards must run the hera application (the deployed release) with no
%% measure started. Steps:
%%   1. connect to both boards and check them: same OTP release, hera_data
%%      and hera_com running, no hera_measure running;
%%   2. check that the boards run the same simulation code as this host
%%      (module md5s). With `load`, load this host's BEAMs onto them
%%      instead (same OTP release needed; not persistent: a reboot goes
%%      back to the deployed release);
%%   3. measure each board's clock offset to this host (round trips over
%%      distribution; the one with the shortest round trip is kept);
%%   4. copy meta.json, filter.json and the board's CSV to its SD card, in
%%      ?CHUNK pieces (large messages have dropped the Wi-Fi link before);
%%   5. start sim_live:board/4 on both boards at the same instant, T0 given
%%      in each board's own clock;
%%   6. wait for both done.json files, fetch the results in ?CHUNK pieces,
%%      and delete the run's folder on the boards.
%% Writes board_meta.json (nodes, releases, clock offsets, code loaded or
%% not) next to the results, and marks erl_meta.json as mode board.

-define(CHUNK, 32768).
-define(START_DELAY_MS, 5000).     % from the start command to T0
-define(DONE_TIMEOUT_MS, 120000).  % after the end of the scenario
-define(RPC_TIMEOUT, 15000).
-define(CLOCK_SAMPLES, 20).
-define(BOARD_ROOT, "/sim").
-define(SIM_MODULES, [hera_fusion, kalman_bench, sim_replay, sim_measure, sim_fusion, sim_live]).

main([RunDir, Master, Tag | Opts]) ->
    Root = hd([R || "root=" ++ R <- Opts] ++ [?BOARD_ROOT]),
    try run(RunDir, #{master => list_to_atom(Master), tag => list_to_atom(Tag),
                      load => lists:member("load", Opts), root => Root}) of
        _ -> halt(0)
    catch
        throw:{abort, Msg} ->
            io:format(standard_error, "sim_board: ~s~n", [Msg]),
            halt(2);
        Class:Reason:Stack ->
            io:format(standard_error, "sim_board failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

run(RunDir, #{master := Master, tag := Tag, load := Load, root := Root}) ->
    Nodes = [Master, Tag],
    [connect(N) || N <- Nodes],
    [check(N) || N <- Nodes],
    Loaded = code_on_boards(Nodes, Load),
    Clocks = maps:from_list([{N, clock_offset(N)} || N <- Nodes]),
    [log("~p: clock offset ~p ms (round trip ~.1f ms)",
         [N, maps:get(offset_ms, C), maps:get(rtt_us, C) / 1000]) || N := C <- Clocks],

    Meta = sim_replay:read_json(filename:join(RunDir, "meta.json")),
    Duration = round(maps:get(<<"duration">>, Meta) * 1000),
    #{backend := Backend} = sim_replay:filter_cfg(RunDir, Meta),
    check_backend(Master, Backend),
    BoardDir = Root ++ "/" ++ run_name(RunDir),
    Common = ["meta.json"] ++ [F || F <- ["filter.json"], filelib:is_regular(filename:join(RunDir, F))],
    upload(Master, RunDir, BoardDir, Common ++ ["nav.csv"]),
    upload(Tag, RunDir, BoardDir, Common ++ ["uwb.csv"]),

    T0 = erlang:system_time(millisecond) + ?START_DELAY_MS,
    BoardT0 = fun(N) -> T0 + maps:get(offset_ms, maps:get(N, Clocks)) end,
    spawn(Master, sim_live, board, [master, BoardDir, BoardT0(Master), Tag]),
    spawn(Tag, sim_live, board, [tag, BoardDir, BoardT0(Tag), Master]),
    log("started, T0 in ~p s, the scenario lasts ~p s", [?START_DELAY_MS div 1000, Duration div 1000]),

    Deadline = T0 + Duration + ?DONE_TIMEOUT_MS,
    Done = maps:from_list([{N, wait_done(N, BoardDir, T0 + Duration, Deadline)} || N <- Nodes]),
    Errors = [{N, Err} || N := #{<<"status">> := <<"error">>, <<"error">> := Err} <- Done],
    Errors =:= [] orelse
        throw({abort, ["a board failed (its files stay in ", BoardDir, "):\n",
                       [io_lib:format("~p: ~s~n", [N, E]) || {N, E} <- Errors]]}),

    fetch(Master, BoardDir, RunDir, ["estimate.csv", "received.csv", "erl_meta.json", "sent_nav.csv"]),
    fetch(Tag, BoardDir, RunDir, ["sent_uwb.csv"]),
    [ok = rpc(N, file, del_dir_r, [BoardDir]) || N <- Nodes],

    ErlMeta = sim_replay:read_json(filename:join(RunDir, "erl_meta.json")),
    sim_replay:write_json(filename:join(RunDir, "erl_meta.json"), ErlMeta#{<<"mode">> => board}),
    sim_replay:write_json(filename:join(RunDir, "board_meta.json"), #{
        master => Master, tag => Tag, code_loaded_from_host => Loaded,
        clock => Clocks, board_dir => list_to_binary(BoardDir),
        releases => maps:from_list([{N, release(N)} || N <- Nodes]),
        done => Done}),
    log("done, results in ~s", [RunDir]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Checks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect(Node) ->
    net_kernel:connect_node(Node) orelse
        throw({abort, io_lib:format("cannot reach ~p (board on? same cookie? try `make info`)", [Node])}),
    log("~p: connected", [Node]).

check(Node) ->
    Otp = rpc(Node, erlang, system_info, [otp_release]),
    Otp =:= erlang:system_info(otp_release) orelse
        throw({abort, io_lib:format("~p runs OTP ~s, this host ~s", [Node, Otp, erlang:system_info(otp_release)])}),
    [is_pid(rpc(Node, erlang, whereis, [P])) orelse
         throw({abort, io_lib:format("~p: ~p is not running (is the hera release running?)", [Node, P])})
     || P <- [hera_data, hera_com, hera_measure_sup]],
    case rpc(Node, supervisor, which_children, [hera_measure_sup]) of
        [] -> ok;
        Children ->
            throw({abort, io_lib:format(
                "~p: ~p hera_measure(s) running; a real nav/uwb measure would mix with the "
                "simulation. Reboot the board (make reboot) or stop them.", [Node, length(Children)])})
    end.

%% The filter's matrix backend (its NIF) must work on the master.
check_backend(Node, Backend) ->
    case rpc:call(Node, Backend, eye, [2], ?RPC_TIMEOUT) of
        {badrpc, Reason} ->
            throw({abort, io_lib:format("~p: matrix backend ~p doesn't work: ~p", [Node, Backend, Reason])});
        _ ->
            log("~p: matrix backend ~p works", [Node, Backend])
    end.

%% The simulation modules must be the same on the boards as here, so the
%% run is traceable to this host's commit.
code_on_boards(Nodes, Load) ->
    Diff = [{N, M} || N <- Nodes, M <- ?SIM_MODULES, md5(N, M) =/= M:module_info(md5)],
    case {Diff, Load} of
        {[], _} ->
            log("boards run the same simulation code as this host", []),
            false;
        {_, false} ->
            throw({abort, io_lib:format(
                "the boards' code differs from this host's: ~p~n"
                "Deploy the current commit (make release) or pass --load-code.", [Diff])});
        {_, true} ->
            [load(N, M) || {N, M} <- Diff],
            [] = [{N, M} || N <- Nodes, M <- ?SIM_MODULES, md5(N, M) =/= M:module_info(md5)],
            log("loaded ~p module(s) onto the boards (until their next reboot)", [length(Diff)]),
            true
    end.

md5(Node, Mod) ->
    case rpc:call(Node, Mod, module_info, [md5], ?RPC_TIMEOUT) of
        {badrpc, _} -> missing;
        Md5 -> Md5
    end.

load(Node, Mod) ->
    {Mod, Bin, File} = code:get_object_code(Mod),
    _ = rpc(Node, code, purge, [Mod]),
    {module, Mod} = rpc(Node, code, load_binary, [Mod, File, Bin]).

release(Node) ->
    {Name, Vsn} = rpc(Node, init, script_id, []),
    #{release => list_to_binary(Name ++ " " ++ Vsn),
      hera_vsn => case rpc(Node, application, get_key, [hera, vsn]) of
                      {ok, V} -> list_to_binary(V);
                      _ -> undefined
                  end}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Clock offset
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Board clock minus host clock (erlang:system_time), from the round trip
%% with the shortest duration: the board read its clock somewhere inside
%% it, so the error is at most half that round trip.
clock_offset(Node) ->
    Samples = [begin
                   H1 = erlang:system_time(microsecond),
                   B = rpc(Node, erlang, system_time, [microsecond]),
                   H2 = erlang:system_time(microsecond),
                   {H2 - H1, B - (H1 + H2) div 2}
               end || _ <- lists:seq(1, ?CLOCK_SAMPLES)],
    {Rtt, Offset} = lists:min(Samples),
    #{offset_ms => round(Offset / 1000), offset_us => Offset, rtt_us => Rtt,
      max_error_ms => Rtt / 2000, samples => ?CLOCK_SAMPLES}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Files
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% <experiment>_<run>, e.g. 003_2026-10-15_abc1234_circle_s1_board.
run_name(RunDir) ->
    Abs = filename:absname(RunDir),
    filename:basename(filename:dirname(Abs)) ++ "_" ++ filename:basename(Abs).

upload(Node, RunDir, BoardDir, Files) ->
    _ = rpc(Node, file, del_dir_r, [BoardDir]),
    ok = rpc(Node, filelib, ensure_path, [BoardDir]),
    [begin
         {ok, Bin} = file:read_file(filename:join(RunDir, F)),
         Dest = BoardDir ++ "/" ++ F,
         ok = rpc(Node, file, write_file, [Dest, <<>>]),
         [ok = rpc(Node, file, write_file, [Dest, Chunk, [append]]) || Chunk <- chunks(Bin)],
         Size = rpc(Node, filelib, file_size, [Dest]),
         Size =:= byte_size(Bin) orelse error({upload_size, Node, F, Size, byte_size(Bin)})
     end || F <- Files],
    log("~p: copied ~s to ~s", [Node, lists:join(", ", Files), BoardDir]).

chunks(<<Chunk:?CHUNK/binary, Rest/binary>>) -> [Chunk | chunks(Rest)];
chunks(<<>>) -> [];
chunks(Last) -> [Last].

fetch(Node, BoardDir, RunDir, Files) ->
    [begin
         Src = BoardDir ++ "/" ++ F,
         Size = rpc(Node, filelib, file_size, [Src]),
         Bin = iolist_to_binary(
             [begin {ok, B} = rpc(Node, sim_live, read_chunk, [Src, Off, ?CHUNK]), B end
              || Off <- lists:seq(0, max(Size - 1, 0), ?CHUNK), Size > 0]),
         byte_size(Bin) =:= Size orelse error({fetch_size, Node, F, byte_size(Bin), Size}),
         ok = file:write_file(filename:join(RunDir, F), Bin)
     end || F <- Files],
    log("~p: fetched ~s", [Node, lists:join(", ", Files)]).

wait_done(Node, BoardDir, End, Deadline) ->
    sleep_until(End),
    wait_done(Node, BoardDir ++ "/done.json", Deadline).

wait_done(Node, File, Deadline) ->
    case rpc:call(Node, file, read_file, [File], ?RPC_TIMEOUT) of
        {ok, Bin} ->
            json:decode(Bin);
        _ ->
            erlang:system_time(millisecond) < Deadline orelse
                throw({abort, io_lib:format("~p: no ~s before the timeout", [Node, File])}),
            timer:sleep(1000),
            wait_done(Node, File, Deadline)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

rpc(Node, M, F, A) ->
    case rpc:call(Node, M, F, A, ?RPC_TIMEOUT) of
        {badrpc, Reason} -> throw({abort, io_lib:format("~p: ~p:~p failed: ~p", [Node, M, F, Reason])});
        Result -> Result
    end.

sleep_until(Wall) ->
    case Wall - erlang:system_time(millisecond) of
        Ms when Ms > 0 -> timer:sleep(Ms);
        _ -> ok
    end.

log(Fmt, Args) ->
    io:format("[sim_board] " ++ Fmt ++ "~n", Args).
