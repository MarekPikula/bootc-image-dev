# bootc image for the Android dev VM. See PLAN.md for the design.
#
# Build with the inputs in versions.env:
#   podman build --build-arg-file versions.env -t localhost/android-dev-vm .
# buildah records the actual base in the image's
# org.opencontainers.image.base.{name,digest} annotations.

# No default on purpose: the value lives in versions.env.
ARG BASE_IMAGE

# Build scripts are bind-mounted from this stage, so they never land in the
# image. A stage mount (unlike a bind from the build context) is relabeled for
# the build container, so it also works on SELinux-enforcing hosts.
FROM scratch AS ctx
COPY build_files/ /

# packages.sh and android-studio.sh alone, so editing another build step
# doesn't redo their layers.
FROM scratch AS pkgs
COPY build_files/packages.sh /

FROM scratch AS studio
COPY build_files/android-studio.sh /

FROM ${BASE_IMAGE}

# A 1.6 GB download, so it comes first: a local rebuild reuses this layer until
# the base or the versions.env entries change. The tarball stays in a tmpfs.
ARG ANDROID_STUDIO_URL
ARG ANDROID_STUDIO_SHA256
RUN --mount=type=bind,from=studio,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var/tmp \
    /ctx/android-studio.sh

# Every package install goes here, in one layer, before system_files/: package
# scriptlets run systemd-sysusers over every sysusers.d file, and with ours
# present they'd bake admin and dev into the image's /etc/passwd
# (tests/image/checks.sh catches that). The tmpfs mounts keep dnf's cache,
# state and logs out of the image.
RUN --mount=type=bind,from=pkgs,source=/,target=/ctx \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/var/cache \
    --mount=type=tmpfs,target=/var/lib/dnf \
    --mount=type=tmpfs,target=/var/log \
    /ctx/packages.sh

# Shown by `bootc status` as the deployment version. CI sets it; otherwise the
# base image's version (e.g. Kinoite's 44.YYYYMMDD.N) would show instead.
ARG IMAGE_VERSION=local

LABEL org.opencontainers.image.title="android-dev-vm" \
      org.opencontainers.image.description="KDE desktop VM for Android development with Claude Code" \
      org.opencontainers.image.source="https://github.com/MarekPikula/bootc-image-dev" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

COPY system_files/ /

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build.sh

RUN bootc container lint
