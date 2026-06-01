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
# Notes:
#   1. Single PR mode: sync_pr.yml push trigger (preview/**) auto-matches branch name
#   2. Multi PR mode: script modifies sync_mult_prs.yml adding push trigger + env vars
#   3. Cloudflare build is automatic after workflow completes
#   4. Example successful run: https://github.com/doc-claw-bot/pingcap-docsite-preview/runs/78489433899
# =============================================================================

set -euo pipefail

REPO_DIR="/home/doc-claw/github/pingcap-docsite-preview"
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

usage() {
    # Print the Usage section from the header comments (between Usage: and Notes: markers)
    sed -n '/^# Usage:/,/^# Notes:/p' "$0" | head -n -1 | sed 's/^# //; s/^#$//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            ACTION="single"
            PR_TYPE="$2"
            PR_NUM="$3"
            shift 3
            ;;
        --multi)
            ACTION="multi"
            shift
            ;;
        --branch-name|-n)
            BRANCH_NAME="$2"
            shift 2
            ;;
        --docs-pr)
            DOCS_PR="$2"
            shift 2
            ;;
        --docs-cn-pr)
            DOCS_CN_PR="$2"
            shift 2
            ;;
        --cloud-pr)
            CLOUD_PR="$2"
            shift 2
            ;;
        --operator-pr)
            OPERATOR_PR="$2"
            shift 2
            ;;
        --release-dir|-r)
            RELEASE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "错误: 未知参数: $1"
            usage
            ;;
    esac
done

# ---- Argument validation ----
if [[ "$ACTION" != "single" && "$ACTION" != "multi" ]]; then
    echo "错误: 请指定 --pr (单 PR) 或 --multi (多 PR)"
    usage
fi

if [[ "$ACTION" == "single" ]]; then
    if [[ -z "$PR_TYPE" || -z "$PR_NUM" ]]; then
        echo "错误: --pr 需要指定类型和 PR 号，例如: --pr docs 12345"
        usage
    fi
    case "$PR_TYPE" in
        docs)       BRANCH_NAME="preview/pingcap/docs/$PR_NUM" ;;
        docs-cn)    BRANCH_NAME="preview/pingcap/docs-cn/$PR_NUM" ;;
        cloud)      BRANCH_NAME="preview-cloud/pingcap/docs/$PR_NUM" ;;
        operator)   BRANCH_NAME="preview-operator/pingcap/docs-tidb-operator/$PR_NUM" ;;
        *)
            echo "错误: 支持的 PR 类型: docs, docs-cn, cloud, operator"
            exit 1
            ;;
    esac
fi

if [[ "$ACTION" == "multi" ]]; then
    if [[ -z "$BRANCH_NAME" ]]; then
        echo "错误: 多 PR 模式需要 --branch-name 指定分支名"
        usage
    fi
    if [[ -z "$DOCS_PR" && -z "$DOCS_CN_PR" && -z "$CLOUD_PR" && -z "$OPERATOR_PR" ]]; then
        echo "错误: 多 PR 模式至少需要指定一个 PR (--docs-pr, --docs-cn-pr, --cloud-pr, --operator-pr)"
        usage
    fi
    if [[ -z "$RELEASE_DIR" ]]; then
        echo "错误: 多 PR 模式需要 --release-dir 指定 release 目录 (例如 release-8.5)"
        usage
    fi
fi

# ---- Print plan ----
echo "═══════════════════════════════════════════"
echo "  文档 PR 预览"
echo "═══════════════════════════════════════════"
if [[ "$ACTION" == "single" ]]; then
    echo "  模式:         单 PR"
    echo "  类型:         $PR_TYPE ($PR_NUM)"
else
    echo "  模式:         多 PR"
    [[ -n "$DOCS_PR" ]]      && echo "  docs PR:      $DOCS_PR"
    [[ -n "$DOCS_CN_PR" ]]   && echo "  docs-cn PR:   $DOCS_CN_PR"
    [[ -n "$CLOUD_PR" ]]     && echo "  cloud PR:     $CLOUD_PR"
    [[ -n "$OPERATOR_PR" ]]  && echo "  operator PR:  $OPERATOR_PR"
    echo "  release 目录: $RELEASE_DIR"
fi
echo "  分支:         $BRANCH_NAME"
echo "  本地仓库:     $REPO_DIR"
echo "  干运行:       $DRY_RUN"
echo "═══════════════════════════════════════════"

# ---- Execution ----

# Step 1: Enter the repo directory
cd "$REPO_DIR"

# Step 2: Ensure main is up-to-date
echo ""
echo "⟳ 获取 main 最新代码..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  [干运行] git fetch $REMOTE main"
    echo "  [干运行] git checkout main"
