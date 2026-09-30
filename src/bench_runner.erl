-module(bench_runner).

-export([run/2, run/3]).
-export([run_path/3]).
-export([dump_csv/0, dump_csv/1]).

%% Benchmarks one Kalman step (predict + update) for a given matrix
%% backend module (mat | oldmat | blasmat, ...) on a 9x9 constant-
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
%% Results (min/mean/median/max/stddev over N iterations, in
%% microseconds) are appended as CSV rows to Path, tagged with Stage
%% so results from different benchmark stages (OTP/toolchain/BLAS
%% updates) accumulate in one file.
%%
%% Usage from a serial/remsh session on the board, e.g.:
%%   bench_runner:run(mat, "stage5-9x9").
%%   bench_runner:run(oldmat, "stage5-9x9").
%%   bench_runner:run(blasmat, "stage5-9x9").
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
    {ImuTimes, _} = run_path(Mod, imu, ?ITERATIONS),
    {UwbTimes, _} = run_path(Mod, uwb, ?ITERATIONS),
    ImuStats = stats(ImuTimes),
    UwbStats = stats(UwbTimes),
    write_row(Path, Stage, Mod, "imu_kf_3x9", ImuStats),
    write_row(Path, Stage, Mod, "uwb_ekf_1x9", UwbStats),
    #{imu => ImuStats, uwb => UwbStats}.

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
run_path(Mod, imu, N) ->
    _ = rand:seed(exsss, ?RAND_SEED),
    {F, Q} = motion_model(Mod, ?DT_IMU),
    H = mk(Mod, [[0,0,1,0,0,0,0,0,0],
                 [0,0,0,0,0,1,0,0,0],
                 [0,0,0,0,0,0,0,0,1]]),
    R = mk(Mod, [[?VAR_ACC,0,0], [0,?VAR_ACC,0], [0,0,?VAR_ACC]]),
    Zs = [mk(Mod, [[random_accel()], [random_accel()], [random_accel()]])
          || _ <- lists:seq(1, N)],
    Step = fun(Z, State) -> kalman_bench:kf(Mod, State, F, H, Q, R, Z) end,
    time_steps(Step, initial_state(Mod), Zs);
run_path(Mod, uwb, N) ->
    _ = rand:seed(exsss, ?RAND_SEED),
    {F, Q} = motion_model(Mod, ?DT_UWB),
    %% Linear prediction, passed in the function form ekf/7 expects.
    FJf = {fun(X) -> Mod:'*'(F, X) end, fun(_) -> F end},
    R = mk(Mod, [[?VAR_RANGE]]),
    Models = list_to_tuple([range_model(Mod, A) || A <- ?ANCHORS]),
    NModels = tuple_size(Models),
    Ms = [{element(I rem NModels + 1, Models), mk(Mod, [[random_range()]])}
          || I <- lists:seq(0, N-1)],
    Step = fun({HJh, Z}, State) -> kalman_bench:ekf(Mod, State, FJf, HJh, Q, R, Z) end,
    time_steps(Step, initial_state(Mod), Ms).

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
    FBlock = [[1, DT, DT*DT/2],
              [0, 1,  DT],
              [0, 0,  1]],
    QBlock = [[?Q_JERK*X || X <- Row] || Row <-
              [[math:pow(DT,5)/20, math:pow(DT,4)/8, math:pow(DT,3)/6],
               [math:pow(DT,4)/8,  math:pow(DT,3)/3, math:pow(DT,2)/2],
               [math:pow(DT,3)/6,  math:pow(DT,2)/2, DT]]],
    {mk(Mod, block_diag3(FBlock)), mk(Mod, block_diag3(QBlock))}.

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

range(Dx, Dy, Dz) ->
    max(math:sqrt(Dx*Dx + Dy*Dy + Dz*Dz), ?MIN_RANGE).

%% At rest in the middle of the anchor area, unit covariance.
initial_state(Mod) ->
    X0 = mk(Mod, [[5.0], [0], [0], [5.0], [0], [0], [1.5], [0], [0]]),
    {X0, Mod:eye(9)}.

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
