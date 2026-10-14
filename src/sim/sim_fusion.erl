-module(sim_fusion).

-export([start/4, stop/1]).

%% Live consumer of the simulation (sim_live), on the master node: runs
%% hera_fusion on what reaches hera_data, as a filter on the board would
%% with the step-1 framework. This is the baseline, flaws included:
%%   - hera_data keeps only the latest sample per (name, node), so it is
%%     polled (every ?POLL_MS) and anything overwritten in between is
%%     lost; lost samples show as gaps in seq.
%%   - the time given to the filter is hera_data's timestamp, taken when
%%     the sample arrived (receiver clock), not when it was measured.
%%   - the master's own NAV samples reach it only through the multicast
%%     loopback.
%%
%% Only samples from Sources (#{nav => Node, uwb => Node}) are used:
%% hera_com multicasts on the LAN, so real boards running hera would
%% otherwise feed the simulation. Others are counted in `foreign`.
%%
%% Times are in seconds since the run's T0 (wall clock, ms), the same
%% time base as the simulation's truth.
%%
%% Writes in Dir: estimate.csv (as sim_replay), received.csv
%% (name,node,seq,t,wall_ms: every sample processed) and erl_meta.json.

-define(POLL_MS, 1).
-define(STREAMS, [nav, uwb]).

start(Cfg, T0, Dir, Sources) ->
    spawn_link(fun() -> init(Cfg, T0, Dir, Sources) end).

%% Stops the consumer, writes its files and returns its counters.
stop(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! {stop, self()},
    receive
        {stopped, Pid, Stats} -> demonitor(Ref, [flush]), Stats;
        {'DOWN', Ref, process, Pid, Reason} -> error({sim_fusion_died, Reason})
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Cfg, T0, Dir, Sources) ->
    %% hera_data's timestamps are monotonic ms; the run's T0 is system ms.
    Offset = erlang:time_offset(millisecond) - T0,
    loop(#{fusion => hera_fusion:new(Cfg), offset => Offset, dir => Dir, sources => Sources,
           foreign => #{}, last => #{}, gaps => #{}, received => #{},
           rows => [], log => [], polls => 0}).

loop(S) ->
    receive
        {stop, From} ->
            Stats = finish(S),
            From ! {stopped, self(), Stats}
    after ?POLL_MS ->
        loop(poll(S))
    end.

%% New samples of every stream, applied in hera_data timestamp order.
poll(S = #{last := Last, offset := Offset, polls := Polls, sources := Sources}) ->
    All = [{Name, Sample} || Name <- ?STREAMS, Sample <- hera_data:get(Name)],
    {Ours, Foreign} = lists:partition(
        fun({Name, {Node, _, _, _}}) -> maps:get(Name, Sources) =:= Node end, All),
    New = [{(T + Offset) / 1000, Name, Node, Seq, Values}
           || {Name, {Node, Seq, T, Values}} <- Ours,
              Seq > maps:get({Name, Node}, Last, 0)],
    S1 = S#{polls := Polls + 1,
            foreign := maps:merge(maps:get(foreign, S),
                                  maps:from_list([{Node, true} || {_, {Node, _, _, _}} <- Foreign]))},
    lists:foldl(fun apply_sample/2, S1, lists:sort(New)).

apply_sample({T, Name, Node, Seq, Values}, S) ->
    #{fusion := F0, last := Last, gaps := Gaps, received := Rec, rows := Rows, log := Log} = S,
    Key = {Name, Node},
    Prev = maps:get(Key, Last, 0),
    F1 = case {Name, Values} of
        {nav, _} -> hera_fusion:nav(F0, T, Values);
        {uwb, [Index, Range]} -> hera_fusion:uwb(F0, T, Index, Range)
    end,
    Wall = erlang:system_time(millisecond),
    S#{fusion := F1,
       last := Last#{Key => Seq},
       gaps := Gaps#{Name => maps:get(Name, Gaps, 0) + (Seq - Prev - 1)},
       received := Rec#{Name => maps:get(Name, Rec, 0) + 1},
       rows := [sim_replay:estimate_row(Name, F1) | Rows],
       log := [[atom_to_binary(Name), $,, atom_to_binary(Node), $,,
                sim_replay:fmt(Seq), $,, sim_replay:fmt(T), $,, sim_replay:fmt(Wall), $\n] | Log]}.

finish(#{fusion := F, dir := Dir, rows := Rows, log := Log,
         gaps := Gaps, received := Rec, polls := Polls, foreign := Foreign}) ->
    ok = file:write_file(filename:join(Dir, "estimate.csv"),
                         [sim_replay:estimate_header() | lists:reverse(Rows)]),
    ok = file:write_file(filename:join(Dir, "received.csv"),
                         ["name,node,seq,t,wall_ms\n" | lists:reverse(Log)]),
    #{late := Late} = hera_fusion:estimate(F),
    Stats = #{received => Rec, seq_gaps => Gaps, late => Late, polls => Polls,
              foreign_nodes => maps:keys(Foreign)},
    sim_replay:write_json(filename:join(Dir, "erl_meta.json"),
        maps:merge(sim_replay:erl_meta(hera_fusion:cfg(F)), Stats#{mode => live})),
    Stats.