else
    git fetch "$REMOTE" main
    git checkout main
    echo "  ✓ main 已更新"
fi

# Step 3: Create a new branch from main
echo ""
echo "⟳ 创建分支: $BRANCH_NAME..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  [干运行] git checkout -b $BRANCH_NAME"
else
    # Delete local branch if it already exists
    if git branch --list "$BRANCH_NAME" | grep -q .; then
        git branch -D "$BRANCH_NAME"
        echo "  ! 已删除本地已存在的同名分支"
    fi
    git checkout -b "$BRANCH_NAME"
    echo "  ✓ 分支已创建"
fi

# Step 4: For multi-PR mode, modify sync_mult_prs.yml
if [[ "$ACTION" == "multi" ]]; then
    echo ""
    echo "⟳ 修改 sync_mult_prs.yml 添加 PR 配置..."

    WORKFLOW_FILE=".github/workflows/sync_mult_prs.yml"

    if [[ "$DRY_RUN" == true ]]; then
        echo "  [干运行] 在 $WORKFLOW_FILE 中添加:"
        echo "    - push: branches: [$BRANCH_NAME]"
        echo "    - env 变量:"
        [[ -n "$DOCS_PR" ]]      && echo "      DOCS_PR: $DOCS_PR"
        [[ -n "$DOCS_CN_PR" ]]   && echo "      DOCS_CN_PR: $DOCS_CN_PR"
        [[ -n "$CLOUD_PR" ]]     && echo "      CLOUD_PR: $CLOUD_PR"
        [[ -n "$OPERATOR_PR" ]]  && echo "      OPERATOR_PR: $OPERATOR_PR"
        echo "      RELEASE_DIR: $RELEASE_DIR"
    else
        # Modify the workflow YAML via inline Python
        python3 << PYEOF
import sys

workflow_file = "$WORKFLOW_FILE"
branch_name = "$BRANCH_NAME"
docs_pr = "$DOCS_PR"
docs_cn_pr = "$DOCS_CN_PR"
cloud_pr = "$CLOUD_PR"
operator_pr = "$OPERATOR_PR"
release_dir = "$RELEASE_DIR"

with open(workflow_file, 'r') as f:
    content = f.read()

# Step 1: Insert push trigger after "on:" — add branch to push branches
old_on = "on:\n  workflow_dispatch:"
new_on = f"""on:
  push:
    branches:
      - {branch_name}
  workflow_dispatch:"""
content = content.replace(old_on, new_on, 1)

# Step 2: Append PR env vars after the GITHUB_TOKEN line
env_vars = []
if docs_pr:
    env_vars.append(f"      DOCS_PR: {docs_pr}")
if docs_cn_pr:
    env_vars.append(f"      DOCS_CN_PR: {docs_cn_pr}")
if cloud_pr:
    env_vars.append(f"      CLOUD_PR: {cloud_pr}")
if operator_pr:
    env_vars.append(f"      OPERATOR_PR: {operator_pr}")
env_vars.append(f"      RELEASE_DIR: {release_dir}")

token_line = "        GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}"
for var in env_vars:
    content = content.replace(token_line, token_line + "\n" + var, 1)

with open(workflow_file, 'w') as f:
    f.write(content)

print("  ✓ sync_mult_prs.yml 已更新")
PYEOF
    fi
fi

# Step 5: Commit and push
echo ""
echo "⟳ 提交并推送..."

if [[ "$DRY_RUN" == true ]]; then
    echo "  [干运行] git add . && git commit -m \"Preview: $BRANCH_NAME\""
    echo "  [干运行] git push $REMOTE $BRANCH_NAME"
else
    git add .
    if git diff --cached --quiet; then
        echo "  ! 没有变更需要提交"
    else
        git commit -m "Preview: $BRANCH_NAME"
        echo "  ✓ 已提交"
    fi

    echo ""
    echo "⟳ 推送到远程..."
    git push "$REMOTE" "$BRANCH_NAME"
    echo "  ✓ 已推送"
fi

# Step 6: Print result summary
echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ 预览已就绪！"
echo "═══════════════════════════════════════════"
echo "  分支:  $BRANCH_NAME"
echo "  仓库:  https://github.com/doc-claw-bot/pingcap-docsite-preview"

if [[ "$ACTION" == "multi" ]]; then
    echo ""
    echo "  多 PR 配置已推送到分支 workflow 文件。"
    echo "  注意: 同步 PR 后，Cloudflare 会自动构建预览。"
    echo "  如需定期更新，请继续配置 sync_scheduler.yml。"
fi

echo ""
echo "  查看运行状态:"
echo "  https://github.com/doc-claw-bot/pingcap-docsite-preview/actions"
echo "═══════════════════════════════════════════"
