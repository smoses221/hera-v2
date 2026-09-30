-module(blasws).

-export([new/2, set_model/3, set_state/3, get_state/1]).
-export([predict/1, update/4, kf_step/4]).
-export([ekf_predict/1, ekf_update/5]).

%% Diagnostic backend between blasmat and kfblas: the same algorithm
%% and API as kfblas, but done with one erlef/blas call per operation
%% (blas:run/2, as blasmat), on c_binary buffers allocated once by
%% new/2 and reused every step (no per-operation allocation, no
%% to_bin copy of intermediate results).
%%
%% Comparing blasmat -> blasws -> kfblas separates the cost of
%% allocation/copying from the cost of making ~15 NIF calls per step.
%%
%% Like kfblas, a workspace is mutable: steps update its buffers in
%% place and return `ok`. Use one from one process only. Matrices are
%% row-major native float64 binaries.
%%
%% Matrix-vector products use dgemm with one column, because erlef's
%% dgemv bounds check is wrong for non-square matrices (see the header
%% of blas_nif.c).

-record(ws, {n, mmax,
             x, p, f, q,     % state and model
             xp, t,          % predict scratch
             pht, k, s, y}). % update scratch

%% new(N, MaxM) -> Ws. Starts with x = 0, P = I, F = I, Q = 0.
new(N, MaxM) when N >= 1, MaxM >= 1, MaxM =< N ->
    Z = fun(Count) -> blas:new(<<0:(Count*64)>>) end,
    Eye = blas:new(eye_bin(N)),
    #ws{n = N, mmax = MaxM,
        x = Z(N), p = Eye, f = blas:new(eye_bin(N)), q = Z(N*N),
        xp = Z(N), t = Z(N*N),
        pht = Z(N*MaxM), k = Z(N*MaxM), s = Z(MaxM*MaxM), y = Z(MaxM)}.

set_model(#ws{f = F, q = Q}, FBin, QBin) ->
    ok = blas:copy(FBin, F),
    ok = blas:copy(QBin, Q).

set_state(#ws{x = X, p = P}, XBin, PBin) ->
    ok = blas:copy(XBin, X),
    ok = blas:copy(PBin, P).

get_state(#ws{x = X, p = P}) ->
    {blas:to_bin(X), blas:to_bin(P)}.

%% x = F x;  P = F P F' + Q
predict(#ws{n = N, x = X, p = P, f = F, q = Q, xp = Xp, t = T}) ->
    run({dgemm, blasRowMajor, n, n, N, 1, N, 1.0, F, N, X, 1, 0.0, Xp, 1}),
    run({dcopy, N, Xp, 1, X, 1}),
    run({dgemm, blasRowMajor, n, n, N, N, N, 1.0, F, N, P, N, 0.0, T, N}),
    run({dcopy, N*N, Q, 1, P, 1}),
    run({dgemm, blasRowMajor, n, t, N, N, N, 1.0, T, N, F, N, 1.0, P, N}).

%% Linear update with M = byte_size(Z) div 8 measurements.
update(Ws = #ws{n = N, x = X, y = Y}, H, R, Z) ->
    M = byte_size(Z) div 8,
    ok = blas:copy(Z, Y),
    run({dgemm, blasRowMajor, n, n, M, 1, N, -1.0, H, N, X, 1, 1.0, Y, 1}),
    correct(Ws, M, H, R).

kf_step(Ws, H, R, Z) ->
    predict(Ws),
    update(Ws, H, R, Z).

ekf_predict(Ws = #ws{x = X}) ->
    predict(Ws),
    blas:to_bin(X).

%% EKF update with Jacobian Jh and h(Xp) = Hx:  y = z - Hx.
ekf_update(Ws = #ws{y = Y}, Jh, Hx, R, Z) ->
    M = byte_size(Z) div 8,
    ok = blas:copy(Z, Y),
    run({daxpy, M, -1.0, Hx, 1, Y, 1}),
    correct(Ws, M, Jh, R).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Rest of the update once y is in place:
%%   PHt = P H';  S = H PHt + R;  K = PHt S^-1;  x += K y;  P -= K PHt'
correct(#ws{n = N, x = X, p = P, pht = PHt, k = K, s = S, y = Y}, M, H, R) ->
    run({dgemm, blasRowMajor, n, t, N, M, N, 1.0, P, N, H, N, 0.0, PHt, M}),
    ok = blas:copy(R, S),
    run({dgemm, blasRowMajor, n, n, M, M, N, 1.0, H, N, PHt, M, 1.0, S, M}),
    run({dcopy, N*M, PHt, 1, K, 1}),
    case M of
        1 ->
            <<S11:64/native-float>> = blas:to_bin(8, S),
            run({dscal, N, 1.0 / S11, K, 1});
        _ ->
            %% S is symmetric, and K (row-major N x M) read col-major
            %% is K' (M x N), so this solves S K' = PHt' in place.
            run({dpotrf, blasColMajor, 'L', M, S, M}),
            run({dpotrs, blasColMajor, 'L', M, N, S, M, K, M})
    end,
    run({dgemm, blasRowMajor, n, n, N, 1, M, 1.0, K, M, Y, 1, 1.0, X, 1}),
    run({dgemm, blasRowMajor, n, t, N, N, M, -1.0, K, M, PHt, M, 1.0, P, N}).

run(Call) ->
    ok = blas:run(Call, clean).

eye_bin(N) ->
    << <<(case I of J -> 1.0; _ -> 0.0 end):64/native-float>>
       || I <- lists:seq(1, N), J <- lists:seq(1, N) >>.
