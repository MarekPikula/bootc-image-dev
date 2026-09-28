# shellcheck shell=bash
# Shared by tests/image/checks.sh (sourced on the host) and tests/vm/checks.sh
# (sent to the guest ahead of it). Usage:
#   check "description" command [args...]   runs it, prints ok or FAIL
#   finish NAME                             prints the summary, exits 1 on failure
# Details a check prints are indented by six spaces (`indent` for piped output).

failed=()

check() {
  local desc=$1
  shift
  if "$@"; then
    echo "ok    $desc"
  else
    echo "FAIL  $desc"
    failed+=("$desc")
  fi
}

indent() {
  sed 's/^/      /'
}

finish() {
  if ((${#failed[@]})); then
    echo "$1: FAILED:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
  fi
  echo "$1: OK"
}
