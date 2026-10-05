#!/bin/bash
# bench_server.sh start IMAGE NP CTX patched|upstream LABEL  |  stop LABEL
# Same server flags for both revisions (the production run script's), port 8011, container bench-server.
# patched adds the fork's env switches (groups, pipeline, graphs) and --prefill-max-partial; speculation OFF.
MODEL_DIR=/home/luk/dev/ai/cache/qwen38-flash-next; M=$(basename $(ls $MODEL_DIR/*UD-Q4_K_XL*-00001-of-*.gguf))
if [[ "$1" == "stop" ]]; then docker logs bench-server > ~/dev/airun/testing/grid-$2-server.log 2>&1; docker rm -f bench-server >/dev/null 2>&1; exit 0; fi
IMAGE=$2; NP=$3; CTX=$4; KIND=$5; LABEL=$6
docker rm -f bench-server >/dev/null 2>&1
ENV=(-e CUDA_DEVICE_ORDER=PCI_BUS_ID -e CUDA_VISIBLE_DEVICES=0,1,2,3,4,5)
ARGS=(-m /models/$M -ngl 99 -ot 'per_layer_token_embd\.weight=CPU' --tensor-split 0.85,1,1,1,1,1 --main-gpu 0 -c $CTX -fa on --parallel $NP --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 --jinja --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --host 0.0.0.0 --port 8011 --metrics)
if [[ "$KIND" == patched ]]; then ENV+=(-e LLAMA_ATTN_ROT_DISABLE=1 -e LLAMA_PIPELINE_PARALLEL=1 -e GGML_CUDA_GRAPHS_FORCE=1 -e LLAMA_DECODE_PIPELINE=1 -e LLAMA_SERVER_GROUPS=5); ARGS+=(--prefill-max-partial 2 --cache-ram 40960); fi
docker run -d --name bench-server --gpus all "${ENV[@]}" -v $MODEL_DIR:/models:ro -p 8011:8011 $IMAGE "${ARGS[@]}" >/dev/null || exit 1
for i in $(seq 1 180); do curl -sf localhost:8011/health >/dev/null && { echo "healthy after $((i*5)) s"; exit 0; }; sleep 5
  docker ps --format '{{.Names}}' | grep -q '^bench-server$' || { echo "SERVER DIED"; docker logs bench-server 2>&1 | grep -aE ' E |error|ASSERT|out of memory|failed' | tail -5 | cut -c1-200; exit 1; }; done; echo "TIMEOUT"; exit 1
