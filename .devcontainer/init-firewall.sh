#!/usr/bin/env bash
# Default-deny egress firewall for the bootc-dev devcontainer.
#
# - Uses native nftables sets (no ipset: rootless containers can't load the
#   ip_set kernel modules, but nf_tables is already loaded on Fedora).
# - Allows: loopback, DNS to the configured resolvers, and TCP 80/443 to the
#   IPs of allowlisted domains plus GitHub's published ranges.
# - Idempotent and atomic: re-run any time with
#     sudo /usr/local/bin/init-firewall.sh
#   e.g. when a CDN rotates IPs and downloads start timing out.
set -euo pipefail
IFS=$'\n\t'

[[ $EUID -eq 0 ]] || { echo "init-firewall: must run as root" >&2; exit 1; }

# Replace with a nearby Fedora mirror, and point dnf at it in your bootc
# Containerfile builds; the default mirror list can redirect anywhere.
FEDORA_MIRROR="${FEDORA_MIRROR:-dl.fedoraproject.org}"

ALLOWED_DOMAINS=(
  # Claude Code: API, login, feature flags
  api.anthropic.com
  claude.ai
  console.anthropic.com
  platform.claude.com
  statsig.anthropic.com

  # VS Code server and extensions
  update.code.visualstudio.com
  marketplace.visualstudio.com
  vscode.blob.core.windows.net

  # Container registries and their blob CDNs
  quay.io
  cdn01.quay.io
  cdn02.quay.io
  cdn03.quay.io
  registry.fedoraproject.org
  ghcr.io
  pkg-containers.githubusercontent.com

  # GitHub content (release downloads, raw files)
  objects.githubusercontent.com
  release-assets.githubusercontent.com
  raw.githubusercontent.com

  # pre-commit hook environments (pre-commit-hooks' PyPI dependency)
  pypi.org
  files.pythonhosted.org

  # Fedora packages for nested image builds
  mirrors.fedoraproject.org
  "$FEDORA_MIRROR"

  # Android Studio / SDK downloads during image builds
  dl.google.com
)

log() { echo "[init-firewall] $*"; }
ipv4_only() { grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || true; }

# --- Collect addresses (works on first run and on re-runs, since DNS and
# --- api.github.com stay reachable under the existing rules) ---------------

mapfile -t DNS_SERVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf | ipv4_only)
if [[ ${#DNS_SERVERS[@]} -eq 0 ]]; then
  echo "init-firewall: no IPv4 nameserver in /etc/resolv.conf" >&2
  exit 1
fi

declare -A SEEN=()
ALLOWED=()
add() { local x; for x in "$@"; do [[ -n ${SEEN[$x]:-} ]] || { SEEN[$x]=1; ALLOWED+=("$x"); }; done; }

log "Fetching GitHub IP ranges"
mapfile -t GH < <(
  curl -fsS --max-time 15 https://api.github.com/meta \
    | jq -r '((.web // []) + (.api // []) + (.git // []) + (.packages // []))[]' \
    | ipv4_only
)
if [[ ${#GH[@]} -eq 0 ]]; then
  echo "init-firewall: could not fetch GitHub ranges" >&2
  exit 1
fi
add "${GH[@]}"

for domain in "${ALLOWED_DOMAINS[@]}"; do
  mapfile -t ips < <(dig +short +time=3 +tries=2 A "$domain" | ipv4_only)
  if [[ ${#ips[@]} -eq 0 ]]; then
    log "WARNING: $domain did not resolve, skipping"
    continue
  fi
  add "${ips[@]}"
done
log "Allowlisting ${#ALLOWED[@]} addresses/ranges"

# --- Build and apply the ruleset atomically ---------------------------------

join() { local IFS=','; echo "$*"; }
RULES="$(mktemp)"
trap 'rm -f "$RULES"' EXIT

cat > "$RULES" <<EOF
table inet devfw
delete table inet devfw
table inet devfw {
  set dns4 {
    type ipv4_addr
    elements = { $(join "${DNS_SERVERS[@]}") }
  }
  set allowed4 {
    type ipv4_addr
    flags interval
    auto-merge
  }
  chain output {
    type filter hook output priority filter; policy drop;
    oifname "lo" accept
    ct state established,related accept
    ip daddr @dns4 udp dport 53 accept
    ip daddr @dns4 tcp dport 53 accept
    ip daddr @allowed4 tcp dport { 80, 443 } accept
    counter reject with icmpx type admin-prohibited
  }
}
EOF

# Add elements in chunks to keep individual lines manageable.
for ((i = 0; i < ${#ALLOWED[@]}; i += 200)); do
  echo "add element inet devfw allowed4 { $(join "${ALLOWED[@]:i:200}") }" >> "$RULES"
done

nft -f "$RULES"
log "Ruleset applied"

# --- Verify -----------------------------------------------------------------

if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "init-firewall: FAIL, example.com is reachable" >&2
  exit 1
fi
if ! curl -fsS --max-time 10 https://api.github.com/zen >/dev/null; then
  echo "init-firewall: FAIL, api.github.com is not reachable" >&2
  exit 1
fi
log "Verified: example.com blocked, api.github.com allowed"
