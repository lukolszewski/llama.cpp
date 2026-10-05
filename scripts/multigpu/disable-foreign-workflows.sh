#!/usr/bin/env bash
# Disable the upstream llama.cpp workflows that cannot work on this fork.
#
# A fork of llama.cpp inherits ~50 CI workflows written for the ggml-org organization: they expect
# org secrets (HF_TOKEN_CI, DEPLOY_KEY_RELEASE), org-owned ccache buckets, and self-hosted runner
# labels such as `ubuntu-slim`, `[self-hosted, Linux, NVIDIA]`. On a personal fork they only produce
# red runs and burn Actions minutes. This script leaves the multigpu workflows enabled and disables
# the rest.
#
# This changes repository settings, so it is a deliberate, documented step rather than something the
# build does on its own. Reversible at any time with --enable.
#
# Usage:
#   scripts/multigpu/disable-foreign-workflows.sh --dry-run
#   scripts/multigpu/disable-foreign-workflows.sh
#   scripts/multigpu/disable-foreign-workflows.sh --enable
#
# Requires: gh CLI authenticated with the repo scope.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-lukolszewski/llama.cpp}"
KEEP_PREFIX="${KEEP_PREFIX:-multigpu-}"
ACTION="disable"
DRY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --enable)  ACTION="enable"; shift ;;
        --dry-run) DRY=1; shift ;;
        --repo)    REPO="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "disable-foreign-workflows: unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v gh > /dev/null 2>&1 || { echo "gh CLI is required (https://cli.github.com)" >&2; exit 1; }

echo "repo: $REPO"
echo "keeping workflows whose file name starts with: $KEEP_PREFIX"
echo "action: $ACTION"
echo

gh api "repos/$REPO/actions/workflows?per_page=100" \
    --paginate --jq '.workflows[] | "\(.id)\t\(.name)\t\(.path)\t\(.state)"' |
while IFS=$'\t' read -r id name path state; do
    case "$path" in
        .github/workflows/"$KEEP_PREFIX"*)
            echo "KEEP   $path ($state)"
            continue ;;
    esac
    case "$state" in
        active)  target="$ACTION" ;;
        disabled) [ "$ACTION" = "enable" ] && target="enable" || { echo "SKIP   $path (already disabled)"; continue; } ;;
        *)       echo "SKIP   $path (state: $state)"; continue ;;
    esac

    if [ -n "$DRY" ]; then
        echo "DRY    $target $path ($name, id $id)"
        continue
    fi

    case "$target" in
        disable) gh api -X PUT "repos/$REPO/actions/workflows/$id/disable" > /dev/null && echo "DISABLED $path" ;;
        enable)  gh api -X PUT "repos/$REPO/actions/workflows/$id/enable"  > /dev/null && echo "ENABLED  $path" ;;
    esac
done

cat <<EOF

Notes:
- Disabling a workflow is repository state, not file content: the upstream files stay untouched, so
  rebasing onto new llama.cpp commits stays clean.
- The downstream pipeline is: multigpu-build.yml (artifacts + Tier A gate), multigpu-release.yml
  (GitHub Releases), multigpu-selfhosted.yml (Tier B on real multi-GPU hardware, inert until you
  register such a runner).
- Independently of this script, .github/workflows/release.yml carries a hard gate so the fork's
  upstream-tracking branch can never mint llama.cpp or llama.cpp-multigpu GitHub Releases.
EOF
