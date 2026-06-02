#!/bin/bash
# monitor_cloudflare_preview.sh — Check Cloudflare Pages deployment status for a preview branch
# Usage: ./monitor_cloudflare_preview.sh <branch> [PR_NUM]
#   $ ./monitor_cloudflare_preview.sh preview-cloud/pingcap/docs/22992 22992
# Output: JSON {ok, status, conclusion, preview_url, branch_preview_url, view_logs_url, pr_preview_urls: [...]}

set -euo pipefail

BP="$1"
PR_NUM="${2:-}"
REPO="doc-claw-bot/pingcap-docsite-preview"
API="https://api.github.com/repos/$REPO"

# Get latest commit SHA on the branch
SHA=$(git ls-remote origin "refs/heads/$BP" 2>/dev/null | cut -f1)
if [ -z "$SHA" ]; then
  echo '{"ok":false,"error":"branch not found"}'
  exit 0
fi

# Query Cloudflare Pages check run from commit
CHECK=$(curl -sf -H "Accept: application/vnd.github+json" \
  "$API/commits/$SHA/check-runs" 2>/dev/null | \
  jq -c '[.check_runs[] | select(.app.name == "Cloudflare Workers and Pages")] | first')

if [ -z "$CHECK" ] || [ "$CHECK" = "null" ]; then
  echo '{"ok":false,"error":"no Cloudflare Pages check run found"}'
  exit 0
fi

STATUS=$(echo "$CHECK" | jq -r '.status')
CONCLUSION=$(echo "$CHECK" | jq -r '.conclusion // "null"')

# When completed, fetch full check run detail for preview URLs and logs link
PREVIEW_URL=""
BP_PREVIEW_URL=""
VIEW_LOGS_URL=""

if [ "$STATUS" = "completed" ]; then
  CHK_ID=$(echo "$CHECK" | jq -r '.id')
  DETAIL=$(curl -sf -H "Accept: application/vnd.github+json" \
    "$API/check-runs/$CHK_ID" 2>/dev/null)

  PREVIEW_URL=$(echo "$DETAIL" | jq -r '.output.summary' 2>/dev/null | \
    grep -oP 'https://[a-zA-Z0-9._-]+\.tidb-doc-preview\.pages\.dev' | head -1)
  BP_PREVIEW_URL=$(echo "$DETAIL" | jq -r '.output.summary' 2>/dev/null | \
    grep -oP 'https://[a-zA-Z0-9._-]+\.tidb-doc-preview\.pages\.dev' | tail -1)

  # View logs URL from Cloudflare dashboard
  DASH_URL=$(echo "$DETAIL" | jq -r '.details_url // ""')
  if [ -n "$DASH_URL" ]; then
    DEPLOY_ID=$(echo "$DASH_URL" | grep -oP 'pages/view/[^/]+/\K[^&?]+' || true)
    if [ -n "$DEPLOY_ID" ]; then
      VIEW_LOGS_URL="https://dash.cloudflare.com/?to=/071677103ec68ee063195042e14da451/pages/view/tidb-doc-preview/$DEPLOY_ID"
    fi
  fi
fi

# Compute PR preview URLs from changed files
# Parse branch to determine product type and source repo
PRODUCT=$(echo "$BP" | cut -d'/' -f1)  # "preview" or "preview-cloud"
REPO_OWNER="pingcap"
REPO_NAME="docs"

# Determine base URL and path prefix
if [ "$PRODUCT" = "preview-cloud" ]; then
  PREFIX="/tidbcloud/master"
else
  PREFIX="/tidb/stable"
fi

# Build PR preview URLs array
PR_URLS_JSON="[]"
if [ -n "$PREVIEW_URL" ] && [ -n "$PR_NUM" ]; then
  CHANGED_FILES=$(curl -sf -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUM/files" 2>/dev/null | \
    jq -r '[.[] | select(.filename | test("\\.md$")) | .filename]')

  if [ -n "$CHANGED_FILES" ] && [ "$CHANGED_FILES" != "[]" ]; then
    PR_URLS_JSON=$(echo "$CHANGED_FILES" | jq -r --arg base "$PREVIEW_URL" --arg prefix "$PREFIX" \
      '[.[] |
        if startswith("tidb-cloud/") then
          $base + "/tidbcloud/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        elif startswith("api/") then
          $base + $prefix + "/api/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        elif startswith("ai/") then
          $base + $prefix + "/ai/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        elif startswith("develop/") then
          $base + $prefix + "/developer/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        elif startswith("best-practices/") then
          $base + $prefix + "/best-practices/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        else
          $base + $prefix + "/" + (split("/") | .[-1] | rtrimstr(".md")) + "/"
        end]')
  fi
fi

# Build JSON safely with jq
jq -n \
  --arg status "$STATUS" \
  --arg conclusion "$CONCLUSION" \
  --arg branch "$BP" \
  --arg preview_url "${PREVIEW_URL:-}" \
  --arg bp_preview_url "${BP_PREVIEW_URL:-}" \
  --arg view_logs_url "${VIEW_LOGS_URL:-}" \
  --argjson pr_preview_urls "$PR_URLS_JSON" \
  '{ok: true, status: $status, conclusion: $conclusion, branch: $branch,
    preview_url: (if $preview_url != "" then $preview_url else null end),
    branch_preview_url: (if $bp_preview_url != "" then $bp_preview_url else null end),
    view_logs_url: (if $view_logs_url != "" then $view_logs_url else null end),
    pr_preview_urls: $pr_preview_urls}'
