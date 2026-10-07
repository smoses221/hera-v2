#!/usr/bin/env escript
%% Run a grisp_updater action on several GRiSP boards in parallel over
%% distributed Erlang.
%%
%% Usage: grisp_fleet.escript Cookie Action [Arg] -- Node...
%%   Actions: update Url | reboot | validate | info

main([Cookie, Action | Rest]) ->
    {Args, ["--" | Nodes]} = lists:splitwith(fun(A) -> A =/= "--" end, Rest),
    Name = list_to_atom("grisp_fleet_" ++ os:getpid()),
    {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
    erlang:set_cookie(list_to_atom(Cookie)),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {self(), N, run(N, Action, Args)} end)
            || N <- [list_to_atom(N) || N <- Nodes]],
    Results = [receive {P, N, R} -> {N, R} end || P <- Pids],
    io:format("~n=== ~s summary ===~n", [Action]),
    Failed = [N || {N, R} <- Results, not report(N, R)],
    Reached = [N || {N, R} <- Results, R =/= {error, unreachable}],
    halt(case {Reached, Failed} of
        {[], _} -> io:format("No board reachable~n"), 1;
        {_, []} -> 0;
        _ -> 1
    end);
main(_) ->
    io:format("Usage: grisp_fleet.escript Cookie Action [Arg] -- Node...~n"),
    halt(2).

run(Node, Action, Args) ->
    case net_adm:ping(Node) of
        pang -> {error, unreachable};
        pong ->
            log(Node, "connected, running ~s", [Action]),
            call(Node, Action, Args)
    end.

call(Node, "update", [Url]) ->
    rpc:call(Node, grisp_updater, update, [list_to_binary(Url)], infinity);
call(Node, "reboot", []) ->
    % The board dies before replying, so do not wait for an answer
    rpc:cast(Node, init, reboot, []);
call(Node, "validate", []) ->
    rpc:call(Node, grisp_updater, validate, [], 10000);
call(Node, "info", []) ->
    % The running release {Name, Version}, from the board's boot script
    Release = rpc:call(Node, init, script_id, [], 10000),
    Info = rpc:call(Node, grisp_updater, info, [], 10000),
    {ok, #{release => Release, updater => Info}}.

report(Node, R) when R =:= ok; R =:= true ->
    log(Node, "OK", []), true;
report(Node, {ok, Info}) ->
    log(Node, "~p", [Info]), true;
report(Node, {error, unreachable}) ->
    log(Node, "skipped (unreachable)", []), true;
report(Node, {error, boot_system_not_validated}) ->
    log(Node, "FAILED: running an unvalidated update, run 'make validate' "
              "to keep it or 'make reboot' to roll back first", []), false;
report(Node, Error) ->
    log(Node, "FAILED: ~p", [Error]), false.

log(Node, Fmt, Args) ->
    io:format("[~s] " ++ Fmt ++ "~n", [Node | Args]).
