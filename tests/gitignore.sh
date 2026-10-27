#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

failures=0

expect_ignored() {
  if ! git check-ignore -q --no-index "$1"; then
    echo "not ignored: $1"
    failures=$((failures + 1))
  fi
}

expect_kept() {
  if git check-ignore -q --no-index "$1"; then
    echo "ignored but must be kept: $1"
    failures=$((failures + 1))
  fi
}

for path in \
  .env \
  .env.prod \
  openseo/.env.prod \
  x.before-1 \
  compose.yaml.before-seafile \
  y.bak \
  host/etc/fstab.bak \
  result \
  result-1 \
  a.qcow2; do
  expect_ignored "$path"
done

for path in \
  foo.example \
  .env.example \
  openseo/.env.example \
  compose.yaml \
  README.md; do
  expect_kept "$path"
done

tracked_but_ignored="$(git ls-files -ci --exclude-standard)"
if [ -n "$tracked_but_ignored" ]; then
  echo "tracked files matched by ignore rules:"
  echo "$tracked_but_ignored"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures gitignore check(s) failed"
  exit 1
fi

echo "gitignore checks passed"
