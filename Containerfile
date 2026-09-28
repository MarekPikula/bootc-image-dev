# bootc image for the Android dev VM. See PLAN.md for the design.
#
# Build with the pinned inputs:
#   podman build --build-arg-file versions.env -t localhost/android-dev-vm .
# buildah records the actual base in the image's
# org.opencontainers.image.base.{name,digest} annotations.

# No default on purpose: the pinned value lives in versions.env.
ARG BASE_IMAGE

# Build scripts are bind-mounted from this stage, so they never land in the
# image. A stage mount (unlike a bind from the build context) is relabeled for
# the build container, so it also works on SELinux-enforcing hosts.
FROM scratch AS ctx
COPY build_files/ /

FROM ${BASE_IMAGE}

# Shown by `bootc status` as the deployment version. CI sets it; otherwise the
# base image's version (e.g. Kinoite's 44.YYYYMMDD.N) would show instead.
ARG IMAGE_VERSION=local

LABEL org.opencontainers.image.title="android-dev-vm" \
      org.opencontainers.image.description="KDE desktop VM for Android development with Claude Code" \
      org.opencontainers.image.source="https://github.com/MarekPikula/bootc-image-dev" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build.sh

RUN bootc container lint
