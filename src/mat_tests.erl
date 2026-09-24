-module(mat_tests).

-include_lib("eunit/include/eunit.hrl").

%% Runs the same matrix test cases against every matrix backend under
%% test. Each `..._test_/0` is an eunit generator returning one
%% {BackendName, Fun} per backend (also understood by run_tests.erl).

% to print matrix     io:format(user, "~20p~n", [numerl:mtfli(P3)]),

-define(BACKENDS, [mat, oldmat]).


tr_test_() -> each_backend(fun tr/1).

tr(Mod) ->
    M1 = mk(Mod, [[1]]),
    ?assertEqual(M1, Mod:tr(M1)),

    M2 = mk(Mod, [[1,2], [3,4]]),
    ?assertEqual(mk(Mod, [[1,3], [2,4]]), Mod:tr(M2)),

    M3 = mk(Mod, [[1,2,3], [4,5,6], [7,8,9]]),
    M3t = mk(Mod, [[1,4,7], [2,5,8], [3,6,9]]),
    ?assertEqual(M3t, Mod:tr(M3)),

    M12 = mk(Mod, [[1,2]]),
    ?assertEqual(mk(Mod, [[1], [2]]), Mod:tr(M12)),

    M21 = mk(Mod, [[1], [2]]),
    ?assertEqual(mk(Mod, [[1,2]]), Mod:tr(M21)),

    M23 = mk(Mod, [[1,2,3], [4,5,6]]),
    M23t = mk(Mod, [[1,4], [2,5], [3,6]]),
    ?assertEqual(M23t, Mod:tr(M23)),

    M32 = mk(Mod, [[1,2], [3,4], [5,6]]),
    M32t = mk(Mod, [[1,3,5], [2,4,6]]),
    ?assertEqual(M32t, Mod:tr(M32)).


'+_test_'() -> each_backend(fun plus/1).

plus(Mod) ->
    S1 = Mod:'+'(mk(Mod, [[1]]), mk(Mod, [[1]])),
    ?assertEqual(mk(Mod, [[2]]), S1),

    S2 = Mod:'+'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5,6], [7,8]])),
    ?assertEqual(mk(Mod, [[6,8], [10,12]]), S2),

    S3 = Mod:'+'(mk(Mod, [[1], [2]]), mk(Mod, [[3], [4]])),
    ?assertEqual(mk(Mod, [[4], [6]]), S3).


'-_test_'() -> each_backend(fun minus/1).

minus(Mod) ->
    S1 = Mod:'-'(mk(Mod, [[1]]), mk(Mod, [[1]])),
    ?assertEqual(mk(Mod, [[0]]), S1),

    S2 = Mod:'-'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5,6], [7,8]])),
    ?assertEqual(mk(Mod, [[-4,-4], [-4,-4]]), S2),

    S3 = Mod:'-'(mk(Mod, [[1], [2]]), mk(Mod, [[3], [4]])),
    ?assertEqual(mk(Mod, [[-2], [-2]]), S3).


'==_test_'() -> each_backend(fun eq/1).

eq(Mod) ->
    M1 = mk(Mod, [[1]]),
    ?assert(Mod:'=='(M1, M1)),

    M2 = mk(Mod, [[1,2], [3,4]]),
    ?assert(Mod:'=='(M2, M2)),

    M3 = mk(Mod, [[1,2,3], [4,5,6]]),
    ?assert(Mod:'=='(M3, M3)),

    ?assertNot(Mod:'=='(M1, M2)),
    ?assertNot(Mod:'=='(M2, M1)).


'N*M_test_'() -> each_backend(fun scalar_mul/1).

scalar_mul(Mod) ->
    M0 = mk(Mod, [[0,0], [0,0]]),
    ?assert(Mod:'=='(M0, Mod:'*'(5, M0))),

    M1 = mk(Mod, [[1,1], [1,1]]),
    NM1 = mk(Mod, [[3,3], [3,3]]),
    ?assert(Mod:'=='(NM1, Mod:'*'(3, M1))),

    M2 = mk(Mod, [[1,2,3], [-4,-5,-6], [7, -8, 9]]),
    NM2 = mk(Mod, [[-1,-2,-3], [4,5,6], [-7, 8, -9]]),
    ?assert(Mod:'=='(NM2, Mod:'*'(-1, M2))).


'M*M_test_'() -> each_backend(fun mat_mul/1).

mat_mul(Mod) ->
    P1 = Mod:'*'(mk(Mod, [[1]]), mk(Mod, [[2]])),
    ?assertEqual(mk(Mod, [[2]]), P1),

    P2 = Mod:'*'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5,6], [7,8]])),
    ?assertEqual(mk(Mod, [[19,22], [43,50]]), P2),

    P3 = Mod:'*'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5], [6]])),
    ?assertEqual(mk(Mod, [[17], [39]]), P3),

    P4 = Mod:'*'(mk(Mod, [[5,6]]), mk(Mod, [[1,2], [3,4]])),
    ?assertEqual(mk(Mod, [[23,34]]), P4),

    P5 = Mod:'*'(mk(Mod, [[1,2]]), mk(Mod, [[3], [4]])),
    ?assertEqual(mk(Mod, [[11]]), P5),

    P6 = Mod:'*'(mk(Mod, [[1], [2]]), mk(Mod, [[3,4]])),
    ?assertEqual(mk(Mod, [[3,4], [6,8]]), P6).


'*´_test_'() -> each_backend(fun mat_mul_tr/1).

