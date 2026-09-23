-module(run_tests).

-export([run/1]).

%% Minimal standalone test runner for targets that don't have the
%% `eunit` application in their cross-built OTP image (`eunit:test/2`
%% then doesn't exist there). Reflects on a test module's exports to
%% find and run plain `..._test/0` functions and eunit test
%% generators (`..._test_/0`, returning a list of {Description, Fun}),
%% without depending on the `eunit` app at all.
%%
%% Usage (after pushing this module + the test modules themselves via
%% scripts/beam_to_paste.sh <module> test):
%%   run_tests:run([mat_tests, oldmat_tests, kalman_tests, kalman_bench_tests]).

run(Modules) when is_list(Modules) ->
    lists:foreach(fun run/1, Modules);
run(Module) ->
    io:format("=== ~p ===~n", [Module]),
    lists:foreach(fun(Export) -> maybe_run(Module, Export) end,
        Module:module_info(exports)).

maybe_run(Module, {F, 0}) ->
    Name = atom_to_list(F),
    case {lists:suffix("_test", Name), lists:suffix("_test_", Name)} of
        {true, false} ->
            run_case(io_lib:format("~p:~p", [Module, F]), fun() -> Module:F() end);
        {_, true} ->
            lists:foreach(
                fun({Desc, TestFun}) ->
                    run_case(io_lib:format("~p:~p (~s)", [Module, F, Desc]), TestFun)
                end,
                Module:F());
        _ ->
            ok
    end;
maybe_run(_Module, _Export) ->
    ok.

run_case(Label, Fun) ->
    io:format("  ~s...", [Label]),
    try
        Fun(),
        io:format("ok~n")
    catch
        Class:Reason:Stack ->
            io:format("FAILED~n    ~p:~p~n    ~p~n", [Class, Reason, Stack])
    end.
