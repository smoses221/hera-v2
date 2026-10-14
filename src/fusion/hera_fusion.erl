-module(hera_fusion).

-export([default_cfg/0, new/1]).
-export([nav/3, uwb/4]).
-export([estimate/1, cfg/1]).
-export([range_model/2]).

%% Baseline position filter for one tag: the Pmod NAV (hera_nav) and the
%% Pmod UWB (hera_uwb) are treated as one rigid point. Pure functions,
%% so the same code runs on the board, in the offline replay
%% (sim_replay) and in the live simulation (sim_fusion).
%%
%% State: the 9-state constant-acceleration model of the benchmark
%% (bench_runner), x = [px,vx,ax, py,vy,ay, pz,vz,az] in the world frame
%% (anchors' frame, z up). z is kept even though the tag moves on a
%% plane: it is held there by a weak pseudo-measurement (planar).
%%
%% Events, each at its time T (s), in any order of sources:
%%   nav(F, T, [Ax,Ay,Az,Gx,Gy,Gz | _]): hera_nav's sample (body frame,
%%     specific force with gravity, rad/s). Yaw is integrated from Gz
%%     outside the Kalman state (roll and pitch assumed 0). The
%%     acceleration rotated to the world frame, gravity removed, is a
%%     linear measurement of [ax, ay, az].
%%   uwb(F, T, Index, Range): hera_uwb's sample. EKF update with
%%     h(x) = |p - anchor(Index)|.
%% Both first predict from the filter's time to T. An event older than
%% the filter's time is applied with dt = 0 and counted in `late`.
%%
%% The matrix backend is a parameter (backend: mat | oldmat | blasmat),
%% as in kalman_bench, whose kf_predict/kf_update are reused.

-define(MIN_RANGE, 1.0e-6). % keeps the Jacobian finite at an anchor

%% Configuration (all overridable by new/1):
%%   backend      matrix module                                  (mat)
%%   anchors      #{Index => {X, Y, Z}} (m)
%%   q_jerk       white-jerk spectral density, m^2/s^5            (1.0)
%%   sigma_acc    world acceleration measurement stddev, m/s^2    (1.0)
%%                Far above the sensor's white noise (~0.02): it also has
%%                to cover the residual biases, which the state lacks. At
%%                0.1 a 2 mg bias gives ~28 cm even when still (sweep in
%%                REDESIGN_LOG, "Simulation baseline").
%%   sigma_range  UWB range stddev, m                             (0.05)
%%   planar       {SigmaPz (m), SigmaVz (m/s)} pseudo-measurement
%%                pz = z0, vz = 0 after every UWB update, or false ({0.05, 0.05})
%%   z0           height of the plane, m                          (0.0)
%%   g            gravity, m/s^2                                  (9.80665)
%%   x0           initial state, 9 floats                         (zeros)
%%   p0_diag      initial covariance diagonal, 9 floats
%%   yaw0         initial yaw, rad                                (0.0)
%%   t0           initial time, s                                 (0.0)
default_cfg() ->
    #{backend => mat,
      anchors => #{1 => {0.0, 0.0, 0.0}, 2 => {4.0, 0.0, 0.0}},
      q_jerk => 1.0,
      sigma_acc => 1.0,
      sigma_range => 0.05,
      planar => {0.05, 0.05},
      z0 => 0.0,
      g => 9.80665,
      x0 => [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      p0_diag => [0.04, 0.01, 0.01, 0.04, 0.01, 0.01, 0.01, 0.01, 0.01],
      yaw0 => 0.0,
      t0 => 0.0}.

new(Opts) ->
    Cfg = maps:merge(default_cfg(), Opts),
    #{backend := Mod, x0 := X0, p0_diag := P0, yaw0 := Yaw0, t0 := T0,
      sigma_acc := SAcc, sigma_range := SRange} = Cfg,
    9 = length(X0),
    9 = length(P0),
    #{cfg => Cfg,
      mod => Mod,
      x => mk(Mod, [[float(V)] || V <- X0]),
      p => mk(Mod, diag_lists(P0)),
      t => float(T0),
      yaw => float(Yaw0),
      t_gyro => undefined,
      late => 0,
      h_acc => mk(Mod, acc_h()),
      r_acc => mk(Mod, diag_lists(lists:duplicate(3, SAcc * SAcc))),
      r_range => mk(Mod, [[SRange * SRange]]),
      planar => planar_model(Mod, Cfg)}.

