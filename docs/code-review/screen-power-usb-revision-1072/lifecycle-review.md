<!-- cspell:words libgpiod RP gpiod pinctrl gpiochip glob INACTIVE BindsTo AS_IS GitGuardian SRC_URI RDEPENDS -->
# Screen lifecycle and deployment review

Result: no unresolved actionable findings in this software scope. This is one
angle of the accumulated PR review, not approval of the whole PR or the boards.

## Revision and scope

Reviewed PR #1080 against `feat/console-board-5v-1062`, using merge-base
`5fd9f8bf6856673d07b27054d0b98dd7ba719561`. Review started at
`d4fde1951cdfd384eced740d9f599c255ebe2b95` and completed at
`00060494b9af330cb2fbe7834fe9bae04bac65c0`; the reviewed lifecycle implementation
was unchanged between those heads. Working changes and untracked files were
inspected for scope. Pending Revision M CAD is excluded.

The entire accumulated change to the screen GPIO owner, its service, the Weston
drop-in, recipe installation/dependencies, host tests and CI step was reviewed.
The existing app/Weston service relationship, Wayland launcher, ordinary/update
reboot command, Pi 5 configuration and current GPIO17 documentation were traced.
No implementation, device, firmware, deployment or PR label was changed.

## Completed checks

- Boot requests GPIO17 inactive on the RP1 controller before announcing readiness.
  Weston requires that owner and synchronously enables power before starting.
  Controller selection uses the label and line name rather than a fixed chip
  number; a missing controller fails without claiming another line.
- The app is ordered after Weston. During an orderly stop, Weston waits for the
  acknowledged low interval before its compositor process is terminated. The
  pinned upstream Weston unit has no existing stop command that would precede
  this new hook. App restart and both reboot paths use systemd rather than
  bypassing the ordered stop transaction.
- Socket commands are private to root, acknowledge completed settling, reject
  invalid frames and do not bypass the owner for an enable. The reviewed failure
  paths include missing owner, lost acknowledgment, interrupted enable settling,
  failed GPIO calls, termination and competing cleanup requests after owner death.
  Low is retried on abnormal cleanup; ownership contention has a bounded timeout.
- The GPIO request deliberately leaves bias unchanged (`AS_IS`). The checked Pi 5
  configuration does not request a GPIO17 pull-up. The hardware documentation now
  correctly requires low, or release without a pull-up; neither this code nor the
  host tests establish a safe released voltage under an independently configured
  pull-up. The service is specifically for the current Pi 5 RP1 appliance.
- Recipe source inventory, executable/unit installation, packaged paths and
  runtime dependencies agree. The owner is pulled in by Weston and does not need
  its own auto-enable entry. The pinned Python manifest places glob/signal in core
  and socket in I/O; the pinned `python3-gpiod` recipe supplies the required
  binding and library dependencies.
- Changed hunks, enclosing functions, removed invariants, caller ordering,
  dependency reuse, blocking boundaries and error propagation were checked.
  There is no audio callback or real-time engine change in this scope. The
  intentional settling waits run in the lifecycle helper.

Primary integration references: [pinned Weston unit](https://raw.githubusercontent.com/yoctoproject/poky/d0b46a6624ec9c61c47270745dd0b2d5abbe6ac1/meta/recipes-graphics/wayland/weston-init/weston.service),
[pinned Python package manifest](https://raw.githubusercontent.com/yoctoproject/poky/d0b46a6624ec9c61c47270745dd0b2d5abbe6ac1/meta/recipes-devtools/python/python3/python3-manifest.json),
[pinned GPIO binding recipe](https://raw.githubusercontent.com/openembedded/meta-openembedded/07330a98cf93806b7a4e0170a541b94962ff3960/meta-python/recipes-devtools/python/python3-gpiod_2.3.0.bb),
and [binding line settings](https://raw.githubusercontent.com/brgl/libgpiod/v2.3/bindings/python/gpiod/line_settings.py).

## Observed validation

The following host commands passed during this review:

```sh
python3 deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py
bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_wayland_wait_tests.sh
bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_reboot_tests.sh
bash deploy/yocto/meta-segno/recipes-graphics/weston-init/test/run_weston_log_tests.sh
```

Results: 12 lifecycle tests, 8 Wayland startup tests, 6 reboot checks and 16 Weston
integration checks passed. The lifecycle suite includes a real local socket and
child-process signal test with GPIO and settling delays substituted.

The earlier systemd fixture and recorded events under
`docs/reviews/pcb-completion-1072/` were inspected, but were not rerun: the local
Docker daemon was unavailable. The recorded unit/drop-in/recipe/test hashes match
current files; the recorded helper hash does not, so those events are historical
supporting evidence, not a fresh acceptance result for this exact source. No
Yocto image rebuild, target systemd run or physical GPIO capture was performed.
The one-second startup and five-second discharge waits remain explicit unmeasured
integration assumptions; an abrupt compositor/kernel fault cannot be sequenced
by a userspace stop hook. These limits do not imply a new pre-PCB prototype task.

## Gate state

At the reviewed head PR #1080 was open with `stage:in-review`,
`autonomy:blocked-verify`, `review:pending` and `ci:pending`. The only reported
check was a neutral GitGuardian result. The main workflow targets `master`, so
this feature-base PR has no observed full CI pass. Current labels correctly avoid
claiming the accumulated review, device qualification or merge gates are complete.
The PR records `Closes #1072`, the separate controller runtime dependency #1082,
and the current manufacturing hold. This scoped result must not be used to set
`review:clean` or `ready-to-merge` by itself.

## Source fingerprint

SHA-256 of the seven changed software/integration files:

```json
{
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-screen-power": "17aef15885acc2034862f71a844c982ba93a33659271923d9072d0dfd01e9b38",
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-screen-power.service": "a0d5af275bb563ad59d58c101567883b24f9e892e36ab801b3cc5a640c671d17",
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/30-segno-screen-power.conf": "b6a852214ac9c707d3c4d62b4a4a25853192f8dfd30684aea9bb9ebb22753a73",
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/segno-bundle.bb": "34de46ccf97bdc9f60d88c0b6c9ba0ae20584930ef3480422521449d31b500b5",
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py": "cf4bf0c6cf9b9961c463c472bf9390e5efe0c0a11a635f22a715b80d0fd37f21",
  "deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/SCREEN_POWER.md": "f9173efd548ade831d900e924f07f1f2f2c9b41feaad968b562b1e2aa0d58a5f",
  ".github/workflows/main.yaml": "a12ab483cf4a4632ecaa17cee18f26b86ef0ac976ea504ae4bad958df4c85666"
}
```
