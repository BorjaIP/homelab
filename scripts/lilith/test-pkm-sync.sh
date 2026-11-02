#!/bin/bash
# Tests for pkm-sync.sh against a throwaway local remote. Touches nothing outside a temp dir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/pkm-sync.sh"
T=$(mktemp -d); cd "$T"
pass=0; failn=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; failn=$((failn+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
G() { git -C "$1" "${@:2}"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
PC="-c user.name=BorjaIP -c user.email=pc@example.com"


# Stand-in for the vault's `lint.py --leaks` (contract: exit 0 clean, 3 leaks, 2 usage/error).
# STUB_MODE selects the behaviour: ok | leak | leak-on-push | usage.
add_stub() { mkdir -p "$1/.claude/scripts"; cat > "$1/.claude/scripts/lint.py" <<'PY'
import os, sys
mode = os.environ.get("STUB_MODE", "ok")
args = sys.argv[1:]
if "--leaks" not in args or mode == "usage":
    print("usage: lint.py --leaks [--staged | --added-vs REF]", file=sys.stderr)
    sys.exit(2)
if mode == "leak" or (mode == "leak-on-push" and "--added-vs" in args):
    print("pkm/notes/a.md:1 wikilink")
    print("leaks: 1")
    sys.exit(3)
print("leaks: 0")
PY
}

git init -q --bare -b main origin.git
git clone -q "file://$T/origin.git" seed 2>/dev/null
mkdir -p seed/pkm; echo base > seed/pkm/a.md; echo base > seed/pkm/shared.md; echo readme > seed/README.md
add_stub seed
G seed add -A; G seed $PC commit -q -m "init"; G seed push -q origin main
git clone -q "file://$T/origin.git" pc
git clone -q "file://$T/origin.git" lilith
run() { PKM_DIR="$T/lilith" bash "$SCRIPT" 2>&1; }
pcpush() { G pc $PC add -A; G pc $PC commit -q -m "vault backup: pc"; G pc $PC pull -q --rebase origin main || echo "HARNESS: pc pull failed"; G pc push -q origin main || echo "HARNESS: pc push failed"; }

echo "T1 no changes"
out=$(run); check "reports nothing to do" '[[ "$out" == *"committed=0 pulled=0 pushed=0"* ]]'

echo "T2 new vault file -> commit + push"
echo hi > lilith/pkm/new.md
out=$(run); echo "    $out"
msg=$(G origin.git log -1 --format=%s); author=$(G origin.git log -1 --format=%an)
check "message format" '[[ "$msg" =~ ^lilith:\ vault\ backup:\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]'
check "author is lilith" '[ "$author" = lilith ]'
check "pushed to origin" '[ "$(G origin.git show main:pkm/new.md)" = hi ]'
check "clone clean afterwards" '[ -z "$(G lilith status --porcelain)" ]'

echo "T3 remote ahead, nothing local -> fast-forward"
echo from-pc > pc/pkm/pc1.md; pcpush
out=$(run); check "pulled 1" '[[ "$out" == *"pulled=1"* ]]'
check "file arrived" '[ -f lilith/pkm/pc1.md ]'

echo "T4 both sides changed different files -> rebase + push, linear history"
echo from-pc2 > pc/pkm/pc2.md; pcpush
echo lil2 > lilith/pkm/lil2.md
out=$(run); echo "    $out"
check "committed, pulled and pushed" '[[ "$out" == *"committed=1 pulled=1 pushed=1"* ]]'
check "origin has both" '[ "$(G origin.git ls-tree -r --name-only main | grep -c -E "pc2.md|lil2.md")" = 2 ]'
check "no merge commits" '[ "$(G origin.git rev-list --merges main | wc -l)" = 0 ]'

echo "T5 same file edited on both sides -> conflict, nothing lost"
echo pc-version > pc/pkm/shared.md; pcpush
echo lilith-version > lilith/pkm/shared.md
out=$(run); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "says conflict" '[[ "$out" == *"conflicts"* ]]'
check "rebase aborted" '[ ! -d lilith/.git/rebase-merge ] && [ ! -d lilith/.git/rebase-apply ]'
check "local commit kept" '[ "$(G lilith show HEAD:pkm/shared.md)" = lilith-version ]'
check "origin untouched" '[ "$(G origin.git show main:pkm/shared.md)" = pc-version ]'
G lilith reset -q --hard origin/main; G lilith fetch -q origin; G lilith reset -q --hard origin/main

echo "T6 secret in the changes -> nothing committed"
echo "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789ab" > lilith/pkm/leak.md
before=$(G lilith rev-parse HEAD)
out=$(run); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "no new commit" '[ "$(G lilith rev-parse HEAD)" = "$before" ]'
check "nothing staged" '[ -z "$(G lilith diff --cached --name-only)" ]'
check "output never prints the secret" '[[ "$out" != *ghp_abcdef* ]]'
rm lilith/pkm/leak.md

echo "T7 tracked file changed outside the vault -> warned, kept, vault still synced"
echo edit >> lilith/README.md; echo vault > lilith/pkm/v7.md
out=$(run); echo "    $out"
check "warns" '[[ "$out" == *"outside pkm/"* ]]'
check "vault file pushed" '[ "$(G origin.git show main:pkm/v7.md)" = vault ]'
check "README edit preserved, not committed" '[ "$(G lilith status --porcelain)" = " M README.md" ]'
G lilith checkout -q -- README.md

echo "T8 shallow clone -> unshallowed"
git clone -q --depth 1 "file://$T/origin.git" lilith2
echo s > lilith2/pkm/s8.md
out=$(PKM_DIR="$T/lilith2" bash "$SCRIPT" 2>&1); echo "    $out"
check "no longer shallow" '[ "$(G lilith2 rev-parse --is-shallow-repository)" = false ]'
check "pushed" '[ "$(G origin.git show main:pkm/s8.md)" = s ]'

echo "T9 wrong branch -> refuses"
G lilith checkout -q -b other
out=$(run); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
G lilith checkout -q main

echo "T10 pkm/private-like ignored content is never committed"
echo "pkm/private/*" > lilith/.gitignore; G lilith add .gitignore; G lilith $PC commit -q -m "ignore"; G lilith push -q origin main 2>/dev/null
mkdir -p lilith/pkm/private; echo secret-diary > lilith/pkm/private/d.md
out=$(run)
check "private file not in origin" '! G origin.git ls-tree -r --name-only main | grep -q private/d.md'

echo "T11 private/ not ignored by git -> refuses to commit it (defense in depth)"
git init -q --bare -b main origin2.git
git clone -q "file://$T/origin2.git" seed2 2>/dev/null
mkdir -p seed2/pkm; echo base > seed2/pkm/a.md
add_stub seed2
G seed2 add -A; G seed2 $PC commit -q -m "init"; G seed2 push -q origin main
git clone -q "file://$T/origin2.git" lilith3
mkdir -p lilith3/pkm/private/reminders; echo diary > lilith3/pkm/private/reminders/d.md; echo ok > lilith3/pkm/pub.md
before=$(G lilith3 rev-parse HEAD)
out=$(PKM_DIR="$T/lilith3" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "explains why" '[[ "$out" == *"private/"* ]]'
check "no new commit" '[ "$(G lilith3 rev-parse HEAD)" = "$before" ]'
check "nothing staged" '[ -z "$(G lilith3 diff --cached --name-only)" ]'
check "nothing reached the remote" '! G origin2.git ls-tree -r --name-only main | grep -q -E "private|pub.md"'

echo "T12 non-ASCII names under private/ with no .gitignore are refused (git quotes them without -z)"
git init -q --bare -b main origin3.git
git clone -q "file://$T/origin3.git" seed3 2>/dev/null
mkdir -p seed3/pkm; echo base > seed3/pkm/a.md; add_stub seed3
G seed3 add -A; G seed3 $PC commit -q -m "init"; G seed3 push -q origin main
git clone -q "file://$T/origin3.git" lilith4
mkdir -p "lilith4/pkm/private/año"; echo d > "lilith4/pkm/private/café.md"; echo d > "lilith4/pkm/private/año/x.md"; echo ok > lilith4/pkm/pub.md
before=$(G lilith4 rev-parse HEAD)
out=$(PKM_DIR="$T/lilith4" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "no new commit" '[ "$(G lilith4 rev-parse HEAD)" = "$before" ]'
check "nothing reached the remote" '! G origin3.git ls-tree -r --name-only main | grep -q -E "private|pub.md"'

echo "T13 thousands of staged paths under private/ (the first match must not hide behind a closed pipe)"
git clone -q "file://$T/origin3.git" lilith5
mkdir -p lilith5/pkm/private/bulk
for i in $(seq 1 4000); do : > "lilith5/pkm/private/bulk/file-number-$i-with-a-long-name.md"; done
before=$(G lilith5 rev-parse HEAD)
out=$(PKM_DIR="$T/lilith5" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "no new commit" '[ "$(G lilith5 rev-parse HEAD)" = "$before" ]'

echo "T14 a secret on the first line of a very large diff is still found"
git clone -q "file://$T/origin3.git" lilith6
{ echo "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789ab"; for i in $(seq 1 8000); do echo "line $i lorem ipsum dolor sit amet consectetur adipiscing"; done; } > lilith6/pkm/big.md
before=$(G lilith6 rev-parse HEAD)
out=$(PKM_DIR="$T/lilith6" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "no new commit" '[ "$(G lilith6 rev-parse HEAD)" = "$before" ]'

echo "T15 leak check finds a leak -> nothing is committed or pushed"
git clone -q "file://$T/origin.git" lilith7
echo "[[Secret]]" > lilith7/pkm/leaky.md
before=$(G lilith7 rev-parse HEAD); rbefore=$(G origin.git rev-parse main)
out=$(STUB_MODE=leak PKM_DIR="$T/lilith7" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "prints the finding" '[[ "$out" == *"pkm/notes/a.md:1 wikilink"* ]]'
check "no new commit" '[ "$(G lilith7 rev-parse HEAD)" = "$before" ]'
check "nothing staged" '[ -z "$(G lilith7 diff --cached --name-only)" ]'
check "the file stays in the work tree" '[ -f lilith7/pkm/leaky.md ]'
check "remote untouched" '[ "$(G origin.git rev-parse main)" = "$rbefore" ]'

echo "T16 leak check clean -> normal commit and push"
out=$(STUB_MODE=ok PKM_DIR="$T/lilith7" bash "$SCRIPT" 2>&1); rc=$?
check "exit 0 and pushed" '[ $rc -eq 0 ] && [[ "$out" == *"committed=1"*"pushed=1"* ]]'

echo "T17 leak check missing -> refuses (fail closed)"
git clone -q "file://$T/origin.git" lilith8
rm lilith8/.claude/scripts/lint.py; echo "x" > lilith8/pkm/t17.md
before=$(G lilith8 rev-parse HEAD)
out=$(PKM_DIR="$T/lilith8" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "says the check is missing" '[[ "$out" == *"leak check"* ]]'
check "no new commit" '[ "$(G lilith8 rev-parse HEAD)" = "$before" ]'

echo "T18 leak check that cannot run (exit 2) -> refuses"
git clone -q "file://$T/origin.git" lilith9
echo "x" > lilith9/pkm/t18.md
before=$(G lilith9 rev-parse HEAD)
out=$(STUB_MODE=usage PKM_DIR="$T/lilith9" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "says it could not run" '[[ "$out" == *"could not run"* ]]'
check "no new commit" '[ "$(G lilith9 rev-parse HEAD)" = "$before" ]'

echo "T19 leak found only at push time -> the commit stays local, nothing is pushed"
git clone -q "file://$T/origin.git" lilith10
echo "x" > lilith10/pkm/t19.md
rbefore=$(G origin.git rev-parse main)
out=$(STUB_MODE=leak-on-push PKM_DIR="$T/lilith10" bash "$SCRIPT" 2>&1); rc=$?
check "exit 1" '[ $rc -eq 1 ]'
check "commit exists locally" '[ "$(G lilith10 log -1 --format=%s)" = "lilith: vault backup: $(G lilith10 log -1 --format=%s | sed "s/^lilith: vault backup: //")" ] && G lilith10 log -1 --format=%s | grep -q "^lilith: vault backup: "'
check "remote untouched" '[ "$(G origin.git rev-parse main)" = "$rbefore" ]'

PKM_SCRIPTS_SRC="${PKM_SCRIPTS_SRC:-$HOME/projects/pkm/.claude/scripts}"
if [ -f "$PKM_SCRIPTS_SRC/lint.py" ] && grep -q -e "--leaks" "$PKM_SCRIPTS_SRC/lint.py"; then
echo "T20 integration with the vault's real lint.py --leaks"
git init -q --bare -b main origin4.git
git clone -q "file://$T/origin4.git" seed4 2>/dev/null
mkdir -p seed4/pkm/notes seed4/.claude; printf 'pkm/private/*\n__pycache__/\n' > seed4/.gitignore
printf -- '---\ntitle: A\ncreated: Monday 24th April 2023 19:04\naliases:\ntags:\n  - t\n---\nhello\n' > seed4/pkm/notes/A.md
cp -r "$PKM_SCRIPTS_SRC" seed4/.claude/scripts; rm -rf seed4/.claude/scripts/tests seed4/.claude/scripts/__pycache__
G seed4 add -A; G seed4 $PC commit -q -m "init"; G seed4 push -q origin main
LONG="the quarterly insurance renewal for the flat is due and the broker needs the signed form back"
new_clone() { git clone -q "file://$T/origin4.git" "$1" 2>/dev/null; mkdir -p "$1/pkm/private/reminders"; printf 'Secret Stuff body\n%s\n' "$LONG" > "$1/pkm/private/reminders/Secret Stuff.md"; }
run4() { PKM_DIR="$T/$1" bash "$SCRIPT" 2>&1; }

new_clone i1; printf -- '---\ntitle: B\ncreated: Monday 24th April 2023 19:04\naliases:\ntags:\n  - t\n---\nlinks to [[A]] only\n' > i1/pkm/notes/B.md
out=$(run4 i1); rc=$?
check "clean public change is committed and pushed" '[ $rc -eq 0 ] && [[ "$out" == *"committed=1"*"pushed=1"* ]]'

new_clone i2; printf 'see [[Secret Stuff]]\n' > i2/pkm/notes/C.md
before=$(G i2 rev-parse HEAD); out=$(run4 i2); rc=$?
check "wikilink to a private-only note is refused" '[ $rc -eq 1 ] && [ "$(G i2 rev-parse HEAD)" = "$before" ]'
check "the report names the page and the kind" '[[ "$out" == *"notes/C.md:1 wikilink"* ]]'
check "the private name is not printed" '[[ "$out" != *"Secret Stuff"* ]]'

new_clone i3; printf 'see [x](../private/reminders/Secret%%20Stuff.md)\n' > i3/pkm/notes/D.md
before=$(G i3 rev-parse HEAD); out=$(run4 i3); rc=$?
check "Markdown link into private/ is refused" '[ $rc -eq 1 ] && [ "$(G i3 rev-parse HEAD)" = "$before" ]'

new_clone i4; printf 'intro\n%s\n' "$LONG" > i4/pkm/notes/E.md
before=$(G i4 rev-parse HEAD); out=$(run4 i4); rc=$?
check "a long line copied from a private note is refused" '[ $rc -eq 1 ] && [ "$(G i4 rev-parse HEAD)" = "$before" ]'
check "nothing of it reached the remote" '! G origin4.git ls-tree -r --name-only main | grep -q -E "notes/(C|D|E).md"'

# Known limit, kept visible: the copy guard compares whole normalized lines, so a private sentence
# pasted inside a longer line is NOT detected.
new_clone i6; printf 'summary: %s\n' "$LONG" > i6/pkm/notes/G.md
out=$(run4 i6); rc=$?
check "KNOWN LIMIT: a private sentence embedded in a longer line is not detected" '[ $rc -eq 0 ]'

new_clone i5; printf 'see /etc/ssl/private/key.pem for the TLS key\n' > i5/pkm/notes/F.md
out=$(run4 i5); rc=$?
check "a public path like /etc/ssl/private/ is not a leak" '[ $rc -eq 0 ] && [[ "$out" == *"committed=1"* ]]'
else
echo "T20 skipped: the vault's lint.py with --leaks was not found at $PKM_SCRIPTS_SRC"
fi

echo; echo "RESULT: $pass passed, $failn failed"
rm -rf "$T"
[ "$failn" -eq 0 ]
