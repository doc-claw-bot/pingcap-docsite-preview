# AGENTS.md

Repo of shell + Python tooling that syncs PingCAP doc PRs into `markdown-pages/` for preview deployments. The Gatsby site itself lives in a separate repo (`pingcap/website-docs`) cloned on demand by `build.sh`; this repo only feeds it content and config.

## Commands

- Create a preview branch: `./preview_docs.sh --pr <docs|docs-cn|cloud|operator> <PR_NUMBER>`. Supports `--multi` for cross-repo previews, `--dry-run` to see the plan without executing, and `--local-sync` to run the sync scripts locally instead of relying on GitHub Actions.
- Preview site locally: `./build.sh dev` (or `build.sh develop`). Auto-clones `pingcap/website-docs` into `./website-docs/`, symlinks `markdown-pages/` into `website-docs/docs/`, copies `docs.json` (and `tooltip-terms.json` if present), then runs `pnpm install --frozen-lockfile && pnpm start` inside that clone.
- Production build: `./build.sh` (defaults to `build`). Same setup as dev, but runs `pnpm build` instead. Before building it rewrites image paths in `markdown-pages/` (to strip the locale prefix from `/media/` references); after building it copies media files into `website-docs/public/media/`.
- Run all tests: `python3 test/test.py` from repo root.
- There is no root `pnpm install`, lint, or typecheck — `package.json` only declares the pnpm version (`packageManager`) used inside `website-docs/`.

## Test setup (easy to miss)

Tests are driven by `test_config.toml` + `test/test.py` (Python 3.11, uses `tomllib`). The runner **requires a root-level `.env`** (gitignored) containing at minimum:

```
GITHUB_TOKEN=<repo-scope token>
TEST=1
DOCS_PR=<num>
DOCS_CN_PR=<num>
CLOUD_DOCS_PR=<num>
OPERATOR_DOCS_PR=<num>
RELEASE_DIR=release-6.7
```

CI populates this file in `.github/workflows/run_tests.yml`. Without `.env` locally the runner crashes at `_load_env`. `TEST=1` makes the sync scripts skip their `git commit` step so the test harness can diff `data/` against the generated `actual/` directory.

## Toolchain quirks

- Shell scripts prefer GNU coreutils: they resolve `gfind`/`gsed` before `find`/`sed`. On macOS install `findutils` + `gnu-sed` via Homebrew or the image-path rewrites in `build.sh` and the `{{< copyable >}}` stripping in `sync_pr.sh` will misbehave.
- `jq` is required by `sync_pr.sh`, `prune_preview_branches.sh`, and `preview_docs.sh --local-sync`.
- `scripts/replace_variables.py` replaces `{{{ .path.to.var }}}` placeholders in Markdown from `variables.json`. A JS port exists at `scripts/replace-variables.js` (behavior differs slightly: the JS version silently leaves unmatched placeholders, while the Python version raises an error).

## Branch naming convention (drives sync behavior)

`sync_pr.sh` parses the *current* git branch name to decide what to sync. The prefix is load-bearing:

- `preview/pingcap/docs/<PR>` → TiDB docs (`en` by default)
- `preview/pingcap/docs-cn/<PR>` → TiDB docs (`zh`)
- `preview-cloud/pingcap/docs/<PR>` → TiDB Cloud (`en/tidbcloud/master`)
- `preview-operator/pingcap/docs-tidb-operator/<PR>` → operator docs (both `en/` and `zh/` under `tidb-in-kubernetes/`)

A PR base branch of the form `i18n-<locale>-<master|release-*>` is normalized to `markdown-pages/<locale>/<product>/<master|release-*>`. `preview_docs.sh` is the helper that creates these branches and pushes them; it only allows branch names starting with `preview/` or `preview-`.

## Sync flow & env vars

- `sync_scaffold.sh` pulls `TOC*.md`, `_index.md`, `_docHome.md`, `docs.json`, and `tooltip-terms.json` from `pingcap/docs-staging` (default `main`, or a commit/branch passed as `$1`). Triggered by `sync_scaffold.yml` every 15 days.
- `sync_pr.sh` clones the source repo, fetches the PR ref, and copies only files changed relative to the PR base (`git diff --merge-base`), then runs `scripts/replace_variables.py` and removes `{{< copyable "..." >}}` shortcode lines (each match also consumes the following line). For `preview`/`preview-operator` it also mirrors TOC-namespace folders (`ai`, `develop`, `best-practices`, `api`, `releases` for tidb; `releases` for operator) into the stable branch path read from `docs.json` so previews reflect canonical URLs.
- `sync_mult_prs.sh` calls `sync_pr.sh` four times and rsyncs `master` → `RELEASE_DIR` for all four locale/product combos. Env vars it reads (must match what `sync_mult_prs.yml` sets): `DOCS_PR`, `DOCS_CN_PR`, `CLOUD_DOCS_PR`, `OPERATOR_DOCS_PR`, `RELEASE_DIR`. Note the `CLOUD_DOCS_PR` spelling — `preview_docs.sh --cloud-pr` maps to this name, not `CLOUD_PR`.
- `sync_scheduler.yml` can re-trigger sync workflows manually (`workflow_dispatch`) or on a schedule (cron lines currently commented out).
- `TEST` env var (any non-empty value) makes every sync script skip its `git commit` step. Essential for tests; easy to leave set by accident in a real shell session.
- `preview_docs.sh` creates preview branches and pushes them. With `--local-sync` it runs `sync_pr.sh` / `sync_mult_prs.sh` locally instead of relying on GitHub Actions; it marks the branch tip with a `[local-sync]` empty commit so `sync_pr.yml` skips re-syncing. Single-PR mode relies on the push trigger in `sync_pr.yml`; multi-PR mode modifies `sync_mult_prs.yml` to add the push trigger and env vars.
- All sync workflows set `git config user.name "Docsite Preview Bot"` themselves, then call the sync script and finally `.github/git_push.sh <ref>` to push back to the same branch the workflow ran on.

## Source-of-truth files

- `docs.json` — declares products, languages, version lists, stable branch, deprecated/archived/dmr versions, and TiDB Cloud OpenAPI spec URLs. Both `build.sh` and `sync_pr.sh` read it. Update here, not in `website-docs/`.
- `test_config.toml` — declares each test target script, its `diff_command`, `test_dependencies`, and per-case `args` + expected-output `directory`.

## Conventions

- Generated/clone artifacts `temp/`, `website-docs/`, and `.env` are gitignored — never commit them. `preview_docs.sh` stages only `.github/workflows/sync_mult_prs.yml` in multi-PR mode (when not using `--local-sync`) to avoid sweeping up stray `temp/` clones; follow that pattern when adding new flows.
- Preview branches (`preview*`) are pruned by `prune_preview_branches.sh` / `prune_branches.yml` once the upstream PR is merged. `DELETE_BRANCHES=remote` deletes on `origin`; default (unset) takes no delete action.
- Tests diff `data/` (expected) vs `actual/` (generated under each `test/<case>/`). When changing sync behavior, update the committed `data/` fixtures, not the runner.
