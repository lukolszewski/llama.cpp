# Runtime image for llama.cpp-multigpu release/CI tarballs.
#
# This Dockerfile does not compile anything. CI unpacks the `...-bin-ubuntu-cuda-<ver>-x64.tar.gz` archive
# that it just built and validated into `bin/` next to this file, and this image only adds the runtime base
# (CUDA runtime + cuBLAS from NVIDIA's image, libgomp for the CPU backend, libssl for HTTPS model downloads,
# curl for the health check). The result has the same layout as upstream's `.devops/cuda.Dockerfile`
# `server` target: everything under /app, entrypoint /app/llama-server, port 8080.
#
#   docker build -f .devops/multigpu-cuda.Dockerfile --build-arg CUDA_VERSION=12.9.1 -t llama.cpp-multigpu:server ctx/
#   (ctx/ contains bin/ = the unpacked archive directory)
#
# The NVIDIA runtime base ships cuda-compat-<ver> (a forward-compatibility libcuda). On a host whose driver is
# older than that library the container toolkit mounts it, and GeForce GPUs reject it ("forward compatibility
# was attempted on non supported HW") so llama.cpp silently falls back to the CPU (seen 2026-10-06 on an
# 8x RTX 4090 host with driver 570). Purged below: the host driver's libcuda is used instead, which is the
# documented R525+ minor-version-compatibility path.
#
# CUDA_VERSION must be the toolkit the archive was built with (12.9.1 or 13.4.1): a cuBLAS/cudart major
# version mismatch between the archive and the base image fails at load time.

ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=12.9.1
ARG BASE_CUDA_RUN_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

FROM ${BASE_CUDA_RUN_CONTAINER}

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_SOURCE=https://github.com/lukolszewski/llama.cpp-multigpu
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp-multigpu server" \
      org.opencontainers.image.description="llama.cpp + multigpu performance patches (Qwen3.8-Flash-Next on consumer multi-GPU)" \
      org.opencontainers.image.url=$IMAGE_SOURCE \
      org.opencontainers.image.source=$IMAGE_SOURCE \
      org.opencontainers.image.licenses=MIT

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 libssl3t64 curl ca-certificates \
    && (apt-get purge -y 'cuda-compat-12-*' 'cuda-compat-13-*' || true) && rm -rf /usr/local/cuda/compat \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# bin/ = the unpacked release archive (llama-server, llama-cli, libggml*.so, libllama.so, libmtmd.so,
# BUILD_INFO.json/txt, LICENSE, AUTHORS). Provenance travels with the image.
COPY bin/ /app/

WORKDIR /app

ENV LLAMA_ARG_HOST=0.0.0.0

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
