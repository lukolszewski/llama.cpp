#!/usr/bin/env bash
# Single-slot benchmark suite: one active session, prefill and generation separately,
# at 5k / 50k / 150k / 200k / 250k prompt+context sizes.
#
# STATUS: implemented but NOT yet executed. No results exist; do not quote numbers from a run you
# have not performed on the machine named in the output header.
#
# Uses llama-bench (see tools/llama-bench) for pp/tg throughput on a real model file. Run the same
# script twice - once with an upstream llama.cpp binary, once with a multigpu binary - on the same
# machine, same model, same configuration, and record both commit hashes.
#
# Usage:
#   scripts/multigpu/bench/run-single-slot.sh --bin ./build/bin/llama-bench \
#       --model /data/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
#       [--sizes 5000,50000,150000,200000,250000] [--reps 3] [--out results.json]
#       [--extra "-sm layer -fa on"] [--env "LLAMA_DECODE_PIPELINE=1"]

set -euo pipefail

BENCH=""
MODEL=""
SIZES="5000,50000,150000,200000,250000"
REPS=3
OUT=""
EXTRA="-ngl 99 -sm layer -fa on"
EXTRA_ENV=""
UPSTREAM_COMMIT=""
MULTIGPU_COMMIT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bin)               BENCH="$2"; shift 2 ;;
        --model)             MODEL="$2"; shift 2 ;;
        --sizes)             SIZES="$2"; shift 2 ;;
        --reps)              REPS="$2"; shift 2 ;;
        --out)               OUT="$2"; shift 2 ;;
        --extra)             EXTRA="$2"; shift 2 ;;
        --env)               EXTRA_ENV="$2"; shift 2 ;;
        --upstream-commit)   UPSTREAM_COMMIT="$2"; shift 2 ;;
        --multigpu-commit)   MULTIGPU_COMMIT="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "run-single-slot: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$BENCH" ] || { echo "run-single-slot: --bin is required (path to llama-bench)" >&2; exit 1; }
[ -x "$BENCH" ] || { echo "run-single-slot: not executable: $BENCH" >&2; exit 1; }
[ -n "$MODEL" ] || { echo "run-single-slot: --model is required (first shard of a split GGUF)" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "run-single-slot: model file not found: $MODEL" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Record provenance with the run so a stray output file is still attributable. Explicit arguments win
# over autodetection: an upstream llama-bench binary is not built from this checkout, so its commit has
# to be passed in.
if [ -z "$MULTIGPU_COMMIT" ]; then
    MULTIGPU_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo TBD)"
fi
if [ -z "$UPSTREAM_COMMIT" ]; then
    UPSTREAM_COMMIT="$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/master 2>/dev/null \
        || git -C "$REPO_ROOT" rev-parse master 2>/dev/null || echo TBD)"
fi
echo "# llama.cpp-multigpu single-slot benchmark"
echo "# date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# hostname:        $(hostname)"
echo "# llama-bench:     $BENCH"
echo "# bench commit:    $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo TBD)"
echo "# multigpu commit: $MULTIGPU_COMMIT"
echo "# upstream commit: $UPSTREAM_COMMIT"
echo "# model:           $MODEL"
echo "# sizes:           $SIZES"
echo "# reps:            $REPS"
echo "# extra args:      $EXTRA"
echo "# extra env:       ${EXTRA_ENV:-none}"
echo "# nvidia driver:   $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo TBD)"
echo "# gpus:            $(nvidia-smi -L 2>/dev/null | wc -l || echo TBD)"
echo
echo "# NOTE: llama-bench -pg takes 'pp,tg' pairs; each size is measured for pp and tg separately."
echo "# NOTE: this suite uses ONE slot. The five-slot suite is scripts/multigpu/bench/run-5-slot.py"
echo
# llama-bench's -pg flag takes pp,tg pairs. Large tg is unnecessary here: generation throughput at a
# given context length is what we want, so a short tg window keeps runtimes sane.
CMD=("$BENCH" -m "$MODEL" -p 1 -n 32 -pg "$SIZES,32" -r "$REPS" -o csv ${EXTRA:+$EXTRA})
echo "\$ ${EXTRA_ENV:+env $EXTRA_ENV }${CMD[*]}"
echo

if [ -n "$EXTRA_ENV" ]; then
    env $EXTRA_ENV "${CMD[@]}" | tee "${OUT:-/dev/stdout}"
else
    "${CMD[@]}" | tee "${OUT:-/dev/stdout}"
fi

cat <<'EOF'

# Interpretation notes
# - pp column = prompt processing (prefill) tokens/s at that context depth.
# - tg column = generation tokens/s with that much context resident.
# - Compare against an upstream llama.cpp binary of a NAMED commit, same machine, same model file.
# - Record per-device VRAM (nvidia-smi during the run) and PCIe link state under load: both change the
#   result on this class of machine, and neither is in llama-bench output.
# - MTP drafts are out of scope for this fork (little single-user benefit, cost in multi-slot mode).
EOF
