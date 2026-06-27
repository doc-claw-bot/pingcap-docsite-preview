#!/bin/bash
# =============================================================================
# preview_docs.sh — Doc PR preview helper script
#
# Creates preview branches on pingcap-docsite-preview and triggers the
# corresponding GitHub Actions workflow to sync PR content for Cloudflare
# docsite preview deployments.
# 
# Usage:
#   # Single PR preview
#   ./preview_docs.sh --pr docs 12345
#   ./preview_docs.sh --pr docs-cn 12345
#   ./preview_docs.sh --pr cloud 12345
#   ./preview_docs.sh --pr operator 12345
#
#   # Multi-PR preview
#   ./preview_docs.sh --multi \
#       --branch-name preview/release-8.5 \
#       --docs-pr 12345 \
#       --docs-cn-pr 67890 \
#       --cloud-pr 11111 \
#       --operator-pr 22222 \
#       --release-dir release-8.5
#
#   # Dry-run (plan only, no execution)
#   ./preview_docs.sh --dry-run --pr docs 12345
#
#   # Local sync (run sync_pr.sh / sync_mult_prs.sh locally instead of relying on GitHub Actions)
#   ./preview_docs.sh --local-sync --pr docs 12345
#   ./preview_docs.sh --local-sync --multi \
#       --branch-name preview/release-8.5 \
#       --docs-pr 12345 \
#       --docs-cn-pr 67890 \
#       --cloud-pr 11111 \
#       --operator-pr 22222 \
#       --release-dir release-8.5
#
# Notes:
#   1. Single PR mode: sync_pr.yml push trigger (preview/**) auto-matches branch name
#   2. Multi PR mode: script modifies sync_mult_prs.yml adding push trigger + env vars
#   3. With --local-sync, the sync scripts run locally and the branch is force-pushed
#   4. Cloudflare build is automatic after workflow completes or after local sync push
# =============================================================================

set -euo pipefail

REPO_DIR="${PREVIEW_DOCS_REPO:-$(cd "$(dirname "$0")" && pwd)}"
REMOTE="origin"
DRY_RUN=false

# ---- Argument parsing ----
ACTION=""       # "single" or "multi"
PR_TYPE=""      # docs, docs-cn, cloud, operator
PR_NUM=""       # single-PR mode: PR number
DOCS_PR=""
DOCS_CN_PR=""
CLOUD_PR=""
OPERATOR_PR=""
RELEASE_DIR=""
BRANCH_NAME=""
LOCAL_SYNC=false

