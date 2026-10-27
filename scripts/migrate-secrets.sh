#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

usage() {
  echo "usage: migrate-secrets.sh --preflight|--encrypt|--fidelity|--check-leaks --env FILE --openseo-env FILE --restic-pass FILE" >&2
  exit 2
}

die() {
  echo "migrate-secrets: $1" >&2
  exit 2
}

mode=""
env_file=""
openseo_env=""
restic_pass=""

while [ $# -gt 0 ]; do
  case "$1" in
    --preflight | --encrypt | --fidelity | --check-leaks)
      [ -z "$mode" ] || usage
      mode=${1#--}
      shift
      ;;
    --env | --openseo-env | --restic-pass)
      [ $# -ge 2 ] || usage
      case "$1" in
        --env) env_file=$2 ;;
        --openseo-env) openseo_env=$2 ;;
        --restic-pass) restic_pass=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$mode" ] || usage
[ -n "$env_file" ] || die "--env is required"
[ -n "$openseo_env" ] || die "--openseo-env is required"
[ -n "$restic_pass" ] || die "--restic-pass is required"
[ -r "$env_file" ] || die "cannot read --env file $env_file"
[ -r "$openseo_env" ] || die "cannot read --openseo-env file $openseo_env"

required_tools() {
  case "$mode" in
    encrypt) echo python3 sudo sops ;;
    fidelity) echo python3 sudo docker ;;
    check-leaks) echo python3 sudo git ;;
    *) echo python3 sudo ;;
  esac
}

for tool in $(required_tools); do
  command -v "$tool" > /dev/null || die "missing tool: $tool"
done

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"

for file in secrets/keys.tsv homelab.env apps/openseo/openseo.env .sops.yaml; do
  [ -f "$file" ] || die "missing $file"
done

env_file=$(CDPATH='' cd -- "$(dirname -- "$env_file")" && pwd -P)/$(basename -- "$env_file")
openseo_env=$(CDPATH='' cd -- "$(dirname -- "$openseo_env")" && pwd -P)/$(basename -- "$openseo_env")

program=$(cat << 'PYTHON'
import json
import os
import re
import subprocess
import sys

mode, env_path, openseo_path = sys.argv[1:4]

production_file = "secrets/homelab.yaml"
dropped_pattern = re.compile(r"^(HF_TOKEN|OLLAMA_.*|PIHOLE_.*|SIGNOZ_VERSION|SIGNOZ_OTELCOL_VERSION)$")
assignment_pattern = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", re.DOTALL)
non_credentials = {"adguard/ADGUARD_USER", "authentik/AUTHENTIK_POSTGRESQL__USER", "grafana/GRAFANA_ADMIN_USER"}
restic_secret = "restic/RESTIC_PASSWORD"

problems = []


def report(message):
    problems.append(message)


def resolve_dollars(key, label, number, raw):
    resolved = []
    index = 0
    while index < len(raw):
        character = raw[index]
        if character != "$":
            resolved.append(character)
            index += 1
            continue
        if raw[index + 1 : index + 2] == "$":
            resolved.append("$")
            index += 2
            continue
        report(f"{label}:{number}: {key} has an unescaped $ that compose would interpolate")
        return None
    return "".join(resolved)


def unescape_double_quoted(raw):
    escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "$": "$$"}
    resolved = []
    index = 0
    while index < len(raw):
        character = raw[index]
        if character == "\\" and index + 1 < len(raw) and raw[index + 1] in escapes:
            resolved.append(escapes[raw[index + 1]])
            index += 2
            continue
        resolved.append(character)
        index += 1
    return "".join(resolved)


def closing_quote(text, quote):
    index = 1
    while index < len(text):
        if quote == '"' and text[index] == "\\":
            index += 2
            continue
        if text[index] == quote:
            return index
        index += 1
    return -1


def trailing_is_comment(rest):
    stripped = rest.strip()
    return stripped == "" or stripped.startswith("#")


def parse_env(path, label):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    entries = {}
    index = 0
    while index < len(lines):
        number = index + 1
        line = lines[index].strip()
        index += 1
        if line == "" or line.startswith("#"):
            continue
        match = assignment_pattern.match(line)
        if not match:
            report(f"{label}:{number}: not a KEY=VALUE line")
            continue
        key, rest = match.group(1), match.group(2)
        if rest[:1] in ("'", '"'):
            quote = rest[0]
            end = closing_quote(rest, quote)
            while end < 0 and index < len(lines):
                rest += "\n" + lines[index]
                index += 1
                end = closing_quote(rest, quote)
            if end < 0:
                report(f"{label}:{number}: {key} has an unterminated quote")
                continue
            if not trailing_is_comment(rest[end + 1 :]):
                report(f"{label}:{number}: {key} has text after its closing quote")
                continue
            inner = rest[1:end]
            value = inner if quote == "'" else resolve_dollars(key, label, number, unescape_double_quoted(inner))
        else:
            value = resolve_dollars(key, label, number, re.split(r"\s#", rest, maxsplit=1)[0].rstrip())
        if value is None:
            continue
        if key in entries:
            report(f"{label}:{number}: {key} is set more than once")
            continue
        entries[key] = value
    return entries


