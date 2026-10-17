#!/usr/bin/bash
# Seeds Claude Code's plugins into /usr/lib/claude-code-plugins, which
# CLAUDE_CODE_PLUGIN_SEED_DIR (in the managed settings) points at. The
# marketplace and the plugins come from the managed settings (next to this
# script), the marketplace's commit from versions.env. Its own RUN, see the
# Containerfile.
set -euo pipefail

settings=/ctx/managed-settings.json
seed=/usr/lib/claude-code-plugins
commit=${CLAUDE_PLUGINS_COMMIT:?}

marketplace="$(jq -r '.extraKnownMarketplaces | keys[]' "$settings")"
[[ $marketplace != *$'\n'* ]] || { echo "managed-settings.json: one marketplace expected" >&2; exit 1; }
url="$(jq -r --arg m "$marketplace" '.extraKnownMarketplaces[$m].source.url' "$settings")"

export HOME=/var/tmp/home CLAUDE_CODE_PLUGIN_CACHE_DIR=$seed
mkdir -p "$HOME"
claude plugin marketplace add "$url"
# The pinned commit, wherever the default branch has moved since.
repo="$seed/marketplaces/$marketplace"
git -C "$repo" fetch --quiet --depth 1 origin "$commit"
git -C "$repo" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
# The plugins set to true. A false entry is how managed settings block one.
enabled="$(jq -r '[.enabledPlugins | to_entries[] | select(.value == true) | .key] | sort | join(" ")' "$settings")"
for plugin in $enabled; do
  claude plugin install "$plugin"
done
[[ "$(git -C "$repo" rev-parse HEAD)" == "$commit" ]] ||
  { echo "the marketplace moved off $commit while installing" >&2; exit 1; }
[[ "$(jq -r '.plugins | keys | join(" ")' "$seed/installed_plugins.json")" == \
  "$enabled" ]] ||
  { echo "installed plugins differ from enabledPlugins" >&2; exit 1; }

# Each plugin must come from the pinned commit: the marketplace's for one
# inside it, the commit the marketplace pins for one kept elsewhere.
# `claude plugin install` names a plugin's directory after the version in its
# manifest if it has one (Superpowers does), but at runtime Claude Code looks
# for the commit's first 12 characters, and on a miss downloads a copy into the
# user's home (seen in a VM). So the directory takes that name, and the
# version's name stays as a link.
while read -r plugin sha path; do
  expected="$(jq -r --arg n "${plugin%@*}" --arg c "$commit" \
    '.plugins[] | select(.name == $n) | .source | (objects | .sha) // $c' "$repo/.claude-plugin/marketplace.json")"
  [[ $sha == "$expected" ]] || { echo "$plugin: installed from $sha, expected $expected" >&2; exit 1; }
  name=${sha:0:12}
  if [[ ${path##*/} != "$name" ]]; then
    mv "$path" "${path%/*}/$name"
    ln -s "$name" "$path"
  fi
done < <(jq -r '.plugins | to_entries[] | "\(.key) \(.value[0].gitCommitSha) \(.value[0].installPath)"' "$seed/installed_plugins.json")

# The same files on every build of the same commit, so an unchanged seed keeps
# its layer (CI builds with --timestamp 0): the commit's date for every time
# Claude Code records, and git holding the pinned commit alone (no branches,
# which follow upstream), repacked in one thread, with no logs or index (its
# stat data is the checkout's). Claude Code never updates a seed, so it needs
# no more.
date="$(git -C "$repo" log -1 --format=%cI)"
jq --arg d "$date" '.plugins[][0] |= (.gitCommitSha[:12] as $v | .version = $v
  | .installPath |= sub("[^/]+$"; $v) | .installedAt = $d | .lastUpdated = $d)' \
  "$seed/installed_plugins.json" >"$HOME/installed.json"
jq --arg d "$date" 'map_values(.lastUpdated = $d)' "$seed/known_marketplaces.json" >"$HOME/known.json"
cp "$HOME/installed.json" "$seed/installed_plugins.json"
cp "$HOME/known.json" "$seed/known_marketplaces.json"
# --no-deref, or origin/HEAD's deletion would take origin/main and leave it.
git -C "$repo" for-each-ref --format='delete %(refname)' | git -C "$repo" update-ref --no-deref --stdin
{ git -C "$repo" config --name-only --get-regexp '^branch\.' || true; } | sed 's/\.[^.]*$//' | sort -u |
  xargs -r -n 1 git -C "$repo" config --remove-section
echo "$commit" >"$repo/.git/shallow"
rm -rf "$seed/.last_inuse_sweep" "$repo/.git/logs" "$repo/.git/index" \
  "$repo/.git/FETCH_HEAD" "$repo/.git/ORIG_HEAD"
git -C "$repo" -c pack.threads=1 repack -a -d -q
git -C "$repo" prune --expire=now
