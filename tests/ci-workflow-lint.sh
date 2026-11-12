#!/usr/bin/env bash
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

workflow=.github/workflows/nix.yml
actionlint_image=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

command -v docker > /dev/null || { echo "missing tool: docker"; exit 2; }
[ -f "$workflow" ] || { echo "FAIL: $workflow does not exist"; exit 1; }

docker run --rm -i "$actionlint_image" -color -stdin-filename "$workflow" - <"$workflow"
echo "ok: actionlint"
