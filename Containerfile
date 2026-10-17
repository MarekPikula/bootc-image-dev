# bootc image for the Android dev VM. See PLAN.md for the design.
#
# Build with the inputs in versions.env:
#   podman build --build-arg-file versions.env -t localhost/android-dev-vm .
#
# CI adds --timestamp 0, so unchanged layers keep their digest (PLAN.md,
# Updates). buildah records the actual base in the image's
# org.opencontainers.image.base.{name,digest} annotations.

# No default on purpose: the value lives in versions.env.
ARG BASE_IMAGE

# Build scripts are bind-mounted from this stage, so they never land in the
# image. A stage mount (unlike a bind from the build context) is relabeled for
# the build container, so it also works on SELinux-enforcing hosts.
FROM scratch AS ctx
COPY build_files/ /

# packages.sh (with Claude Code's signing key), android-studio.sh,
# studio-plugins.sh (with its list) and claude-plugins.sh (with the managed
# settings it reads) alone, so editing another build step doesn't redo their
# layers.
FROM scratch AS pkgs
COPY build_files/packages.sh build_files/claude-code.asc /

FROM scratch AS studio
COPY build_files/android-studio.sh /

FROM scratch AS studio-plugins
COPY build_files/studio-plugins.sh build_files/studio-plugins.txt /

FROM scratch AS claude-plugins
COPY build_files/claude-plugins.sh system_files/usr/lib/android-dev-vm/claude-code/managed-settings.json /

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
ARG CLAUDE_CODE_REPO
ARG CLAUDE_CODE_KEY_FINGERPRINT
RUN --mount=type=bind,from=pkgs,source=/,target=/ctx \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/var/cache \
    --mount=type=tmpfs,target=/var/lib/dnf \
    --mount=type=tmpfs,target=/var/log \
    /ctx/packages.sh

# Studio's plugins, after the packages so a bump redoes only this.
RUN --mount=type=bind,from=studio-plugins,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var/tmp \
    /ctx/studio-plugins.sh

# Claude Code's plugins, seeded with the claude from packages.sh. Before
# system_files/, whose managed settings would send it to the VM's proxy.
ARG CLAUDE_PLUGINS_COMMIT
RUN --mount=type=bind,from=claude-plugins,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var/tmp \
    /ctx/claude-plugins.sh

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

# Warnings fail the build too, so a new one gets looked at.
RUN bootc container lint --fatal-warnings
