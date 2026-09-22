-module(bench_runner).

-export([run/2, run/3]).
-export([dump_csv/0, dump_csv/1]).

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
%% Usage from a serial/remsh session on the board, e.g.:
%%   bench_runner:run(mat, "otp25-baseline").
%%   bench_runner:run(oldmat, "otp25-baseline").
%%   bench_runner:dump_csv().  %% prints the accumulated results as
%%                             %% base64, to pull off over serial --
%%                             %% see dump_csv/1 below.

-define(DEFAULT_PATH, "/bench_results.csv").
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
