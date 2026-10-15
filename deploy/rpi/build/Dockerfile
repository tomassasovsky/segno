# Reproducible aarch64 build image for the Segno appliance bundle: what
# ivi-homescreen runs from /opt/segno. Build and run it on an arm64 host
# (Apple Silicon, ubuntu-24.04-arm):
#   docker build --platform linux/arm64 \
#     --build-arg FLUTTER_VERSION=<FLUTTER_ENGINE_VERSION> -t segno-bundle-build deploy/rpi/build
#   docker run --rm --platform linux/arm64 -v "$PWD":/workspace segno-bundle-build
# The entrypoint is segno-build.sh; the bundle lands in build/appliance/bundle.
#
# FLUTTER_VERSION has to be the release whose engine the image ships: the AOT
# snapshot loads only on its own engine revision. The single source is
# FLUTTER_ENGINE_VERSION in
# deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc,
# which build-arm64-bundle.sh and appliance-release.yml both pass here, so the
# argument has no default.
FROM ubuntu:24.04

# No GTK and no Flutter desktop runner: the app is built with `flutter
# assemble` and the audio engine with its own CMake project. clang, cmake,
# ninja and the ALSA headers are for the engine.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ninja-build libasound2-dev clang cmake pkg-config \
      git curl unzip xz-utils zip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG FLUTTER_VERSION
RUN test -n "$FLUTTER_VERSION" \
    || { echo "FLUTTER_VERSION is required (flutter-engine-version.inc)" >&2; exit 1; }
ENV FLUTTER_HOME=/opt/flutter
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
ENV PATH=/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# safe.directory: the repo is bind-mounted with the host user's uid. The Linux
# artifacts carry gen_snapshot for linux-arm64, which `flutter assemble` needs
# for the AOT snapshot; fetching them here keeps each build off the network.
RUN git config --global --add safe.directory '*' \
    && flutter config --enable-linux-desktop \
    && flutter precache --linux

COPY segno-build.sh /usr/local/bin/segno-build
RUN chmod +x /usr/local/bin/segno-build

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/segno-build"]
