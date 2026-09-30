-module(bench_runner).

-export([run/2, run/3]).
-export([run_path/3]).
-export([dump_csv/0, dump_csv/1]).

%% Benchmarks one Kalman step (predict + update) for a given backend on
%% a 9x9 constant-
%% acceleration model. State x = [px,vx,ax, py,vy,ay, pz,vz,az]:
%% position, velocity and acceleration for each axis. Two paths, both
%% treating the sensor as a measurement (no control input):
%%   - imu_kf_3x9:  IMU accelerations, linear KF update
%%                  (kalman_bench:kf/7, H: 3x9, S: 3x3), dt = 0.01 s.
%%   - uwb_ekf_1x9: UWB range to one anchor (round-robin over 4),
%%                  EKF update (kalman_bench:ekf/7) with the nonlinear
%%                  h(x) = |p - anchor| linearised by its Jacobian
%%                  (1x9, S: 1x1), dt = 0.1 s.
%%
%% Backends:
%%   - mat | oldmat | blasmat: matrix modules, one call per matrix
%%     operation, through kalman_bench:kf/7 and ekf/7.
%%   - blasws: same, but on erlef/blas buffers reused across steps
%%     (diagnostic: no per-operation allocation).
%%   - kfblas: the whole step in one NIF call (two for the EKF, whose
%%     range model stays in Erlang). kfblas also runs a third path,
%%     uwb_ekf_range_1x9, with the range model in C: one call per step.
%%
%% Results (min/mean/median/max/stddev over N iterations, in
%% microseconds) are appended as CSV rows to Path, tagged with Stage
%% so results from different benchmark stages (OTP/toolchain/BLAS
%% updates) accumulate in one file.
%%
%% Usage from a serial/remsh session on the board, e.g.:
%%   bench_runner:run(mat, "stage5-9x9").
%%   bench_runner:run(oldmat, "stage5-9x9").
%%   bench_runner:run(blasmat, "stage5-9x9").
%%   bench_runner:run(blasws, "stage6-fused").
%%   bench_runner:run(kfblas, "stage6-fused").
%%   bench_runner:dump_csv().  %% prints the accumulated results as
%%                             %% base64, to pull off over serial --
%%                             %% see dump_csv/1 below.

-define(DEFAULT_PATH, "/bench_results.csv").
-define(ITERATIONS, 20000).

%% Fixed RNG seed so benchmark runs stay reproducible/comparable
%% across stages (OTP/toolchain/BLAS) instead of each run drawing a
%% different random sensor-data stream. Each path reseeds, so every
%% backend sees exactly the same inputs.
-define(RAND_SEED, {42, 1337, 271828}).

-define(DT_IMU, 0.01).      % 100 Hz
-define(DT_UWB, 0.1).       % 10 Hz
-define(Q_JERK, 1.0).       % white-jerk spectral density
-define(VAR_ACC, 0.01).     % (0.1 m/s^2)^2
-define(VAR_RANGE, 0.01).   % (0.1 m)^2
-define(MIN_RANGE, 1.0e-6). % keeps the Jacobian finite at an anchor

%% UWB anchors (m), non-coplanar so z is observable.
-define(ANCHORS, [{0.0, 0.0, 0.5}, {10.0, 0.0, 2.5},
                  {10.0, 10.0, 0.5}, {0.0, 10.0, 2.5}]).

run(Mod, Stage) ->
    run(Mod, Stage, ?DEFAULT_PATH).

run(Mod, Stage, Path) ->
    ensure_header(Path),
    maps:from_list(
        [begin
             {Times, _} = run_path(Mod, BenchPath, ?ITERATIONS),
             Stats = stats(Times),
             write_row(Path, Stage, Mod, label(BenchPath), Stats),
             {BenchPath, Stats}
         end || BenchPath <- paths(Mod)]).

paths(kfblas) -> [imu, uwb, uwb_range];
paths(_) -> [imu, uwb].

label(imu) -> "imu_kf_3x9";
label(uwb) -> "uwb_ekf_1x9";
label(uwb_range) -> "uwb_ekf_range_1x9".

