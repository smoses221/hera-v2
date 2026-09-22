#!/usr/bin/env bash
# Prints an Erlang expression that loads a freshly host-compiled
# module's .beam into a running node -- paste the printed text
# directly into a live serial or remsh shell on the board to
# hot-update that one module without a full redeploy.
#
# BEAM bytecode is portable across host/target architecture (only
# NIFs need cross-compiling), so a module compiled here with
# `rebar3 compile` loads and runs fine on the GRISP target as long
# as the target's OTP version can still read this bytecode version
# -- this stops being true across an OTP major-version bump, where a
# real redeploy is required instead.
#
# Usage: scripts/beam_to_paste.sh <module> [profile]
set -euo pipefail

MODULE="${1:?usage: beam_to_paste.sh <module> [profile]}"
PROFILE="${2:-default}"
BEAM="_build/${PROFILE}/lib/hera/ebin/${MODULE}.beam"

rebar3 compile >/dev/null

if [ ! -f "$BEAM" ]; then
    echo "No such beam file: $BEAM" >&2
    echo "(compiled a different module name, or wrong profile?)" >&2
    exit 1
fi

echo "B64 ="
base64 -w 76 "$BEAM" | sed 's/^/"/; s/$/"/'
echo ",{module, ${MODULE}} = code:load_binary(${MODULE}, \"${MODULE}.beam\", base64:decode(B64))."
