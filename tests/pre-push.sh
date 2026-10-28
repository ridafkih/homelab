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

commit README.md "a clean file" "Start"
if pushes; then
  fail "a push without homelab.exposureDenylist set went through"
fi
grep -q 'set homelab.exposureDenylist' "$work/push.log" || fail "the hook did not say homelab.exposureDenylist is unset"

git config homelab.exposureDenylist "$work/missing"
pushes && fail "a push with a missing denylist went through"

git config homelab.exposureDenylist "$work/denylist"
pushes || { cat "$work/push.log"; fail "a clean push was refused"; }

commit README.md "built by planted-tool-name" "Add a leak"
pushes && fail "a push whose tree holds a denylisted line went through"

git reset -q --hard HEAD~1
commit notes.md "built by planted-tool-name" "Add a leak"
commit notes.md "nothing here" "Remove it again"
pushes && fail "a push whose history adds a denylisted line went through"

git reset -q --hard origin/main
commit README.md "still clean" "Mention planted-tool-name"
pushes && fail "a push whose commit message holds a denylisted line went through"

git reset -q --hard origin/main
commit README.md "still clean" "Change the readme"
pushes || { cat "$work/push.log"; fail "a clean follow-up push was refused"; }

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "ok: the pre-push hook applies the denylist to the tree, the diffs and the messages"
