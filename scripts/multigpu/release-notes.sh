#!/usr/bin/env bash
# Compose a GitHub Release body from the build metadata produced by build-info.sh.
#
# The body always names: the multigpu commit, the upstream llama.cpp base commit, toolchain/CUDA,
# platform, the downstream patch list, the artifact table with a per-row validation state, benchmark
# status (TBD until measured), and the limitations we refuse to hide.
#
# Usage: scripts/multigpu/release-notes.sh --meta DIR_WITH_BUILD_INFO.json \
#         --assets-manifest FILE [name<TAB>platform<TAB>cuda<TAB>arch<TAB>tier_b] \
#         [--title-date YYYY-MM-DD] [--rolling]

set -euo pipefail

META=""
MANIFEST=""
TITLE_DATE="$(date -u +%Y-%m-%d)"
ROLLING=""

while [ $# -gt 0 ]; do
    case "$1" in
        --meta)            META="$2"; shift 2 ;;
        --assets-manifest) MANIFEST="$2"; shift 2 ;;
        --title-date)      TITLE_DATE="$2"; shift 2 ;;
        --rolling)         ROLLING=1; shift ;;
        -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "release-notes: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$META" ] || { echo "release-notes: --meta is required" >&2; exit 1; }

pick_meta() {
    find "$META" -maxdepth 1 -name 'BUILD_INFO.json' -o -maxdepth 1 -name '*BUILD_INFO.json' | head -1
}

JSON="$(pick_meta || true)"
[ -n "$JSON" ] || { echo "release-notes: no BUILD_INFO.json under $META" >&2; exit 1; }

get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2], 'TBD'))" "$JSON" "$1"; }

MG_COMMIT="$(get multigpu_commit)"
MG_SHORT="$(get multigpu_commit_short)"
UP_COMMIT="$(get upstream_base_commit)"
BUILD_DATE="$(get build_date)"
CUDA_TOOLKIT="$(get cuda_toolkit_version)"
CUDA_ARCH="$(get cuda_architectures)"
COMPILER="$(get compiler)"
CMAKE_VER="$(get cmake)"
OS_VER="$(get os)"
PATCH_COUNT="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('patches',[])))" "$JSON")"

REPO_URL="https://github.com/${GITHUB_REPOSITORY:-lukolszewski/llama.cpp-multigpu}"