usage() {
    cat <<'USAGE'
Usage:
  # Single PR preview
  ./preview_docs.sh --pr docs 12345
  ./preview_docs.sh --pr docs-cn 12345
  ./preview_docs.sh --pr cloud 12345
  ./preview_docs.sh --pr operator 12345

  # Multi-PR preview
  ./preview_docs.sh --multi \
      --branch-name preview/release-8.5 \
      --docs-pr 12345 \
      --docs-cn-pr 67890 \
      --cloud-pr 11111 \
      --operator-pr 22222 \
      --release-dir release-8.5

  # Dry-run (plan only, no execution)
  ./preview_docs.sh --dry-run --pr docs 12345

  # Local sync (run sync_pr.sh / sync_mult_prs.sh locally instead of relying on GitHub Actions)
  ./preview_docs.sh --local-sync --pr docs 12345
  ./preview_docs.sh --local-sync --multi \
      --branch-name preview/release-8.5 \
      --docs-pr 12345 \
      --docs-cn-pr 67890 \
      --cloud-pr 11111 \
      --operator-pr 22222 \
      --release-dir release-8.5

Notes:
  1. Single PR mode: sync_pr.yml push trigger (preview/**) auto-matches branch name
  2. Multi PR mode: script modifies sync_mult_prs.yml adding push trigger + env vars
  3. With --local-sync, the sync scripts run locally and the branch is force-pushed
  4. Cloudflare build is automatic after workflow completes or after local sync push
USAGE
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            if [[ -n "$ACTION" && "$ACTION" != "single" ]]; then
                echo "Error: --pr conflicts with --multi; choose one mode only"
                usage
            fi
            ACTION="single"
            if [[ $# -lt 3 ]]; then
                echo "Error: --pr requires two arguments: TYPE PR_NUMBER"
                usage
            fi
            PR_TYPE="$2"
            PR_NUM="$3"
            shift 3
            ;;
        --multi)
            if [[ -n "$ACTION" && "$ACTION" != "multi" ]]; then
                echo "Error: --multi conflicts with --pr; choose one mode only"
                usage
            fi
            ACTION="multi"
            shift
            ;;
        --branch-name|-n)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            BRANCH_NAME="$2"
            shift 2
            ;;
        --docs-pr)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            DOCS_PR="$2"
            shift 2
            ;;
        --docs-cn-pr)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            DOCS_CN_PR="$2"
            shift 2
            ;;
        --cloud-pr)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            CLOUD_PR="$2"
            shift 2
            ;;
        --operator-pr)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            OPERATOR_PR="$2"
            shift 2
            ;;
        --release-dir|-r)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires an argument"
                usage
            fi
            RELEASE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --local-sync)
            LOCAL_SYNC=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Error: unknown argument: $1"
            usage
            ;;
    esac
done

# ---- Argument validation ----
if [[ "$ACTION" != "single" && "$ACTION" != "multi" ]]; then
    echo "Error: specify --pr (single PR) or --multi (multiple PRs)"
    usage
fi

# Validate that all PR numbers are positive integers.
validate_pr_number() {
    local label="$1" value="$2"
    if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $label must be a positive integer, got: '$value'"
        exit 1
    fi
}

if [[ "$ACTION" == "single" ]]; then
    if [[ -z "$PR_TYPE" || -z "$PR_NUM" ]]; then
        echo "Error: --pr requires a type and PR number, e.g. --pr docs 12345"
        usage
    fi
    validate_pr_number "--pr PR_NUMBER" "$PR_NUM"
    if [[ -n "$BRANCH_NAME" ]]; then
        echo "Warning: --branch-name is ignored in single-PR mode (branch is derived from PR type)"
    fi
    case "$PR_TYPE" in
        docs)       BRANCH_NAME="preview/pingcap/docs/$PR_NUM" ;;
        docs-cn)    BRANCH_NAME="preview/pingcap/docs-cn/$PR_NUM" ;;
        cloud)      BRANCH_NAME="preview-cloud/pingcap/docs/$PR_NUM" ;;
        operator)   BRANCH_NAME="preview-operator/pingcap/docs-tidb-operator/$PR_NUM" ;;
        *)
            echo "Error: supported PR types: docs, docs-cn, cloud, operator"
            exit 1
            ;;
    esac
fi

if [[ "$ACTION" == "multi" ]]; then
    if [[ -z "$BRANCH_NAME" ]]; then
        echo "Error: multi-PR mode requires --branch-name"
        usage
    fi
    if [[ -z "$DOCS_PR" && -z "$DOCS_CN_PR" && -z "$CLOUD_PR" && -z "$OPERATOR_PR" ]]; then
        echo "Error: multi-PR mode requires at least one PR (--docs-pr, --docs-cn-pr, --cloud-pr, --operator-pr)"
        usage
    fi
    validate_pr_number "--docs-pr" "$DOCS_PR"
    validate_pr_number "--docs-cn-pr" "$DOCS_CN_PR"
    validate_pr_number "--cloud-pr" "$CLOUD_PR"
    validate_pr_number "--operator-pr" "$OPERATOR_PR"
    if [[ -z "$RELEASE_DIR" ]]; then
        echo "Error: multi-PR mode requires --release-dir (e.g. release-8.5)"
        usage
    fi
fi

# ---- Local sync helper ----
run_local_sync() {
    # sync_pr.sh / sync_mult_prs.sh require jq and GITHUB_TOKEN.
    if ! which jq &>/dev/null; then
        echo "Error: jq is required for --local-sync but not installed."
        exit 1
    fi
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "Error: GITHUB_TOKEN is required for --local-sync."
        exit 1
    fi

    # The sync scripts skip commits when TEST is set. Local-sync needs real commits,
    # so clear it for the sync subprocesses while preserving the caller's env.
    (
        export TEST=

        if [[ "$ACTION" == "single" ]]; then
            echo ""
            echo "> Running local sync for single PR..."
            ./sync_pr.sh "$BRANCH_NAME"
        else
            echo ""
            echo "> Running local sync for multiple PRs..."
            # sync_mult_prs.sh reads these exact env var names.
            export DOCS_PR DOCS_CN_PR CLOUD_DOCS_PR OPERATOR_DOCS_PR RELEASE_DIR
            ./sync_mult_prs.sh
        fi
    )
}

# ---- Print plan ----
echo "═══════════════════════════════════════════"
echo "  Doc PR Preview"
echo "═══════════════════════════════════════════"
if [[ "$ACTION" == "single" ]]; then
    echo "  Mode:         Single PR"
    echo "  Type:         $PR_TYPE ($PR_NUM)"
else
    echo "  Mode:         Multi PR"
    [[ -n "$DOCS_PR" ]]      && echo "  docs PR:      $DOCS_PR"
    [[ -n "$DOCS_CN_PR" ]]   && echo "  docs-cn PR:   $DOCS_CN_PR"
    [[ -n "$CLOUD_PR" ]]     && echo "  cloud PR:     $CLOUD_PR"
    [[ -n "$OPERATOR_PR" ]]  && echo "  operator PR:  $OPERATOR_PR"
    echo "  Release dir:  $RELEASE_DIR"
fi
echo "  Branch:       $BRANCH_NAME"
echo "  Local repo:   $REPO_DIR"
echo "  Local sync:   $LOCAL_SYNC"
echo "  Dry run:      $DRY_RUN"
echo "═══════════════════════════════════════════"

# ---- Execution ----

# Step 1: cd into the repo
cd "$REPO_DIR"

# Refuse to operate unless the branch name uses an allowed preview prefix.
case "$BRANCH_NAME" in
    preview/*|preview-*)
        ;;
    *)
        echo "Error: refusing to push branch '$BRANCH_NAME'"
        echo "  Branch name must start with 'preview/' or 'preview-' prefix."
        exit 1
        ;;
esac

# Abort if the working tree has uncommitted changes that could conflict.
if [[ "$DRY_RUN" != true ]]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Error: working tree has uncommitted changes in $REPO_DIR"
        echo "  Please commit or stash them before running this script."
        exit 1
    fi
fi

# Step 2: Fetch latest main and reset local main to origin/main
echo ""
echo "> Fetching latest main..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] git fetch $REMOTE main"
    echo "  [dry-run] git checkout -B main refs/remotes/$REMOTE/main"
else
    git fetch "$REMOTE" main
    # Reset/create local main to exactly match origin/main so the preview
    # branch is always created from the up-to-date default branch.
    git checkout -B main "refs/remotes/$REMOTE/main"
    echo "  ✓ main updated"
fi

# Step 3: Create new branch from main
echo ""
echo "> Creating branch: $BRANCH_NAME..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] git checkout -b $BRANCH_NAME"
else
    # Remove existing local branch with the same name
    if git rev-parse --verify --quiet "$BRANCH_NAME" >/dev/null; then
        # Move off the branch first in case we are currently on it.
        if ! git checkout main 2>/dev/null; then
            echo "Error: failed to switch to main before deleting branch '$BRANCH_NAME'"
            exit 1
        fi
        git branch -D "$BRANCH_NAME"
        echo "  ! Deleted existing local branch with same name"
    fi
    git checkout -b "$BRANCH_NAME"
    echo "  ✓ Branch created"
fi

# Step 3.5: Optionally run the sync scripts locally instead of relying on GitHub Actions.
if [[ "$LOCAL_SYNC" == true && "$DRY_RUN" != true ]]; then
    run_local_sync
fi

# Step 4: For multi-PR mode, modify sync_mult_prs.yml (idempotent).
# Skip this when using local sync because the files are already synchronized locally.
if [[ "$ACTION" == "multi" && "$LOCAL_SYNC" != true ]]; then
    echo ""
    echo "> Updating sync_mult_prs.yml with PR config..."

    WORKFLOW_FILE=".github/workflows/sync_mult_prs.yml"

    # Env var names here MUST match what sync_mult_prs.sh reads:
    # DOCS_PR, DOCS_CN_PR, CLOUD_DOCS_PR, OPERATOR_DOCS_PR, RELEASE_DIR.
    ENV_DOCS_PR="$DOCS_PR"
    ENV_DOCS_CN_PR="$DOCS_CN_PR"
    ENV_CLOUD_DOCS_PR="$CLOUD_PR"
    ENV_OPERATOR_DOCS_PR="$OPERATOR_PR"

    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] Reset $WORKFLOW_FILE from origin/main, then:"
        echo "    - push: branches: [$BRANCH_NAME]"
        echo "    - env vars:"
        [[ -n "$DOCS_PR" ]]          && echo "      DOCS_PR: $DOCS_PR"
        [[ -n "$DOCS_CN_PR" ]]       && echo "      DOCS_CN_PR: $DOCS_CN_PR"
        [[ -n "$CLOUD_PR" ]]         && echo "      CLOUD_DOCS_PR: $CLOUD_PR"
        [[ -n "$OPERATOR_PR" ]]      && echo "      OPERATOR_DOCS_PR: $OPERATOR_PR"
        echo "      RELEASE_DIR: $RELEASE_DIR"
    else
        # Restore the pristine workflow file from origin/main so that
        # repeated runs always start from a clean baseline (idempotent).
        git show "refs/remotes/$REMOTE/main:$WORKFLOW_FILE" > "$WORKFLOW_FILE"

        # Modify the workflow YAML via inline Python. Use quoted heredoc and
        # pass values through the environment to avoid shell interpolation
        # issues with values containing $, backticks, or quotes.
        PD_WORKFLOW_FILE="$WORKFLOW_FILE" \
        PD_BRANCH_NAME="$BRANCH_NAME" \
        PD_DOCS_PR="$ENV_DOCS_PR" \
        PD_DOCS_CN_PR="$ENV_DOCS_CN_PR" \
        PD_CLOUD_DOCS_PR="$ENV_CLOUD_DOCS_PR" \
        PD_OPERATOR_DOCS_PR="$ENV_OPERATOR_DOCS_PR" \
        PD_RELEASE_DIR="$RELEASE_DIR" \
        python3 << 'PYEOF'
import os, sys

workflow_file = os.environ["PD_WORKFLOW_FILE"]
branch_name = os.environ["PD_BRANCH_NAME"]
docs_pr = os.environ["PD_DOCS_PR"]
docs_cn_pr = os.environ["PD_DOCS_CN_PR"]
cloud_pr = os.environ["PD_CLOUD_DOCS_PR"]
operator_pr = os.environ["PD_OPERATOR_DOCS_PR"]
release_dir = os.environ["PD_RELEASE_DIR"]

try:
    with open(workflow_file, 'r') as f:
        content = f.read()
except OSError as e:
    print(f"  ✗ Failed to read {workflow_file}: {e}", file=sys.stderr)
    sys.exit(1)

# Insert push trigger after "on:".
old_on = "on:\n  workflow_dispatch:"
new_on = (
    "on:\n"
    "  push:\n"
    "    branches:\n"
    f"      - {branch_name}\n"
    "  workflow_dispatch:"
)
new_content = content.replace(old_on, new_on, 1)
if new_content == content:
    print(f"  ✗ Failed to insert push trigger: pattern not found in {workflow_file}", file=sys.stderr)
    print(f"    Expected to find: {old_on!r}", file=sys.stderr)
    sys.exit(1)
content = new_content

# Build env var lines to append after GITHUB_TOKEN.
env_vars = []
if docs_pr:
    env_vars.append(f"        DOCS_PR: {docs_pr}")
if docs_cn_pr:
    env_vars.append(f"        DOCS_CN_PR: {docs_cn_pr}")
if cloud_pr:
    env_vars.append(f"        CLOUD_DOCS_PR: {cloud_pr}")
if operator_pr:
    env_vars.append(f"        OPERATOR_DOCS_PR: {operator_pr}")
env_vars.append(f"        RELEASE_DIR: {release_dir}")

# Replace GITHUB_TOKEN line with itself + all env vars in one shot (correct order).
token_line = "        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
if token_line not in content:
    print(f"  ✗ Failed to find GITHUB_TOKEN env line in {workflow_file}", file=sys.stderr)
    sys.exit(1)
replacement = token_line + "\n" + "\n".join(env_vars)
content = content.replace(token_line, replacement, 1)

try:
    with open(workflow_file, 'w') as f:
        f.write(content)
except OSError as e:
    print(f"  ✗ Failed to write {workflow_file}: {e}", file=sys.stderr)
    sys.exit(1)

print("  ✓ sync_mult_prs.yml updated")
PYEOF
    fi
fi

# Step 5: Commit and push
echo ""
echo "> Committing and pushing..."

if [[ "$DRY_RUN" == true ]]; then
    if [[ "$LOCAL_SYNC" == true ]]; then
        echo "  [dry-run] run local sync (sync_pr.sh / sync_mult_prs.sh)"
        echo "  [dry-run] git commit --allow-empty -m \"[local-sync] skip workflow sync for this branch\""
    elif [[ "$ACTION" == "multi" ]]; then
        echo "  [dry-run] git add .github/workflows/sync_mult_prs.yml"
        echo "  [dry-run] git commit -m \"Preview: $BRANCH_NAME\""
    else
        echo "  [dry-run] (no files to stage for branch trigger)"
    fi
    if [[ "$LOCAL_SYNC" == true ]]; then
        echo "  [dry-run] git push --force $REMOTE $BRANCH_NAME"
    else
        echo "  [dry-run] git push --force-with-lease $REMOTE $BRANCH_NAME"
    fi
else
    if [[ "$LOCAL_SYNC" == true ]]; then
        # sync_pr.sh / sync_mult_prs.sh already committed the synced content.
        echo "  ✓ Local sync completed; no additional local commits needed"
        # Add a marker commit so sync_pr.yml can detect that this branch was already
        # synchronized locally and skip the redundant Actions run.
        git commit --allow-empty -m "[local-sync] skip workflow sync for this branch" || true
    elif [[ "$ACTION" == "multi" ]]; then
        # Stage only the workflow file; avoid accidentally committing stray
        # untracked files (e.g. temp/ clones left by sync scripts).
        git add "$WORKFLOW_FILE"
        if git diff --cached --quiet; then
            echo "  ! No changes to commit"
        else
            git commit -m "Preview: $BRANCH_NAME"
            echo "  ✓ Committed"
        fi
    else
        # Single-PR mode relies on the sync_pr.yml push trigger; nothing to
        # stage locally.
        echo "  ✓ No local changes needed (sync_pr.yml handles the build)"
    fi

    echo ""
    echo "> Pushing to remote..."
    if [[ "$LOCAL_SYNC" == true ]]; then
        # Local sync reconstructs the branch from origin/main, so force push is safe
        # and avoids stale-remote-ref rejections when re-previewing.
        git push --force "$REMOTE" "$BRANCH_NAME"
    else
        # Fetch the target branch so that the local remote-tracking ref is up-to-date.
        # Without this, --force-with-lease would reject the push when re-previewing a
        # branch that was advanced by the workflow (git_push.sh) since our last fetch.
        git fetch "$REMOTE" "$BRANCH_NAME" 2>/dev/null || true
        git push --force-with-lease "$REMOTE" "$BRANCH_NAME"
    fi
    echo "  ✓ Pushed"
fi

# Step 6: Print result summary
REPO_URL=$(git remote get-url "$REMOTE" 2>/dev/null | sed -E 's|git@github.com:|https://github.com/|; s|\.git$||')
echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Preview ready!"
echo "═══════════════════════════════════════════"
echo "  Branch:   $BRANCH_NAME"
echo "  Repo:     $REPO_URL"

if [[ "$ACTION" == "multi" ]]; then
    echo ""
    if [[ "$LOCAL_SYNC" == true ]]; then
        echo "  Multi-PR content synchronized locally and pushed."
        echo "  Cloudflare will auto-build from the pushed branch."
    else
        echo "  Multi-PR config pushed on the branch workflow file."
        echo "  Cloudflare will auto-build once the workflow syncs the PRs."
    fi
    echo "  For periodic updates, configure sync_scheduler.yml."
fi

echo ""
echo "  Check workflow status:"
echo "  $REPO_URL/actions"
echo "═══════════════════════════════════════════"