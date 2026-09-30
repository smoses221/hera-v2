# Host-only builds of the static GRiSP NIFs as dynamic libraries, for
# `rebar3 eunit` (see the test profile hook in rebar.config). On the
# GRiSP board the same C files are linked statically into ERTS by
# `rebar3 grisp build` instead, against the toolchain's netlib BLAS.
#   blas_nif.c   -> priv/eblas_nif.so   (vendored erlef/blas; blasmat, blasws)
#   kfblas_nif.c -> priv/kfblas_nif.so  (fused Kalman steps; kfblas)

NIF_DIR = ../grisp/grisp2/common/build/nifs
PRIV = ../priv

ERLANG_ROOT_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERL_INCLUDE_DIR = $(ERLANG_ROOT_DIR)/usr/include

CC ?= gcc
CFLAGS ?= -O3 -std=gnu99 -finline-functions -w

all: $(PRIV)/eblas_nif.so $(PRIV)/kfblas_nif.so

$(PRIV)/eblas_nif.so: $(NIF_DIR)/blas_nif.c
	mkdir -p $(PRIV)
	$(CC) $(CFLAGS) -DBLAS_DYNAMIC_NIF -fPIC -shared -o $@ $< \
		-I $(ERL_INCLUDE_DIR) -lopenblas -llapacke

$(PRIV)/kfblas_nif.so: $(NIF_DIR)/kfblas_nif.c
	mkdir -p $(PRIV)
	$(CC) $(CFLAGS) -DKFBLAS_DYNAMIC_NIF -fPIC -shared -o $@ $< \
		-I $(ERL_INCLUDE_DIR) -lopenblas -llapacke -lm

clean:
	rm -f $(PRIV)/eblas_nif.so $(PRIV)/kfblas_nif.so

.PHONY: all clean