cat <<EOF
**llama.cpp-multigpu** is a temporary downstream performance fork of
[\`llama.cpp\`](https://github.com/ggml-org/llama.cpp): targeted performance patches for
**Qwen3.8-Flash-Next** on **consumer multi-GPU systems**, particularly machines with constrained or
shared **PCIe** links. It is not a new inference engine, model format, or API.

> **STATUS: TEMPORARY DOWNSTREAM FORK.** These binaries exist because these workloads are currently
> faster here than upstream. When upstream llama.cpp reaches comparable performance, this repository
> has succeeded and should be archived in favour of upstream.

| | |
| --- | --- |
| multigpu commit | \`$MG_COMMIT\` |
| upstream llama.cpp base | \`$UP_COMMIT\` |
| downstream patches | $PATCH_COUNT (see below) |
| built | $BUILD_DATE |
| CUDA toolkit | $CUDA_TOOLKIT |
| CUDA architectures | ${CUDA_ARCH:-TBD} |
| compiler | $COMPILER |
| cmake | $CMAKE_VER |
| OS | $OS_VER |
| model targeted | Qwen3.8-Flash-Next, GGUF arch \`qwen4exp\`, \`unsloth/Qwen3.8-Flash-Next-GGUF\` / \`UD-Q4_K_XL\` (~111.3 GB, 4 shards) |

EOF

if [ -n "$ROLLING" ]; then
    cat <<EOF
This is the **rolling nightly** release: it is replaced by the next successful nightly build and is
not a permanent record. For a citable build use a date-tagged release (\`multigpu-YYYYMMDD\`).

EOF
fi

cat <<EOF
## Downloads

EOF

if [ -n "$MANIFEST" ] && [ -s "$MANIFEST" ]; then
    echo "| artifact | platform | CUDA | device architectures | packaging (Tier A) | runtime validated (Tier B) |"
    echo "| --- | --- | --- | --- | --- | --- |"
    while IFS=$'\t' read -r name platform cuda arch tiera tierb; do
        [ -n "${name:-}" ] || continue
        echo "| \`$name\` | ${platform:-TBD} | ${cuda:-TBD} | ${arch:-TBD} | ${tiera:-passed} | ${tierb:-TBD} |"
    done < "$MANIFEST"
    echo
else
    echo "See the asset list on this release. Every archive embeds \`BUILD_INFO.json\` with the exact"
    echo "source revisions, toolchain and configuration used to build it."
    echo
fi

cat <<'EOF'
**Read the validation columns.** Public CI has no GPU, so every artifact passes the offline
packaging/integrity gate (Tier A), but no published artifact has been runtime-validated on real
hardware yet (Tier B = `TBD` for every row). Tier B needs the benchmark machine attached as a
self-hosted runner; once a Tier B run exists for a configuration, that row is updated and the others
stay `TBD`. Windows and other CUDA/architecture combinations may remain unvalidated indefinitely:
they ship as ordinary llama.cpp builds, built and packaging-checked, **not runtime-validated by us**.
If your hardware is one of those, your report is what tells us whether it works — please open an issue
with the archive name, GPU model and count, PCIe topology, driver and CUDA version.

EOF

echo "## Downstream patches in this build"
echo
python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("| commit | subject |")
print("| --- | --- |")
for p in d.get("patches", []):
    print("| `%s` | %s |" % (p.get("commit", "TBD"), p.get("subject", "TBD")))
PY
echo
echo "Per-patch description, runtime switches and removal criteria: [docs/multigpu/patches.md](https://github.com/${GITHUB_REPOSITORY:-lukolszewski/llama.cpp-multigpu}/blob/multigpu/docs/multigpu/patches.md)."
echo "The individual patches are also attached as a \`-patches.tar.gz\` \`git format-patch\` export, so you"
echo "can build upstream llama.cpp plus only the patches you want."
echo

cat <<'EOF'
## Benchmarks

**No performance numbers are published yet** — the benchmark runs have not been executed. The table
structure, protocol and hardware record exist and every result cell is `TBD`:

- [docs/multigpu/benchmarks.md](https://github.com/lukolszewski/llama.cpp-multigpu/blob/multigpu/docs/multigpu/benchmarks.md)
- [machine-01 hardware record](https://github.com/lukolszewski/llama.cpp-multigpu/blob/multigpu/benches/multi-gpu/machine-01-7950x-6x3090/hardware.md)

Published numbers will always name the upstream commit, the multigpu commit, the machine, the model +
quantization and the full server configuration. Informally observed speedups on this class of workload
have not been re-measured under that protocol, so they are not restated here.

## Known limitations

- Highly workload-specific; the primary target is Qwen3.8-Flash-Next. Other models may not benefit.
- **Some patches may make other workloads or other hardware configurations worse.** No patch is claimed
  to be universally correct — that is precisely why this is a targeted downstream patchset.
- Multi-GPU PCIe topology matters; results on constrained links do not transfer to fast interconnects.
- **Mixed prefill + generation is currently less than ideal** — the two interfere. All-prefill and
  all-generate numbers are best-case slices, not a picture of multi-tenant serving.
- Intended use is **several concurrent sessions for one user / workload owner** (agent sessions,
  coding agents, parallel chats, research jobs) — not arbitrary unrelated users with consistent latency
  expectations.
- Upstream compatibility may occasionally break when rebasing onto new llama.cpp changes.
- MTP (multi-token prediction) drafts are out of scope: little benefit in single-user mode, and they
  cost throughput in the multi-slot case.

## Usage

Everything is normal llama.cpp usage; the patches are selected at runtime, so one build carries the
whole set.

```sh
LLAMA_DECODE_PIPELINE=1 \
llama-server -m Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  -ngl 99 -sm layer -fa on -np 5 --ctx-size 200000 \
  --prefill-max-partial 1 --prefill-max-long 1
```

## Relationship to upstream

Upstream llama.cpp is not a competitor; it is where this work belongs. Patches are kept as individual
identifiable commits referencing the relevant upstream issue/PR, and are deleted once upstream makes
them redundant. Upstream license and attribution are preserved (MIT). General-purpose users should use
upstream llama.cpp.

EOF

echo "Provenance: \`BUILD_INFO.json\` / \`BUILD_INFO.txt\` inside every archive. License: MIT (upstream llama.cpp)."
