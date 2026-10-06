#!/usr/bin/env bash
# =============================================================================
# test-local.sh — verify the bench image on the workstation without renting anything and without
# touching the production GPUs. Three gates:
#
#   dryrun    argument assembly for both sides (no GPU, no network)
#   download  the real downloader against a public repo without a token (one 640 MB file), then the
#             idempotent re-run (must SKIP) and a truncated-file resume
#   bench     a complete `bench` run on ONE spare GPU with a small model: hardware record, server,
#             grid rows, table, DONE marker
#
#   ./test-local.sh                 # all gates
#   ./test-local.sh bench           # one gate
#   IMAGE=ghcr.io/lukolszewski/llama.cpp-multigpu:bench-cuda12.9-dev GPU_DEVICE=6 ./test-local.sh
#
# Defaults build the image locally from the latest release server image. GPU_DEVICE must be a GPU that
# is not serving anything (machine-01: index 6, the RTX 5060 Ti). SMALL_MODEL_DIR/SMALL_MODEL point at any
# small GGUF on disk; the download gate fetches its own.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9}"
IMAGE="${IMAGE:-llama.cpp-multigpu:bench-local-test}"
GPU_DEVICE="${GPU_DEVICE:-6}"
TEST_ROOT="${TEST_ROOT:-${TMPDIR:-/tmp}/mgbench-local-test}"
SMALL_MODEL_DIR="${SMALL_MODEL_DIR:-$TEST_ROOT/models}"
SMALL_MODEL="${SMALL_MODEL:-Qwen3-0.6B-Q8_0.gguf}"
GATES=("${@:-all}")

say()  { printf '\n\033[1m### %s\033[0m\n' "$*"; }
pass() { echo "   PASS: $*"; }
fail() { echo "   FAIL: $*" >&2; exit 1; }

if [ -z "${IMAGE_PREBUILT:-}" ] && ! docker image inspect "$IMAGE" >/dev/null 2>&1 || [ -n "${REBUILD:-}" ]; then
  say "build $IMAGE from $BASE_IMAGE"
  docker build -q -f "$ROOT/.devops/multigpu-bench.Dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" "$ROOT" >/dev/null || fail "docker build failed"
  pass "built"
fi

gate_dryrun() {
  say "GATE dry-run: both command lines, fork flag only on the multigpu side"
  local out; out=$(docker run --rm "$IMAGE" dry-run) || fail "dry-run exited non-zero"
  echo "$out" | sed 's/^/   /'
  grep -E '^\[multigpu\].*--prefill-max-partial 2' <<<"$out" >/dev/null || fail "multigpu line lacks --prefill-max-partial"
  grep -E '^\[upstream\]' <<<"$out" | grep -q -- '--prefill-max-partial' && fail "upstream line carries a fork-only flag"
  for a in '-c 1310720' '--parallel 5' '--cache-type-k q8_0' '-b 2048 -ub 512' '-fa on' "per_layer_token_embd"; do grep -q -- "$a" <<<"$out" || fail "missing: $a"; done
  grep -q 'baseline-' <<<"$out" || fail "no default upstream tarball URL"
  pass "command lines match the machine-01 configuration"
}

dl() { docker run --rm -e HF_REPO=unsloth/Qwen3-0.6B-GGUF -e HF_FILES="$SMALL_MODEL" -e PROGRESS_INTERVAL=5 -v "$SMALL_MODEL_DIR:/models" "$IMAGE" download 2>&1; }
gate_download() {
  say "GATE download: public repo, no token, one file"
  mkdir -p "$SMALL_MODEL_DIR"; rm -f "$SMALL_MODEL_DIR/$SMALL_MODEL" "$SMALL_MODEL_DIR/$SMALL_MODEL.aria2"
  local out; out=$(dl) || { echo "$out" | tail -20; fail "download mode failed"; }
  echo "$out" | grep -E 'HF_TOKEN|PLAN|DONE|finished' | sed 's/^/   /'
  grep -q 'HF_TOKEN not set' <<<"$out" || fail "token-optional path not taken"
  [ -s "$SMALL_MODEL_DIR/$SMALL_MODEL" ] || fail "file missing"
  pass "downloaded anonymously"
  say "GATE download: re-run must SKIP"
  out=$(dl); grep -q 'SKIP' <<<"$out" || fail "second run did not skip"; grep -q 'GET ' <<<"$out" && fail "second run fetched bytes"
  pass "idempotent"
  say "GATE download: truncated file must RESUME to the exact sha256"
  local size; size=$(stat -c %s "$SMALL_MODEL_DIR/$SMALL_MODEL")
  truncate -s $((size/2)) "$SMALL_MODEL_DIR/$SMALL_MODEL"
  out=$(dl); grep -q 'DONE' <<<"$out" || { echo "$out" | tail -10; fail "resume did not complete"; }
  [ "$(stat -c %s "$SMALL_MODEL_DIR/$SMALL_MODEL")" -eq "$size" ] || fail "resumed size differs"
  pass "resumed (aria2 verified the checksum)"
}

gate_bench() {
  say "GATE bench: full bench mode on GPU $GPU_DEVICE with $SMALL_MODEL (2 slots, 2000 tokens)"
  [ -f "$SMALL_MODEL_DIR/$SMALL_MODEL" ] || fail "no $SMALL_MODEL_DIR/$SMALL_MODEL (run the download gate first or point SMALL_MODEL_DIR at one)"
  local res="$TEST_ROOT/results"; rm -rf "$res"; mkdir -p "$res"
  docker run --rm --gpus "\"device=$GPU_DEVICE\"" -e SKIP_DOWNLOAD=1 -e MODEL_FILE="$SMALL_MODEL" -e PARALLEL=2 -e CTX=16384 \
    -e GRID_SLOTS=1,2 -e GRID_SIZES=2000 -e MIN_GPUS=1 -e MIN_VRAM_GB=8 -e OT= -e MACHINE_NAME=local-test -e HEALTH_TIMEOUT=300 \
    -v "$SMALL_MODEL_DIR:/models:ro" -v "$res:/results" "$IMAGE" bench 2>&1 | grep -E 'GPUs:|compute capability|hardware record|healthy|slots=|DONE|FAILED' | sed 's/^/   /'
  [ -f "$res/DONE" ] || { tail -30 "$res/bench.log"; fail "no DONE marker"; }
  for f in hardware.md hardware.json config.json COMMITS.txt BUILD_INFO.json grid-multigpu.json grid-multigpu-server.log grid-table.md; do [ -s "$res/$f" ] || fail "$f missing/empty"; done
  python3 - "$res/grid-multigpu.json" <<'PY' || fail "grid rows incomplete"
import json, sys
d = json.load(open(sys.argv[1])); rows = d["rows"]
assert len(rows) == 2 and all("pp_agg" in r and "tg_agg" in r for r in rows), rows
print("   rows:", [(r["slots"], r["size_tokens"], r["pp_slot_mean"], r["tg_slot_mean"]) for r in rows])
PY
  cat "$res/grid-table.md" | sed 's/^/   /'
  pass "bench mode produced a complete results directory in $res"
}

for g in "${GATES[@]}"; do
  case "$g" in
    all) gate_dryrun; gate_download; gate_bench ;;
    dryrun) gate_dryrun ;; download) gate_download ;; bench) gate_bench ;;
    *) fail "unknown gate $g (dryrun|download|bench|all)" ;;
  esac
done
say "all requested gates passed"
