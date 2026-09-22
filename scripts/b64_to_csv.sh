#!/usr/bin/env bash
# Decodes a captured serial-terminal log (containing the
# -----BEGIN BENCH CSV-----/-----END BENCH CSV----- block printed by
# bench_runner:dump_csv/0,1) into a real CSV file, saved under
# data/<DD-MM-YYYY_HH-MM-SS>/ (EU date order), timestamped for when
# it was pulled off the board.
#
# Usage: scripts/b64_to_csv.sh <captured_serial_log> [output_csv_name]
#
# <captured_serial_log> is your terminal's raw scrollback/log file
# (screen/minicom/picocom/PuTTY logging, etc.) covering the
# bench_runner:dump_csv() call -- everything outside the BEGIN/END
# markers (shell prompts, echoed commands, other output) is ignored.
set -euo pipefail

INPUT="${1:?usage: b64_to_csv.sh <captured_serial_log> [output_csv_name]}"
OUT_NAME="${2:-bench_results.csv}"

if [ ! -f "$INPUT" ]; then
    echo "No such file: $INPUT" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMESTAMP="$(date +%d-%m-%Y_%H-%M-%S)"
OUT_DIR="$REPO_ROOT/data/${TIMESTAMP}"
OUT_FILE="${OUT_DIR}/${OUT_NAME}"

if ! grep -q -- '-----BEGIN BENCH CSV' "$INPUT"; then
    echo "No '-----BEGIN BENCH CSV' marker found in $INPUT -- did you capture the full bench_runner:dump_csv() output?" >&2
    exit 1
fi
if ! grep -q -- '-----END BENCH CSV-----' "$INPUT"; then
    echo "No '-----END BENCH CSV-----' marker found in $INPUT -- capture looks truncated." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

sed -n '/-----BEGIN BENCH CSV/,/-----END BENCH CSV-----/p' "$INPUT" \
    | sed '1d;$d' \
    | tr -d '\r' \
    | base64 -d > "$OUT_FILE"

echo "Wrote $(wc -l < "$OUT_FILE" | tr -d ' ') lines to $OUT_FILE"