%% Runs N filter steps of one path and returns {PerStepTimesUs,
%% FinalState}. Also used by kalman_bench_tests to check that all
%% backends end in the same state.
%%
%% The randomized measurement stream is generated *before* timing
%% starts, so RNG cost never counts as filter cost. F/H/Q/R and the
%% anchors stay fixed -- those are the model/tuning parameters of a
%% real Kalman filter; only the measurement Z and the evolving (X, P)
%% state change. The filter runs continuously across the stream,
%% threading (X, P) from one step into the next, as hera does.
%%
%% For blasws/kfblas the filter is mutable, so the returned final state
%% is read out with get_state/1 as {XList, PList} (flat, row-major).
run_path(Eng, imu, N) when Eng =:= kfblas; Eng =:= blasws ->
    Zs = [f64(Z) || Z <- imu_readings(N)],
    H = f64(imu_h()),
    R = f64(imu_r()),
    Filter = engine_filter(Eng, ?DT_IMU),
    Step = fun(Z, Flt) -> ok = Eng:kf_step(Flt, H, R, Z), Flt end,
    engine_result(Eng, time_steps(Step, Filter, Zs));
run_path(Eng, uwb, N) when Eng =:= kfblas; Eng =:= blasws ->
    Ms = [{A, f64([Z])} || {A, Z} <- range_readings(N)],
    R = f64([?VAR_RANGE]),
    Filter = engine_filter(Eng, ?DT_UWB),
    %% Range model in Erlang, from the predicted state the NIF returns.
    Step = fun({Anchor, Z}, Flt) ->
        Xp = Eng:ekf_predict(Flt),
        {Hx, Jh} = range_bins(Xp, Anchor),
        ok = Eng:ekf_update(Flt, Jh, Hx, R, Z),
        Flt
    end,
    engine_result(Eng, time_steps(Step, Filter, Ms));
run_path(kfblas, uwb_range, N) ->
    Ms = [{f64(tuple_to_list(A)), f64([Z])} || {A, Z} <- range_readings(N)],
    R = f64([?VAR_RANGE]),
    Filter = engine_filter(kfblas, ?DT_UWB),
    %% Range model in C: one call per step. Position is x[0], x[3], x[6].
    Step = fun({Anchor, Z}, Flt) ->
        ok = kfblas:ekf_range_step(Flt, {0, 3, 6}, Anchor, R, Z),
        Flt
    end,
    engine_result(kfblas, time_steps(Step, Filter, Ms));
run_path(Mod, imu, N) ->
    Zs = [mk(Mod, [[A] || A <- Z]) || Z <- imu_readings(N)],
    {F, Q} = motion_model(Mod, ?DT_IMU),
    H = mk(Mod, imu_h()),
    R = mk(Mod, imu_r()),
    Step = fun(Z, State) -> kalman_bench:kf(Mod, State, F, H, Q, R, Z) end,
    time_steps(Step, initial_state(Mod), Zs);
run_path(Mod, uwb, N) ->
    Models = maps:from_list([{A, range_model(Mod, A)} || A <- ?ANCHORS]),
    Ms = [{maps:get(A, Models), mk(Mod, [[Z]])} || {A, Z} <- range_readings(N)],
    {F, Q} = motion_model(Mod, ?DT_UWB),
    %% Linear prediction, passed in the function form ekf/7 expects.
    FJf = {fun(X) -> Mod:'*'(F, X) end, fun(_) -> F end},
    R = mk(Mod, [[?VAR_RANGE]]),
    Step = fun({HJh, Z}, State) -> kalman_bench:ekf(Mod, State, FJf, HJh, Q, R, Z) end,
    time_steps(Step, initial_state(Mod), Ms).

imu_h() ->
    [[0,0,1,0,0,0,0,0,0],
     [0,0,0,0,0,1,0,0,0],
     [0,0,0,0,0,0,0,0,1]].

imu_r() ->
    [[?VAR_ACC,0,0], [0,?VAR_ACC,0], [0,0,?VAR_ACC]].

%% The seeded input streams, as plain floats. Every backend converts
%% the same stream to its own format, so all see identical inputs.
imu_readings(N) ->
    _ = rand:seed(exsss, ?RAND_SEED),
    [[random_accel() || _ <- [x, y, z]] || _ <- lists:seq(1, N)].

%% [{Anchor, Range}], anchors taken round-robin.
range_readings(N) ->
    _ = rand:seed(exsss, ?RAND_SEED),
    Anchors = list_to_tuple(?ANCHORS),
    [{element(I rem tuple_size(Anchors) + 1, Anchors), random_range()}
     || I <- lists:seq(0, N-1)].