mat_mul_tr(Mod) ->
    P1 = Mod:'*´'(mk(Mod, [[1]]), mk(Mod, [[2]])),
    ?assertEqual(mk(Mod, [[2]]), P1),

    P2 = Mod:'*´'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5,7], [6,8]])),
    ?assertEqual(mk(Mod, [[19,22], [43,50]]), P2),

    P3 = Mod:'*´'(mk(Mod, [[1,2], [3,4]]), mk(Mod, [[5,6]])),
    ?assertEqual(mk(Mod, [[17], [39]]), P3),

    P4 = Mod:'*´'(mk(Mod, [[5,6]]), mk(Mod, [[1,3], [2,4]])),
    ?assertEqual(mk(Mod, [[23,34]]), P4),

    P5 = Mod:'*´'(mk(Mod, [[1,2]]), mk(Mod, [[3,4]])),
    ?assertEqual(mk(Mod, [[11]]), P5),

    P6 = Mod:'*´'(mk(Mod, [[1], [2]]), mk(Mod, [[3], [4]])),
    ?assertEqual(mk(Mod, [[3,4], [6,8]]), P6).


row_test_() -> each_backend(fun row/1).

row(Mod) ->
    M1 = mk(Mod, [[1]]),
    ?assertEqual(mk(Mod, [[1]]), Mod:row(1, M1)),

    M2 = mk(Mod, [[1, 2], [3, 4]]),
    ?assertEqual(mk(Mod, [[1,2]]), Mod:row(1, M2)),
    ?assertEqual(mk(Mod, [[3,4]]), Mod:row(2, M2)).


col_test_() -> each_backend(fun col/1).

col(Mod) ->
    M1 = mk(Mod, [[1]]),
    ?assertEqual(M1, Mod:col(1, M1)),

    M2 = mk(Mod, [[1, 2], [3, 4]]),
    ?assertEqual(mk(Mod, [[1], [3]]), Mod:col(1, M2)),
    ?assertEqual(mk(Mod, [[2], [4]]), Mod:col(2, M2)).


get_test_() -> each_backend(fun get_elem/1).

get_elem(Mod) ->
    M = mk(Mod, [[1, 2], [3, 4]]),
    ?assertEqual(num(Mod, 1), Mod:get(1, 1, M)),
    ?assertEqual(num(Mod, 2), Mod:get(1, 2, M)),
    ?assertEqual(num(Mod, 3), Mod:get(2, 1, M)),
    ?assertEqual(num(Mod, 4), Mod:get(2, 2, M)).


zeros_test_() -> each_backend(fun zeros/1).

zeros(Mod) ->
    Z1 = mk(Mod, [[0]]),
    ?assertEqual(Z1, Mod:zeros(1,1)),

    Z2 = mk(Mod, [[0,0], [0,0]]),
    ?assertEqual(Z2, Mod:zeros(2,2)),

    Z12 = mk(Mod, [[0,0]]),
    ?assertEqual(Z12, Mod:zeros(1,2)),

    Z21 = mk(Mod, [[0], [0]]),
    ?assertEqual(Z21, Mod:zeros(2,1)).


eye_test_() -> each_backend(fun eye/1).

eye(Mod) ->
    I1 = mk(Mod, [[1]]),
    ?assertEqual(I1, Mod:eye(1)),

    I2 = mk(Mod, [[1,0], [0,1]]),
    ?assertEqual(I2, Mod:eye(2)),

    I3 = mk(Mod, [[1,0,0], [0,1,0], [0,0,1]]),
    ?assertEqual(I3, Mod:eye(3)).


diag_test_() -> each_backend(fun diag/1).

diag(Mod) ->
    D1 = mk(Mod, [[5]]),
    ?assertEqual(D1, Mod:diag([5])),

    D2 = mk(Mod, [[1,0,0], [0,1,0], [0,0,1]]),
    ?assertEqual(D2, Mod:diag([1,1,1])),

    D3 = mk(Mod, [[7,0,0], [0,8,0], [0,0,-2]]),
    ?assertEqual(D3, Mod:diag([7,8,-2])).


inv_test_() -> each_backend(fun inv/1).

inv(Mod) ->
    M1 = mk(Mod, [[1]]),
    ?assert(Mod:'=='(M1, Mod:inv(M1))),

    I2 = Mod:eye(2),
    M2 = mk(Mod, [[1,2], [3,4]]),
    ?assert(Mod:'=='(I2, Mod:'*'(M2, Mod:inv(M2)))),

    I3 = Mod:eye(3),
    M3 = mk(Mod, [[2,-1,0], [-1,2,-1], [0,-1,2]]),
    ?assert(Mod:'=='(I3, Mod:'*'(M3, Mod:inv(M3)))),

    I4 = Mod:eye(4),
    M4 = mk(Mod, [[1,1,1,0], [0,3,1,2], [2,3,1,0], [1,0,2,1]]),
    ?assert(Mod:'=='(I4, Mod:'*'(M4, Mod:inv(M4)))).


%% Helpers

each_backend(TestFun) ->
    [{atom_to_list(Mod), fun() -> TestFun(Mod) end} || Mod <- ?BACKENDS].

%% oldmat has no matrix/1 constructor: its matrix() type is already a
%% plain nested list, so construction is the identity for that backend.
mk(mat, L) -> mat:matrix(L);
mk(oldmat, L) -> L.

%% mat stores elements as floats, oldmat keeps them as given.
num(mat, N) -> float(N);
num(oldmat, N) -> N.
