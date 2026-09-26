#!/usr/bin/env bash
# Canonical fork-sync script for @schuettc/* republished forks.
# Source of truth: tools-ops/templates/fork-sync/upstream-sync.sh — every fork
# carries this file BYTE-IDENTICAL; per-fork settings live only in the
# workflow's `env:` block. Verify conformance with tools-ops/templates/fork-sync/check.sh.
#
# Model (see templates/fork-sync/README.md):
#   - schuettc-publish = upstream + genuine source patches + this CI. It never
#     carries packaging metadata (scoped name, -schuettc.N version, repo URLs).
#   - Daily: rebase onto upstream. Clean -> stamp metadata into an isolated copy
#     of the package, publish via npm OIDC trusted publishing (provenance), push
#     the rebased branch + a tag. Conflict or any other failure -> open (or reuse)
#     a tracking issue that @mentions the owner, and fail the run.
#
# Required env (set in the workflow):
#   UPSTREAM_REPO    owner/name of the upstream repo
#   UPSTREAM_BRANCH  upstream branch to track (main, master, ...)
#   PKG_NAME         published name, e.g. @schuettc/pi-claude-bridge
#   PKG_DIR          package directory relative to the repo root ("." for root)
#   TAG_PREFIX       git tag prefix for releases, e.g. "v" or "pi-auto-review-v"
# Optional env:
#   TEST_CMD         command run (repo root) after the rebase, before anything is published.
#                    Must install its own deps. Failure = issue + no publish. A clean rebase
#                    is not proof our patches still work; this is.
#   BUILD_CMD        command run (repo root) before packing, when the package ships built output.
#                    The isolated copy is published with --ignore-scripts, so any build the
#                    package's own prepack/prepublishOnly would do MUST happen here.
#   FORCE            "true" publishes even when already in sync
#   DRY_RUN          "true" runs everything (rebase, test, build, stamp, npm pack) but never
#                    publishes, pushes, tags, or files issues. Proves the pipeline end to end.
#   NOTIFY_TEST      "true" opens + closes a test issue to prove notifications, then exits
# Provided by Actions: GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, GITHUB_SERVER_URL, GITHUB_RUN_ID, GH_TOKEN
set -Eeuo pipefail

# stamp_package <package.json>: write the published name, -schuettc.N version
# and fork repo URLs into an isolated copy's package.json (env PKG_NAME, VER,
# FORK, DIR_FIELD). The one place stamping lives: the daily flow below calls it,
# and tools-ops/templates/fork-sync/first-publish.sh reaches it through
# `upstream-sync.sh --stamp <package.json>`, so a first publish is stamped
# exactly the way CI stamps.
stamp_package() {
  PKG_NAME="$PKG_NAME" VER="$VER" FORK="$FORK" DIR_FIELD="${DIR_FIELD:-}" node -e '
  const fs = require("fs"), f = process.argv[1], p = JSON.parse(fs.readFileSync(f));
  const { PKG_NAME, VER, FORK, DIR_FIELD } = process.env;
  p.name = PKG_NAME;
  p.version = VER;
  p.repository = { type: "git", url: `git+https://github.com/${FORK}.git`, ...(DIR_FIELD ? { directory: DIR_FIELD } : {}) };
  p.homepage = DIR_FIELD ? `https://github.com/${FORK}/tree/schuettc-publish/${DIR_FIELD}#readme` : `https://github.com/${FORK}#readme`;
  p.bugs = { url: `https://github.com/${FORK}/issues` };
  delete p.private;
  fs.writeFileSync(f, JSON.stringify(p, null, 2) + "\n");
' "$1"
}
if [ "${1:-}" = "--stamp" ]; then
  : "${PKG_NAME:?}" "${VER:?}" "${FORK:?}"
  stamp_package "${2:?usage: upstream-sync.sh --stamp <package.json>}"
  exit 0
fi

