#!/usr/bin/bash
# Installs Android Studio into /usr/lib/android-studio from the tarball pinned
# in versions.env. Its own RUN, see the Containerfile.
set -euo pipefail

tarball=/var/tmp/android-studio.tar.gz
# --retry-all-errors: also retry a transfer that breaks midway.
curl -fsSL --retry 3 --retry-all-errors -o "$tarball" "${ANDROID_STUDIO_URL:?}"
echo "${ANDROID_STUDIO_SHA256:?}  $tarball" | sha256sum -c -
mkdir /usr/lib/android-studio
tar -xzf "$tarball" -C /usr/lib/android-studio --strip-components=1 --no-same-owner

# Updates come with the image, and /usr is read-only anyway.
echo 'ide.no.platform.update=true' >>/usr/lib/android-studio/bin/idea.properties
