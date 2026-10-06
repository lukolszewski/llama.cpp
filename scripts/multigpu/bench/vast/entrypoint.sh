#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh — PID 1 (or Vast.ai onstart command) of the llama.cpp-multigpu
# bench image (.devops/multigpu-bench.Dockerfile).
#
# Modes
#   bench     download the model, record the hardware, run the README grid
#             (scripts/multigpu/bench/readme_grid.py) against the fork's
#             llama-server and, if asked, against the upstream baseline build,
#             leave everything in $RESULTS_DIR and exit (DONE / FAILED marker).
#   serve     download if needed, exec llama-server with the production flags.
#   download  fetch the model and exit.
#   hardware  write the machine record and exit.
#   dry-run   print the server command lines, touch nothing.
#   shell     bash.
#
# Everything is an environment variable (see the "knobs" block); the defaults are
# the machine-01 benchmark configuration from docs/multigpu/benchmarks.md so a
# rented box measures exactly what the README describes. Nothing here needs a
# GitHub credential; the only secret that may be passed is HF_TOKEN (optional).
# =============================================================================
set -uo pipefail

MODE="${1:-bench}"
case "$MODE" in
  shell|bash) shift; exec bash "$@" ;;
  bench|serve|download|hardware|dry-run) shift $(( $# > 0 ? 1 : 0 )) ;;
  *) echo "FATAL: unknown mode '$MODE' (bench|serve|download|hardware|dry-run|shell)" >&2; exit 2 ;;
esac

# --- knobs: model ------------------------------------------------------------
MODEL_DIR="${MODEL_DIR:-/models}"
HF_REPO="${HF_REPO:-unsloth/Qwen3.8-Flash-Next-GGUF}"
QUANT="${QUANT:-UD-Q4_K_XL}"
HF_FILES="${HF_FILES:-}"                 # explicit repo paths (rehearsal with a small model)
MODEL_FILE="${MODEL_FILE:-}"             # basename of shard 1 in $MODEL_DIR; default: *$QUANT*-00001-of-*.gguf
ALIAS="${ALIAS:-qwen3.8-flash-next}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
# --- knobs: server (machine-01 benchmark configuration) ----------------------
PORT="${PORT:-8009}"
PARALLEL="${PARALLEL:-5}"
CTX="${CTX:-$(( PARALLEL * 262144 ))}"   # total context = PARALLEL x 262144
KV_TYPE="${KV_TYPE:-q8_0}"
UBATCH="${UBATCH:-512}"
BATCH="${BATCH:-2048}"
CACHE_RAM="${CACHE_RAM:-16384}"
DEVICES="${DEVICES-}"                    # unset = every visible GPU
TENSOR_SPLIT="${TENSOR_SPLIT-}"          # unset = VRAM-proportional, main GPU minus MAIN_GPU_RESERVE_GB
MAIN_GPU="${MAIN_GPU-0}"
MAIN_GPU_RESERVE_GB="${MAIN_GPU_RESERVE_GB:-3.6}"   # 24 GB x 0.15: reproduces machine-01's 0.85,1,1,1,1,1
NGL="${NGL:-99}"
OT="${OT-per_layer_token_embd\.weight=CPU}"   # PLE tensor stays on the host (mmap)
FA="${FA-on}"
JINJA="${JINJA:-1}"; TEMP="${TEMP:-1.0}"; TOP_P="${TOP_P:-0.95}"; TOP_K="${TOP_K:-20}"; MIN_P="${MIN_P:-0.0}"
PREFILL_MAX_PARTIAL="${PREFILL_MAX_PARTIAL-2}"      # fork-only flag; never passed to upstream
EXTRA_ARGS="${EXTRA_ARGS:-}"
# fork runtime switches (ignored by an upstream binary)
PIPELINE_PARALLEL="${PIPELINE_PARALLEL:-1}"
GRAPHS_FORCE="${GRAPHS_FORCE:-1}"
DECODE_PIPELINE="${DECODE_PIPELINE:-1}"
SERVER_GROUPS="${SERVER_GROUPS:-$PARALLEL}"
ATTN_ROT_DISABLE="${ATTN_ROT_DISABLE-}"             # unset = 1 unless KV is f16
# --- knobs: bench ------------------------------------------------------------
RESULTS_DIR="${RESULTS_DIR:-/results}"
MACHINE_NAME="${MACHINE_NAME:-TBD}"
BENCH_SIDES="${BENCH_SIDES:-multigpu}"              # "multigpu" or "multigpu,upstream" (patched side always first)
GRID_SLOTS="${GRID_SLOTS:-1,5}"
GRID_SIZES="${GRID_SIZES:-5000,50000,150000,200000,250000}"
UPSTREAM_GRID_SLOTS="${UPSTREAM_GRID_SLOTS:-$GRID_SLOTS}"
UPSTREAM_GRID_SIZES="${UPSTREAM_GRID_SIZES:-$GRID_SIZES}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/opt/upstream}"
UPSTREAM_TARBALL_URL="${UPSTREAM_TARBALL_URL:-}"    # default: the fork's baseline-<sha7> release asset (see below)
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-900}"             # s; PTX JIT on Turing can take minutes
MIN_GPUS="${MIN_GPUS:-2}"
MIN_VRAM_GB="${MIN_VRAM_GB:-140}"                   # 111 GB weights + 5 x 262k q8_0 KV + compute buffers
GRID_TIMEOUT="${GRID_TIMEOUT:-0}"                   # s per side, 0 = none

