# The Flutter engine the ivi-homescreen image runs (#1318), in one place.
#
# flutter-engine-prebuilt installs it, and segno-bundle refuses an app bundle
# whose AOT snapshot was compiled for any other engine (a snapshot loads only on
# its own engine revision). The bundle side of the pin is the FLUTTER_VERSION
# build argument the release workflow passes for the ivi image.
#
# The version is the newest Flutter release meta-flutter publishes a prebuilt
# arm64 release engine for (github.com/meta-flutter/flutter-engine releases);
# the commit is that release's bin/internal/engine.version, which is also the
# `engineRevision` of `flutter --version --machine`. Bump both together, with
# the prebuilt recipe's file name (its PV) and SRC_URI checksum.
FLUTTER_ENGINE_VERSION = "3.47.5"
FLUTTER_ENGINE_COMMIT = "af7e796e161ae0bb1ff0758c71a7105418bd9ded"

# The profile build of the same engine, for DevTools on the device
# (deploy/rpi/profile-on-device.sh). Not in the image: `segno-build --profile`
# fetches it into the profile bundle, checked against this digest. Bump it with
# the commit.
FLUTTER_ENGINE_PROFILE_SHA256 = "b7628eff74d3ed30e036094f5cfe9a384fa403568ea71bbd4b279af028a79d83"
