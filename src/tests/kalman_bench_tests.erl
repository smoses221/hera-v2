-module(kalman_bench_tests).

-include_lib("eunit/include/eunit.hrl").

%% Runs the same fixture data and golden values as previous kalman_tests.erl file
%% (which exercises production kalman:kf/6 against the `mat` backend)
%% through kalman_bench:kf/7 instead, for every matrix backend under
%% test. This both (a) checks kalman_bench's parametrized equations
%% match kalman.erl's production behaviour, and (b) gives every
%% backend (`oldmat`, `blasmat`) the same correctness coverage.

-define(BACKENDS, [mat, oldmat, blasmat]).

kf_all_backends_test_() ->
    [{atom_to_list(Mod), fun() -> kf_backend(Mod) end} || Mod <- ?BACKENDS].

kf_backend(Mod) ->
    S = [-0.0139570, 0.0177654, -0.0043154, -0.0032242, -0.0011087, 0.0068842, 0.0127815, -0.0054593, 0.0172686],
    A = [-0.067219, -0.187752, 0.039476, -0.629077, 0.294998, -0.018021, -0.089338, 0.316988, -0.110355],
    X0 = mk_zeros(Mod, 3, 1),
    P0 = mk_zeros(Mod, 3, 3),
    {X9, P9} = kf_test_loop(Mod, {X0, P0}, S, A),

    TrueX9 = mk(Mod, [
        [-0.003818873411179362],
        [-0.0030451417563099863],
        [0.010728608371567826]
    ]),
    TrueP9 = mk(Mod, [
        [0.0011803595978981166,0.002838977349786346,0.003240423305540969],
        [0.0028389773497863456,0.008065893282913787,0.012971945407050236],
        [0.0032404233055409693,0.012971945407050232,0.036352205605987994]
    ]),

    ?assert(Mod:'=='(TrueX9, X9)),
    ?assert(Mod:'=='(TrueP9, P9)).

kf_test_loop(_Mod, State, [], []) ->
    State;
kf_test_loop(Mod, State, [S|Ss], [A|As]) ->
    DT = 0.1,
    EA = 0.01,
    VarA = 0.2,
    VarS = 0.01,

    F = mk(Mod, [[1,DT,0.5*DT*DT], [0,1,DT], [0,0,1]]),
    H = mk(Mod, [[1,0,0], [0,0,1]]),
    G = Mod:col(3, F),
    Q = Mod:eval([EA, '*', G, '*´', G]),
    R = mk(Mod, [[VarS,0], [0,VarA]]),
    Z = mk(Mod, [[S], [A]]),

    NewState = kalman_bench:kf(Mod, State, F, H, Q, R, Z),
    kf_test_loop(Mod, NewState, Ss, As).

%% Golden values from the former kalman_tests:ekf_test (production
%% kalman:ekf/6 on `mat`), run through kalman_bench:ekf/7 per backend.
ekf_all_backends_test_() ->
    [{atom_to_list(Mod), fun() -> ekf_backend(Mod) end} || Mod <- ?BACKENDS].

ekf_backend(Mod) ->
    A = [1.3076,1.8246,1.7409,1.5532,1.7215,1.6290,1.2415,2.0059,1.7394],
    X0 = mk(Mod, [[1]]),
    P0 = mk(Mod, [[1]]),
    {X9, P9} = ekf_test_loop(Mod, {X0, P0}, A),
    ?assertEqual(1.2855, round(Mod:get(1, 1, X9)*10000)/10000),
    ?assertEqual(0.0036, round(Mod:get(1, 1, P9)*10000)/10000).

ekf_test_loop(_Mod, State, []) ->
    State;
ekf_test_loop(Mod, State, [A|As]) ->
    F = fun(X) -> X end,
    Jf = fun(_) -> mk(Mod, [[1]]) end,
    H = fun(X11) -> Mod:'*'(X11, X11) end, % Radius*X11^2
    Jh = fun(X11) -> Mod:'*'(2, X11) end,  % 2*Radius*X11
    Q = mk(Mod, [[0]]),
    R = mk(Mod, [[0.2]]),
    Z = mk(Mod, [[A]]),

    NewState = kalman_bench:ekf(Mod, State, {F, Jf}, {H, Jh}, Q, R, Z),
    ekf_test_loop(Mod, NewState, As).

%% bench_runner's two paths (9x9 IMU KF, 9x9 UWB EKF) must end in the
%% same state on every backend as on the pure-Erlang `oldmat`
%% reference, which checks the model plumbing and each backend at once.
-define(AGREE_STEPS, 200).

bench_paths_agree_test_() ->
    [{atom_to_list(Mod) ++ " " ++ atom_to_list(Path),
      fun() -> bench_path_agrees(Mod, Path) end}
     || Mod <- ?BACKENDS, Mod =/= oldmat, Path <- [imu, uwb]].

bench_path_agrees(Mod, Path) ->
    {_, {XRef, PRef}} = bench_runner:run_path(oldmat, Path, ?AGREE_STEPS),
    {_, {X, P}} = bench_runner:run_path(Mod, Path, ?AGREE_STEPS),
    assert_close(to_list(oldmat, XRef), to_list(Mod, X)),
    assert_close(to_list(oldmat, PRef), to_list(Mod, P)).

assert_close(Expected, Actual) ->
    ?assertEqual(length(Expected), length(Actual)),
    [?assert(abs(E - A) =< 1.0e-6) || {E, A} <- lists:zip(Expected, Actual)],
    ok.

to_list(oldmat, M) -> lists:flatten(M);
to_list(Mod, M) -> Mod:to_array(M).

%% oldmat has no matrix/1 constructor: its matrix() type is already a
%% plain nested list, so construction is the identity for that backend.
mk(mat, L) -> mat:matrix(L);
mk(oldmat, L) -> L;
mk(blasmat, L) -> blasmat:matrix(L).

mk_zeros(Mod, N, M) -> Mod:zeros(N, M).
