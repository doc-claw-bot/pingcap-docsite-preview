#!/bin/bash

# Synchronize the content of multiple PRs to the markdown-pages folder to deploy a preview website.
#
# Preferred input:
#   MULTI_PR_REFS as a newline-delimited list of preview branch refs, for example:
#     preview/pingcap/docs/1234
#     preview/pingcap/docs-cn/5678
#     preview/pingcap/docs/9012
#
# Backward-compatible input:
#   DOCS_PR / DOCS_CN_PR / CLOUD_DOCS_PR / OPERATOR_DOCS_PR
#
# Optional:
#   RELEASE_DIR=release-x.y to mirror master content into a release directory after syncing.

set -euo pipefail
set -x

# Get the directory of this script.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd "$SCRIPT_DIR"

collect_branch_refs() {
  local -n out_refs=$1

  if [[ -n "${MULTI_PR_REFS:-}" ]]; then
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      out_refs+=("$ref")
    done <<< "$MULTI_PR_REFS"
  fi

  # Backward-compatible env vars.
  if [[ -n "${DOCS_PR:-}" ]]; then
    out_refs+=("preview/pingcap/docs/${DOCS_PR}")
  fi
  if [[ -n "${DOCS_CN_PR:-}" ]]; then
    out_refs+=("preview/pingcap/docs-cn/${DOCS_CN_PR}")
  fi
  if [[ -n "${CLOUD_DOCS_PR:-}" ]]; then
    out_refs+=("preview-cloud/pingcap/docs/${CLOUD_DOCS_PR}")
  fi
  if [[ -n "${OPERATOR_DOCS_PR:-}" ]]; then
    out_refs+=("preview-operator/pingcap/docs-tidb-operator/${OPERATOR_DOCS_PR}")
  fi
}

commit_changes() {
  local mess=$1
  # Return early if TEST is set and not empty.
  test -n "${TEST:-}" && echo "Test mode, returning..." && return 0
  git add .
  git commit -m "$mess" || echo "No changes to commit"
}

declare -a BRANCH_REFS=()
collect_branch_refs BRANCH_REFS

if [[ ${#BRANCH_REFS[@]} -eq 0 ]]; then
  echo "Error: no PR refs provided. Set MULTI_PR_REFS or legacy *_PR env vars."
  exit 1
fi

for ref in "${BRANCH_REFS[@]}"; do
  ./sync_pr.sh "$ref"
done

if [[ -n "${RELEASE_DIR:-}" && "$RELEASE_DIR" != "master" ]]; then
  rsync -av markdown-pages/zh/tidb/master/ markdown-pages/zh/tidb/"$RELEASE_DIR"/
  rsync -av markdown-pages/en/tidb/master/ markdown-pages/en/tidb/"$RELEASE_DIR"/
  rsync -av markdown-pages/en/tidb-in-kubernetes/master/ markdown-pages/en/tidb-in-kubernetes/"$RELEASE_DIR"/
  rsync -av markdown-pages/zh/tidb-in-kubernetes/master/ markdown-pages/zh/tidb-in-kubernetes/"$RELEASE_DIR"/
  commit_changes "Update the {release-x.y} directory"
else
  commit_changes "Update multi-PR preview content"
fi
