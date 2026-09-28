-module(blasmat).

-export([tr/1, inv/1]).
-export(['+'/2, '-'/2, '=='/2, '*'/2, '*´'/2]).
-export([row/2, col/2, get/3]).
-export([zeros/2, eye/1, diag/1]).
-export([eval/1]).
-export([matrix/1,to_array/1]).

-export_type([matrix/0]).

%% Same API as mat.erl, backed by the erlef/blas NIF (vendored as
%% src/blas.erl + grisp/grisp2/common/build/nifs/blas_nif.c).
%%
%% A matrix is an immutable Erlang binary of row-major native float64s.
%% BLAS works in place on mutable c_binaries, so every BLAS-backed
%% operation writes into a fresh c_binary and copies the result back
%% out; read-only BLAS arguments are passed as the binary directly.
%% Pure data movement (tr, row, col, get, construction) stays in Erlang.
%%
%% All BLAS calls use blas:run/2 with `clean` scheduling: blas:run/1
%% would first run a dgemm timing benchmark (timeEst) to pick a
%% scheduler, which is pointless for the <= 6x6 matrices used here.

-record(blasmat, {rows, cols, bin}).

-type matrix() :: #blasmat{rows :: pos_integer(), cols :: pos_integer(), bin :: binary()}.

-define(EPSILON, 1.0e-6).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% create matrix from a list of rows
-spec matrix(L) -> matrix() when
    L :: [[number(), ...], ...].

matrix(L = [Row|_]) ->
    #blasmat{rows = length(L), cols = length(Row),
             bin = << <<(float(X)):64/native-float>> || R <- L, X <- R >>}.


