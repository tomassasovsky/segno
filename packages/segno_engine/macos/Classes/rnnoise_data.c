// Forwarder translation unit for the CocoaPods (macOS/iOS) build.
//
// CocoaPods cannot reference source files outside the podspec directory, so
// the vendored RNNoise TU under ../../third_party/rnnoise is pulled in here.
// Hidden visibility matches CMakeLists.txt: rnnoise internals are unprefixed
// and must not export from the engine dylib.
#pragma GCC visibility push(hidden)
#include "../../third_party/rnnoise/src/rnnoise_data.c"
#pragma GCC visibility pop
