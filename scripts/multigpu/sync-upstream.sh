#!/usr/bin/env bash
# Keep the fork current with upstream llama.cpp without losing the patch boundaries.
#
# Branch model:
#   master    upstream llama.cpp mirror (never released from)
#   multigpu  master + the identifiable patch series; repository default; CI + releases come from here
#
# Usage:
#   scripts/multigpu/sync-upstream.sh              # fetch, fast-forward master, report the delta
#   scripts/multigpu/sync-upstream.sh --rebase     # also rebase multigpu onto the new master
#   scripts/multigpu/sync-upstream.sh --merge      # merge instead of rebase (keeps published SHAs)
#
# Never run --rebase/--merge if other people have already built from the current multigpu commits:
# prefer --merge in that case so their SHAs stay valid.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MODE="report"
PATCHED_BRANCH="${MULTIGPU_PATCHED_BRANCH:-multigpu}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ggml-org/llama.cpp.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
MIRROR_BRANCH="${MIRROR_BRANCH:-master}"

while [ $# -gt 0 ]; do
    case "$1" in
        --rebase) MODE="rebase"; shift ;;
        --merge)  MODE="merge"; shift ;;
        --dry-run) echo "dry run: would use mode $MODE"; exit 0 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "sync-upstream: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1; then
    echo "-- adding upstream remote $UPSTREAM_REMOTE ($UPSTREAM_URL)"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

echo "-- fetching upstream"
git fetch --quiet "$UPSTREAM_REMOTE" "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

UP="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
echo "upstream head: $UP"

echo "-- updating the $MIRROR_BRANCH mirror"
CUR="$(git rev-parse --abbrev-ref HEAD)"
git checkout "$MIRROR_BRANCH" 2>/dev/null || git checkout -b "$MIRROR_BRANCH" "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
if git merge-base --is-ancestor "$MIRROR_BRANCH" "$UP" 2>/dev/null; then
    git merge --ff-only "$UP"
    echo "fast-forwarded $MIRROR_BRANCH to $UP"
else
    echo "!! $MIRROR_BRANCH has diverged from upstream; investigate before forcing."
    git log --oneline "$UP..$MIRROR_BRANCH" | head
fi
git checkout "$CUR"

echo
echo "-- patchset status on $PATCHED_BRANCH"
git log --oneline "$MIRROR_BRANCH..$PATCHED_BRANCH" 2>/dev/null | sed 's/^/  /' || echo "  (cannot compare)"
echo
echo "  downstream commits: $(git rev-list --count "$MIRROR_BRANCH..$PATCHED_BRANCH" 2>/dev/null || echo '?')"
echo "  behind upstream by: $(git rev-list --count "$PATCHED_BRANCH..$MIRROR_BRANCH" 2>/dev/null || echo '?') commits"
echo "  files touched:      $(git diff --name-only "$MIRROR_BRANCH..$PATCHED_BRANCH" 2>/dev/null | wc -l)"

if [ "$MODE" = "report" ]; then
    cat <<EOF

Next steps (see docs/multigpu/upstream-sync.md):
  1. $0 --rebase    (or --merge if these commits are already in use by others)
  2. resolve conflicts patch by patch; expect hot spots in:
       src/llama-memory-hybrid-idx.*  src/models/qwen4exp.cpp  src/llama-graph.*
       src/llama-context.cpp  ggml/src/ggml-backend.cpp  tools/server/server-context.cpp
  3. build (CUDA + CPU) and run scripts/multigpu/validate-artifact.sh
  4. with a GPU: scripts/multigpu/bench/runtime-smoke.sh, then the important benchmark workloads
  5. check whether any upstream change makes a local patch redundant -> delete it, do not keep it
     out of habit (docs/multigpu/patches.md#removal-criteria)
EOF
    exit 0
fi

echo
echo "-- $MODE of $PATCHED_BRANCH onto $MIRROR_BRANCH"
git checkout "$PATCHED_BRANCH"
if [ "$MODE" = "rebase" ]; then
    git rebase "$MIRROR_BRANCH"
else
    git merge --no-ff "$MIRROR_BRANCH" -m "Merge $MIRROR_BRANCH (upstream sync $(git log -1 --format=%h "$MIRROR_BRANCH")) into $PATCHED_BRANCH"
fi

echo
echo "done. Verify before pushing:"
echo "  git log --oneline $MIRROR_BRANCH..$PATCHED_BRANCH     # patch boundaries must still be visible"
echo "  git diff --stat $MIRROR_BRANCH..$PATCHED_BRANCH       # delta should not silently balloon"
echo "Nothing was pushed by this script."
