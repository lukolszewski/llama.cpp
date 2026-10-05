#!/usr/bin/env bash
# Tier B: runtime validation on a real multi-GPU machine.
#
# This is the only validation that actually proves the binaries work, and it cannot run on
# GitHub-hosted CI (no GPU there, and public CI must not download a ~111 GB model). It runs on the
# benchmark machine itself - locally, or through .github/workflows/multigpu-selfhosted.yml.
#
# Scope: start a 5-slot server on the target model, prefill, generate a few tokens on all slots,
# capture per-device VRAM and the PCIe/link state during load, then shut down. It is a smoke test,
# NOT a benchmark: no throughput claim may be drawn from it.
#
# Usage:
#   scripts/multigpu/bench/runtime-smoke.sh --model /path/to/...-00001-of-00004.gguf \
#       [--bin ./build/bin/llama-server] [--slots 5] [--ctx 32768] [--port 8080] \
#       [--env LLAMA_DECODE_PIPELINE=1] [--out DIR]
#
# Exit code 0 = the patched build served real requests on real hardware.

set -uo pipefail

MODEL=""
BIN="./build/bin/llama-server"
SLOTS=5
CTX=32768
PORT=8080
EXTRA_ENV=""
OUT="runtime-smoke"
NGL=99
LOGGED_ARGS="-sm layer -fa on"
TIMEOUT_START=3600   # a 111 GB model on 6 devices takes a while to load

while [ $# -gt 0 ]; do
    case "$1" in
        --model)    MODEL="$2"; shift 2 ;;
        --bin)      BIN="$2"; shift 2 ;;
        --slots)    SLOTS="$2"; shift 2 ;;
        --ctx)      CTX="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --ngl)      NGL="$2"; shift 2 ;;
        --args)     LOGGED_ARGS="$2"; shift 2 ;;
        --env)      EXTRA_ENV="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "runtime-smoke: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$MODEL" ] || { echo "runtime-smoke: --model is required" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "runtime-smoke: model not found: $MODEL" >&2; exit 1; }
[ -x "$BIN" ]   || { echo "runtime-smoke: server binary not executable: $BIN" >&2; exit 1; }

mkdir -p "$OUT"
SERVER_LOG="$OUT/server.log"
URL="http://127.0.0.1:$PORT"

echo "# llama.cpp-multigpu Tier B runtime smoke"
echo "date:    $(date -u --iso-8601=seconds)"
echo "host:    $(hostname)"
echo "binary:  $BIN"
echo "model:   $MODEL"
echo "slots:   $SLOTS  ctx: $CTX  args: $LOGGED_ARGS  env: ${EXTRA_ENV:-none}"
echo "commit:  $(git rev-parse HEAD 2>/dev/null || echo TBD)"
echo "driver:  $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo TBD)"
echo

# Refuse to run on a machine whose GPUs are already busy: a smoke test that fails because slot 3 is
# holding a running server proves nothing about the build.
if command -v nvidia-smi > /dev/null 2>&1; then
    busy="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -n | tail -1)"
    echo "max per-GPU memory in use before start: ${busy} MiB"
    if [ "${busy:-0}" -gt 2048 ]; then
        echo "!! GPUs already appear busy. Stop the existing server first - this test is not a"
        echo "   benchmark and a contended GPU makes it meaningless."
        exit 1
    fi
fi

CMD="$BIN -m $MODEL -ngl $NGL -np $SLOTS --ctx-size $CTX --port $PORT $LOGGED_ARGS"
echo "\$ ${EXTRA_ENV:+env $EXTRA_ENV }$CMD"
if [ -n "$EXTRA_ENV" ]; then
    env $EXTRA_ENV $CMD > "$SERVER_LOG" 2>&1 &
else
    $CMD > "$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

cleanup() {
    echo "-- stopping server (pid $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "-- waiting for /health (up to ${TIMEOUT_START}s; the model is ~111 GB)"
ok=no
for _ in $(seq 1 "$TIMEOUT_START"); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "!! server exited during startup; last 40 log lines:"; tail -40 "$SERVER_LOG"; exit 1
    fi
    if curl -sf "$URL/health" > /dev/null 2>&1; then ok=yes; break; fi
    sleep 1
done
[ "$ok" = yes ] || { echo "!! server never became healthy"; tail -40 "$SERVER_LOG"; exit 1; }
echo "server healthy"

echo "-- prefill + generate on one slot"
curl -sf "$URL/completion" -H 'Content-Type: application/json' \
    -d '{"prompt":"Explain why PCIe link width matters for multi-GPU inference.","n_predict":32,"temperature":0,"seed":1,"cache_prompt":false}' \
    -o "$OUT/one_slot.json" || { echo "!! single-slot request failed"; tail -30 "$SERVER_LOG"; exit 1; }
python3 - "$OUT/one_slot.json" <<'PY' || exit 1
import json,sys
d=json.load(open(sys.argv[1]))
if d.get("error"): print("!! server error:", d["error"]); sys.exit(1)
n=d.get("tokens_predicted") or d.get("timings",{}).get("predicted_n") or 0
pp=d.get("tokens_evaluated") or d.get("timings",{}).get("prompt_eval_len") or 0
print(f"   evaluated {pp} prompt tokens, generated {n} tokens")
if int(n) < 1: print("!! no tokens generated"); sys.exit(1)
PY

echo "-- concurrent prefill on all $SLOTS slots"
pids=""
for s in $(seq 0 $((SLOTS - 1))); do
    body="$(python3 -c "
import json,sys
n=int(sys.argv[1]); rng=' '.join(f'tok{i%997}' for i in range(n))
print(json.dumps({'prompt':rng,'n_predict':16,'temperature':0,'seed':100+int(sys.argv[2]),'cache_prompt':False,'parallel':int(sys.argv[2])}))
" 2048 "$s")"
    curl -sf "$URL/completion" -H 'Content-Type: application/json' -d "$body" -o "$OUT/concurrent_$s.json" &
    pids="$pids $!"
done
wait $pids
for s in $(seq 0 $((SLOTS - 1))); do
    [ -s "$OUT/concurrent_$s.json" ] || { echo "!! slot $s produced no response"; tail -30 "$SERVER_LOG"; exit 1; }
done
echo "   all $SLOTS slots responded"

echo "-- capturing device state under load"
nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu,clocks.sm,pcie.link.gen.current,pcie.link.width.current \
    --format=csv > "$OUT/nvidia-smi-under-load.csv" 2>/dev/null || echo "   nvidia-smi unavailable"
nvidia-smi topo -m > "$OUT/nvidia-smi-topo.txt" 2>/dev/null || true
grep -E "CUDA|device|offload|buffer|memory|slot" "$SERVER_LOG" | tail -40 > "$OUT/server-device-summary.txt" || true

echo
echo "Tier B PASSED: this build loaded the target model and served real requests on real hardware."
echo "This is a smoke test. It supports NO throughput claim - use scripts/multigpu/bench/ for that."
echo "Artifacts in $OUT/"
