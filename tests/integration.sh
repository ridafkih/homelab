#!/usr/bin/env bash
set -uo pipefail

usage() {
  printf 'usage: %s [--published]\n' "$0" >&2
  exit 2
}

published=false
case "${1:-}" in
  '') ;;
  --published) published=true ;;
  *) usage ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2

baseline=9af811a
main_after_t0=1362ce2
remote_url=https://github.com/ridafkih/homelab.git
tasks="T0-exposure-audit T2-build-host C1-flake-skeleton C2-secrets-contract C3-compose-contract
S-compose-edge S-compose-media S-compose-seafile S-compose-observability S-compose-dns-ai S-compose-openseo S-compose-windows
S-secrets-values M-hardware-network M-storage-disko M-nvidia M-egress M-dns-firewall M-host-basics M-docker-apps M-backup M-vm-smoke
CI-build R-retire-arch D-cutover-runbook D-readme-restore"
age_identity='AGE-SECRET-KEY-1[A-Z0-9]{50,}'

for tool in git jq gitleaks trufflehog age-keygen; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'missing tool: %s\n' "$tool"; exit 2; }
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/integration.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM

ran=0
failures=0
pass() { ran=$((ran + 1)); }
fail() { ran=$((ran + 1)); failures=$((failures + 1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3], got [$2]"; fi; }

git cat-file -e "$baseline^{commit}" 2>/dev/null || { printf 'baseline %s is not in %s\n' "$baseline" "$root"; exit 2; }
head_sha=$(git rev-parse HEAD)

merges=$(git log --merges --format=%s "$baseline..HEAD")
for task in $tasks; do
  if printf '%s\n' "$merges" | grep -Eq "^Merge $task(:|$)"; then pass; else fail "no merge commit for $task in $baseline..HEAD"; fi
done
if git merge-base --is-ancestor "$main_after_t0" HEAD; then pass; else fail "T0's main commit $main_after_t0 is not in HEAD"; fi

allowed_top=".github .gitignore .gitleaks.toml .sops.yaml LICENSE README.md apps compose.yaml docs flake.lock flake.nix homelab.env hosts modules scripts secrets tests"
check "top level is exactly the agreed set" "$(git ls-files | cut -d/ -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')" "$(printf '%s\n' $allowed_top | sort | tr '\n' ' ' | sed 's/ $//')"
check "no Arch host/, config/ or openseo/ paths tracked" "$(git ls-files -- host config openseo Makefile .env.example | wc -l | tr -d ' ')" "0"
check "no env files, hand backups, disk images or build outputs tracked" \
  "$(git ls-files | grep -Ec '(^|/)\.env(\..*)?$|(^|/)\.envrc$|\.before-|\.bak$|\.qcow2$|(^|/)result(-[^/]*)?$' || true)" "0"
check "no machine-id tracked" "$(git ls-files | grep -c 'machine-id$' || true)" "0"

identity_paths=$(git log --format= --name-only -E -G"$age_identity" HEAD | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
check "age identities in history live only in secrets/test-age.key" "$identity_paths" "secrets/test-age.key"
distinct_identities=$(git log -p --format= HEAD | grep -oE "$age_identity" | sort -u | wc -l | tr -d ' ')
check "exactly one age identity in history" "$distinct_identities" "1"

test_recipient=$(sed -nE 's/^  - &test (age1[0-9a-z]+)$/\1/p' .sops.yaml)
test_public=$(age-keygen -y secrets/test-age.key 2>/dev/null)
check "secrets/test-age.key is the &test recipient in .sops.yaml" "$test_public" "$test_recipient"
production_recipients=$(sed -nE 's/^ +recipient: (age1[0-9a-z]+)$/\1/p' secrets/homelab.yaml | sort | tr '\n' ' ' | sed 's/ $//')
expected_recipients=$(sed -nE 's/^  - &(host|admin) (age1[0-9a-z]+)$/\2/p' .sops.yaml | sort | tr '\n' ' ' | sed 's/ $//')
check "secrets/homelab.yaml is encrypted to exactly host and admin" "$production_recipients" "$expected_recipients"
case " $production_recipients " in
  *" $test_recipient "*) fail "the public test key can decrypt secrets/homelab.yaml" ;;
  *) pass ;;
esac
check "secrets/vm.yaml is encrypted to the test key only" "$(sed -nE 's/^ +recipient: (age1[0-9a-z]+)$/\1/p' secrets/vm.yaml | tr '\n' ' ' | sed 's/ $//')" "$test_recipient"

leaf_values() {
  awk '
    /^sops:/ { exit }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); depth = RLENGTH / 4
      line = substr($0, RLENGTH + 1)
      key = line; sub(/:.*/, "", key)
      value = line; sub(/^[^:]*:[[:space:]]*/, "", value)
      path[depth] = key
      if (value == "") next
      full = path[0]; for (i = 1; i <= depth; i++) full = full "/" path[i]
      if (value ~ /^ENC\[AES256_GCM,data:.*,type:[a-z]+\]$/) kind = "enc"
      else if (value == "\"\"") kind = "empty"
      else kind = "plain"
      print full "\t" kind
    }
  ' "$1"
}
empty_allowed=$(awk -F '\t' '$4 == "allow" { print $3 }' secrets/keys.tsv | sort -u)
for file in secrets/homelab.yaml secrets/vm.yaml; do
  leaves=$(leaf_values "$file")
  [ -n "$leaves" ] && pass || fail "$file has no values"
  plain=$(printf '%s\n' "$leaves" | awk -F '\t' '$2 == "plain" { print $1 }' | tr '\n' ' ')
  check "$file has no plaintext values" "$plain" ""
  bad_empty=$(printf '%s\n' "$leaves" | awk -F '\t' '$2 == "empty" { print $1 }' | grep -vxF -f <(printf '%s\n' "$empty_allowed") | tr '\n' ' ')
  check "$file leaves only allow-empty keys empty" "$bad_empty" ""
