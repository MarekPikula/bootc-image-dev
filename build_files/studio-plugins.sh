#!/usr/bin/bash
# Installs the plugins pinned in studio-plugins.txt (next to this script) into
# /usr/lib/android-studio/plugins/<plugin ID>, where Studio loads them like the
# plugins it ships with. Its own RUN, see the Containerfile.
set -euo pipefail

list=/ctx/studio-plugins.txt
zip=/var/tmp/plugin.zip
unpacked=/var/tmp/plugin

while read -r id sha256 url; do
  # --retry-all-errors: also retry a transfer that breaks midway.
  curl -fsSL --retry 3 --retry-all-errors -o "$zip" "$url"
  echo "$sha256  $zip" | sha256sum -c -
  unzip -q "$zip" -d "$unpacked"
  # One top directory, holding the plugin with the ID the list names.
  top=("$unpacked"/*)
  ((${#top[@]} == 1)) || { echo "$url: ${#top[@]} top-level entries" >&2; exit 1; }
  for jar in "${top[0]}"/lib/*.jar; do
    if [[ "$(unzip -p "$jar" META-INF/plugin.xml 2>/dev/null)" == *"<id>$id</id>"* ]]; then
      mv "${top[0]}" "/usr/lib/android-studio/plugins/$id"
      continue 2
    fi
  done
  echo "$url: no plugin with ID $id" >&2
  exit 1
done < <(grep -vE '^\s*(#|$)' "$list")

# The image and VM checks read which plugins are ours from here.
install -D -m 0644 "$list" /usr/lib/android-dev-vm/studio-plugins.txt
