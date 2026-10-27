#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

baseline=9af811a
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

for path in host/README.md Makefile .env.example; do
  if [ -n "$(git ls-files -- "$path")" ] || [ -e "$path" ]; then
    fail "$path is still present"
  fi
done

leftover="$(git ls-files -- host config openseo)"
if [ -n "$leftover" ]; then
  fail "Arch paths still tracked: $(echo "$leftover" | tr '\n' ' ')"
fi

for dir in host config openseo; do
  if [ -d "$dir" ]; then
    fail "$dir/ directory still exists on disk"
  fi
done

allowed=".github .gitignore .gitleaks.toml .sops.yaml LICENSE README.md apps compose.yaml docs flake.lock flake.nix homelab.env hosts modules scripts secrets tests"
top_level="$(git ls-files | cut -d/ -f1 | sort -u)"
for entry in $top_level; do
  case " $allowed " in
    *" $entry "*) ;;
    *) fail "unexpected top-level entry: $entry" ;;
  esac
done
for entry in $allowed; do
  if ! echo "$top_level" | grep -qxF "$entry"; then
    if [ "$entry" = .github ]; then
      echo "note: .github is not tracked yet; CI-build adds it in this wave"
    else
      fail "missing top-level entry: $entry"
    fi
  fi
done

if ! git cat-file -e "$baseline:.env.example" 2>/dev/null; then
  fail "baseline $baseline:.env.example is not in history"
else
  while IFS='=' read -r key value; do
    case "$key" in
      '' | \#*) continue ;;
      OLLAMA_* | PIHOLE_*) continue ;;
      *_VERSION)
        if ! git grep -qE "image: [^ ]+:${value}(@|$)" -- apps; then
          fail "$key ($value) is not pinned as an image tag under apps/"
        fi
        ;;
      *)
        if ! grep -qE "^${key}=" homelab.env && ! git grep -qw "$key" -- secrets/keys.tsv; then
          fail "$key from the old .env.example is in neither homelab.env nor secrets/keys.tsv"
        fi
        ;;
    esac
  done < <(git show "$baseline:.env.example")
fi

reference_pattern='(^|[^a-zA-Z0-9_./-])host/|\.\./config/|\.env\.example|Makefile|\bmake (up|down|pull|update|ps|restart)\b|COMPOSE_PROFILES'
code_hits="$(git grep -nE "$reference_pattern" -- flake.nix hosts modules apps scripts .github ':!scripts/tests' || true)"
if [ -n "$code_hits" ]; then
  fail "code still references retired Arch tooling:"
  echo "$code_hits"
fi

readme_hits="$(git grep -nE "$reference_pattern" -- README.md || true)"
if [ -n "$readme_hits" ]; then
  echo "note for D-readme-restore: README.md still mentions retired Arch tooling:"
  echo "$readme_hits"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures retire-arch check(s) failed"
  exit 1
fi

echo "retire-arch checks passed"