%% Stand-ins for noisy sensor readings, in plausible physical ranges
%% (accelerations of a walking/driving target, ranges inside the
%% 10 m x 10 m anchor area). They are not consistent with any
%% trajectory; for a pure timing benchmark only non-degenerate,
%% reproducible values matter. Could use a defined trajectory and add Gaussian noise.
random_accel() ->
    -2.0 + rand:uniform() * 4.0.

random_range() ->
    1.0 + rand:uniform() * 13.0.

%% Constant-acceleration model: F and Q are block-diagonal, one 3x3
%% block per axis. Q is the discrete white-jerk process noise.
motion_model(Mod, DT) ->
    {F, Q} = motion_lists(DT),
    {mk(Mod, F), mk(Mod, Q)}.

motion_lists(DT) ->
    FBlock = [[1, DT, DT*DT/2],
              [0, 1,  DT],
              [0, 0,  1]],
    QBlock = [[?Q_JERK*X || X <- Row] || Row <-
              [[math:pow(DT,5)/20, math:pow(DT,4)/8, math:pow(DT,3)/6],
               [math:pow(DT,4)/8,  math:pow(DT,3)/3, math:pow(DT,2)/2],
               [math:pow(DT,3)/6,  math:pow(DT,2)/2, DT]]],
    {block_diag3(FBlock), block_diag3(QBlock)}.

block_diag3(B) ->
    [[case I div 3 =:= J div 3 of
          true -> lists:nth(J rem 3 + 1, lists:nth(I rem 3 + 1, B));
          false -> 0
      end || J <- lists:seq(0, 8)] || I <- lists:seq(0, 8)].

%% UWB range to Anchor: h(x) = |p - anchor|, and its Jacobian (1x9),
%% d|p - a|/dp = (p - a)/|p - a| in the three position slots. Both are
%% evaluated at the predicted state on every step, so reading X and
%% building these small matrices is part of the timed cost, as in a
%% real EKF.
range_model(Mod, {Ax, Ay, Az}) ->
    Diff = fun(X) ->
        {Mod:get(1, 1, X) - Ax, Mod:get(4, 1, X) - Ay, Mod:get(7, 1, X) - Az}
    end,
    H = fun(X) ->
        {Dx, Dy, Dz} = Diff(X),
        mk(Mod, [[range(Dx, Dy, Dz)]])
    end,
    Jh = fun(X) ->
        {Dx, Dy, Dz} = Diff(X),
        Rng = range(Dx, Dy, Dz),
        mk(Mod, [[Dx/Rng, 0, 0, Dy/Rng, 0, 0, Dz/Rng, 0, 0]])
    end,
    {H, Jh}.

%% The same model for blasws/kfblas: from the predicted state binary,
%% returns {h(Xp), Jh(Xp)} as float64 binaries.
range_bins(<<Px:64/native-float, _:16/binary, Py:64/native-float, _:16/binary,
             Pz:64/native-float, _/binary>>, {Ax, Ay, Az}) ->
    {Dx, Dy, Dz} = {Px - Ax, Py - Ay, Pz - Az},
    Rng = range(Dx, Dy, Dz),
    {<<Rng:64/native-float>>,
     f64([Dx/Rng, 0.0, 0.0, Dy/Rng, 0.0, 0.0, Dz/Rng, 0.0, 0.0])}.

range(Dx, Dy, Dz) ->
    max(math:sqrt(Dx*Dx + Dy*Dy + Dz*Dz), ?MIN_RANGE).

%% At rest in the middle of the anchor area, unit covariance.
initial_state(Mod) ->
    {mk(Mod, [[X] || X <- x0()]), Mod:eye(9)}.

x0() ->
    [5.0, 0, 0, 5.0, 0, 0, 1.5, 0, 0].

