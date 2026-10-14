-module(hera_fusion_tests).

-include_lib("eunit/include/eunit.hrl").

%% hera_fusion on exact (noise-free) inputs generated here, with the
%% default anchors (0,0,0) and (4,0,0). The full simulations with noise
%% are in sim/ (Python); these only check the filter's maths.

-define(G, 9.80665).
-define(NAV_DT, 0.01).
-define(UWB_EVERY, 25). % one range every 25 NAV samples, anchors alternating

%% Tag still at (2, 2, 0): exact inputs keep it there.
static_stays_put_test() ->
    F = run(mat, fun(_) -> {{2.0, 2.0, 0.0}, {0.0, 0.0, 0.0}} end,
            #{x0 => [2.0, 0, 0, 2.0, 0, 0, 0, 0, 0]}, 1000),
    #{x := [Px, Vx, _, Py, Vy, _, Pz, _, _]} = hera_fusion:estimate(F),
    ?assert(abs(Px - 2.0) < 1.0e-9),
    ?assert(abs(Py - 2.0) < 1.0e-9),
    ?assert(abs(Pz) < 1.0e-9),
    ?assert(abs(Vx) + abs(Vy) < 1.0e-9).

%% Constant velocity, started 20 cm off and with velocity 0: the ranges
%% and accelerations pull position and velocity onto the truth.
constant_velocity_converges_test() ->
    V = {0.05, 0.03},
    Truth = fun(T) -> {{1.0 + 0.05 * T, 1.5 + 0.03 * T, 0.0}, {0.0, 0.0, 0.0}} end,
    F = run(mat, Truth, #{x0 => [1.2, 0, 0, 1.4, 0, 0, 0, 0, 0]}, 3000),
    #{t := T, x := [Px, Vx, _, Py, Vy, _, _, _, _]} = hera_fusion:estimate(F),
    {{TPx, TPy, _}, _} = Truth(T),
    ?assert(math:sqrt(sq(Px - TPx) + sq(Py - TPy)) < 0.01),
    ?assert(abs(Vx - element(1, V)) < 0.005),
    ?assert(abs(Vy - element(2, V)) < 0.005).

%% Analytic range Jacobian = numerical derivative.
range_jacobian_test() ->
    X = [1.3, 0.2, 0.0, 2.1, -0.1, 0.0, 0.4, 0.0, 0.0],
    A = {4.0, 0.0, 0.5},
    {H, J} = hera_fusion:range_model(col(X), {oldmat, A}),
    Eps = 1.0e-6,
    Num = [begin
               Xe = [case K of I -> V + Eps; _ -> V end || {K, V} <- lists:enumerate(X)],
               {He, _} = hera_fusion:range_model(col(Xe), {oldmat, A}),
               (He - H) / Eps
           end || I <- lists:seq(1, 9)],
    [?assert(abs(Ja - Jn) < 1.0e-5) || {Ja, Jn} <- lists:zip(J, Num)].

%% An accelerometer z bias makes z drift; the planar pseudo-measurement
%% holds it near the plane.
planar_constraint_bounds_z_test() ->
    Still = fun(_) -> {{2.0, 2.0, 0.0}, {0.0, 0.0, 0.0}} end,
    Opts = #{x0 => [2.0, 0, 0, 2.0, 0, 0, 0, 0, 0], acc_bias => {0.0, 0.0, 0.05}},
    Z = fun(F) -> lists:nth(7, maps:get(x, hera_fusion:estimate(F))) end,
    Held = Z(run(mat, Still, Opts, 3000)),
    Free = Z(run(mat, Still, Opts#{planar => false}, 3000)),
    ?assert(abs(Held) < 0.05),
    ?assert(abs(Free) > 10 * abs(Held)).

%% Every backend gives the same estimate.
backends_agree_test_() ->
    Circle = fun(T) ->
        W = 0.3,
        {{2.0 + math:sin(W * T), 2.0 - math:cos(W * T), 0.0},
         {-W * W * math:sin(W * T), W * W * math:cos(W * T), 0.0}}
    end,
    Opts = #{x0 => [2.05, 0, 0, 0.95, 0, 0, 0, 0, 0]},
    Ref = maps:get(x, hera_fusion:estimate(run(oldmat, Circle, Opts, 500))),
    [{atom_to_list(Mod), fun() ->
         X = maps:get(x, hera_fusion:estimate(run(Mod, Circle, Opts, 500))),
         [?assert(abs(A - B) < 1.0e-9) || {A, B} <- lists:zip(Ref, X)]
     end} || Mod <- [mat, blasmat]].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% N NAV samples (yaw 0, so body = world) every ?NAV_DT, and a range every
%% ?UWB_EVERY samples, from Truth(T) -> {Position, Acceleration}.
%% Opts: hera_fusion config, plus acc_bias (added to the NAV samples).
run(Mod, Truth, Opts, N) ->
    {Bx, By, Bz} = maps:get(acc_bias, Opts, {0.0, 0.0, 0.0}),
    F0 = hera_fusion:new(maps:remove(acc_bias, Opts#{backend => Mod})),
    #{anchors := Anchors} = hera_fusion:cfg(F0),
    lists:foldl(
        fun(K, F) ->
            T = K * ?NAV_DT,
            {P, {Ax, Ay, Az}} = Truth(T),
            F1 = hera_fusion:nav(F, T, [Ax + Bx, Ay + By, Az + ?G + Bz, 0.0, 0.0, 0.0]),
            case K rem ?UWB_EVERY of
                0 ->
                    Index = (K div ?UWB_EVERY) rem 2 + 1,
                    hera_fusion:uwb(F1, T, Index, dist(P, maps:get(Index, Anchors)));
                _ ->
                    F1
            end
        end, F0, lists:seq(1, N)).

dist({X, Y, Z}, {Ax, Ay, Az}) ->
    math:sqrt(sq(X - Ax) + sq(Y - Ay) + sq(Z - Az)).

sq(X) -> X * X.

col(X) -> [[V] || V <- X].
