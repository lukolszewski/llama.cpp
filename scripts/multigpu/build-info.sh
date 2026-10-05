#!/usr/bin/env bash
# Generate llama.cpp-multigpu build provenance metadata.
#
# Every artifact we publish embeds this output as BUILD_INFO.json / BUILD_INFO.txt, so that a
# downloaded binary always identifies: the multigpu commit it was built from, the upstream llama.cpp
# revision it sits on, the toolchain, the CUDA architecture list, and the downstream patchset it
# contains. No opaque binaries.
#
# Usage:
#   scripts/multigpu/build-info.sh [--platform OS] [--backend NAME] [--cuda-version V]
#                                 [--cuda-arch LIST] [--cuda-sass sm_86,...] [--cuda-ptx sm_50,...]
#                                 [--driver-floor TEXT] [--cmake-config STR]
#                                 [--runtime-tested true|false|TBD] [--format json|text]
#
# Environment overrides (used by CI):
#   BUILD_PLATFORM, BUILD_BACKEND, CUDA_VERSION, CUDA_ARCH_LIST, CMAKE_CONFIG, RUNTIME_TESTED

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Collapse newlines and escape quotes so free-form text (commit subjects, compiler banners) can be
# embedded in JSON without a jq dependency.
json_escape() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

PLATFORM="${BUILD_PLATFORM:-unknown}"
BACKEND="${BUILD_BACKEND:-unknown}"
CUDA_VER="${CUDA_VERSION:-}"
CUDA_ARCH="${CUDA_ARCH_LIST:-}"
CUDA_SASS="${CUDA_SASS:-}"
CUDA_PTX="${CUDA_PTX:-}"
DRIVER_FLOOR="${DRIVER_FLOOR:-}"
CMAKE_CFG="${CMAKE_CONFIG:-}"
RUNTIME_TESTED="${RUNTIME_TESTED:-TBD}"
FORMAT="json"

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)        PLATFORM="$2"; shift 2 ;;
        --backend)         BACKEND="$2"; shift 2 ;;
        --cuda-version)    CUDA_VER="$2"; shift 2 ;;
        --cuda-arch)       CUDA_ARCH="$2"; shift 2 ;;
        --cuda-sass)       CUDA_SASS="$2"; shift 2 ;;
        --cuda-ptx)        CUDA_PTX="$2"; shift 2 ;;
        --driver-floor)    DRIVER_FLOOR="$2"; shift 2 ;;
        --cmake-config)    CMAKE_CFG="$2"; shift 2 ;;
        --runtime-tested)  RUNTIME_TESTED="$2"; shift 2 ;;
        --format)          FORMAT="$2"; shift 2 ;;
        -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-info: unknown argument: $1" >&2; exit 1 ;;
    esac
done

COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=7 HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
COMMIT_DATE="$(git log -1 --format=%cI HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DIRTY=no
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=yes

# --- upstream base -----------------------------------------------------------
# The upstream commit this branch is built on = merge base with upstream/master, falling back to the
# fork's own master (the upstream-tracking branch). Recorded so every benchmark and every binary can
# say exactly which llama.cpp revision it is ahead of.
UPSTREAM_BASE=""
UPSTREAM_BASE_DATE=""
UPSTREAM_BASE_SOURCE=""
for ref in refs/remotes/upstream/master refs/remotes/origin/master upstream/master origin/master master; do
    if base="$(git merge-base HEAD "$ref" 2>/dev/null)"; then
        UPSTREAM_BASE="$base"
        UPSTREAM_BASE_DATE="$(git log -1 --format=%cI "$base" 2>/dev/null || true)"
        UPSTREAM_BASE_SOURCE="$ref"
        break
    fi
done
if [ -z "$UPSTREAM_BASE" ]; then
    UPSTREAM_BASE="TBD"
    UPSTREAM_BASE_SOURCE="none (no upstream-tracking ref available in this checkout)"
fi

AHEAD="$(git rev-list --count "${UPSTREAM_BASE}..HEAD" 2>/dev/null || echo TBD)"

# --- toolchain ---------------------------------------------------------------
COMPILER="TBD"
if command -v cc  >/dev/null 2>&1; then COMPILER="$(cc --version 2>/dev/null | head -1 | tr -d '\r')"; fi
CMAKE_VER="TBD"
command -v cmake >/dev/null 2>&1 && CMAKE_VER="$(cmake --version 2>/dev/null | head -1 | tr -d '\r')"
NVCC_VER="TBD"
if command -v nvcc >/dev/null 2>&1; then NVCC_VER="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9.]+' | tr -d '\r')"; fi
NINJA_VER="TBD"
command -v ninja >/dev/null 2>&1 && NINJA_VER="$(ninja --version 2>/dev/null | tr -d '\r')"
OS_INFO="TBD"
[ -r /etc/os-release ] && OS_INFO="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
KERNEL="$(uname -sr 2>/dev/null || echo TBD)"

# --- downstream patch list ---------------------------------------------------
# Each commit between the upstream base and HEAD is one identifiable optimization; see
# docs/multigpu/patches.md for what each one does.
PATCH_TXT="$(git log --reverse --format='  %h  %s' "${UPSTREAM_BASE}..HEAD" 2>/dev/null || true)"
[ -n "$PATCH_TXT" ] || PATCH_TXT="  (none)"

