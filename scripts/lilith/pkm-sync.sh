#!/bin/bash
# Two-way sync of Hermes' clone of the pkm repo with origin/main.
#   1. commits changes made inside the vault folder as "lilith: vault backup: <date time>"
#   2. rebases onto origin/main (never discards local commits)
#   3. pushes to main
# Before committing and before pushing it refuses if `.claude/scripts/lint.py --leaks` reports that a
# public page leaks private content (or if that check is missing or cannot run). No bypass switch.
# Pipelines with an early-exit reader (`| grep -q`, `| head`) are avoided on purpose: under pipefail the
# writer dies of SIGPIPE (141) and the `if` reads that as "not found", which silently disables a guard.
# Aborts with exit 1 and leaves everything as it was when something looks wrong.
set -euo pipefail

PKM_DIR="${PKM_DIR:-/home/bis/pkm}"
VAULT_DIR="${VAULT_DIR:-pkm}"
BRANCH="${BRANCH:-main}"
AUTHOR_NAME="${AUTHOR_NAME:-lilith}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-lilith@lilith.local}"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
export GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_COMMITTER_NAME="$AUTHOR_NAME"
export GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL"

SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(sk|rk)-[A-Za-z0-9_-]{20,}|\bghp_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}|\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b|\bAKIA[0-9A-Z]{16}\b|(api[_-]?key|secret|token|passw(or)?d)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9_+=-]{24,}'

log() { echo "pkm-sync: $*"; }
fail() { echo "pkm-sync: $*" >&2; exit 1; }

# Runs the vault's leak check from the repo root. Returns 0 only when it ran and found nothing.
leak_check() {
  if [ ! -f .claude/scripts/lint.py ]; then
    echo "pkm-sync: leak check missing (.claude/scripts/lint.py); refusing to publish" >&2
    return 1
  fi
  local out rc=0
  out=$(python3 .claude/scripts/lint.py --leaks "$@" 2>&1) || rc=$?
  case $rc in
    0) return 0 ;;
    3) printf '%s\n' "$out" >&2
       echo "pkm-sync: a public page would leak private content; refusing to publish" >&2
       return 1 ;;
    *) printf '%s\n' "$out" >&2
       echo "pkm-sync: leak check could not run (exit $rc); refusing to publish" >&2
       return 1 ;;
  esac
}

cd "$PKM_DIR"
exec 9>"$(git rev-parse --git-dir)/pkm-sync.lock"
flock -n 9 || { log "another run is in progress, skipping"; exit 0; }

[ "$(git symbolic-ref --short HEAD)" = "$BRANCH" ] || fail "not on $BRANCH, refusing to run"
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch --quiet --unshallow origin
fi

committed=0
git add -A -- "$VAULT_DIR"
leaked=0
while IFS= read -r -d '' f; do
  case "$f" in "$VAULT_DIR"/private/*) leaked=1 ;; esac
done < <(git diff --cached --name-only -z --no-renames)
if [ "$leaked" -eq 1 ]; then
  git reset -q -- "$VAULT_DIR"
  fail "$VAULT_DIR/private/ is not ignored by Git (check .gitignore); refusing to commit it, nothing was committed"
fi
if ! git diff --cached --quiet; then
  nsecret=$(git diff --cached -U0 | grep -E '^\+[^+]' | grep -Eic -e "$SECRET_RE" || true)
  if [ "${nsecret:-0}" -gt 0 ]; then
    git reset -q -- "$VAULT_DIR"
    echo "pkm-sync: possible secret in the vault changes, nothing committed. Changed files:" >&2
    git status --short -- "$VAULT_DIR" >&2
    exit 1
  fi
  if ! leak_check --staged; then
    git reset -q -- "$VAULT_DIR"
    echo "pkm-sync: nothing was committed; the files stay in the work tree. Changed files:" >&2
    git status --short -- "$VAULT_DIR" >&2
    exit 1
  fi
  git commit -q -m "lilith: vault backup: $(date '+%Y-%m-%d %H:%M:%S')"
  committed=1
fi

outside=$(git status --porcelain --untracked-files=no | wc -l)
[ "$outside" -eq 0 ] || log "warning: $outside tracked file(s) changed outside $VAULT_DIR/, not committed"

pulled=0
pushed=0
for attempt in 1 2 3; do
  git fetch --quiet origin "$BRANCH"
  behind=$(git rev-list --count "HEAD..origin/$BRANCH")
  ahead=$(git rev-list --count "origin/$BRANCH..HEAD")
  if [ "$behind" -gt 0 ]; then
    if [ "$ahead" -eq 0 ]; then
      git merge --quiet --ff-only "origin/$BRANCH"
    elif ! git rebase --quiet --autostash "origin/$BRANCH" >/dev/null 2>&1; then
      git rebase --abort >/dev/null 2>&1 || true
      fail "rebase onto origin/$BRANCH conflicts; local commits kept, resolve by hand (cd $PKM_DIR)"
    fi
    pulled=$((pulled + behind))
    ahead=$(git rev-list --count "origin/$BRANCH..HEAD")
  fi
  [ "$ahead" -gt 0 ] || break
  leak_check --added-vs "origin/$BRANCH" || fail "leak check failed before pushing; local commits kept, nothing pushed"
  if git push --quiet origin "HEAD:$BRANCH" 2>/dev/null; then
    pushed=$ahead
    break
  fi
  [ "$attempt" -lt 3 ] || fail "push rejected 3 times, local commits kept"
done

log "at $(git rev-parse --short HEAD): committed=$committed pulled=$pulled pushed=$pushed"