done

history_lines() {
  git log -p --format= HEAD -- . ':!tests' ':!scripts/tests' ':!docs/decisions'
}
check "no PEM private key in history" "$(history_lines | grep -cE '^\+.*-----BEGIN [A-Z ]*PRIVATE KEY-----' || true)" "0"
check "no Hugging Face token in history" "$(history_lines | grep -cE '^\+.*hf_[A-Za-z0-9]{30,}' || true)" "0"

scan_history() {
  label=$1 repo=$2
  if gitleaks git --no-banner --redact --exit-code 1 --config "$root/.gitleaks.toml" --report-format json --report-path "$scratch/gitleaks-$label.json" "$repo" >/dev/null 2>&1; then
    pass
  else
    fail "gitleaks found $(jq length "$scratch/gitleaks-$label.json" 2>/dev/null || echo '?') finding(s) in $label history"
    jq -r '.[] | "    | \(.RuleID) \(.File) \(.Commit[0:8])"' "$scratch/gitleaks-$label.json" 2>/dev/null
  fi
  trufflehog git "file://$repo" --no-update --json --results=verified,unverified,unknown > "$scratch/trufflehog-$label.json" 2>/dev/null
  found=$(jq -c 'select(.SourceMetadata != null) | {d: .DetectorName, f: .SourceMetadata.Data.Git.file, c: .SourceMetadata.Data.Git.commit[0:8]}' "$scratch/trufflehog-$label.json" 2>/dev/null)
  if [ -z "$found" ]; then pass; else fail "trufflehog found secrets in $label history"; printf '%s\n' "$found" | sed 's/^/    | /'; fi
}

branch=$(git symbolic-ref --short HEAD)
git clone -q --bare --single-branch --branch "$branch" "$root" "$scratch/head.git"
scan_history head "$scratch/head.git"

for doc in README.md docs/cutover.md docs/restore.md; do
  [ -f "$doc" ] && pass || fail "$doc is missing"
done
readme=$(cat README.md 2>/dev/null)
holds_in_readme() {
  if printf '%s\n' "$readme" | grep -Eiq "$2"; then pass; else fail "README does not say $1"; fi
}
holds_in_readme "the whole box goes out through Mullvad" 'mullvad'
holds_in_readme "the Cloudflare tunnel edge is the one exception" 'cloudflare[^.]*(edge|tunnel)[^.]*(exception|except|bypass)|(exception|except|bypass)[^.]*cloudflare'
holds_in_readme "backups stay on disk" 'on-disk|on disk|local disk'
holds_in_readme "the media drive is not backed up" 'media[^.]*(not|never|excluded|isn.t)|(not|never|excluded|except)[^.]*media'
holds_in_readme "how to cut over" '\(\./docs/cutover\.md\)'
check "README spells Keeper.sh in full" "$(printf '%s\n' "$readme" | grep -oE 'Keeper(\.sh)?' | grep -cvx 'Keeper.sh' || true)" "0"
if printf '%s\n' "$readme" | grep -Eiq 'still (runs|on) arch'; then fail "README carries a migration status line"; else pass; fi

if $published; then
  remote_heads=$(git ls-remote --heads "$remote_url" 2>/dev/null)
  if [ -z "$remote_heads" ]; then
    fail "could not list $remote_url"
  else
    head_of() { printf '%s\n' "$remote_heads" | awk -v ref="refs/heads/$1" '$2 == ref { print $1 }'; }
    check "origin nixos is this HEAD" "$(head_of nixos)" "$head_sha"
    remote_main=$(head_of main)
    check "origin main is T0's commit" "$(git rev-parse --verify -q "$remote_main^{commit}" 2>/dev/null)" "$(git rev-parse "$main_after_t0")"
    if [ -n "$remote_main" ] && git cat-file -e "$remote_main^{commit}" 2>/dev/null; then
      check "origin main carries only T0's commit beyond $baseline" "$(git rev-list "$baseline..$remote_main" | tr '\n' ' ' | sed 's/ $//')" "$(git rev-parse "$main_after_t0")"
    else
      fail "origin main $remote_main is not in the local object store"
    fi
    check "origin feat/seafile is untouched" "$(head_of feat/seafile)" "$(git rev-parse "$baseline")"
    check "origin has only main, nixos and feat/seafile" "$(printf '%s\n' "$remote_heads" | awk '{ sub("refs/heads/", "", $2); print $2 }' | sort | tr '\n' ' ' | sed 's/ $//')" "feat/seafile main nixos"
    if git clone -q --bare --single-branch --branch nixos "$remote_url" "$scratch/published.git" 2>/dev/null; then
      pass
      scan_history published "$scratch/published.git"
    else
      fail "could not clone origin nixos"
    fi
  fi
fi

if [ "$ran" = 0 ]; then
  printf 'no checks ran\n'
  exit 1
fi
printf '%s checks, %s failed\n' "$ran" "$failures"
[ "$failures" = 0 ]
