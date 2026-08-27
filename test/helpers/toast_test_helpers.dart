import 'package:toastification/toastification.dart';

/// Hard-resets the `toastification` process-global singleton between tests.
///
/// Under `very_good test --optimization` every test file shares ONE isolate,
/// so `toastification`'s singleton outlives each individual test tree. Each
/// `ToastificationManager` it keeps holds an `OverlayEntry` bound to the tree
/// that first raised a toast, and `showCustom` only builds a fresh holder when
/// that entry is `null`. When a prior test's exit-animation teardown timer (a
/// bare `Future.delayed`) has not been pumped past, the entry is left non-null
/// but pointing at a now-disposed overlay — so the NEXT test's toast renders
/// into a dead overlay and its key is never found (#875). The failing test is
/// whichever toast test a given `--test-randomize-ordering-seed` happens to
/// run after the leaker, which is why per-test hardening never stuck.
///
/// Dropping the managers forces a brand-new manager — and a brand-new overlay
/// — for the next test's toast, making the outcome independent of test
/// ordering. Call it in `setUp`, alongside `resetAppToastsForTest()` (which
/// clears the app shell's own id→item registry) for a clean toast slate.
///
/// `toastification.managers` is a `@visibleForTesting` package member, so this
/// lives in test code rather than in `lib/`.
void resetToastificationForTest() {
  toastification.managers.clear();
}
