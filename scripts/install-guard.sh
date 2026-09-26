#!/usr/bin/env bash
# Installs the pre-commit guard that protects a tree shared by several agents.
#
# The guard itself lives in .git/hooks/, which git does not version, so a fresh
# clone has to install it again. Run this once per clone, or after a
# `git clone`/`git worktree add`:
#
#   ./scripts/install-guard.sh
#
# What it prevents is described at the top of the hook itself.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/.git/hooks/pre-commit"

if [ ! -d "$root/.git/hooks" ]; then
  echo "Kein .git/hooks in $root — ist das ein Worktree oder eine Kopie ohne Git?" >&2
  exit 1
fi

cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
# Pre-commit guard for a tree that several agents share.
#
# The problem this prevents
# ------------------------
# .git/index is ONE mutable file. Every agent that follows the recipe in
# .opencode/agents/game.md uses a private GIT_INDEX_FILE, but one that forgets
# — or a plain `git add` in the meantime — leaves the SHARED index holding a
# snapshot from an older state. The next `git commit` writes that snapshot, and
# files nobody touched get silently reverted or deleted.
#
# The rule
# --------
# Whatever the commit changes must be exactly what is on disk. A path that
# differs between the index and the worktree is a stale-index artefact, because
# the project's recipe stages whole files (`git add <file>`), never hunks.
#
# Escape hatch: a human doing deliberate partial staging can pass
# `git commit --no-verify`.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" 2>/dev/null || exit 1

candidates=$(git diff --cached --name-only HEAD 2>/dev/null)

stale=""
for f in $candidates; do
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    # `git diff --quiet -- f` compares the index against the worktree. Quiet
    # success means they are identical, which is what a correct `git add` gives.
    if ! git diff --quiet -- "$f" 2>/dev/null; then
      stale="$stale $f"
    fi
  elif [ -e "$f" ]; then
    stale="$stale $f"
  fi
done

if [ -n "$stale" ]; then
  echo "pre-commit: ABGELEHNT — der Index weicht vom Arbeitsbaum ab." >&2
  echo "            Fast immer ist das ein veralteter Index eines anderen Agenten." >&2
  echo >&2
  for f in $stale; do echo "            $f" >&2; done
  echo >&2
  echo "            Ein Commit würde diese Dateien auf einen alten Stand zurücksetzen" >&2
  echo "            oder löschen, obwohl niemand sie so angefasst hat." >&2
  echo "            Fix: eigenen Index verwenden —" >&2
  echo "                 export GIT_INDEX_FILE=\$(mktemp)" >&2
  echo "                 git read-tree HEAD && git add <deine Dateien> && git commit …" >&2
  echo "            Oder wenn der Index wirklich falsch ist: git reset -q HEAD -- ." >&2
  echo "            Bewusstes Teil-Staging: git commit --no-verify" >&2
  exit 1
fi

exit 0
HOOK

chmod +x "$hook"
echo "pre-commit-Guard installiert: $hook"
