// Forwarder translation unit for the Swift Package Manager (macOS) build.
//
// SPM only compiles sources inside the package directory, so the vendored
// RNNoise TU is pulled in via this relative #include. Hidden visibility
// matches CMakeLists.txt: rnnoise internals are unprefixed and must not
// export from the engine dylib.
#pragma GCC visibility push(hidden)
#include "../../../../third_party/rnnoise/src/rnn.c"
#pragma GCC visibility pop
