-module(sim_live).

-export([main/1]).

%% One node of a live simulation, started by sim/run.py:
%%   erl -sname M -setcookie C -noshell -run sim_live main master <Dir> <T0> <TagNode>
%%   erl -sname T -setcookie C -noshell -run sim_live main tag    <Dir> <T0> <MasterNode>
%%
%% Both nodes run hera's supervision tree (hera_data, hera_com,
%% hera_measure_sup). hera_sup is started directly rather than the hera
%% application, whose dependencies (grisp, grisp_updater_grisp2) need
%% the board.
%%   master: replays nav.csv through sim_measure (as hera_nav would) and
%%           runs sim_fusion on what hera_data receives.
%%   tag:    replays uwb.csv through sim_measure (as hera_uwb would).
%% Samples are due at wall clock T0 + t (ms, erlang:system_time), the
%% same on both nodes since they share the host's clock. Each node halts
%% ?MARGIN_MS after the experiment's duration.

-define(MARGIN_MS, 2000).

main([Role, Dir, T0Str, PeerStr]) ->
    try run(list_to_existing_atom(Role), Dir, list_to_integer(T0Str), list_to_atom(PeerStr)) of
        _ -> halt(0)
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "sim_live ~s failed: ~p:~p~n~p~n", [Role, Class, Reason, Stack]),
            halt(1)
    end.

run(Role, Dir, T0, Peer) when Role =:= master; Role =:= tag ->
    Meta = sim_replay:read_json(filename:join(Dir, "meta.json")),
    Duration = round(maps:get(<<"duration">>, Meta) * 1000),
    process_flag(trap_exit, true),
    {ok, _} = hera_sup:start_link(),
    ok = connect(Peer, T0),
    Fusion = case Role of
        master ->
            Cfg = sim_replay:filter_cfg(Dir, Meta),
            sim_fusion:start(Cfg, T0, Dir, #{nav => node(), uwb => Peer});
        tag ->
            undefined
    end,
    Stream = case Role of master -> nav; tag -> uwb end,
    {ok, _} = hera:start_measure(sim_measure, #{
        file => filename:join(Dir, atom_to_list(Stream) ++ ".csv"),
        name => Stream, t0 => T0, dir => Dir}),
    sleep_until(T0 + Duration + ?MARGIN_MS),
    case Fusion of
        undefined -> ok;
        _ -> io:format("sim_live master: ~p~n", [sim_fusion:stop(Fusion)])
    end.

%% The peer is started at the same time; retry until T0.
connect(Peer, T0) ->
    case net_kernel:connect_node(Peer) of
        true ->
            ok;
        _ ->
            case erlang:system_time(millisecond) < T0 of
                true -> timer:sleep(100), connect(Peer, T0);
                false -> {error, {peer_unreachable, Peer}}
            end
    end.

sleep_until(Wall) ->
    case Wall - erlang:system_time(millisecond) of
        Ms when Ms > 0 -> timer:sleep(Ms);
        _ -> ok
    end.
