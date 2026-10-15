-module(sim_replay).

-export([main/1, run/1, run/2, nav_only/1]).
-export([filter_cfg/2, read_csv/1, read_json/1, write_json/2]).
-export([estimate_header/0, estimate_row/2, fmt/1, erl_meta/1]).

%% Offline run of hera_fusion on a simulated experiment (sim/generate.py).
%% Reads from RunDir:
%%   meta.json    anchors and initial state (+ everything else, unused here)
%%   nav.csv      t,ax,ay,az,gx,gy,gz,mx,my,mz   (hera_nav's sample)
%%   uwb.csv      t,anchor,range                 (hera_uwb's sample)
%%   filter.json  optional overrides of hera_fusion:default_cfg/0
%% and replays every sample, in true-time order, into the filter. Writes:
%%   estimate.csv  one row per filter update (see estimate_header/0)
%%   erl_meta.json backend, OTP release, module md5s, effective config
%%
%% nav_only/1 is the NAV-only reference: the same filter, configuration
%% and initial state, fed only the NAV samples (no UWB correction, so no
%% planar pseudo-measurement either), written to estimate_nav_only.csv.
%% It shows how fast the IMU alone drifts. It doesn't depend on the run
%% mode, so live runs get it from their nav.csv too.
%%
%% Deterministic: the same inputs and the same BEAMs give byte-identical
%% estimate CSVs. erl_meta.json also holds the run's wall time, so it differs.
%%
%% From the shell: sim_replay:run(Dir), sim_replay:nav_only(Dir).
%% From sim/run.py: erl -noshell -run sim_replay main <RunDir> [nav_only]
%% (without nav_only: both; with it: only the NAV-only reference).

main(Args) ->
    try
        case Args of
            [RunDir] -> run(RunDir), nav_only(RunDir);
            [RunDir, "nav_only"] -> nav_only(RunDir)
        end
    of
        _ -> halt(0)
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "sim_replay failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

run(RunDir) ->
    run(RunDir, #{}).

run(RunDir, Overrides) ->
    Meta = read_json(filename:join(RunDir, "meta.json")),
    Cfg = filter_cfg(RunDir, Meta),
    Events = events(RunDir),
    Start = erlang:monotonic_time(microsecond),
    {Rows, Fusion} = replay(hera_fusion:new(maps:merge(Cfg, Overrides)), Events),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    ok = file:write_file(filename:join(RunDir, "estimate.csv"), [estimate_header() | Rows]),
    #{late := Late} = hera_fusion:estimate(Fusion),
    write_json(filename:join(RunDir, "erl_meta.json"),
        (erl_meta(hera_fusion:cfg(Fusion)))#{
            mode => offline, events => length(Events), late => Late,
            filter_wall_us => Elapsed}),
    #{events => length(Events), late => Late, filter_wall_us => Elapsed}.

nav_only(RunDir) ->
    Cfg = filter_cfg(RunDir, read_json(filename:join(RunDir, "meta.json"))),
    Events = [E || E = {_, nav, _} <- events(RunDir)],
    {Rows, _} = replay(hera_fusion:new(Cfg), Events),
    ok = file:write_file(filename:join(RunDir, "estimate_nav_only.csv"), [estimate_header() | Rows]),
    #{events => length(Events)}.

%% Folds the events into the filter: {one estimate row per event, filter}.
replay(Fusion0, Events) ->
    lists:mapfoldl(
        fun(Event, F0) ->
            F1 = apply_event(Event, F0),
            {estimate_row(element(2, Event), F1), F1}
        end, Fusion0, Events).

%% hera_fusion's configuration for this experiment: the defaults, then
%% the anchors and initial state from meta.json, then filter.json.
filter_cfg(RunDir, Meta) ->
    #{<<"anchors">> := Anchors, <<"init">> := Init} = Meta,
    FromMeta = #{
        anchors => maps:from_list(
            [{binary_to_integer(K), list_to_tuple([float(C) || C <- V])}
             || K := V <- Anchors]),
        x0 => [float(V) || V <- maps:get(<<"x0">>, Init)],
        yaw0 => float(maps:get(<<"yaw0">>, Init)),
        t0 => float(maps:get(<<"t0">>, Init, 0.0))},
    Overrides = case read_json_opt(filename:join(RunDir, "filter.json")) of
        undefined -> #{};
        Json -> json_cfg(Json)
    end,
    maps:merge(maps:merge(hera_fusion:default_cfg(), FromMeta), Overrides).

%% filter.json keys are hera_fusion's config keys.
json_cfg(Json) ->
    Known = maps:keys(hera_fusion:default_cfg()),
    maps:from_list(
        [begin
             Key = binary_to_existing_atom(K),
             lists:member(Key, Known) orelse error({unknown_filter_key, K}),
             {Key, json_value(Key, V)}
         end || K := V <- Json]).

json_value(backend, V) -> binary_to_existing_atom(V);
json_value(planar, false) -> false;
json_value(planar, [Pz, Vz]) -> {float(Pz), float(Vz)};
json_value(anchors, V) ->
    maps:from_list([{binary_to_integer(K), list_to_tuple([float(C) || C <- P])} || K := P <- V]);
json_value(_, V) when is_list(V) -> [float(X) || X <- V];
json_value(_, V) when is_number(V) -> float(V).

%% All samples, in true-time order: NAV before UWB at equal times.
events(RunDir) ->
    {_, Nav} = read_csv(filename:join(RunDir, "nav.csv")),
    {_, Uwb} = read_csv(filename:join(RunDir, "uwb.csv")),
    Tagged = [{T, nav, Vs} || [T | Vs] <- Nav] ++
             [{T, uwb, {round(I), R}} || [T, I, R] <- Uwb],
    lists:sort(fun({Ta, Sa, _}, {Tb, Sb, _}) -> {Ta, Sa} =< {Tb, Sb} end, Tagged).

apply_event({T, nav, Values}, F) -> hera_fusion:nav(F, T, Values);
apply_event({T, uwb, {Index, Range}}, F) -> hera_fusion:uwb(F, T, Index, Range).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Shared with the live simulation (sim_fusion, sim_measure)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

estimate_header() ->
    <<"t,src,px,vx,ax,py,vy,ay,pz,vz,az,pxx,pxy,pyy,pzz,yaw\n">>.

estimate_row(Src, F) ->
    #{t := T, x := X, p_pos := {Pxx, Pxy, Pyy, Pzz}, yaw := Yaw} = hera_fusion:estimate(F),
    [lists:join($,, [fmt(T), atom_to_binary(Src)] ++ [fmt(V) || V <- X ++ [Pxx, Pxy, Pyy, Pzz, Yaw]]), $\n].

fmt(V) when is_integer(V) -> integer_to_binary(V);
fmt(V) -> float_to_binary(V, [short]).

%% {Header, Rows}: a CSV of numbers with one header line.
read_csv(File) ->
    {ok, Bin} = file:read_file(File),
    [Header | Lines] = binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global, trim_all]),
    {binary:split(Header, <<",">>, [global]),
     [[num(C) || C <- binary:split(L, <<",">>, [global])] || L <- Lines]}.

