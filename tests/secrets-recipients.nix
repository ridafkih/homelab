{ pkgs, self, lib }:
pkgs.runCommand "secrets-recipients"
  {
    nativeBuildInputs = [ pkgs.age pkgs.yq-go pkgs.jq pkgs.gnugrep pkgs.coreutils ];
    secrets = self + "/secrets";
    sopsConfig = self + "/.sops.yaml";
  }
  ''
    set -euo pipefail

    hash=$(printf '\043')
    key="$secrets/test-age.key"
    test -s "$key" || { echo "missing secrets/test-age.key"; exit 1; }

    key_lines=$(grep -cE '^AGE-SECRET-KEY-1[0-9A-Z]+$' "$key" || true)
    [ "$key_lines" = 1 ] || { echo "test-age.key must hold exactly one age identity, found $key_lines"; exit 1; }
    if grep -vqE "^($hash created: .+|$hash public key: age1[0-9a-z]+|AGE-SECRET-KEY-1[0-9A-Z]+)\$" "$key"; then
      echo "test-age.key has lines other than age-keygen output"
      exit 1
    fi

    test_recipient=$(age-keygen -y "$key")
    grep -qxF "$(printf '%s public key: %s' "$hash" "$test_recipient")" "$key" || { echo "test-age.key public key comment does not match"; exit 1; }

    shopt -s nullglob
    for file in "$secrets"/*.yaml; do
      name=$(basename "$file")
      [ "$name" = vm.yaml ] && continue
      if grep -qF "$test_recipient" "$file"; then
        echo "$name is encrypted to the public test key"
        exit 1
      fi
    done

    vm_recipients=$(yq -o=json '.sops.age' "$secrets/vm.yaml" | jq -r '[.[].recipient] | sort | join(",")')
    [ "$vm_recipients" = "$test_recipient" ] || { echo "secrets/vm.yaml must be encrypted to the test key only"; exit 1; }

    yq -o=json 'explode(.)' "$sopsConfig" > rules.json

    jq -e '.creation_rules | length > 0' rules.json > /dev/null || { echo ".sops.yaml has no creation rules"; exit 1; }
    jq -e '.creation_rules | all(has("path_regex") and (.path_regex | length > 0))' rules.json > /dev/null \
      || { echo "every .sops.yaml rule must have a path_regex"; exit 1; }

    recipients_of() {
      jq -r --arg regex "$1" '
        [.creation_rules[] | select(.path_regex == $regex)] as $rules
        | if ($rules | length) != 1 then error("expected one rule for " + $regex) else $rules[0] end
        | [ (.age // empty | if type == "array" then .[] else split(",")[] end),
            (.key_groups // [] | .[] | .age // [] | .[] | if type == "object" then .recipient else . end) ]
        | map(gsub("\\s"; "")) | map(select(length > 0)) | sort | join(",")
      ' rules.json
    }

    vm_rule=$(recipients_of '^secrets/vm\.yaml$')
    [ "$vm_rule" = "$test_recipient" ] || { echo "the vm.yaml rule must name only the test recipient"; exit 1; }

    jq -e '.creation_rules[0].path_regex == "^secrets/vm\\.yaml$"' rules.json > /dev/null \
      || { echo "the vm.yaml rule must come first"; exit 1; }

    production_rule=$(recipients_of '^secrets/homelab\.yaml$')
    production_count=$(echo "$production_rule" | tr ',' '\n' | grep -c '^age1' || true)
    [ "$production_count" = 2 ] || { echo "the homelab.yaml rule must name exactly the host and admin recipients, found $production_count"; exit 1; }
    if echo "$production_rule" | grep -qF "$test_recipient"; then
      echo "the homelab.yaml rule names the test recipient"
      exit 1
    fi

    occurrences=$(grep -oF "$test_recipient" "$sopsConfig" | wc -l)
    [ "$occurrences" -le 1 ] || { echo "the test recipient appears more than once in .sops.yaml"; exit 1; }

    for regex in $(jq -r '.creation_rules[].path_regex' rules.json); do
      [ "$regex" = '^secrets/vm\.yaml$' ] && continue
      if echo "secrets/vm.yaml" | grep -qE "$regex"; then
        echo "rule $regex also matches secrets/vm.yaml"
        exit 1
      fi
      if echo "$(recipients_of "$regex")" | grep -qF "$test_recipient"; then
        echo "rule $regex names the test recipient"
        exit 1
      fi
    done

    if grep -qE 'AGE-SECRET-KEY|BEGIN (OPENSSH|PGP|RSA|EC) PRIVATE' "$sopsConfig"; then
      echo ".sops.yaml holds private key material"
      exit 1
    fi

    touch "$out"
  ''
