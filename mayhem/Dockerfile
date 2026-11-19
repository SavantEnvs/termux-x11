# syntax=docker/dockerfile:1.7
#
# Commit image for termux-x11 (Android X server). The Android build (Gradle + NDK) cannot run on a
# Linux host, so mayhem/build.sh builds the X server termux-x11 pins (submodule
# lorie/src/main/cpp/xserver @ 7dbd8d0d) with meson, with termux-x11's lorie/clipboard.c linked in.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Build deps of the X server (Xvfb DDX) + xkbcomp/xkb data it runs at start-up.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      meson ninja-build pkg-config xfonts-utils \
      libpixman-1-dev libxfont-dev libxkbfile-dev x11proto-dev libxau-dev libxdmcp-dev \
      libxshmfence-dev libxcvt-dev xtrans-dev libssl-dev libbsd-dev libdrm-dev libepoxy-dev \
      libtirpc-dev x11-xkb-utils xkb-data \
 && rm -rf /var/lib/apt/lists/*

# The xserver submodule at the commit termux-x11 pins (a git submodule is not in the checkout's
# tree), fetched by commit + sha256. build.sh builds it out of tree with the fuzz flags (it is the
# code under test, SPEC §6.2 item 19); this copy stays read-only.
ARG XSERVER_SHA=7dbd8d0dd1929c2011009fd1770c8aa470df97fb
ARG XSERVER_SHA256=ec2055b97923d281a4598c0cb055c50b25cfd11144f75177bc814803de815368
RUN d=/opt/toolchains/deps/xserver-7dbd8d0d && mkdir -p "$d/src" \
 && curl -fsSL -o /tmp/xserver.tgz \
      "https://gitlab.freedesktop.org/xorg/xserver/-/archive/${XSERVER_SHA}/xserver-${XSERVER_SHA}.tar.gz" \
 && echo "${XSERVER_SHA256}  /tmp/xserver.tgz" | sha256sum -c - \
 && tar -xzf /tmp/xserver.tgz --strip-components=1 -C "$d/src" \
 && rm -f /tmp/xserver.tgz && chmod -R a+rX,a-w "$d"

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