%% Numbers as Python writes them: 1, 1.5, 1e-05, 1.5e-05, nan is not used.
num(B) ->
    try binary_to_float(B)
    catch error:badarg ->
        try float(binary_to_integer(B))
        catch error:badarg ->
            [M, E] = binary:split(string:lowercase(B), <<"e">>),
            binary_to_float(<<M/binary, ".0e", E/binary>>)
        end
    end.

read_json(File) ->
    {ok, Bin} = file:read_file(File),
    json:decode(Bin).

read_json_opt(File) ->
    case filelib:is_regular(File) of
        true -> read_json(File);
        false -> undefined
    end.

write_json(File, Term) ->
    file:write_file(File, [json:format(jsonable(Term)), $\n]).

%% Versions of everything that produced an estimate, to find a run's
%% code again: the md5s identify the BEAMs even with a dirty tree.
erl_meta(Cfg = #{backend := Backend}) ->
    Mods = [hera_fusion, kalman_bench, Backend, ?MODULE, sim_fusion, sim_measure],
    #{backend => Backend,
      otp_release => list_to_binary(erlang:system_info(otp_release)),
      erts_version => list_to_binary(erlang:system_info(version)),
      module_md5 => maps:from_list(
          [{M, binary:encode_hex(M:module_info(md5), lowercase)} || M <- Mods]),
      filter_cfg => Cfg,
      run_at => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second)))}.

jsonable(M) when is_map(M) ->
    maps:from_list([{json_key(K), jsonable(V)} || K := V <- M]);
jsonable(L) when is_list(L) -> [jsonable(V) || V <- L];
jsonable(T) when is_tuple(T) -> jsonable(tuple_to_list(T));
jsonable(V) when is_atom(V), V =/= true, V =/= false, V =/= null -> atom_to_binary(V);
jsonable(V) -> V.

json_key(K) when is_atom(K) -> atom_to_binary(K);
json_key(K) when is_integer(K) -> integer_to_binary(K);
json_key(K) -> K.
