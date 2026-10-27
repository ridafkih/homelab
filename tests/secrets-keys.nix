{ pkgs, self, lib }:
pkgs.runCommand "secrets-keys"
  {
    nativeBuildInputs = [ pkgs.yq-go pkgs.jq pkgs.gnugrep pkgs.coreutils ];
    secrets = self + "/secrets";
  }
  ''
    set -euo pipefail

    table="$secrets/keys.tsv"
    test -s "$table" || { echo "missing secrets/keys.tsv"; exit 1; }

    if grep -qE 'HF_TOKEN|OLLAMA|PIHOLE' "$table"; then
      echo "secrets/keys.tsv names a forbidden key"
      exit 1
    fi

    bad_rows=$(grep -cvP '^(-\t-|[a-z][a-z-]*\.env\t[A-Z][A-Z0-9_]*)\t[a-z][a-z-]*/[A-Z][A-Z0-9_]*\t(deny|allow)$' "$table" || true)
    if [ "$bad_rows" != 0 ]; then
      echo "secrets/keys.tsv has $bad_rows malformed rows"
      exit 1
    fi

    cut -f3 "$table" | LC_ALL=C sort -u > expected

    leaf_paths() {
      yq -o=json '.' "$1" | jq -r 'del(.sops) | paths(scalars) | map(tostring) | join("/")' | LC_ALL=C sort
    }

    key_tree_matches() {
      leaf_paths "$1" > actual
      diff -u expected actual
    }

    shopt -s nullglob
    files=("$secrets"/*.yaml)
    test -e "$secrets/vm.yaml" || { echo "missing secrets/vm.yaml"; exit 1; }

    for file in "''${files[@]}"; do
      name=$(basename "$file")
      grep -q '^sops:' "$file" || { echo "$name is not a sops file"; exit 1; }
      if grep -qE 'HF_TOKEN|OLLAMA|PIHOLE' "$file"; then
        echo "$name names a forbidden key"
        exit 1
      fi
      if ! key_tree_matches "$file"; then
        echo "$name key tree differs from secrets/keys.tsv"
        exit 1
      fi
      unencrypted=$(yq -o=json '.' "$file" | jq -r 'del(.sops) | [paths(scalars) as $p | getpath($p) | select(type != "string" or (startswith("ENC[") | not))] | length')
      if [ "$unencrypted" != 0 ]; then
        echo "$name has $unencrypted unencrypted values"
        exit 1
      fi
    done

    first_secret=$(head -n1 expected)
    consumer=$(echo "$first_secret" | cut -d/ -f1)
    key=$(echo "$first_secret" | cut -d/ -f2)
    yq "del(.\"$consumer\".\"$key\")" "$secrets/vm.yaml" > missing.yaml
    if key_tree_matches missing.yaml > /dev/null; then
      echo "self-check: a missing key was not detected"
      exit 1
    fi
    yq '.extra.EXTRA_KEY = "ENC[x]"' "$secrets/vm.yaml" > extra.yaml
    if key_tree_matches extra.yaml > /dev/null; then
      echo "self-check: an extra key was not detected"
      exit 1
    fi

    touch "$out"
  ''