: "${UPSTREAM_REPO:?}" "${UPSTREAM_BRANCH:?}" "${PKG_NAME:?}" "${PKG_DIR:?}" "${TAG_PREFIX:?}"
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
NOTIFY_TEST="${NOTIFY_TEST:-false}"
BRANCH="schuettc-publish"
FORK="${GITHUB_REPOSITORY:?}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${FORK}/actions/runs/${GITHUB_RUN_ID:-local}"
PHASE="setup"

# Always address the fork explicitly: gh otherwise prefers a remote named
# "upstream" as its default repo and would try to file issues on the upstream
# project, where this token has no rights.
gh_fork() { gh "$@" -R "$FORK"; }

open_issue() { # title body -> creates or comments on an open issue with that title
  local title="$1" body="$2" num
  if [ "$DRY_RUN" = "true" ]; then echo "DRY RUN: would file issue: $title"; return 0; fi
  body="$(printf '%s\n\nRun: %s\n\ncc @%s' "$body" "$RUN_URL" "${GITHUB_REPOSITORY_OWNER:-}")"
  # List (not --search): the search index is eventually consistent and misses
  # an issue filed seconds earlier, which produced duplicates.
  num="$(TITLE="$title" gh_fork issue list --state open --limit 200 --json number,title \
    --jq 'map(select(.title == env.TITLE)) | .[0].number // empty')"
  if [ -n "$num" ]; then
    gh_fork issue comment "$num" --body "$body" >/dev/null && echo "Commented on existing issue #$num."
  else
    gh_fork issue create --title "$title" --body "$body" && echo "Opened tracking issue."
  fi
}

on_error() {
  local rc=$? line="$1"
  # set -E propagates this trap into subshells; only the top-level shell reports,
  # otherwise one failure files two issues (subshell, then parent).
  if [ "${BASHPID:-$$}" != "$$" ]; then exit "$rc"; fi
  trap - ERR
  git rebase --abort >/dev/null 2>&1 || true
  open_issue "upstream-sync failed: ${PKG_NAME}" \
    "The upstream-sync run failed in phase \`${PHASE}\` (line ${line}, exit ${rc}). Nothing was published after the failure point." \
    || echo "::warning::Could not open tracking issue."
  echo "::error::upstream-sync failed in phase ${PHASE}."
  exit "$rc"
}
trap 'on_error $LINENO' ERR

if [ "$NOTIFY_TEST" = "true" ]; then
  PHASE="notify-test"
  url="$(gh_fork issue create --title "upstream-sync notification test (${PKG_NAME})" \
    --body "$(printf 'Test issue opened by the upstream-sync notify_test input to prove the alert path reaches the owner. Safe to ignore; closed automatically.\n\nRun: %s\n\ncc @%s' "$RUN_URL" "${GITHUB_REPOSITORY_OWNER:-}")")"
  echo "Opened ${url}"
  gh_fork issue close "$url" --comment "Notification test complete." >/dev/null
  echo "Closed ${url}. If you received the email/notification, the alert path works."
  exit 0
fi

PHASE="fetch-upstream"
git config user.name "schuettc-fork-bot"
git config user.email "actions@github.com"
git remote add upstream "https://github.com/${UPSTREAM_REPO}.git" 2>/dev/null \
  || git remote set-url upstream "https://github.com/${UPSTREAM_REPO}.git"
git fetch upstream "$UPSTREAM_BRANCH" --quiet
UP="upstream/${UPSTREAM_BRANCH}"

base="$(git merge-base HEAD "$UP")"
ahead="$(git rev-list --count "${base}..${UP}")"
echo "${UP} is ${ahead} commit(s) ahead of our base ${base}"

if [ "$ahead" -eq 0 ] && [ "$FORCE" != "true" ] && [ "$DRY_RUN" != "true" ]; then
  echo "In sync; nothing to publish."
  exit 0
fi

