#!/usr/bin/bash
# Builds a qcow2 from an image in rootful podman storage with
# bootc-image-builder, then compresses it (zstd) for download. Needs root and
# privileged containers, so it runs in CI, not in the devcontainer.
#
# Usage: sudo disk/build-qcow2.sh IMAGE OUTPUT.qcow2
# The installed system tracks IMAGE for updates (there's no separate target
# ref), so pass the registry name the VM should update from.
set -euo pipefail

# Archived upstream (merged into osbuild/image-builder), but still the
# documented builder for bootc disk images. Pinned by digest.
bib=quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b

image=${1:?usage: $0 IMAGE OUTPUT.qcow2}
output=${2:?usage: $0 IMAGE OUTPUT.qcow2}
here="$(dirname "$(readlink -f "$0")")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Kinoite sets no default root filesystem, so name one: btrfs, as Fedora's
# atomic desktops use.
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$here/config.toml:/config.toml:ro" \
  -v "$work:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$bib" --type qcow2 --rootfs btrfs --progress verbose "$image"

# -W: out-of-order writes let the compression use every core.
qemu-img convert -c -W -O qcow2 -o compression_type=zstd \
  "$work/qcow2/disk.qcow2" "$output"
qemu-img info "$output"
