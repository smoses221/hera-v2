-module(kalman_bench).

-export([kf_predict/4, kf_update/5, kf/7]).

%% Same equations as kalman.erl's kf/kf_predict/kf_update, parametrized
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
