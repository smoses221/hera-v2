-module(oldmat_tests).

-include_lib("eunit/include/eunit.hrl").

%% Mirrors mat_tests.erl, but exercises the pure-Erlang `oldmat` backend.
%% oldmat's matrix() type is a plain nested list, so no constructor call
%% is needed where mat_tests.erl uses mat:matrix(...).

-define(assert_equal(A,B), ?assert(oldmat:'=='(A,B))).


tr_test() ->
    M1 = [[1]],
    ?assertEqual(M1, oldmat:tr(M1)),

    M2 = [[1,2], [3,4]],
    ?assertEqual([[1,3], [2,4]], oldmat:tr(M2)),

    M3 = [[1,2,3], [4,5,6], [7,8,9]],
    M3t = [[1,4,7], [2,5,8], [3,6,9]],
    ?assertEqual(M3t, oldmat:tr(M3)),

    M12 = [[1,2]],
    ?assertEqual([[1], [2]], oldmat:tr(M12)),

    M21 = [[1], [2]],
    ?assertEqual([[1,2]], oldmat:tr(M21)),

    M23 = [[1,2,3], [4,5,6]],
    M23t = [[1,4], [2,5], [3,6]],
    ?assertEqual(M23t, oldmat:tr(M23)),

    M32 = [[1,2], [3,4], [5,6]],
    M32t = [[1,3,5], [2,4,6]],
    ?assertEqual(M32t, oldmat:tr(M32)).


'+_test'() ->
    S1 = oldmat:'+'([[1]], [[1]]),
    ?assertEqual([[2]], S1),

    S2 = oldmat:'+'([[1,2], [3,4]], [[5,6], [7,8]]),
    ?assertEqual([[6,8], [10,12]], S2),

    S3 = oldmat:'+'([[1], [2]], [[3], [4]]),
    ?assertEqual([[4], [6]], S3).


'-_test'() ->
    S1 = oldmat:'-'([[1]], [[1]]),
    ?assertEqual([[0]], S1),

    S2 = oldmat:'-'([[1,2], [3,4]], [[5,6], [7,8]]),
    ?assertEqual([[-4,-4], [-4,-4]], S2),

    S3 = oldmat:'-'([[1], [2]], [[3], [4]]),
    ?assertEqual([[-2], [-2]], S3).


'==_test'() ->
    M1 = [[1]],
    ?assert(oldmat:'=='(M1, M1)),

    M2 = [[1,2], [3,4]],
    ?assert(oldmat:'=='(M2, M2)),

    M3 = [[1,2,3], [4,5,6]],
    ?assert(oldmat:'=='(M3, M3)),

    ?assertNot(oldmat:'=='(M1, M2)),
    ?assertNot(oldmat:'=='(M2, M1)).


'N*M_test'() ->
    M0 = [[0,0], [0,0]],
    ?assert(oldmat:'=='(M0, oldmat:'*'(5, M0))),

    M1 = [[1,1], [1,1]],
    NM1 = [[3,3], [3,3]],
    ?assert(oldmat:'=='(NM1, oldmat:'*'(3, M1))),

    M2 = [[1,2,3], [-4,-5,-6], [7, -8, 9]],
    NM2 = [[-1,-2,-3], [4,5,6], [-7, 8, -9]],
    ?assert(oldmat:'=='(NM2, oldmat:'*'(-1, M2))).


'M*M_test'() ->
    P1 = oldmat:'*'([[1]], [[2]]),
    ?assertEqual([[2]], P1),

    P2 = oldmat:'*'([[1,2], [3,4]], [[5,6], [7,8]]),
    ?assertEqual([[19,22], [43,50]], P2),

    P3 = oldmat:'*'([[1,2], [3,4]], [[5], [6]]),
    ?assertEqual([[17], [39]], P3),

    P4 = oldmat:'*'([[5,6]], [[1,2], [3,4]]),
    ?assertEqual([[23,34]], P4),

    P5 = oldmat:'*'([[1,2]], [[3], [4]]),
    ?assertEqual([[11]], P5),

    P6 = oldmat:'*'([[1], [2]], [[3,4]]),
    ?assertEqual([[3,4], [6,8]], P6).