# POSIX-awk-portable JSON assembly (no gawk gensub dependency): iterate the log in bash.
PATCH_JSON=""
while IFS='|' read -r p_sha p_date p_sub; do
    [ -n "${p_sha:-}" ] || continue
    [ -n "$PATCH_JSON" ] && PATCH_JSON="${PATCH_JSON},"$'\n    '
    PATCH_JSON="${PATCH_JSON}{\"commit\": \"$(json_escape "$p_sha")\", \"date\": \"$(json_escape "$p_date")\", \"subject\": \"$(json_escape "$p_sub")\"}"
done <<EOFLOG
$(git log --reverse --format='%h|%cI|%s' "${UPSTREAM_BASE}..HEAD" 2>/dev/null || true)
EOFLOG

if [ "$FORMAT" = "text" ]; then
    cat <<EOF
llama.cpp-multigpu build metadata
---------------------------------
project             : llama.cpp-multigpu
based on            : llama.cpp (https://github.com/ggml-org/llama.cpp)
multigpu commit     : $COMMIT
multigpu short      : $SHORT
branch/ref          : $BRANCH
commit date         : $COMMIT_DATE
upstream base       : $UPSTREAM_BASE  (via $UPSTREAM_BASE_SOURCE)
upstream base date  : ${UPSTREAM_BASE_DATE:-TBD}
commits ahead       : $AHEAD
worktree dirty      : $DIRTY
build date          : $BUILD_DATE
platform            : $PLATFORM
backend             : $BACKEND
cuda toolkit        : ${CUDA_VER:-TBD} ($NVCC_VER)
cuda architectures  : ${CUDA_ARCH:-TBD}
cuda SASS (native)  : ${CUDA_SASS:-TBD}
cuda PTX (JIT)      : ${CUDA_PTX:-none}
driver floor        : ${DRIVER_FLOOR:-TBD}
compiler            : $COMPILER
cmake               : $CMAKE_VER
ninja               : $NINJA_VER
os / kernel         : $OS_INFO / $KERNEL
cmake config        : ${CMAKE_CFG:-recorded in CI log}
runtime validated   : $RUNTIME_TESTED   (Tier B: only sm_86 / Linux can be validated by us today)
benchmark status    : measured 2026-10-05 on machine-01 (6x RTX 3090), see docs/multigpu/benchmarks.md

downstream patches ($AHEAD):
$PATCH_TXT
EOF
    exit 0
fi

# JSON. Emitted by hand so the script works in build environments without jq.
cat <<EOF
{
  "project": "llama.cpp-multigpu",
  "project_kind": "temporary downstream performance fork of llama.cpp",
  "upstream_repo": "https://github.com/ggml-org/llama.cpp",
  "multigpu_commit": "$COMMIT",
  "multigpu_commit_short": "$SHORT",
  "multigpu_branch": "$(json_escape "$BRANCH")",
  "multigpu_commit_date": "$COMMIT_DATE",
  "upstream_base_commit": "$UPSTREAM_BASE",
  "upstream_base_commit_date": "${UPSTREAM_BASE_DATE:-}",
  "upstream_base_resolved_via": "$(json_escape "$UPSTREAM_BASE_SOURCE")",
  "commits_ahead_of_upstream_base": "$AHEAD",
  "worktree_dirty": "$DIRTY",
  "build_date": "$BUILD_DATE",
  "platform": "$(json_escape "$PLATFORM")",
  "backend": "$(json_escape "$BACKEND")",
  "cuda_toolkit_version": "$(json_escape "${CUDA_VER:-TBD}")",
  "cuda_nvcc": "$(json_escape "$NVCC_VER")",
  "cuda_architectures": "$(json_escape "${CUDA_ARCH:-}")",
  "cuda_sass": "$(json_escape "${CUDA_SASS:-}")",
  "cuda_ptx": "$(json_escape "${CUDA_PTX:-}")",
  "driver_floor": "$(json_escape "${DRIVER_FLOOR:-}")",
  "compiler": "$(json_escape "$COMPILER")",
  "cmake": "$(json_escape "$CMAKE_VER")",
  "ninja": "$(json_escape "$NINJA_VER")",
  "os": "$(json_escape "$OS_INFO")",
  "kernel": "$(json_escape "$KERNEL")",
  "cmake_config": "$(json_escape "${CMAKE_CFG:-}")",
  "validation": {
    "tier_a_packaging": "see scripts/multigpu/validate-artifact.sh / CI job",
    "tier_b_runtime": "$RUNTIME_TESTED",
    "tier_b_note": "GitHub-hosted CI has no GPU; runtime validation is limited to configurations we own hardware for"
  },
  "benchmark_status": "measured 2026-10-05 on machine-01 (6x RTX 3090) against upstream df03399b8; see docs/multigpu/benchmarks.md",
  "target_model": "Qwen3.8-Flash-Next (llama.cpp arch qwen4exp), unsloth/Qwen3.8-Flash-Next-GGUF UD-Q4_K_XL",
  "license": "MIT (upstream llama.cpp license preserved)",
  "patches": [
    ${PATCH_JSON}
  ]
}
EOF
