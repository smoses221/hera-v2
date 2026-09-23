-module(kalman_tests).

-include_lib("eunit/include/eunit.hrl").

kf_test() ->
    S = [-0.0139570, 0.0177654, -0.0043154, -0.0032242, -0.0011087, 0.0068842, 0.0127815, -0.0054593, 0.0172686],
    A = [-0.067219, -0.187752, 0.039476, -0.629077, 0.294998, -0.018021, -0.089338, 0.316988, -0.110355],
    X0 = mat:zeros(3, 1),
    P0 = mat:zeros(3, 3),
    {X9, P9} = kf_test_loop({X0, P0}, S, A),

    TrueX9 = mat:matrix([
        [-0.003818873411179362],
        [-0.0030451417563099863],
        [0.010728608371567826]
    ]),
    TrueP9 = mat:matrix([
        [0.0011803595978981166,0.002838977349786346,0.003240423305540969],
        [0.0028389773497863456,0.008065893282913787,0.012971945407050236],
        [0.0032404233055409693,0.012971945407050232,0.036352205605987994]
    ]),

    ?assert(mat:'=='(TrueX9, X9)),
    ?assert(mat:'=='(TrueP9, P9)).

kf_test_loop(State, [], []) ->
    State;
kf_test_loop(State, [S|Ss], [A|As]) ->
    DT = 0.1,
    EA = 0.01,
    VarA = 0.2,
    VarS = 0.01,

    F = mat:matrix([[1,DT,0.5*DT*DT], [0,1,DT], [0,0,1]]),
    H = mat:matrix([[1,0,0], [0,0,1]]),
    G = mat:col(3, F),
    Q = mat:eval([EA, '*', G, '*´', G]),
    R = mat:matrix([[VarS,0], [0,VarA]]),
    Z = mat:matrix([[S], [A]]),
    
    NewState = kalman:kf(State, F, H, Q, R, Z),
    kf_test_loop(NewState, Ss, As).


ekf_test() ->
    A = [1.3076,1.8246,1.7409,1.5532,1.7215,1.6290,1.2415,2.0059,1.7394],
    X0 = mat:matrix([[1]]),
    P0 = mat:matrix([[1]]),
    {X9, P9} = ekf_test_loop({X0,P0}, A),
    ?assertEqual(1.2855, round(mat:get(1,1,X9)*10000)/10000),
    ?assertEqual(0.0036, round(mat:get(1,1,P9)*10000)/10000).

ekf_test_loop(State, []) ->
    State;
ekf_test_loop(State, [A|As]) ->
    F = fun(X) -> X end,
    Jf = fun(_) -> mat:matrix([[1]]) end,
    H = fun(X11) -> mat:'*'(X11,X11) end, % Radius*X11^2
    Jh = fun(X11) -> mat:'*'(2,X11) end, % 2*Radius*X11
    Q = mat:matrix([[0]]),
    R = mat:matrix([[0.2]]),
    Z = mat:matrix([[A]]),

    NewState = kalman:ekf(State, {F,Jf}, {H,Jh}, Q, R, Z),
    ekf_test_loop(NewState, As).
