#!/usr/bin/env bash
# Export the downstream commit range as individual patch files, plus an index.
#
# The Git history is the source of truth; nothing here is committed as a stale .patch file. Users who
# want upstream + only selected patches can apply these to a stock llama.cpp checkout:
#
#   git checkout -b with-patches upstream/master
#   git am patches/0001-*.patch 0007-*.patch
#
# Usage: scripts/multigpu/export-patches.sh [--out DIR] [-n COUNT] [--base REF] [--keep-existing]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT="patches"
COUNT=""
BASE=""
KEEP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)           OUT="$2"; shift 2 ;;
        -n|--count)      COUNT="$2"; shift 2 ;;
        --base)          BASE="$2"; shift 2 ;;
        --keep-existing) KEEP=1; shift ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "export-patches: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$BASE" ]; then
    for ref in refs/remotes/upstream/master refs/remotes/origin/master upstream/master origin/master master; do
        if BASE="$(git merge-base HEAD "$ref" 2>/dev/null)"; then break; fi
    done
fi
if [ -z "${BASE:-}" ]; then
    echo "export-patches: could not resolve an upstream base; pass --base <ref>" >&2
    exit 1
fi

if [ -d "$OUT" ] && [ -z "$KEEP" ]; then
    rm -rf "$OUT"
fi
mkdir -p "$OUT"

RANGE="$BASE..HEAD"
if [ -n "$COUNT" ]; then
    FIRST="$(git rev-list --first-parent "$RANGE" | tail -n "$COUNT" | tail -1)"
    RANGE="${FIRST}^..HEAD"
fi

git format-patch --cover-letter -o "$OUT" "$RANGE" > /dev/null

PATCH_COUNT="$(git rev-list --count "$RANGE")"

# Index: what each patch is, which upstream issue/PR it relates to, which runtime switch selects it,
# and which files it touches. Everything except the switch column is read out of the commit itself.
{
    echo "# llama.cpp-multigpu patch export"
    echo
    echo "- upstream base: \`$(git log -1 --format='%H %cI' "$BASE")\`"
    echo "- multigpu HEAD: \`$(git log -1 --format='%H %cI' HEAD)\`"
    echo "- patches: $PATCH_COUNT (plus a cover letter)"
    echo
    echo "| # | commit | subject | upstream refs | files |"
    echo "| --- | --- | --- | --- | --- |"
    i=0
    while IFS= read -r sha; do
        i=$((i + 1))
        subj="$(git log -1 --format=%s "$sha")"
        # Attribution comes from the commit message only (subject + body + trailers). Numbers inside
        # the changed source lines are deliberately excluded: they are code comments and would
        # overstate which upstream discussion a patch actually refers to.
        refs="$( { git log -1 --format='%s%n%b' "$sha" || true; } \
                 | grep -oE '#[0-9]{4,5}' | sort -u | tr '\n' ' ' || true )"
        files="$(git show --stat --format= "$sha" | grep -E ' \| ' | sed 's/ *|.*//' | tr '\n' ' ' || true)"
        printf '| %d | `%s` | %s | %s | %s |\n' "$i" "${sha:0:9}" "$subj" "${refs:-—}" "${files:-—}"
    done < <(git rev-list --reverse "$RANGE")
    echo
    echo "Detailed description of each optimization, its runtime switch and its removal criteria:"
    echo "see [docs/multigpu/patches.md](../docs/multigpu/patches.md)."
    echo
    echo "Patches are ordered oldest first. \`git am\` them in order; some build on earlier ones."
} > "$OUT/PATCHES.md"

echo "exported $PATCH_COUNT patch files (plus cover letter) to $OUT/"
echo "index: $OUT/PATCHES.md"