%% A blasws/kfblas filter with the motion model and initial state set
%% (P0 = I is new/2's default). Sized for up to 3 measurements (IMU).
engine_filter(Eng, DT) ->
    {F, Q} = motion_lists(DT),
    Filter = Eng:new(9, 3),
    ok = Eng:set_model(Filter, f64(F), f64(Q)),
    ok = Eng:set_state(Filter, f64(x0()), f64(eye_lists(9))),
    Filter.

engine_result(Eng, {Times, Filter}) ->
    {X, P} = Eng:get_state(Filter),
    {Times, {floats(X), floats(P)}}.

eye_lists(N) ->
    [[case I of J -> 1; _ -> 0 end || J <- lists:seq(1, N)] || I <- lists:seq(1, N)].

%% Row-major native float64 binary of a (nested) list of numbers.
f64(L) ->
    << <<(float(X)):64/native-float>> || X <- lists:flatten(L) >>.

floats(Bin) ->
    [X || <<X:64/native-float>> <= Bin].

%% Prints Path as base64, wrapped at 76 chars/line, between clear
%% markers. On the host: capture your serial terminal's scrollback
%% (enable logging before calling this), cut everything between the
%% BEGIN/END markers into its own file, then:
%%   base64 -d captured.b64 > bench_results.csv
dump_csv() ->
    dump_csv(?DEFAULT_PATH).

dump_csv(Path) ->
    {ok, Bin} = file:read_file(Path),
    io:format("-----BEGIN BENCH CSV ~s-----~n", [Path]),
    print_b64_chunks(base64:encode(Bin)),
    io:format("-----END BENCH CSV-----~n").

print_b64_chunks(Bin) when byte_size(Bin) =< 76 ->
    io:format("~s~n", [Bin]);
print_b64_chunks(Bin) ->
    <<Chunk:76/binary, Rest/binary>> = Bin,
    io:format("~s~n", [Chunk]),
    print_b64_chunks(Rest).

%% Times Step(M, State) for each M, threading State through.
time_steps(Step, State0, Ms) ->
    lists:mapfoldl(
        fun(M, State) ->
            T0 = erlang:monotonic_time(microsecond),
            NewState = Step(M, State),
            T1 = erlang:monotonic_time(microsecond),
            {T1 - T0, NewState}
        end,
        State0, Ms).

stats(Times) ->
    N = length(Times),
    Sorted = lists:sort(Times),
    Min = hd(Sorted),
    Max = lists:last(Sorted),
    Sum = lists:sum(Times),
    Mean = Sum / N,
    Median = median(Sorted),
    Variance = lists:sum([math:pow(T - Mean, 2) || T <- Times]) / N,
    Stddev = math:sqrt(Variance),
    #{n => N, min => Min, max => Max, mean => Mean, median => Median, stddev => Stddev}.

median(Sorted) ->
    N = length(Sorted),
    Mid = N div 2,
    case N rem 2 of
        1 -> lists:nth(Mid + 1, Sorted);
        0 -> (lists:nth(Mid, Sorted) + lists:nth(Mid + 1, Sorted)) / 2
    end.

%% oldmat has no matrix/1 constructor: its matrix() type is already a
%% plain nested list, so construction is the identity for that backend.
mk(mat, L) -> mat:matrix(L);
mk(oldmat, L) -> L;
mk(blasmat, L) -> blasmat:matrix(L).

ensure_header(Path) ->
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            case open_for_write(Path, [write]) of
                {ok, Fd} ->
                    ok = file:write(Fd, "stage,backend,path,n,min_us,mean_us,median_us,max_us,stddev_us\n"),
                    ok = file:close(Fd);
                {error, Reason} ->
                    error({bench_csv_unwritable, Path, Reason})
            end
    end.

write_row(Path, Stage, Mod, PathLabel, Stats) ->
    #{n := N, min := Min, max := Max, mean := Mean, median := Median, stddev := Stddev} = Stats,
    Line = io_lib:format("~s,~s,~s,~b,~b,~.3f,~.3f,~b,~.3f~n",
        [Stage, atom_to_list(Mod), PathLabel, N, Min, Mean, Median, Max, Stddev]),
    case open_for_write(Path, [append]) of
        {ok, Fd} ->
            ok = file:write(Fd, Line),
            ok = file:close(Fd);
        {error, Reason} ->
            error({bench_csv_unwritable, Path, Reason})
    end.

%% file:open/2 doesn't create missing parent directories (e.g. the SD
%% card mount point existing but a subdirectory in Path not yet
%% created), so ensure the parent dir exists before every open. If
%% Path's filesystem itself isn't there (wrong mount point guessed),
%% this still fails with a clear {bench_csv_unwritable, Path, Reason}
%% error instead of a raw pattern-match crash.
open_for_write(Path, Modes) ->
    _ = filelib:ensure_dir(Path),
    file:open(Path, Modes).
