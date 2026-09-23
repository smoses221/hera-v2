-module(mat).

-export([tr/1, inv/1]).
-export(['+'/2, '-'/2, '=='/2, '*'/2, '*´'/2]).
-export([row/2, col/2, get/3]).
-export([zeros/2, eye/1, diag/1]).
-export([eval/1]).
-export([matrix/1,to_array/1]).

-export_type([matrix/0]).

-type matrix() :: numerl:matrix().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% create matrix
matrix(M) ->
    numerl:matrix(M).

%% returns an array
to_array(M) ->
    numerl:mtfl(M).

%% transpose matrix
-spec tr(M) -> Transposed when
    M :: matrix(),
    Transposed :: matrix().

tr(M) ->
    numerl:transpose(M).


%% matrix addition (M3 = M1 + M2)
-spec '+'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'+'(M1, M2) ->
    numerl:add(M1,M2).


%% matrix subtraction (M3 = M1 - M2)
-spec '-'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'-'(M1, M2) ->
    numerl:sub(M1,M2).


%% matrix multiplication (M3 = Op1 * M2)
-spec '*'(Op1, M2) -> M3 when
    Op1 :: number() | matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'*'(N, M) when is_number(N) ->
    numerl:mult(M,N);
'*'(M1, M2) ->
    numerl:dot(M1,M2).


%% transposed matrix multiplication (M3 = M1 * tr(M2))
-spec '*´'(M1, M2) -> M3 when
    M1 :: matrix(),
    M2 :: matrix(),
    M3 :: matrix().

'*´'(M1, M2) ->
    numerl:dot(M1,tr(M2)).


%% return true if M1 equals M2 
-spec '=='(M1, M2) -> boolean() when
    M1 :: matrix(),
    M2 :: matrix().

'=='(M1, M2) ->
    numerl:equals(M1,M2).


%% return the row I of M
-spec row(I, M) -> Row when
    I :: pos_integer(),
    M :: matrix(),
    Row :: matrix().

row(I, M) ->
    numerl:row(I,M).


%% return the column J of M
-spec col(J, M) -> Col when
    J :: pos_integer(),
    M :: matrix(),
    Col :: matrix().

col(J, M) ->
    numerl:col(J,M).


%% return the element at index (I,J) in M
-spec get(I, J, M) -> Elem when
    I :: pos_integer(),
    J :: pos_integer(),
    M :: matrix(),
    Elem :: number().

get(I, J, M) ->
    numerl:get(I,J,M).


%% return a null matrix of size NxM
-spec zeros(N, M) -> Zeros when
    N :: pos_integer(),
    M :: pos_integer(),
    Zeros :: matrix().

zeros(N, M) ->
    numerl:zeros(N,M).


%% return an identity matrix of size NxN
-spec eye(N) -> Identity when
    N :: pos_integer(),
    Identity :: matrix().

eye(N) ->
    numerl:eye(N).


%% return a square diagonal matrix with the elements of L on the main diagonal
-spec diag(L) -> Diag when
    L :: [number(), ...],
    Diag :: matrix().

diag(L) ->
    N = length(L),
    D = diag(L, [[0 || _ <- lists:seq(1, N)] || _ <- lists:seq(1, N)] , 0, []),
    numerl:matrix(D).


%% compute the inverse of a square matrix
-spec inv(M) -> Invert when
    M :: matrix(),
    Invert :: matrix().

inv(M) ->
    %N = numerl:matrix(M),
    numerl:inv(M).


%% evaluate a list of matrix operations
-spec eval(Expr) -> Result when
    Expr :: [T],
    T :: matrix() | '+' | '-' | '*' | '*´',
    Result :: matrix().

% Evaluates strictly left to right, with no operator precedence.
eval([L|[O|[R|T]]]) ->
    F = fun mat:O/2,
    eval([F(L, R)|T]);
eval([Res]) ->
    Res.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% build a diagonal matrix from a zero matrix
diag([], [], _, Acc) ->
    lists:reverse(Acc);
diag([X|Xs], [Row|Rows], I, Acc) ->
    {L1, [_|T1]} = lists:split(I, Row),
    NewRow = lists:append([L1, [X], T1]),
    diag(Xs, Rows, I+1, [NewRow|Acc]).