BIN_DIR=/app
INFO=/app/BUILD_INFO.json
mkdir -p "$RESULTS_DIR" 2>/dev/null || true
LOG="$RESULTS_DIR/bench.log"
log() { echo "[$(date '+%F %T %Z')] $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; { echo "$(date -u +%FT%TZ) $*"; } > "$RESULTS_DIR/FAILED"; exit 1; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

MG_COMMIT="$(json_get $INFO multigpu_commit)"; MG7="${MG_COMMIT:0:7}"
UP_COMMIT="$(json_get $INFO upstream_base_commit)"; UP7="${UP_COMMIT:0:7}"
[ -n "$UPSTREAM_TARBALL_URL" ] || UPSTREAM_TARBALL_URL="https://github.com/lukolszewski/llama.cpp-multigpu/releases/download/baseline-${UP7}/llama.cpp-upstream-${UP7}-bin-ubuntu-cuda-12.9-x64.tar.gz"

# ---------------------------------------------------------------------------
# GPU census and pre-flight
# ---------------------------------------------------------------------------
GPU_CSV="$(nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null || true)"
N_GPU="$(printf '%s\n' "$GPU_CSV" | grep -c . || true)"
if [ -z "$DEVICES" ] && [ "$N_GPU" -gt 0 ]; then DEVICES="$(seq -s, 0 $((N_GPU-1)))"; fi
SEL=(${DEVICES//,/ })
TOTAL_MIB=0; for i in "${SEL[@]}"; do m=$(printf '%s\n' "$GPU_CSV" | awk -F', ' -v i="$i" '$1==i{print $3}'); TOTAL_MIB=$((TOTAL_MIB + ${m:-0})); done
DRIVER_CUDA="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9.]+' | grep -oE '[0-9.]+' || echo 0)"
DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo unknown)"

preflight() {
  log "GPUs: $N_GPU visible, using [$DEVICES], $((TOTAL_MIB/1024)) GiB VRAM selected; driver $DRIVER_VER (CUDA $DRIVER_CUDA)"
  printf '%s\n' "$GPU_CSV" | sed 's/^/    /' | tee -a "$LOG"
  [ "${#SEL[@]}" -ge "$MIN_GPUS" ] || fail "need at least $MIN_GPUS GPUs, have ${#SEL[@]} (MIN_GPUS to override)"
  [ "$((TOTAL_MIB/1024))" -ge "$MIN_VRAM_GB" ] || fail "need >= $MIN_VRAM_GB GB of VRAM for this model, have $((TOTAL_MIB/1024)) GB (MIN_VRAM_GB to override)"
  # Ask the binary, not the version numbers: CUDA must initialise in THIS container on THIS driver
  # (2026-10-06: a forward-compat libcuda in the base image made ggml fall back to the CPU on a 570 driver).
  local devs; devs="$(/app/llama-server --list-devices 2>&1 | grep -cE '^\s*CUDA[0-9]+:' || true)"
  if [ "${devs:-0}" -lt "${#SEL[@]}" ]; then
    /app/llama-server --list-devices 2>&1 | tail -n 15 | tee -a "$LOG"
    fail "llama-server sees $devs CUDA device(s), need ${#SEL[@]}: the CUDA backend does not initialise on this host (driver/libcuda), refusing to continue"
  fi
  log "llama-server --list-devices: $devs CUDA device(s)"
  # Which GPUs have native code in this build? BUILD_INFO lists SASS and PTX targets; a PTX-only GPU needs a driver
  # that understands the toolkit's PTX (CUDA 12.9 -> R575+).
  local sass ptx toolkit
  sass="$(json_get $INFO cuda_sass)"; ptx="$(json_get $INFO cuda_ptx)"; toolkit="$(json_get $INFO cuda_toolkit_version)"
  local cc ccs; ccs="$(printf '%s\n' "$GPU_CSV" | awk -F', ' '{print $4}' | sort -u)"
  for cc in $ccs; do
    local sm="sm_${cc/./}"
    if printf '%s' "$sass" | grep -qE "(^|,)${sm}a?(,|$)"; then
      log "compute capability $cc: native code ($sm) in this build"
    elif printf '%s' "$ptx" | grep -qE "(^|,)${sm}(,|$)"; then
      log "compute capability $cc: PTX only ($sm) -> the driver JIT-compiles; needs driver CUDA >= ${toolkit%.*}"
      python3 -c "import sys; sys.exit(0 if float('$DRIVER_CUDA') >= float('${toolkit%.*}') else 1)" \
        || fail "GPU cc $cc has only PTX in this build and the driver reports CUDA $DRIVER_CUDA < ${toolkit%.*}; pick a host with a newer driver"
    else
      log "WARNING: compute capability $cc has neither SASS nor an exact PTX target in this build (SASS: $sass; PTX: $ptx); the driver will JIT the nearest lower PTX if it can"
    fi
  done
}

# VRAM-proportional tensor split; the main GPU gives up MAIN_GPU_RESERVE_GB for compute buffers (machine-01: 0.85 on 24 GB).
auto_split() {
  python3 - "$GPU_CSV" "$DEVICES" "$MAIN_GPU" "$MAIN_GPU_RESERVE_GB" <<'PY'
import sys
rows = {int(l.split(', ')[0]): float(l.split(', ')[2]) / 1024 for l in sys.argv[1].splitlines() if l.strip()}
dev = [int(x) for x in sys.argv[2].split(',') if x != '']
main = int(sys.argv[3] or 0); reserve = float(sys.argv[4])
if len(dev) < 2: print(""); sys.exit()
w = []
for pos, d in enumerate(dev):
    gb = rows.get(d, 0.0)
    if pos == main: gb = max(gb - reserve, gb * 0.5)
    w.append(gb)
top = max(w) or 1.0
print(",".join(f"{x/top:.2f}".rstrip('0').rstrip('.') for x in w))
PY
}

# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------
download_model() {
  log ">> model: $HF_REPO ${HF_FILES:-$QUANT} -> $MODEL_DIR"
  local t0; t0=$(date +%s)
  # straight into the log (no pipeline: a closed pipe would SIGPIPE aria2 mid-download, seen as exit 141)
  MODEL_DIR="$MODEL_DIR" HF_REPO="$HF_REPO" QUANT="$QUANT" HF_FILES="$HF_FILES" USE_MMPROJ=0 MTP=0 \
  ARIA_READOUT="${ARIA_READOUT:-false}" ARIA_SUMMARY="${ARIA_SUMMARY:-60}" PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}" \
    /usr/local/bin/download-model.sh >> "$LOG" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || fail "model download failed (exit $rc, see bench.log)"
  log ">> model: complete in $(( $(date +%s) - t0 )) s"
  echo "$(( $(date +%s) - t0 ))" > "$RESULTS_DIR/download-seconds"
}

resolve_model_file() {
  if [ -z "$MODEL_FILE" ]; then
    shopt -s nullglob; local sh=("$MODEL_DIR"/*"$QUANT"*-00001-of-*.gguf); shopt -u nullglob
    if [ ${#sh[@]} -eq 0 ]; then
      [ "$MODE" = "dry-run" ] && { MODEL_FILE="<$QUANT shard 1>"; return; }
      fail "no *${QUANT}*-00001-of-*.gguf in $MODEL_DIR (set MODEL_FILE for a single-file model)"
    fi
    MODEL_FILE="$(basename "${sh[0]}")"
  fi
  [ "$MODE" = "dry-run" ] || [ -f "$MODEL_DIR/$MODEL_FILE" ] || fail "$MODEL_DIR/$MODEL_FILE not found"
}

# ---------------------------------------------------------------------------
# server command line; $1 = multigpu|upstream
# ---------------------------------------------------------------------------
build_args() {
  local kind="$1"
  ARGS=(-m "$MODEL_DIR/$MODEL_FILE" --alias "$ALIAS" -ngl "$NGL")
  [ -n "$OT" ] && ARGS+=(-ot "$OT")
  [ -n "$TENSOR_SPLIT" ] && ARGS+=(--tensor-split "$TENSOR_SPLIT")
  [ -n "$MAIN_GPU" ] && [ "${#SEL[@]}" -gt 1 ] && ARGS+=(--main-gpu "$MAIN_GPU")
  ARGS+=(-c "$CTX")
  [ -n "$FA" ] && ARGS+=(-fa "$FA")
  ARGS+=(--parallel "$PARALLEL" --cache-type-k "$KV_TYPE" --cache-type-v "$KV_TYPE" --cache-ram "$CACHE_RAM" -b "$BATCH" -ub "$UBATCH")
  [ "$JINJA" = "1" ] && ARGS+=(--jinja)
  ARGS+=(--temp "$TEMP" --top-p "$TOP_P" --top-k "$TOP_K" --min-p "$MIN_P" --host 0.0.0.0 --port "$PORT" --metrics)
  [ "$kind" = multigpu ] && [ -n "$PREFILL_MAX_PARTIAL" ] && ARGS+=(--prefill-max-partial "$PREFILL_MAX_PARTIAL")
  [ -n "$EXTRA_ARGS" ] && { read -ra _x <<< "$EXTRA_ARGS"; ARGS+=("${_x[@]}"); }
}
export_env() {
  export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"
  [ -n "$DEVICES" ] && export CUDA_VISIBLE_DEVICES="$DEVICES"
  export LLAMA_PIPELINE_PARALLEL="$PIPELINE_PARALLEL" GGML_CUDA_GRAPHS_FORCE="$GRAPHS_FORCE"
  export LLAMA_DECODE_PIPELINE="$DECODE_PIPELINE" LLAMA_SERVER_GROUPS="$SERVER_GROUPS"
  [ -z "$ATTN_ROT_DISABLE" ] && [ "$KV_TYPE" != "f16" ] && ATTN_ROT_DISABLE=1
  [ -n "$ATTN_ROT_DISABLE" ] && export LLAMA_ATTN_ROT_DISABLE="$ATTN_ROT_DISABLE"
  ENV_LINE="CUDA_VISIBLE_DEVICES=${DEVICES:-<all>} LLAMA_DECODE_PIPELINE=$DECODE_PIPELINE LLAMA_SERVER_GROUPS=$SERVER_GROUPS LLAMA_PIPELINE_PARALLEL=$PIPELINE_PARALLEL GGML_CUDA_GRAPHS_FORCE=$GRAPHS_FORCE LLAMA_ATTN_ROT_DISABLE=${ATTN_ROT_DISABLE:-<unset>}"
}
quote_args() { local a out=(); for a in "$@"; do case "$a" in *[!A-Za-z0-9._\-/=]*) out+=("'${a//\'/\'\\\'\'}'") ;; *) out+=("$a") ;; esac; done; echo "${out[*]}"; }

# ---------------------------------------------------------------------------
# upstream baseline binaries (the fork's own build of its upstream base commit, same recipe)
# ---------------------------------------------------------------------------
fetch_upstream() {
  if [ -x "$UPSTREAM_DIR/llama-server" ]; then log ">> upstream: $UPSTREAM_DIR/llama-server present"; return 0; fi
  log ">> upstream: fetching $UPSTREAM_TARBALL_URL"
  mkdir -p "$UPSTREAM_DIR"
  # The baseline prerelease may still be building when the patched side finishes: poll for it (UPSTREAM_WAIT s).
  local waited=0
  until curl -fsSL --retry 3 --retry-delay 10 -o /tmp/upstream.tar.gz "$UPSTREAM_TARBALL_URL"; do
    waited=$((waited + 60))
    [ "$waited" -le "${UPSTREAM_WAIT:-3600}" ] || fail "upstream baseline tarball not available after ${UPSTREAM_WAIT:-3600}s ($UPSTREAM_TARBALL_URL); build it with .github/workflows/multigpu-baseline.yml or set UPSTREAM_TARBALL_URL"
    log "   upstream tarball not there yet (${waited}s), retrying in 60 s"; sleep 60
  done
  tar -xzf /tmp/upstream.tar.gz -C "$UPSTREAM_DIR" --strip-components=1 || fail "upstream tarball did not extract"
  rm -f /tmp/upstream.tar.gz
  [ -x "$UPSTREAM_DIR/llama-server" ] || fail "no llama-server in the upstream tarball"
  "$UPSTREAM_DIR/llama-server" --version 2>&1 | tee -a "$LOG" || true
}

# ---------------------------------------------------------------------------
# one side of the grid
# ---------------------------------------------------------------------------
SERVER_PID=""
stop_server() { [ -n "$SERVER_PID" ] || return 0; kill -INT "$SERVER_PID" 2>/dev/null; for _ in $(seq 1 60); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 1; done; kill -9 "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'stop_server' EXIT

run_side() {   # run_side multigpu|upstream BIN_DIR SLOTS SIZES
  local kind="$1" bin="$2" slots="$3" sizes="$4"
  local slog="$RESULTS_DIR/grid-$kind-server.log" out="$RESULTS_DIR/grid-$kind.json"
  build_args "$kind"
  log ">> [$kind] $bin/llama-server $(quote_args "${ARGS[@]}")"
  log ">> [$kind] env: $ENV_LINE"
  "$bin/llama-server" --version >> "$LOG" 2>&1 || true
  "$bin/llama-server" "${ARGS[@]}" > "$slog" 2>&1 &
  SERVER_PID=$!
  local t0 el=0; t0=$(date +%s)
  until curl -fsS -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 5; el=$(( $(date +%s) - t0 ))
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -n 200 "$slog" >> "$LOG"; fail "[$kind] llama-server exited during load after ${el}s (last 200 log lines in bench.log)"; }
    [ "$el" -lt "$HEALTH_TIMEOUT" ] || { tail -n 100 "$slog" >> "$LOG"; stop_server; fail "[$kind] /health not green after ${HEALTH_TIMEOUT}s"; }
    (( el % 60 == 0 )) && log "   [$kind] loading... ${el}s"
  done
  log ">> [$kind] healthy after ${el}s; grid slots=$slots sizes=$sizes"
  nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader 2>/dev/null | tr '\n' ';' | sed "s/^/   [$kind] VRAM after load: /" | tee -a "$LOG"; echo
  local used_mib=0 m
  for m in $(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null | awk -F', ' -v d=",$DEVICES," 'index(d, ","$1",") {print $2}'); do used_mib=$((used_mib + m)); done
  if [ "$used_mib" -lt "${MIN_LOADED_MIB:-10240}" ]; then stop_server; fail "[$kind] only ${used_mib} MiB of VRAM in use after load on GPUs [$DEVICES]: the model is not on the GPUs (CPU fallback?), see $slog"; fi
  local tcmd=(); [ "$GRID_TIMEOUT" -gt 0 ] && tcmd=(timeout "$GRID_TIMEOUT")
  "${tcmd[@]}" python3 /usr/local/bin/readme_grid.py "http://127.0.0.1:$PORT" "$kind" "$out" "$slots" "$sizes" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  stop_server
  [ "$rc" -eq 0 ] || fail "[$kind] readme_grid.py exited $rc"
  grep -q '"pp_agg"' "$out" || fail "[$kind] grid produced no successful row"
  grep -ciE 'CUDA error|GGML_ASSERT|out of memory|Segmentation' "$slog" | sed "s/^/   [$kind] error-looking lines in server log: /" | tee -a "$LOG"
  log ">> [$kind] done in $(( $(date +%s) - t0 )) s"
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
[ -z "$TENSOR_SPLIT" ] && [ "${#SEL[@]}" -gt 1 ] && TENSOR_SPLIT="$(auto_split)"
export_env

case "$MODE" in
  hardware) python3 /usr/local/bin/collect-hardware.py "$RESULTS_DIR" --machine-name "$MACHINE_NAME"; exit $? ;;
  download) download_model; exit 0 ;;
  dry-run)
    resolve_model_file
    for k in multigpu upstream; do build_args "$k"; echo "[$k] llama-server $(quote_args "${ARGS[@]}")"; done
    echo "env: $ENV_LINE"; echo "split: ${TENSOR_SPLIT:-<none>} (GPUs [$DEVICES], $((TOTAL_MIB/1024)) GiB)"; echo "upstream tarball: $UPSTREAM_TARBALL_URL"
    exit 0 ;;
  serve)
    [ "$SKIP_DOWNLOAD" = "1" ] || download_model
    resolve_model_file; build_args multigpu
    log ">> exec /app/llama-server $(quote_args "${ARGS[@]}")"; log ">> env: $ENV_LINE"
    rm -f /tmp/.serving; touch /tmp/.serving
    exec /app/llama-server "${ARGS[@]}" ;;
esac

# ---- bench ------------------------------------------------------------------
rm -f "$RESULTS_DIR/DONE" "$RESULTS_DIR/FAILED"
T_START=$(date +%s)
log "===== llama.cpp-multigpu bench: multigpu $MG7 (upstream base $UP7), sides=$BENCH_SIDES, machine=$MACHINE_NAME ====="
cp "$INFO" "$RESULTS_DIR/BUILD_INFO.json" 2>/dev/null || true
preflight
python3 /usr/local/bin/collect-hardware.py "$RESULTS_DIR" --machine-name "$MACHINE_NAME" 2>&1 | tee -a "$LOG"
[ "$SKIP_DOWNLOAD" = "1" ] || download_model
resolve_model_file
log ">> config: model=$MODEL_FILE ctx=$CTX parallel=$PARALLEL kv=$KV_TYPE ub=$UBATCH b=$BATCH fa=$FA split=${TENSOR_SPLIT:-<none>} main=$MAIN_GPU devices=[$DEVICES] cache_ram=$CACHE_RAM"
export MODEL_DIR HF_REPO QUANT HF_FILES MODEL_FILE PORT PARALLEL CTX KV_TYPE UBATCH BATCH CACHE_RAM DEVICES TENSOR_SPLIT MAIN_GPU MAIN_GPU_RESERVE_GB NGL OT FA JINJA TEMP TOP_P TOP_K MIN_P PREFILL_MAX_PARTIAL EXTRA_ARGS PIPELINE_PARALLEL GRAPHS_FORCE DECODE_PIPELINE SERVER_GROUPS ATTN_ROT_DISABLE BENCH_SIDES GRID_SLOTS GRID_SIZES UPSTREAM_GRID_SLOTS UPSTREAM_GRID_SIZES UPSTREAM_TARBALL_URL MACHINE_NAME HEALTH_TIMEOUT MIN_GPUS MIN_VRAM_GB
python3 - "$RESULTS_DIR/config.json" <<PY
import json, os, sys
keys = "MODEL_DIR HF_REPO QUANT HF_FILES MODEL_FILE PORT PARALLEL CTX KV_TYPE UBATCH BATCH CACHE_RAM DEVICES TENSOR_SPLIT MAIN_GPU MAIN_GPU_RESERVE_GB NGL OT FA JINJA TEMP TOP_P TOP_K MIN_P PREFILL_MAX_PARTIAL EXTRA_ARGS PIPELINE_PARALLEL GRAPHS_FORCE DECODE_PIPELINE SERVER_GROUPS ATTN_ROT_DISABLE BENCH_SIDES GRID_SLOTS GRID_SIZES UPSTREAM_GRID_SLOTS UPSTREAM_GRID_SIZES UPSTREAM_TARBALL_URL MACHINE_NAME HEALTH_TIMEOUT MIN_GPUS MIN_VRAM_GB".split()
env = {"MODEL_FILE": "$MODEL_FILE", "TENSOR_SPLIT": "$TENSOR_SPLIT", "CTX": "$CTX", "DEVICES": "$DEVICES", "ATTN_ROT_DISABLE": "${ATTN_ROT_DISABLE:-}"}
json.dump({k: env.get(k, os.environ.get(k, "")) for k in keys}, open(sys.argv[1], "w"), indent=1)
PY
{
  echo "multigpu commit: $MG_COMMIT (image $(json_get $INFO backend), CUDA $(json_get $INFO cuda_toolkit_version), SASS $(json_get $INFO cuda_sass), PTX $(json_get $INFO cuda_ptx))"
  echo "upstream base:   $UP_COMMIT"
} > "$RESULTS_DIR/COMMITS.txt"

for side in ${BENCH_SIDES//,/ }; do
  case "$side" in
    multigpu) run_side multigpu "$BIN_DIR" "$GRID_SLOTS" "$GRID_SIZES"; echo "$(date -u +%FT%TZ) multigpu" >> "$RESULTS_DIR/SIDES_DONE" ;;
    upstream) fetch_upstream
              echo "upstream binary: $("$UPSTREAM_DIR/llama-server" --version 2>&1 | tr '\n' ' ') from $UPSTREAM_TARBALL_URL" >> "$RESULTS_DIR/COMMITS.txt"
              run_side upstream "$UPSTREAM_DIR" "$UPSTREAM_GRID_SLOTS" "$UPSTREAM_GRID_SIZES"; echo "$(date -u +%FT%TZ) upstream" >> "$RESULTS_DIR/SIDES_DONE" ;;
    *) fail "unknown side '$side' in BENCH_SIDES" ;;
  esac
done
grep -q '^upstream binary' "$RESULTS_DIR/COMMITS.txt" || echo "upstream: not measured on this machine (BENCH_SIDES=$BENCH_SIDES)" >> "$RESULTS_DIR/COMMITS.txt"

if [ -f "$RESULTS_DIR/grid-upstream.json" ]; then
  python3 /usr/local/bin/readme_table.py "$RESULTS_DIR/grid-upstream.json" "$RESULTS_DIR/grid-multigpu.json" > "$RESULTS_DIR/grid-table.md" 2>>"$LOG" || true
  python3 /usr/local/bin/plot-grid.py "$RESULTS_DIR/grid-upstream.json" "$RESULTS_DIR/grid-multigpu.json" -o "$RESULTS_DIR/grid.svg" \
    --note "$MACHINE_NAME · ${#SEL[@]} × $(printf '%s\n' "$GPU_CSV" | head -1 | awk -F', ' '{print $2}') · $PARALLEL slots × $((CTX/PARALLEL)) ctx · $KV_TYPE KV · upstream $UP7 vs multigpu $MG7 · $(date +%F)" 2>>"$LOG" || true
else
  python3 /usr/local/bin/readme_table.py - "$RESULTS_DIR/grid-multigpu.json" > "$RESULTS_DIR/grid-table.md" 2>>"$LOG" || true
fi
WALL=$(( $(date +%s) - T_START ))
log "===== DONE in ${WALL}s (download $(cat "$RESULTS_DIR/download-seconds" 2>/dev/null || echo 0)s) ====="
{ echo "$(date -u +%FT%TZ) ok wall=${WALL}s sides=$BENCH_SIDES"; } > "$RESULTS_DIR/DONE"
exit 0
