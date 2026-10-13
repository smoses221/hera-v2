-module(kalman_bench).

-export([kf_predict/4, kf_update/5, kf/7]).
-export([ekf/7]).

%% Same equations as kalman.erl's kf/kf_predict/kf_update/ekf, parametrized
%% over the matrix backend module (mat | oldmat | blasmat, ...) so the
%% same code path can be used both to check a backend's correctness
%% against kalman.erl's golden values and to benchmark it, without
%% modifying the production kalman module.

kf(Mod, {X0, P0}, F, H, Q, R, Z) ->
    {Xp, Pp} = kf_predict(Mod, {X0, P0}, F, Q),
    kf_update(Mod, {Xp, Pp}, H, R, Z).


kf_predict(Mod, {X0, P0}, F, Q) ->
    Xp = Mod:'*'(F, X0),
    Pp = Mod:eval([F, '*', P0, '*´', F, '+', Q]),
    {Xp, Pp}.
%*´ is M3 = M1 * tr(M2)

kf_update(Mod, {Xp, Pp}, H, R, Z) ->
    S = Mod:eval([H, '*', Pp, '*´', H, '+', R]),
    Sinv = Mod:inv(S),
    K = Mod:eval([Pp, '*´', H, '*', Sinv]),
    Y = Mod:'-'(Z, Mod:'*'(H, Xp)),
    X1 = Mod:eval([K, '*', Y, '+', Xp]), % Terms are the other way around in my notes 
    P1 = Mod:'-'(Pp, Mod:eval([K, '*', H, '*', Pp])),
    {X1, P1}.


%% Extended Kalman filter without control input, as kalman:ekf/6.
%% [X0, P0, Q, R, Z] are Mod matrices; F, Jf, H, Jh are functions of
%% the state returning Mod matrices (Jf/Jh: Jacobians of F/H at X).
ekf(Mod, {X0, P0}, {F, Jf}, {H, Jh}, Q, R, Z) ->
    % Prediction
    Xp = F(X0),
    Jfx = Jf(X0),
    Pp = Mod:eval([Jfx, '*', P0, '*´', Jfx, '+', Q]),

    % Update
    Jhx = Jh(Xp),
    S = Mod:eval([Jhx, '*', Pp, '*´', Jhx, '+', R]),
    Sinv = Mod:inv(S),
    K = Mod:eval([Pp, '*´', Jhx, '*', Sinv]),
    Y = Mod:'-'(Z, H(Xp)),
    X1 = Mod:eval([K, '*', Y, '+', Xp]),
    P1 = Mod:'-'(Pp, Mod:eval([K, '*', Jhx, '*', Pp])),
    {X1, P1}.
