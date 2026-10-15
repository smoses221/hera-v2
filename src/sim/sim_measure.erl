-module(sim_measure).

-behaviour(hera_measure).

-export([init/1, measure/1]).

%% hera_measure that replays a simulated sensor (sim/generate.py) in
%% real time, in place of hera_nav or hera_uwb, for the live simulation
%% (sim_live). Everything after measure/1 is the real framework:
%% hera_measure -> hera_com (UDP multicast) -> hera_data.
%%
%% Each CSV row is `t, Values...`. measure/1 waits until the row's true
%% time, wall clock T0 + t, then returns Values, so samples leave when
%% the simulated sensor produced them. The payload is the same as the
%% real measure's ([Ax..Mz] for nav, [Index, Range] for uwb).
%%
%% To join what the master received with the truth, every sample sent is
%% logged as `seq,t,wall_ms` (sent_<name>.csv in Dir), with seq the
%% number hera_measure gives it. hera_measure doesn't tell its callback
%% the seq, so first_seq/1 computes it the same way (init_seq): 1 on a
%% fresh node, else one more than the last known on any node (a board
%% that already ran a `nav` measure since it booted).
%%
%% Options:
%%   file  the CSV          name  measure name (nav | uwb)
%%   t0    wall clock start, erlang:system_time(millisecond)
%%   dir   where to write the sent log

init(#{file := File, name := Name, t0 := T0, dir := Dir}) ->
    {_, Rows} = sim_replay:read_csv(File),
    {ok, #{rows => Rows, t0 => T0, seq => first_seq(Name), sent => [],
           log => filename:join(Dir, "sent_" ++ atom_to_list(Name) ++ ".csv")},
     #{name => Name, iter => length(Rows), timeout => 0}}.

measure(State = #{rows := [[T | Values] | Rest], t0 := T0, seq := Seq, sent := Sent}) ->
    Due = T0 + round(T * 1000),
    Wait = Due - erlang:system_time(millisecond),
    Wait > 0 andalso timer:sleep(Wait),
    Now = erlang:system_time(millisecond),
    NewState = State#{rows := Rest, seq := Seq + 1, sent := [{Seq, T, Now} | Sent]},
    Rest =:= [] andalso write_log(NewState),
    {ok, encode(Values), NewState}.

%% As hera_measure:init_seq/1, which runs right after init/1.
first_seq(Name) ->
    {Res, _} = rpc:multicall(hera_data, get, [Name, node()]),
    lists:max([0 | [S || [{_, S, _, _}] <- Res]]) + 1.

%% hera_uwb sends the anchor index as an integer.
encode([Index, Range]) -> [round(Index), Range];
encode(Values) -> Values.

write_log(#{log := Log, sent := Sent}) ->
    Rows = [[sim_replay:fmt(S), $,, sim_replay:fmt(T), $,, sim_replay:fmt(W), $\n]
            || {S, T, W} <- lists:reverse(Sent)],
    ok = file:write_file(Log, ["seq,t,wall_ms\n" | Rows]).
