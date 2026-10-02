#!/usr/bin/bash
# Builds a zstd-compressed qcow2 from an image in rootful podman storage, using
# the image's own bootc. Needs root, privileged containers and loop devices, so
# it runs in CI, not in the devcontainer.
#
# Usage: sudo disk/build-qcow2.sh IMAGE OUTPUT.qcow2
# The installed system tracks IMAGE for updates, so pass the registry name the
# VM should update from (tagged locally, it needn't be published yet).
set -euo pipefail

image=${1:?usage: $0 IMAGE OUTPUT.qcow2}
output=${2:?usage: $0 IMAGE OUTPUT.qcow2}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Room for the Android SDK, emulator images and Gradle caches. Both the raw file
# and the qcow2 are sparse, so unused space costs nothing.
truncate -s 64G "$work/disk.raw"

# As bootc-installation(7) documents for --via-loopback: privileged, the host's
# /dev for the loop device, its PID and IPC namespaces and container storage so
# bootc can find the image it runs from.
# --generic-image: every bootloader (BIOS and UEFI), no firmware boot entries.
# The root filesystem (btrfs) comes from the image's
# /usr/lib/bootc/install/50-android-dev-vm.toml.
podman run --rm --privileged --pid=host --ipc=host \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v "$work:/output" \
  "$image" \
  bootc install to-disk --via-loopback --generic-image \
  --target-imgref "$image" /output/disk.raw

# -W: out-of-order writes let the compression use every core.
qemu-img convert -c -W -O qcow2 -o compression_type=zstd \
  "$work/disk.raw" "$output"
qemu-img info "$output"
