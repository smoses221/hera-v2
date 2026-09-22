-module(bench_runner).

-export([run/2, run/3]).

%% Benchmarks kalman_bench:kf/7 for a given matrix backend module
%% (mat | oldmat | blasmat, ...), over the two correction paths used
%% by hera's actual sensor fusion: a 6x6 state (P/F/Q) with a UWB
%% range update (H: 1x6, S: 1x1) and a NAV update (H: 2x6, S: 2x2).
%%
%% Results (min/mean/median/max/stddev over N iterations, in
%% microseconds) are appended as CSV rows to Path, tagged with Stage
%% so results from different benchmark stages (OTP/toolchain/BLAS
%% updates) accumulate in one file.
%%
%% Usage from a remsh session on the board, e.g.:
%%   bench_runner:run(mat, "otp25-baseline").
%%   bench_runner:run(oldmat, "otp25-baseline").
%%
%% The default CSV path below is a guess at the on-target writable
%% SD card mount point and has NOT been verified against the actual
%% GRISP2 runtime filesystem layout yet -- pass an explicit Path
%% (run/3) once the correct location is confirmed on hardware.

-define(DEFAULT_PATH, "/media/mmcsd-1/bench_results.csv").
-define(ITERATIONS, 1000).

run(Mod, Stage) ->
    run(Mod, Stage, ?DEFAULT_PATH).

run(Mod, Stage, Path) ->
    ensure_header(Path),
    {F, P0, Q} = fixtures_6x6(Mod),
    UwbH = mk(Mod, [[1,0,0,0,0,0]]),
    UwbR = mk(Mod, [[0.01]]),
    UwbZ = mk(Mod, [[1.0]]),
    NavH = mk(Mod, [[0,1,0,0,0,0], [0,0,1,0,0,0]]),
    NavR = mk(Mod, [[0.01,0], [0,0.01]]),
    NavZ = mk(Mod, [[1.0], [1.0]]),
    X0 = Mod:zeros(6, 1),

    UwbStats = bench_path(Mod, {X0, P0}, F, Q, UwbH, UwbR, UwbZ),
    NavStats = bench_path(Mod, {X0, P0}, F, Q, NavH, NavR, NavZ),

    write_row(Path, Stage, Mod, "uwb_1x6", UwbStats),
    write_row(Path, Stage, Mod, "nav_2x6", NavStats),
    #{uwb => UwbStats, nav => NavStats}.

bench_path(Mod, State, F, Q, H, R, Z) ->
    Times = [time_one_iter(Mod, State, F, Q, H, R, Z) || _ <- lists:seq(1, ?ITERATIONS)],
    stats(Times).

time_one_iter(Mod, State, F, Q, H, R, Z) ->
    T0 = erlang:monotonic_time(microsecond),
    _ = kalman_bench:kf(Mod, State, F, H, Q, R, Z),
    T1 = erlang:monotonic_time(microsecond),
    T1 - T0.

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

fixtures_6x6(Mod) ->
    DT = 0.1,
    F = mk(Mod, [
        [1,0,0,DT,0,0],
        [0,1,0,0,DT,0],
        [0,0,1,0,0,DT],
        [0,0,0,1,0,0],
        [0,0,0,0,1,0],
        [0,0,0,0,0,1]
    ]),
    P0 = mk(Mod, [
        [1,0,0,0,0,0],
        [0,1,0,0,0,0],
        [0,0,1,0,0,0],
        [0,0,0,1,0,0],
        [0,0,0,0,1,0],
        [0,0,0,0,0,1]
    ]),
    Q = mk(Mod, [
        [0.01,0,0,0,0,0],
        [0,0.01,0,0,0,0],
        [0,0,0.01,0,0,0],
        [0,0,0,0.01,0,0],
        [0,0,0,0,0.01,0],
        [0,0,0,0,0,0.01]
    ]),
    {F, P0, Q}.

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
            {ok, Fd} = file:open(Path, [write]),
            ok = file:write(Fd, "stage,backend,path,n,min_us,mean_us,median_us,max_us,stddev_us\n"),
            ok = file:close(Fd)
    end.

write_row(Path, Stage, Mod, PathLabel, Stats) ->
    #{n := N, min := Min, max := Max, mean := Mean, median := Median, stddev := Stddev} = Stats,
    Line = io_lib:format("~s,~s,~s,~b,~b,~.3f,~.3f,~b,~.3f~n",
        [Stage, atom_to_list(Mod), PathLabel, N, Min, Mean, Median, Max, Stddev]),
    {ok, Fd} = file:open(Path, [append]),
    ok = file:write(Fd, Line),
    ok = file:close(Fd).