def read_table():
    rows = []
    with open("secrets/keys.tsv", encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            if line:
                template, env_key, secret, empty = line.split("\t")
                rows.append({"secret": secret, "empty": empty})
    policy = {}
    for row in rows:
        allowed = row["empty"] == "allow"
        policy[row["secret"]] = policy.get(row["secret"], True) and allowed
    return policy


def read_restic_password():
    chunks = []
    with os.fdopen(3, "rb") as handle:
        while True:
            chunk = handle.read(4096)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode("utf-8").rstrip("\n")


def merge_sources(sources):
    merged = {}
    for label, entries in sources:
        for key, value in entries.items():
            if key in merged and merged[key] != value:
                report(f"{key} has different values in the two env files")
                continue
            merged[key] = value
    return merged


def collect():
    policy = read_table()
    source_of = {}
    for secret in policy:
        if secret == restic_secret:
            continue
        consumer, source_key = secret.split("/", 1)
        if source_key in source_of:
            report(f"secrets/keys.tsv maps {source_key} to two consumers")
        source_of[source_key] = secret
    plain = set(parse_env("homelab.env", "homelab.env")) | set(parse_env("apps/openseo/openseo.env", "apps/openseo/openseo.env"))
    sources = [("--env", parse_env(env_path, "--env")), ("--openseo-env", parse_env(openseo_path, "--openseo-env"))]
    merged = merge_sources(sources)
    categories = {}
    for key in sorted(merged):
        if key in source_of:
            categories[key] = "secret " + source_of[key]
        elif dropped_pattern.match(key):
            categories[key] = "dropped"
        elif key in plain:
            categories[key] = "plain"
        else:
            categories[key] = "unknown"
            report(f"{key} is not in secrets/keys.tsv, homelab.env, apps/openseo/openseo.env or the dropped list")
    values = {}
    for source_key, secret in sorted(source_of.items()):
        if source_key not in merged:
            report(f"{source_key} ({secret}) is missing from the env files")
            continue
        values[secret] = merged[source_key]
    values[restic_secret] = read_restic_password()
    for secret, value in sorted(values.items()):
        name = "restic password" if secret == restic_secret else secret
        if value == "" and not policy.get(secret, False):
            report(f"{name} is empty and secrets/keys.tsv does not allow that")
        if "'" in value or "\n" in value:
            report(f"{name} holds a single quote or newline, which 0004's rendering forbids")
    return sources, merged, categories, values


def nested(values):
    document = {}
    for secret, value in sorted(values.items()):
        consumer, key = secret.split("/", 1)
        document.setdefault(consumer, {})[key] = value
    return document


def fail_on_problems():
    if problems:
        for message in problems:
            print(f"migrate-secrets: {message}", file=sys.stderr)
        print(f"migrate-secrets: {len(problems)} problem(s), nothing encrypted", file=sys.stderr)
        sys.exit(1)


def preflight(merged, categories, values):
    for key in sorted(categories):
        flags = []
        if merged[key] == "":
            flags.append("empty")
        if "$" in merged[key]:
            flags.append("dollar")
        suffix = f" [{' '.join(flags)}]" if flags else ""
        print(f"{categories[key]:<52} {key}{suffix}")
    fail_on_problems()
    print(f"ok: {len(values)} secrets ready for {production_file}")


def encrypt(values):
    fail_on_problems()
    payload = json.dumps(nested(values), sort_keys=True).encode("utf-8")
    command = ["sops", "encrypt", "--filename-override", production_file, "--input-type", "json", "--output-type", "yaml", "/dev/stdin"]
    sys.exit(subprocess.run(command, input=payload).returncode)


def compose_environment(path):
    clean_env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]}
    command = ["docker", "compose", "--project-directory", os.getcwd(), "-p", "migrate-secrets-fidelity", "--env-file", path, "-f", "-", "config", "--environment"]
    result = subprocess.run(command, input=b"services: {}\n", capture_output=True, env=clean_env)
    if result.returncode != 0:
        print(f"migrate-secrets: docker compose config --environment failed for {path}", file=sys.stderr)
        sys.exit(1)
    resolved = {}
    for line in result.stdout.decode("utf-8").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            resolved[key] = value
    return resolved


def fidelity(sources):
    fail_on_problems()
    failed = 0
    for path, (label, entries) in zip((env_path, openseo_path), sources):
        resolved = compose_environment(path)
        for key in sorted(entries):
            same = resolved.get(key) == entries[key]
            failed += 0 if same else 1
            print(f"{'pass' if same else 'FAIL'} {label} {key}")
    print("PASS" if failed == 0 else f"FAIL: {failed} key(s) differ from compose")
    sys.exit(0 if failed == 0 else 1)


def check_leaks(values):
    fail_on_problems()
    patterns = [value for secret, value in values.items() if value and secret not in non_credentials]
    tracked = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode("utf-8").split("\0")
    tree_hits = 0
    for path in tracked:
        if not path or path == production_file or not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            content = handle.read().decode("utf-8", errors="replace")
        tree_hits += 1 if any(pattern in content for pattern in patterns) else 0
    history = subprocess.run(["git", "log", "-p", "--all", "--", ".", f":!{production_file}"], capture_output=True, check=True).stdout.decode("utf-8", errors="replace")
    history_hits = sum(1 for line in history.splitlines() if any(pattern in line for pattern in patterns))
    print(f"skipped by name: {' '.join(sorted(non_credentials))}")
    clean = tree_hits == 0 and history_hits == 0
    print(f"{'PASS' if clean else 'FAIL'}: {tree_hits} tracked file(s), {history_hits} history line(s) hold a secret value")
    sys.exit(0 if clean else 1)


sources, merged, categories, values = collect()
if mode == "preflight":
    preflight(merged, categories, values)
elif mode == "encrypt":
    encrypt(values)
elif mode == "fidelity":
    fidelity(sources)
else:
    check_leaks(values)
PYTHON
)

python3 -I -c "$program" "$mode" "$env_file" "$openseo_env" 3< <(sudo -n cat -- "$restic_pass")
