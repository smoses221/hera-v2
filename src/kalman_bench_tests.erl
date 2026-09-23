-module(kalman_bench_tests).

-include_lib("eunit/include/eunit.hrl").

%% Runs the same fixture data and golden values as kalman_tests.erl
%% (which exercises production kalman:kf/6 against the `mat` backend)
%% through kalman_bench:kf/7 instead, for every matrix backend under
%% test. This both (a) checks kalman_bench's parametrized equations
%% match kalman.erl's production behaviour, and (b) gives every
%% backend (starting with `oldmat`) the same correctness coverage.

-define(BACKENDS, [mat, oldmat]).

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

%% oldmat has no matrix/1 constructor: its matrix() type is already a
%% plain nested list, so construction is the identity for that backend.
mk(mat, L) -> mat:matrix(L);
mk(oldmat, L) -> L.

mk_zeros(Mod, N, M) -> Mod:zeros(N, M).
