# Benchmark image for rented multi-GPU machines (Vast.ai): the gated cuda-12.9 release image plus the
# model downloader, the README grid protocol (readme_grid.py / readme_table.py / plot-grid.py), the hardware
# record collector and an entrypoint with a `bench` mode. It compiles nothing and adds no binaries of its
# own: /app is byte-identical to the server image it is built FROM. Documentation:
# scripts/multigpu/bench/vast/README.md.
#
#   docker build -f .devops/multigpu-bench.Dockerfile \
#     --build-arg BASE_IMAGE=ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9-20261006 \
#     -t ghcr.io/lukolszewski/llama.cpp-multigpu:bench-cuda12.9-20261006 .
#
# Why cuda-12.9 only: one image has to cover V100 (sm_70), Turing (PTX), Ampere, Ada and Blackwell boxes;
# the cuda-13.4 flavour has no Volta/Turing code and its base image refuses drivers older than CUDA 13.4.
ARG BASE_IMAGE=ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9
FROM ${BASE_IMAGE}

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp-multigpu bench" \
      org.opencontainers.image.description="llama.cpp-multigpu server image + README benchmark grid runner for rented multi-GPU machines" \
      org.opencontainers.image.source=https://github.com/lukolszewski/llama.cpp-multigpu

# aria2: 16-connection model download; python3: grid/table/plot scripts; pciutils: PCIe link registers when
# visible; openssh-server: Vast.ai's ssh launch mode installs it at boot otherwise (minutes of billed time).
RUN apt-get update \
    && apt-get install -y --no-install-recommends aria2 python3 pciutils jq openssh-server procps \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY scripts/multigpu/bench/vast/entrypoint.sh scripts/multigpu/bench/vast/download-model.sh \
     scripts/multigpu/bench/vast/healthcheck.sh scripts/multigpu/bench/vast/collect-hardware.py \
     scripts/multigpu/bench/readme_grid.py scripts/multigpu/bench/readme_table.py \
     scripts/multigpu/bench/plot-grid.py /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/download-model.sh /usr/local/bin/healthcheck.sh \
             /usr/local/bin/collect-hardware.py /usr/local/bin/readme_grid.py /usr/local/bin/readme_table.py \
             /usr/local/bin/plot-grid.py \
    && mkdir -p /models /results

# NVIDIA's runtime base declares NVIDIA_REQUIRE_CUDA=cuda>=12.9 and the container runtime refuses older
# drivers; cudart 12.9 runs on any R525+ driver for the SASS targets (minor-version compatibility), so the
# check is disabled here. PTX-only GPUs still need a CUDA>=12.9 driver; the entrypoint's pre-flight says so.
ENV NVIDIA_DISABLE_REQUIRE=1 \
    MODEL_DIR=/models RESULTS_DIR=/results \
    HF_REPO=unsloth/Qwen3.8-Flash-Next-GGUF QUANT=UD-Q4_K_XL \
    PORT=8009 PARALLEL=5 KV_TYPE=q8_0 UBATCH=512 BATCH=2048 CACHE_RAM=16384

WORKDIR /app
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s CMD [ "/usr/local/bin/healthcheck.sh" ]
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bench" ]
