// Forwarder header for the Swift Package Manager (macOS) build.
//
// engine_private.h includes "le_clock_follow.h" (#1228, the MIDI clock
// follower), but the real header lives in ../src/midi/ — outside this SPM
// package, where SPM refuses to add a header search path. SPM does add this
// target's include/ directory to the search path, so this forwarder (found
// after the relative-to-source lookup fails, like le_midi_clock.h beside it)
// redirects to the real header at the plugin root.
#include "../../../../../src/midi/le_clock_follow.h"