if [ "$ahead" -gt 0 ]; then
  PHASE="rebase"
  echo "Rebasing our patch stack onto ${UP}..."
  if ! git rebase "$UP"; then
    trap - ERR
    upstream_log="$(git --no-pager log --oneline "${base}..${UP}")"
    git rebase --abort || true
    open_issue "upstream sync: manual rebase needed (${PKG_NAME})" \
      "$(printf 'Rebasing `%s` onto `%s` hit conflicts on our source patches and was aborted. Nothing was published.\n\nNew upstream commits (%s):\n\n```\n%s\n```\n\nResolve locally: rebase `%s` onto `%s`, force-push, then re-run the workflow (or wait for the next daily run).' \
        "$BRANCH" "$UP" "$ahead" "$upstream_log" "$BRANCH" "$UP")" \
      || echo "::warning::Could not open tracking issue."
    echo "::error::Rebase conflicted; published nothing."
    exit 1
  fi
fi

PHASE="version"
DIR_FIELD="${PKG_DIR#./}"; DIR_FIELD="${DIR_FIELD%/}"; [ "$DIR_FIELD" = "." ] && DIR_FIELD=""
PKG_JSON="${DIR_FIELD:+${DIR_FIELD}/}package.json"
upstream_ver="$(git show "${UP}:${PKG_JSON}" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).version')"
echo "upstream base version: ${upstream_ver}"

published="$(npm view "$PKG_NAME" versions --json 2>/dev/null || echo '[]')"
next_n="$(BASE="$upstream_ver" PUBLISHED="$published" node -e '
  const base = process.env.BASE;
  let v = [];
  try { v = JSON.parse(process.env.PUBLISHED); } catch (_) {}
  if (!Array.isArray(v)) v = [v];
  const re = new RegExp("^" + base.replace(/[.]/g, "\\.") + "-schuettc\\.(\\d+)$");
  let max = 0;
  for (const s of v) { const m = re.exec(s); if (m) max = Math.max(max, parseInt(m[1], 10)); }
  process.stdout.write(String(max + 1));
')"
new_ver="${upstream_ver}-schuettc.${next_n}"
echo "publishing new version: ${new_ver}"

if [ -n "${TEST_CMD:-}" ]; then
  PHASE="test"
  echo "Testing: ${TEST_CMD}"
  bash -c "$TEST_CMD"
fi

if [ -n "${BUILD_CMD:-}" ]; then
  PHASE="build"
  echo "Building: ${BUILD_CMD}"
  bash -c "$BUILD_CMD"
fi

# Publish from an isolated copy with packaging metadata stamped in. This keeps
# the branch free of fork metadata and sidesteps workspace/arborist issues in
# monorepos. Provenance is bound to the OIDC token + GITHUB_* env, not the cwd.
PHASE="publish"
pubdir="$(mktemp -d)"
rsync -a --exclude .git --exclude node_modules "${PKG_DIR%/}/" "$pubdir/"
VER="$new_ver" stamp_package "$pubdir/package.json"
if [ "$DRY_RUN" = "true" ]; then
  ( cd "$pubdir" && npm pack --dry-run --ignore-scripts )
  rm -rf "$pubdir"
  echo "DRY RUN OK: would publish ${PKG_NAME}@${new_ver} and push ${BRANCH} + tag ${TAG_PREFIX}${new_ver}."
  exit 0
fi
# --ignore-scripts: the copy is already built (BUILD_CMD) and lives outside the
# repo, so upstream lifecycle hooks (monorepo-relative builds, "publish via CI"
# guards) would fail or misfire here.
( cd "$pubdir" && npm publish --provenance --access public --tag latest --ignore-scripts )
rm -rf "$pubdir"

# Keep schuettc-publish rebased so tomorrow's run sees ahead=0. The branch keeps
# upstream's name/version; the scoped name and -schuettc.N live on npm + the tag.
PHASE="push"
git push --force-with-lease origin "HEAD:${BRANCH}"
git tag "${TAG_PREFIX}${new_ver}"
git push origin "${TAG_PREFIX}${new_ver}"

echo "Published ${PKG_NAME}@${new_ver}; pushed ${BRANCH} + tag ${TAG_PREFIX}${new_ver}."
