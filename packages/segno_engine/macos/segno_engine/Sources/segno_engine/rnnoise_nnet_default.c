// Forwarder translation unit for the macOS plugin build (SPM + CocoaPods).
//
// SPM only compiles sources inside the package directory; CocoaPods compiles
// these same files via segno_engine.podspec's source_files glob. Do not add
// a Classes/ copy — that would duplicate-compile the same rnnoise_* symbols.
// Hidden visibility matches CMakeLists.txt: rnnoise internals are unprefixed
// and must not export from the engine dylib.
#pragma GCC visibility push(hidden)
#include "../../../../third_party/rnnoise/src/nnet_default.c"
#pragma GCC visibility pop
