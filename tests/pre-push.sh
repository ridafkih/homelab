#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
hooks=$root/scripts/hooks
[ -x "$hooks/pre-push" ] || { echo "FAIL: scripts/hooks/pre-push is missing or not executable"; exit 1; }

for tool in git tar grep sed mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool"; exit 2; }
done

work=$(mktemp -d -t pre-push-test.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

failures=0
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

printf '%s\n' '# planted' 'planted-tool-name' > "$work/denylist"
git init -q --bare "$work/remote.git"
git init -q "$work/clone"
cd "$work/clone"
git config user.name test
git config user.email test
git config core.hooksPath "$hooks"
git remote add origin "$work/remote.git"

commit() {
  printf '%s\n' "$2" > "$1"
  git add -A
  git commit -q -m "$3"
}

pushes() {
  git push -q origin HEAD:refs/heads/main > "$work/push.log" 2>&1
}

refused() {
  if pushes; then
    fail "$1 went through"
  elif ! grep -q -- "$2" "$work/push.log"; then
    cat "$work/push.log"
    fail "$1 was refused without saying: $2"
  fi
}

at=@
tailnet=ts

commit README.md "a clean file" "Start"
refused "a push without homelab.exposureDenylist set" 'set homelab.exposureDenylist'

git config homelab.exposureDenylist "$work/missing"
refused "a push with a missing denylist" 'is missing or empty'

printf '%s\n' '# only a comment' > "$work/comments"
git config homelab.exposureDenylist "$work/comments"
refused "a push with a denylist that holds no patterns" 'holds no patterns'

git config homelab.exposureDenylist "$work/denylist"
pushes || { cat "$work/push.log"; fail "a clean push was refused"; }

commit README.md "built by planted-tool-name" "Add a leak"
refused "a push whose tree holds a denylisted line" 'the tree going to refs/heads/main would publish:'

git reset -q --hard HEAD~1
commit notes.md "built by planted-tool-name" "Add a leak"
commit notes.md "nothing here" "Remove it again"
refused "a push whose history adds a denylisted line" 'commits going to refs/heads/main would publish:'

git reset -q --hard origin/main
commit README.md "still clean" "Mention planted-tool-name"
refused "a push whose commit subject holds a denylisted line" 'commits going to refs/heads/main would publish:'

git reset -q --hard origin/main
printf '%s\n' "still clean, again" > README.md
git add -A
git commit -q -m "Change the readme" -m "- built by planted-tool-name"
refused "a push whose commit body has a denylisted bullet" 'commits going to refs/heads/main would publish:'

git reset -q --hard origin/main
commit README.md "still clean, once more" "Reach the box at host.tail1234.${tailnet}.net"
refused "a push whose commit message names the tailnet" 'tailnet domain'

git reset -q --hard origin/main
commit leak.md "built by planted-tool-name" "Add a leak behind the hook's back"
git -c core.hooksPath=/dev/null push -q origin HEAD:refs/heads/side > "$work/push.log" 2>&1 || { cat "$work/push.log"; fail "the hookless push did not land"; }
commit README.md "clean on top" "Change the readme"
if git push -q origin HEAD:refs/heads/side > "$work/push.log" 2>&1; then
  fail "a push whose tree still holds a leak the remote already has went through"
elif ! grep -q 'the tree going to refs/heads/side would publish:' "$work/push.log"; then
  cat "$work/push.log"
  fail "the tree scan did not refuse a leak the remote already has"
elif grep -q 'commits going to' "$work/push.log"; then
  cat "$work/push.log"
  fail "the history scan flagged a clean commit on top of a published leak"
fi

git reset -q --hard origin/main
git commit -q --allow-empty -m "Change nothing" -m "Co-Authored-By: someone <1+someone${at}users.noreply.github.com>"
pushes || { cat "$work/push.log"; fail "a clean follow-up push with a noreply co-author trailer was refused"; }

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "ok: the pre-push hook applies the never-list and the denylist to the tree, the diffs and the messages"