%% returns the elements as a flat, row-major list of floats
to_array(#blasmat{bin = Bin}) ->
    [X || <<X:64/native-float>> <= Bin].


%% transpose matrix
-spec tr(M) -> Transposed when
    M :: matrix(),
    Transposed :: matrix().

tr(M = #blasmat{rows = R, cols = C}) ->
    T = list_to_tuple(to_array(M)),
    #blasmat{rows = C, cols = R,
             bin = << <<(element(I*C + J + 1, T)):64/native-float>>
                      || J <- lists:seq(0, C-1), I <- lists:seq(0, R-1) >>}.


%% matrix addition (M3 = M1 + M2)
-spec '+'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'+'(M1, M2) ->
    axpy(1.0, M2, M1).


%% matrix subtraction (M3 = M1 - M2)
-spec '-'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'-'(M1, M2) ->
    axpy(-1.0, M2, M1).


%% matrix multiplication (M3 = Op1 * M2)
-spec '*'(Op1, M2) -> M3 when
    Op1 :: number() | matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'*'(N, M = #blasmat{rows = R, cols = C, bin = Bin}) when is_number(N) ->
    X = blas:new(Bin),
    ok = blas:run({dscal, R*C, float(N), X, 1}, clean),
    M#blasmat{bin = blas:to_bin(X)};
'*'(#blasmat{rows = R1, cols = K, bin = A}, #blasmat{rows = K, cols = C2, bin = B}) ->
    gemm(n, R1, C2, K, A, K, B, C2).


%% transposed matrix multiplication (M3 = M1 * tr(M2)), done by dgemm
%% directly instead of materialising tr(M2)
-spec '*´'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'*´'(#blasmat{rows = R1, cols = K, bin = A}, #blasmat{rows = R2, cols = K, bin = B}) ->
    gemm(t, R1, R2, K, A, K, B, K).


%% return true if M1 equals M2, up to ?EPSILON per element (as numerl)
-spec '=='(M1, M2) -> boolean() when
    M1 :: matrix(),
    M2 :: matrix().

'=='(M1 = #blasmat{rows = R, cols = C}, M2 = #blasmat{rows = R, cols = C}) ->
    lists:all(fun({X, Y}) -> abs(X - Y) =< ?EPSILON end,
              lists:zip(to_array(M1), to_array(M2)));
'=='(_, _) ->
    false.


%% return the row I of M
-spec row(I, M) -> Row when
    I :: pos_integer(),
    M :: matrix(),
    Row :: matrix().

row(I, #blasmat{rows = R, cols = C, bin = Bin}) when I >= 1, I =< R ->
    #blasmat{rows = 1, cols = C, bin = binary:part(Bin, (I-1)*C*8, C*8)}.


%% return the column J of M
-spec col(J, M) -> Col when
    J :: pos_integer(),
    M :: matrix(),
    Col :: matrix().

col(J, M = #blasmat{rows = R, cols = C}) when J >= 1, J =< C ->
    #blasmat{rows = R, cols = 1,
             bin = << <<(get(I, J, M)):64/native-float>> || I <- lists:seq(1, R) >>}.


%% return the element at index (I,J) in M
-spec get(I, J, M) -> Elem when
    I :: pos_integer(),
    J :: pos_integer(),
    M :: matrix(),
    Elem :: float().

get(I, J, #blasmat{rows = R, cols = C, bin = Bin}) when I >= 1, I =< R, J >= 1, J =< C ->
    Skip = ((I-1)*C + J-1) * 8,
    <<_:Skip/binary, X:64/native-float, _/binary>> = Bin,
    X.


%% return a null matrix of size NxM
-spec zeros(N, M) -> Zeros when
    N :: pos_integer(),
    M :: pos_integer(),
    Zeros :: matrix().

zeros(N, M) ->
    #blasmat{rows = N, cols = M, bin = zero_bin(N*M)}.


%% return an identity matrix of size NxN
-spec eye(N) -> Identity when
    N :: pos_integer(),
    Identity :: matrix().

eye(N) ->
    diag(lists:duplicate(N, 1)).


%% return a square diagonal matrix with the elements of L on the main diagonal
-spec diag(L) -> Diag when
    L :: [number(), ...],
    Diag :: matrix().

diag(L) ->
    N = length(L),
    Indexed = lists:zip(lists:seq(1, N), L),
    matrix([[case I of J -> X; _ -> 0 end || J <- lists:seq(1, N)] || {I, X} <- Indexed]).


%% compute the inverse of a square matrix (LAPACKE dgetrf + dgetri)
-spec inv(M) -> Invert when
    M :: matrix(),
    Invert :: matrix().

inv(M = #blasmat{rows = N, cols = N, bin = Bin}) ->
    A = blas:new(Bin),
    Ipiv = blas:new(int32, lists:duplicate(N, 0)),
    ok = blas:run({dgetrf, blasRowMajor, N, N, A, N, Ipiv}, clean),
    ok = blas:run({dgetri, blasRowMajor, N, A, N, Ipiv}, clean),
    M#blasmat{bin = blas:to_bin(A)}.


%% evaluate a list of matrix operations
-spec eval(Expr) -> Result when
    Expr :: [T],
    T :: matrix() | '+' | '-' | '*' | '*´',
    Result :: matrix().

% Evaluates strictly left to right, with no operator precedence.
eval([L|[O|[R|T]]]) ->
    F = fun blasmat:O/2,
    eval([F(L, R)|T]);
eval([Res]) ->
    Res.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Y + Alpha*X, via daxpy on a copy of Y
axpy(Alpha, #blasmat{rows = R, cols = C, bin = X}, Y = #blasmat{rows = R, cols = C, bin = YBin}) ->
    Out = blas:new(YBin),
    ok = blas:run({daxpy, R*C, Alpha, X, 1, Out, 1}, clean),
    Y#blasmat{bin = blas:to_bin(Out)}.

%% (M x N) = A (M x K) * op(B), with op(B) = B (TransB = n) or tr(B) (t)
gemm(TransB, M, N, K, A, Lda, B, Ldb) ->
    C = blas:new(zero_bin(M*N)),
    ok = blas:run({dgemm, blasRowMajor, n, TransB, M, N, K,
                   1.0, A, Lda, B, Ldb, 0.0, C, N}, clean),
    #blasmat{rows = M, cols = N, bin = blas:to_bin(C)}.

%% N float64 zeros (+0.0 is all zero bits in IEEE 754)
zero_bin(N) ->
    <<0:(N*64)>>.
