-module(kfblas_tests).

-include_lib("eunit/include/eunit.hrl").

%% Correctness of the mutable-filter backends, kfblas (whole step in one
%% NIF call) and blasws (one erlef/blas call per operation, reused
%% buffers). They share an API, so every case runs once per engine.
%% They don't fit the Mod:'*' matrix API of mat_tests/kalman_bench_tests,
%% hence this separate module. Reference results are the same golden
%% values as kalman_bench_tests and the oldmat backend.

-define(ENGINES, [kfblas, blasws]).
-define(AGREE_STEPS, 200).

%% Same data and golden values as kalman_bench_tests:kf_backend/1.
kf_golden_test_() -> each_engine(fun kf_golden/1).

kf_golden(Eng) ->
    S = [-0.0139570, 0.0177654, -0.0043154, -0.0032242, -0.0011087, 0.0068842, 0.0127815, -0.0054593, 0.0172686],
    A = [-0.067219, -0.187752, 0.039476, -0.629077, 0.294998, -0.018021, -0.089338, 0.316988, -0.110355],
    Filter = kf_golden_filter(Eng),
    kf_golden_run(Eng, Filter, S, A),
    {X9, P9} = Eng:get_state(Filter),
    assert_close([-0.003818873411179362, -0.0030451417563099863, 0.010728608371567826], floats(X9)),
    assert_close([0.0011803595978981166,0.002838977349786346,0.003240423305540969,
                  0.0028389773497863456,0.008065893282913787,0.012971945407050236,
                  0.0032404233055409693,0.012971945407050232,0.036352205605987994], floats(P9)).

kf_golden_filter(Eng) ->
    DT = 0.1,
    EA = 0.01,
    F = [[1,DT,0.5*DT*DT], [0,1,DT], [0,0,1]],
    G = [0.5*DT*DT, DT, 1],              % column 3 of F
    Q = [[EA*Gi*Gj || Gj <- G] || Gi <- G],
    Filter = Eng:new(3, 2),
    ok = Eng:set_model(Filter, f64(F), f64(Q)),
    ok = Eng:set_state(Filter, f64([0,0,0]), f64(lists:duplicate(9, 0))),
    Filter.

kf_golden_run(_Eng, _Filter, [], []) ->
    ok;
kf_golden_run(Eng, Filter, [S|Ss], [A|As]) ->
    H = f64([[1,0,0], [0,0,1]]),
    R = f64([[0.01,0], [0,0.2]]),
    ok = Eng:kf_step(Filter, H, R, f64([S, A])),
    kf_golden_run(Eng, Filter, Ss, As).

%% Same data and golden values as kalman_bench_tests:ekf_backend/1:
%% x' = x, h(x) = x^2, the model evaluated in Erlang between
%% ekf_predict/1 and ekf_update/5.
ekf_golden_test_() -> each_engine(fun ekf_golden/1).

ekf_golden(Eng) ->
    A = [1.3076,1.8246,1.7409,1.5532,1.7215,1.6290,1.2415,2.0059,1.7394],
    Filter = Eng:new(1, 1),
    ok = Eng:set_model(Filter, f64([1]), f64([0])),
    ok = Eng:set_state(Filter, f64([1]), f64([1])),
    [begin
         <<Xp:64/native-float>> = Eng:ekf_predict(Filter),
         ok = Eng:ekf_update(Filter, f64([2*Xp]), f64([Xp*Xp]), f64([0.2]), f64([Z]))
     end || Z <- A],
    {<<X9:64/native-float>>, <<P9:64/native-float>>} = Eng:get_state(Filter),
    ?assertEqual(1.2855, round(X9*10000)/10000),
    ?assertEqual(0.0036, round(P9*10000)/10000).

%% predict/1 + update/4 must give the same result as kf_step/4.
split_step_test_() -> each_engine(fun split_step/1).

split_step(Eng) ->
    H = f64([[1,0,0], [0,0,1]]),
    R = f64([[0.01,0], [0,0.2]]),
    Z = f64([0.3, -0.1]),
    Fused = kf_golden_filter(Eng),
    Split = kf_golden_filter(Eng),
    ok = Eng:kf_step(Fused, H, R, Z),
    ok = Eng:predict(Split),
    ok = Eng:update(Split, H, R, Z),
    {XF, PF} = Eng:get_state(Fused),
    {XS, PS} = Eng:get_state(Split),
    assert_close(floats(XF), floats(XS)),
    assert_close(floats(PF), floats(PS)).

%% Resetting a used filter with set_state/3 gives exactly what a fresh
%% filter gives: nothing is left behind in the reused buffers.
reuse_test_() -> each_engine(fun reuse/1).

reuse(Eng) ->
    S = [0.01, -0.02, 0.03],
    A = [0.1, 0.2, -0.3],
    Fresh = kf_golden_filter(Eng),
    kf_golden_run(Eng, Fresh, S, A),
    Reused = kf_golden_filter(Eng),
    kf_golden_run(Eng, Reused, [1.0, 2.0], [3.0, -4.0]),
    ok = Eng:set_state(Reused, f64([0,0,0]), f64(lists:duplicate(9, 0))),
    kf_golden_run(Eng, Reused, S, A),
    ?assertEqual(Eng:get_state(Fresh), Eng:get_state(Reused)).

%% bench_runner's 9x9 paths must end in the same state as on the
%% pure-Erlang oldmat backend. kfblas's range model in C (uwb_range)
%% must match oldmat's Erlang EKF (uwb) too.
bench_paths_agree_test_() ->
    [{atom_to_list(Eng) ++ " " ++ atom_to_list(Path),
      fun() -> bench_path_agrees(Eng, Path, Path) end}
     || Eng <- ?ENGINES, Path <- [imu, uwb]]
    ++ [{"kfblas uwb_range", fun() -> bench_path_agrees(kfblas, uwb_range, uwb) end}].

bench_path_agrees(Eng, Path, RefPath) ->
    {_, {XRef, PRef}} = bench_runner:run_path(oldmat, RefPath, ?AGREE_STEPS),
    {_, {X, P}} = bench_runner:run_path(Eng, Path, ?AGREE_STEPS),
    assert_close(lists:flatten(XRef), X),
    assert_close(lists:flatten(PRef), P).

%% S = H P H' + R that isn't positive definite is reported, not crashed on.
not_pos_def_test() ->
    Filter = kfblas:new(2, 2),
    ok = kfblas:set_state(Filter, f64([0, 0]), f64([0, 0, 0, 0])),
    ?assertEqual({error, not_positive_definite},
                 kfblas:update(Filter, f64([[1,0], [0,1]]), f64([[-1,0], [0,-1]]), f64([1, 1]))).

%% Helpers

each_engine(TestFun) ->
    [{atom_to_list(Eng), fun() -> TestFun(Eng) end} || Eng <- ?ENGINES].

assert_close(Expected, Actual) ->
    ?assertEqual(length(Expected), length(Actual)),
    [?assert(abs(E - A) =< 1.0e-6) || {E, A} <- lists:zip(Expected, Actual)],
    ok.

f64(L) ->
    << <<(float(X)):64/native-float>> || X <- lists:flatten(L) >>.

floats(Bin) ->
    [X || <<X:64/native-float>> <= Bin].
