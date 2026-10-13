-module(blas).

%% Vendored from erlef/blas (https://github.com/erlef/blas), src/blas.erl
%% at commit 85acda8db5902af39764107f8436bc5eb0bcc67d. Apache-2.0.
%% Only on_load/0 is changed: blas isn't a separate application here, so
%% the NIF is looked up in hera's priv dir. On GRiSP the NIF is static
%% (grisp/grisp2/common/build/nifs/blas_nif.c) and the path is ignored.

-export([run/1, run/2, hash/1]).
-export([new/1, new/2, shift/2, copy/2, to_bin/1, to_bin/2, to_list/2, ltb/2, btl/2, predictor/0]).


-record(c_binary, {size, offset, resource}).

-on_load(on_load/0).

on_load()->
    LibBaseName = "eblas_nif",
    PrivDir = code:priv_dir(hera),
    Lib = filename:join([PrivDir, LibBaseName]),
    erlang:load_nif(Lib, {1.1}).

ltb(Type, List)->
    chain:ltb(Type, List).

btl(Type, Bin)->
    chain:btl(Type, Bin).


shift(Shift,C_binary=#c_binary{size=Size, offset=Offset}) when Shift+Offset >=0, Shift+Offset =< Size ->
    C_binary#c_binary{offset=Offset+Shift}.


% SIZE IN BYTES
new(Size) when is_integer(Size) andalso Size >= 0->
    #c_binary{size=Size, offset=0, resource=new_nif(Size)};
new(Binary) when is_binary(Binary) ->
    C = new(size(Binary)),
    copy(Binary, C),
    C.

new(Type, List) when is_list(List)->
    new(chain:ltb(Type, List)).

to_list(Type, Cbin=#c_binary{})->
    chain:btl(Type, to_bin(Cbin)).


new_nif(_)->
    nif_not_loaded.

copy(Binary, C_binary=#c_binary{offset=C_offset, size=C_size}) when size(Binary) =< C_size - C_offset ->
    copy_nif(Binary, C_binary).

copy_nif(_, _)->
    nif_not_loaded.


to_bin(C_binary=#c_binary{offset=Offset, size=C_size}) ->
    to_bin(C_size-Offset, C_binary).

to_bin(B_size, C_binary=#c_binary{offset=Offset, size=C_size}) when B_size>=0, B_size =< C_size-Offset->
    bin_nif(B_size, C_binary).

bin_nif(_,_)->
    nif_not_loaded.


predictor()->
    MaxSize = timeEst:benchmark(),
    fun(BlasOp) -> round(100*timeEst:n_elements(BlasOp) / MaxSize) end.

run(Wrapped)->
    % For some reason, using Predictor in on_load cause a crash. It seems nifs cannot be used that early.
    Predictor = 
        try persistent_term:get({?MODULE, pred}) of 
            B -> B
        catch 
            _:_ ->
                predictor(), 
                B = predictor(),
                persistent_term:put({?MODULE, pred}, B),
                B
    end,

    T = Predictor(Wrapped),
    run(Wrapped, T).


run(Wrapped, dirty) when is_tuple(Wrapped) -> dirty_unwrapper(Wrapped, 100);
run(Wrapped, clean) when is_tuple(Wrapped) -> clean_unwrapper(Wrapped, 50);
run(Wrapped, T) when T < 0   -> dirty_unwrapper(Wrapped, 100); %LAPACKE function.
run(Wrapped, T) when T < 100 -> clean_unwrapper(Wrapped, T);
run(Wrapped, T)              -> dirty_unwrapper(Wrapped, T).

dirty_unwrapper(_,_) -> nif_not_loaded.
clean_unwrapper(_,_) -> nif_not_loaded.
hash(_) -> nif_not_loaded.
