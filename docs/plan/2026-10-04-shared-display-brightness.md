# Shared display brightness

Issue #1113, following ownership corrections #1111 and #1112.
Implementation is authorized; merging remains human gated.

SettingsTrayCubit should own navigation only. The existing application-wide
DisplayBrightnessCubit owns brightness changes, hardware application and saved
values. The tray should read and edit that same state, so reopening the tray
or changing another surface cannot restore a stale duplicate value.

Keep the existing optimistic brightness and explicit retry behavior. Make save
failure visible above the real Settings tray; a message drawn in the underlying
Scaffold is hidden by the opaque tray. Verify failure notice and successful retry
with the actual TracksView composition, not a different test-only hierarchy.

Remove the duplicated settings/client dependencies and migrate only required
constructor/provider fixtures. No new dependencies, fallback persistence owner,
native changes or hardware claim. Verify focused owner/view behavior, app
coverage, strict analysis, formatting and a nonempty Bloc scan. Independent
final source review and current-head CI are both required for ready-to-merge.
