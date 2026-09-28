#!/usr/bin/bash
# Assertions against a built image, without booting it. Runs every check, then
# exits non-zero if any failed.
#
# Usage: tests/image/checks.sh IMAGE
# In CI the image is in rootful storage, so run it with sudo there.
set -euo pipefail

image=${1:?usage: $0 IMAGE}
cd "$(dirname "$(readlink -f "$0")")/../.."

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

# expect_meta Labels|Annotations KEY VALUE
expect_meta() {
  local actual
  actual="$(podman image inspect --format "{{ index .$1 \"$2\" }}" "$image")"
  [[ $actual == "$3" ]] || { echo "      $2 is '$actual', expected '$3'"; return 1; }
}

# One offline container serves every in-image check.
ctr="$(podman run -d --rm --network=none "$image" sleep infinity)"
trap 'podman rm -f -t 0 "$ctr" >/dev/null || true' EXIT

# Runs the bash script on stdin inside the image.
in_image() {
  podman exec -i "$ctr" /usr/bin/bash -euo pipefail -s
}

# versions.env pins repo:tag@digest; buildah records what FROM actually used
# as repo@digest.
pinned_base="$(sed -n 's/^BASE_IMAGE=//p' versions.env)"
pinned_repo="${pinned_base%%@*}"
pinned_base_ref="${pinned_repo%:*}@${pinned_base#*@}"

check "is a bootc image" expect_meta Labels containers.bootc 1
check "built from the base pinned in versions.env" \
  expect_meta Annotations org.opencontainers.image.base.name "$pinned_base_ref"

# No credentials in the image (CLAUDE.md). A password field may only hold a
# marker with no hash in it: '!'/'*' characters or '!locked' ('!$6$...' is a
# locked but real hash, which `usermod -U` would restore). The passwd files must
# defer to shadow ('x') or carry such a marker. Kinoite keeps system users in
# /usr/lib/passwd (nss-altfiles), where pam_unix also accepts a hash. An empty
# field means login without a password, except in gshadow (no group password).
check "no passwords in passwd, shadow or gshadow files" in_image <<'EOF'
awk -F: '
  { ok = $2 ~ /^([!*]+|!locked)$/ }
  FILENAME ~ /passwd$/ && $2 == "x" { ok = 1 }
  FILENAME ~ /gshadow$/ && $2 == ""  { ok = 1 }
  !ok { print "      " FILENAME ": " $1; bad = 1 }
  END { exit bad }' /etc/passwd /usr/lib/passwd /etc/shadow /etc/gshadow
EOF
# Fails closed: a find error aborts the snippet (set -e) instead of being
# masked by a pipeline.
check "no authorized_keys files" in_image <<'EOF'
found="$(find / -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print)"
[[ -z $found ]] || { sed 's/^/      /' <<<"$found"; exit 1; }
EOF
check "no SSH host keys" in_image <<'EOF'
! compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null
EOF

if ((${#failed[@]})); then
  echo "image checks: FAILED:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "image checks: OK"
