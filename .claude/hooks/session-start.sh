#!/bin/bash
# SESSION START — give a web session a COMPLETE and CURRENT copy of this repo.
#
# Why this exists (2026-08-14). Claude Code on the web clones with `--depth`, so a
# session opens holding only the newest handful of commits — this repo arrived with
# THREE. The FILES are current, so ordinary work is unaffected and the truncation is
# invisible: nothing errors, nothing looks wrong.
#
# What it silently breaks is anything that reads BACKWARDS. `git log` and `git blame`
# stop early, and — the reason this hook exists — a scan of the history for leaked
# credentials returns a confident "clean" having never seen most of the repo. That
# happened in the myhumansapp/apps.leadershiptap audit: the first scan covered 50 of
# 415 commits and proved nothing. A clean result that proves nothing is worse than no
# result, because it gets believed.
#
# That matters more here than in the web repos, not less. This repository is PUBLIC,
# and an iOS project is the classic place for a signing certificate or an App Store
# key to be committed and later deleted — still fully readable in history. Its August
# 2026 audit came back genuinely clean across all 24 commits, and the only way to keep
# re-proving that is to make sure the next scan can see the whole thing.
#
# There is no GitHub setting for this. Clone depth is chosen by whoever runs the
# clone, not by the repository, so correcting it here is the only durable fix.
#
# FETCH ONLY — never pull, never checkout, never merge. `fetch` updates this
# machine's copy of what is on GitHub and touches no working file and no branch you
# have open, so it cannot disturb work in progress or overwrite anything unpushed.
# That restriction is the point, not an oversight.
#
# NO DEPENDENCY STEP, unlike the copies in apps.leadershiptap and myhumansapp: there
# is no package.json here and nothing to install. The build is Xcode's, it runs on
# macOS in CI (see .github/workflows/ci.yml), and no Linux session can reproduce it —
# so a hook that pretended otherwise would only fail every start. If a package manager
# is ever added, this is where it goes.
set -euo pipefail

# A Mac's clone is already complete; this is a web-session problem only.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# `--unshallow` ERRORS on an already-complete clone, so ask before using it rather
# than swallowing a failure that would hide a real one.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "Clone is shallow — fetching full history..."
  git fetch --unshallow --tags origin \
    || echo "WARNING: could not fetch full history. Anything reading git log/blame, or scanning history, is INCOMPLETE."
else
  # Already complete: still refresh, so `origin/main` reflects what is really on
  # GitHub rather than whatever was true when the container was built.
  git fetch --tags origin \
    || echo "WARNING: could not reach origin. Your view of origin/main may be stale."
fi

echo "Session ready — full history fetched."
