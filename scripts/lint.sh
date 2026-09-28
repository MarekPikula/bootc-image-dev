#!/usr/bin/bash
# Static checks for the image sources. Runs in the devcontainer and in CI.
# Runs every linter, then exits non-zero if any of them failed.
#
# .devcontainer/ is skipped: it's maintained from the host, not part of the
# image.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

failed=()
run() {
  echo "==> $1"
  "$@" || failed+=("$1")
}

# Tracked files plus new files that aren't committed yet (changes stay
# uncommitted until they're reviewed), minus ignored ones. Assigned first so a
# git failure stops the script instead of yielding an empty list.
file_list="$(git ls-files --cached --others --exclude-standard --deduplicate \
  -- ':!:.devcontainer/')"
mapfile -t files <<<"$file_list"

# Shell scripts: *.sh, plus anything with a sh/bash shebang (e.g. helpers in
# system_files/usr/bin that have no extension).
shell_scripts=()
for f in "${files[@]}"; do
  [[ -f $f ]] || continue
  if [[ $f == *.sh ]] || head -n1 "$f" | grep -qE '^#!.*[/ ](ba)?sh\b'; then
    shell_scripts+=("$f")
  fi
done

run hadolint Containerfile
run shellcheck --external-sources "${shell_scripts[@]}"
run actionlint

if ((${#failed[@]})); then
  echo "lint: FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "lint: OK"