'*´_test'() ->
    P1 = oldmat:'*´'([[1]], [[2]]),
    ?assertEqual([[2]], P1),

    P2 = oldmat:'*´'([[1,2], [3,4]], [[5,7], [6,8]]),
    ?assertEqual([[19,22], [43,50]], P2),

    P3 = oldmat:'*´'([[1,2], [3,4]], [[5,6]]),
    ?assertEqual([[17], [39]], P3),

    P4 = oldmat:'*´'([[5,6]], [[1,3], [2,4]]),
    ?assertEqual([[23,34]], P4),

    P5 = oldmat:'*´'([[1,2]], [[3,4]]),
    ?assertEqual([[11]], P5),

    P6 = oldmat:'*´'([[1], [2]], [[3], [4]]),
    ?assertEqual([[3,4], [6,8]], P6).


row_test() ->
    M1 = [[1]],
    ?assertEqual([[1]], oldmat:row(1, M1)),

    M2 = [[1, 2], [3, 4]],
    ?assertEqual([[1,2]], oldmat:row(1, M2)),
    ?assertEqual([[3,4]], oldmat:row(2, M2)).


col_test() ->
    M1 = [[1]],
    ?assertEqual(M1, oldmat:col(1, M1)),

    M2 = [[1, 2], [3, 4]],
    ?assertEqual([[1], [3]], oldmat:col(1, M2)),
    ?assertEqual([[2], [4]], oldmat:col(2, M2)).


get_test() ->
    M = [[1, 2], [3, 4]],
    ?assertEqual(1, oldmat:get(1, 1, M)),
    ?assertEqual(2, oldmat:get(1, 2, M)),
    ?assertEqual(3, oldmat:get(2, 1, M)),
    ?assertEqual(4, oldmat:get(2, 2, M)).


zeros_test() ->
    Z1 = [[0]],
    ?assertEqual(Z1, oldmat:zeros(1,1)),

    Z2 = [[0,0], [0,0]],
    ?assertEqual(Z2, oldmat:zeros(2,2)),

    Z12 = [[0,0]],
    ?assertEqual(Z12, oldmat:zeros(1,2)),

    Z21 = [[0], [0]],
    ?assertEqual(Z21, oldmat:zeros(2,1)).


eye_test() ->
    I1 = [[1]],
    ?assertEqual(I1, oldmat:eye(1)),

    I2 = [[1,0], [0,1]],
    ?assertEqual(I2, oldmat:eye(2)),

    I3 = [[1,0,0], [0,1,0], [0,0,1]],
    ?assertEqual(I3, oldmat:eye(3)).


diag_test() ->
    D1 = [[5]],
    ?assertEqual(D1, oldmat:diag([5])),

    D2 = [[1,0,0], [0,1,0], [0,0,1]],
    ?assertEqual(D2, oldmat:diag([1,1,1])),

    D3 = [[7,0,0], [0,8,0], [0,0,-2]],
    ?assertEqual(D3, oldmat:diag([7,8,-2])).


inv_test() ->
    M1 = [[1]],
    ?assert(oldmat:'=='(M1, oldmat:inv(M1))),

    I2 = oldmat:eye(2),
    M2 = [[1,2], [3,4]],
    ?assert(oldmat:'=='(I2, oldmat:'*'(M2, oldmat:inv(M2)))),

    I3 = oldmat:eye(3),
    M3 = [[2,-1,0], [-1,2,-1], [0,-1,2]],
    ?assert(oldmat:'=='(I3, oldmat:'*'(M3, oldmat:inv(M3)))),

    I4 = oldmat:eye(4),
    M4 = [[1,1,1,0], [0,3,1,2], [2,3,1,0], [1,0,2,1]],
    ?assert(oldmat:'=='(I4, oldmat:'*'(M4, oldmat:inv(M4)))).
