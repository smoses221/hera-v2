-module(kfblas).

-export([new/2, set_model/3, set_state/3, get_state/1]).
-export([predict/1, update/4, kf_step/4]).
-export([ekf_predict/1, ekf_update/5, ekf_range_step/5]).

%% A whole Kalman filter step in one NIF call, on cblas/LAPACKE
%% (grisp/grisp2/common/build/nifs/kfblas_nif.c). All buffers are
%% allocated once by new/2 and reused, so steps don't allocate.
%%
%% A Filter is a mutable NIF resource holding x, P, F, Q and all
%% scratch space: the step functions update it in place and return
%% `ok`. Use one Filter from one process only.
%%
%% Matrices and vectors are row-major native float64 binaries
%% (<<X:64/native-float, ...>>), e.g. from blasmat:matrix/1's binary
%% or f64/1 in bench_runner.
%%
%% Same equations as kalman_bench:kf/7 and ekf/7, except that K is
%% obtained by a Cholesky solve (dpotrf/dpotrs) instead of inverting
%% S, and m = 1 is a plain division.

-on_load(on_load/0).

on_load() ->
    %% Static NIF on GRiSP (path ignored), priv/kfblas_nif.so on the host.
    erlang:load_nif(filename:join(code:priv_dir(hera), "kfblas_nif"), 0).

%% new(N, MaxM) -> Filter: state size N, up to MaxM measurements per
%% update. Starts with x = 0, P = I, F = I, Q = 0.
new(_N, _MaxM) -> erlang:nif_error(nif_not_loaded).

%% set_model(Filter, F, Q) -> ok   (N x N each)
set_model(_Filter, _F, _Q) -> erlang:nif_error(nif_not_loaded).

%% set_state(Filter, X, P) -> ok   (N, N x N)
set_state(_Filter, _X, _P) -> erlang:nif_error(nif_not_loaded).

%% get_state(Filter) -> {X, P}, copied out as binaries.
get_state(_Filter) -> erlang:nif_error(nif_not_loaded).

%% predict(Filter) -> ok:  x = F x, P = F P F' + Q.
predict(_Filter) -> erlang:nif_error(nif_not_loaded).

%% update(Filter, H, R, Z) -> ok | {error, not_positive_definite}
%% Linear update with M = byte_size(Z) div 8 measurements
%% (H: M x N, R: M x M).
update(_Filter, _H, _R, _Z) -> erlang:nif_error(nif_not_loaded).

%% kf_step(Filter, H, R, Z): predict/1 + update/4 in one call.
kf_step(_Filter, _H, _R, _Z) -> erlang:nif_error(nif_not_loaded).

%% ekf_predict(Filter) -> Xp: predict/1, then returns the predicted
%% state so the caller can evaluate h(Xp) and its Jacobian.
ekf_predict(_Filter) -> erlang:nif_error(nif_not_loaded).

%% ekf_update(Filter, Jh, Hx, R, Z) -> ok | {error, not_positive_definite}
%% EKF update with Jacobian Jh (M x N) and h(Xp) = Hx (M).
ekf_update(_Filter, _Jh, _Hx, _R, _Z) -> erlang:nif_error(nif_not_loaded).

%% ekf_range_step(Filter, {Ix, Iy, Iz}, Anchor, R, Z): predict + EKF
%% update for a single range Z = |p - Anchor| with the range model in
%% C: one call, nothing built in Erlang. {Ix, Iy, Iz}: 0-based indices
%% of the position in x. Anchor: 3 doubles; R, Z: 1 double each.
ekf_range_step(_Filter, _PosIdx, _Anchor, _R, _Z) -> erlang:nif_error(nif_not_loaded).
