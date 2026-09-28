# Host-only build of the vendored erlef/blas NIF, as a dynamic library
# for `rebar3 eunit` (see the test profile hook in rebar.config). On the
# GRiSP board the same C file is linked statically into ERTS by
# `rebar3 grisp build` instead, against the toolchain's netlib BLAS.

NIF_SRC = ../grisp/grisp2/common/build/nifs/blas_nif.c
C_SRC_OUTPUT = ../priv/eblas_nif.so

ERLANG_ROOT_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERL_INCLUDE_DIR = $(ERLANG_ROOT_DIR)/usr/include

CC ?= gcc
CFLAGS ?= -O3 -std=gnu99 -finline-functions -w

$(C_SRC_OUTPUT): $(NIF_SRC)
	mkdir -p $(dir $(C_SRC_OUTPUT))
	$(CC) $(CFLAGS) -DBLAS_DYNAMIC_NIF -fPIC -shared -o $@ $< \
		-I $(ERL_INCLUDE_DIR) -lopenblas -llapacke

clean:
	rm -f $(C_SRC_OUTPUT)
