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
# the prebuilt recipe's file name (its PV) and SRC_URI checksum. After a bump,
# check that the console's log still says "Using the Impeller rendering
# backend (OpenGLES)", not "(OpenGLESSDF)": the console leaves Impeller's SDF
# shapes off (homescreen.toml says why), and only the engine default keeps
# them off.
FLUTTER_ENGINE_VERSION = "3.50.0"
FLUTTER_ENGINE_COMMIT = "371f77202a73e8dff57a8b3bff75bca55c090aee"

# The profile build of the same engine, for DevTools on the device
# (deploy/rpi/profile-on-device.sh). Not in the image: `segno-build --profile`
# fetches it into the profile bundle, checked against this digest. Bump it with
# the commit.
FLUTTER_ENGINE_PROFILE_SHA256 = "924e4351d1584f3aec755e2d6c2af6f47c3e6750e21c8b388a523132148f99f6"