cfg(#{cfg := Cfg}) ->
    Cfg.

%% A NAV sample at time T.
nav(F0, T, [Ax, Ay, Az, _Gx, _Gy, Gz | _]) ->
    F1 = #{yaw := Yaw} = integrate_yaw(F0, T, Gz),
    F2 = #{mod := Mod, x := Xp, p := Pp} = predict(F1, T),
    #{cfg := #{g := G}, h_acc := H, r_acc := R} = F2,
    C = math:cos(Yaw),
    S = math:sin(Yaw),
    Z = mk(Mod, [[C * Ax - S * Ay], [S * Ax + C * Ay], [Az - G]]),
    {X1, P1} = kalman_bench:kf_update(Mod, {Xp, Pp}, H, R, Z),
    F2#{x := X1, p := P1}.

%% A UWB range to anchor Index at time T. The EKF update is
%% kalman_bench:kf_update/5 on the measurement linearised at the
%% prediction, Z' = Z - h(Xp) + J*Xp, so that Z' - J*Xp = Z - h(Xp).
uwb(F0, T, Index, Range) ->
    F1 = #{mod := Mod, x := Xp, p := Pp, r_range := R} = predict(F0, T),
    #{cfg := #{anchors := Anchors}} = F1,
    {H, J} = range_model(Xp, {Mod, maps:get(Index, Anchors)}),
    Jx = Mod:get(1, 1, Mod:'*'(mk(Mod, [J]), Xp)),
    Z = mk(Mod, [[Range - H + Jx]]),
    {X1, P1} = kalman_bench:kf_update(Mod, {Xp, Pp}, mk(Mod, [J]), R, Z),
    planar_update(F1#{x := X1, p := P1}).

%% The current estimate, as plain floats.
estimate(#{mod := Mod, x := X, p := P, t := T, yaw := Yaw, late := Late}) ->
    Get = fun(I, J, M) -> Mod:get(I, J, M) end,
    #{t => T,
      x => [Get(I, 1, X) || I <- lists:seq(1, 9)],
      p_pos => {Get(1, 1, P), Get(1, 4, P), Get(4, 4, P), Get(7, 7, P)},
      yaw => Yaw,
      late => Late}.

%% h(x) = |p - anchor| and its Jacobian (1x9, list), from a state
%% matrix X of backend Mod.
range_model(X, {Mod, {Ax, Ay, Az}}) ->
    Dx = Mod:get(1, 1, X) - Ax,
    Dy = Mod:get(4, 1, X) - Ay,
    Dz = Mod:get(7, 1, X) - Az,
    R = max(math:sqrt(Dx * Dx + Dy * Dy + Dz * Dz), ?MIN_RANGE),
    {R, [Dx / R, 0.0, 0.0, Dy / R, 0.0, 0.0, Dz / R, 0.0, 0.0]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Yaw from the gyroscope, over the time since the previous NAV sample
%% (the first sample only sets the reference time).
integrate_yaw(F = #{t_gyro := undefined}, T, _Gz) ->
    F#{t_gyro := T};
integrate_yaw(F = #{t_gyro := Tg, yaw := Yaw}, T, Gz) ->
    Dt = max(T - Tg, 0.0),
    F#{t_gyro := max(T, Tg), yaw := Yaw + Gz * Dt}.

%% Constant-acceleration prediction from the filter's time to T.
predict(F = #{t := T0, late := Late}, T) when T < T0 ->
    F#{late := Late + 1};
predict(F = #{t := T0}, T) when T == T0 ->
    F;
predict(F = #{mod := Mod, t := T0, x := X, p := P, cfg := #{q_jerk := Qj}}, T) ->
    {Fm, Q} = motion_lists(T - T0, Qj),
    {Xp, Pp} = kalman_bench:kf_predict(Mod, {X, P}, mk(Mod, Fm), mk(Mod, Q)),
    F#{t := float(T), x := Xp, p := Pp}.

planar_update(F = #{planar := false}) ->
    F;
planar_update(F = #{mod := Mod, x := X, p := P, planar := {H, R, Z}}) ->
    {X1, P1} = kalman_bench:kf_update(Mod, {X, P}, H, R, Z),
    F#{x := X1, p := P1}.

planar_model(_Mod, #{planar := false}) ->
    false;
planar_model(Mod, #{planar := {SPz, SVz}, z0 := Z0}) ->
    H = [[0, 0, 0, 0, 0, 0, 1, 0, 0],
         [0, 0, 0, 0, 0, 0, 0, 1, 0]],
    {mk(Mod, H), mk(Mod, diag_lists([SPz * SPz, SVz * SVz])), mk(Mod, [[float(Z0)], [0.0]])}.

%% Same F and Q as bench_runner:motion_lists/1, for any DT: one 3x3
%% block per axis, Q the discrete white-jerk process noise.
motion_lists(DT, Qj) ->
    FBlock = [[1, DT, DT * DT / 2],
              [0, 1, DT],
              [0, 0, 1]],
    QBlock = [[Qj * X || X <- Row] || Row <-
              [[math:pow(DT, 5) / 20, math:pow(DT, 4) / 8, math:pow(DT, 3) / 6],
               [math:pow(DT, 4) / 8, math:pow(DT, 3) / 3, math:pow(DT, 2) / 2],
               [math:pow(DT, 3) / 6, math:pow(DT, 2) / 2, DT]]],
    {block_diag3(FBlock), block_diag3(QBlock)}.

block_diag3(B) ->
    [[case I div 3 =:= J div 3 of
          true -> float(lists:nth(J rem 3 + 1, lists:nth(I rem 3 + 1, B)));
          false -> 0.0
      end || J <- lists:seq(0, 8)] || I <- lists:seq(0, 8)].

acc_h() ->
    [[0, 0, 1, 0, 0, 0, 0, 0, 0],
     [0, 0, 0, 0, 0, 1, 0, 0, 0],
     [0, 0, 0, 0, 0, 0, 0, 0, 1]].

diag_lists(L) ->
    N = length(L),
    [[case I of J -> float(V); _ -> 0.0 end || J <- lists:seq(1, N)]
     || {I, V} <- lists:zip(lists:seq(1, N), L)].

%% oldmat's matrix() is already a nested list.
mk(oldmat, L) -> [[float(V) || V <- Row] || Row <- L];
mk(Mod, L) -> Mod:matrix([[float(V) || V <- Row] || Row <- L]).
