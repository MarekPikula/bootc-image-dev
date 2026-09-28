#!/usr/bin/bash
# Runs the numbered build steps next to this script (NN-name.sh) in order.
# Each step is a separate script so a failure names the step that broke.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"

for step in "$here"/[0-9][0-9]-*.sh; do
  echo "==> $(basename "$step")"
  "$step"
done
