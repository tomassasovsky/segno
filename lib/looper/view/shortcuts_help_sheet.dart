import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Opens the keyboard-shortcut legend for the Big Picture performance surface
/// as a dismissible console dialog (Esc / tap-outside close it). Surfaced by the
/// chrome's help button and by the `?` (Shift+/) key, so the shortcuts in
/// `TracksCommands.handleKey` — otherwise invisible to a new or screen-reader
/// user — become discoverable by pointer, keyboard, and assistive tech alike.
Future<void> showShortcutsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ShortcutsHelpDialog(),
  );
}

/// A single legend entry: a platform-aware key [chip] and its [description].
/// [id] is a stable, locale/platform-independent handle for the row's key.
class _Shortcut {
  const new(this.id, this.chip, this.description);

  /// Stable identifier used in the row's widget key.
  final String id;

  /// The key(s) shown in the chip (e.g. `Space`, `⌘Z`, `1–8`).
  final String chip;

  /// What the shortcut does.
  final String description;
}

/// The keyboard-shortcut legend, grouped Transport / Tracks / Navigation with
/// platform-correct modifiers (`⌘` on macOS, `Ctrl` elsewhere). Each row is one
/// merged [Semantics] node so a screen reader reads "R: Record or overdub the
/// selected track" as a unit, and the dialog names its route.
class _ShortcutsHelpDialog extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Segno targets Windows/Linux too, so the modifier must not hardcode ⌘.
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    // On macOS the modifier abuts the key (⌘Z); elsewhere it joins with `+`.
    String combo(String key) => isMac ? '⌘$key' : 'Ctrl+$key';

    // The console's own dialog, from the pen's `Dialog` — see
    // `SESSION & CAPTURE / shortcuts`. Was a Material `AlertDialog`, which put
    // Material's shape, padding and buttons on a console face.
    return Semantics(
      // Names the route so assistive tech announces the legend as it opens.
      label: l10n.a11yShortcutsHelp,
      // Centred, so the panel is the shell's 744 and as tall as its rows
      // rather than the whole screen (#1590 DLG-2).
      child: Center(
        child: ConsoleDialogShell(
          key: const Key('shortcutsHelp_dialog'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                l10n.a11yShortcutsHelp,
                style: TextStyle(
                  color: context.surface.textPrimary,
                  fontSize: 20,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: _ShortcutTable(
                    groups: [
                      (
                        l10n.shortcutGroupTransport,
                        [
                          _Shortcut(
                            'playStop',
                            'Space',
                            l10n.shortcutPlayStopAll,
                          ),
                          _Shortcut('clear', 'C', l10n.clearAllTooltip),
                          _Shortcut('mode', 'M', l10n.shortcutMode),
                          _Shortcut('arm', 'A', l10n.shortcutArm),
                        ],
                      ),
                      (
                        l10n.shortcutGroupTracks,
                        [
                          // One row, all modes: the digit keys always select,
                          // and the mode decides what else they do (mute / FX
                          // chain).
                          _Shortcut('select', '1–8', l10n.shortcutSelectTrack),
                          _Shortcut('bank', 'B', l10n.shortcutBank),
                          _Shortcut('record', 'R', l10n.shortcutRecord),
                          _Shortcut('playPause', 'P', l10n.shortcutPlayPause),
                          _Shortcut(
                            'undoOverdub',
                            'U',
                            l10n.shortcutUndoOverdub,
                          ),
                          _Shortcut('undo', combo('Z'), l10n.shortcutUndo),
                          _Shortcut(
                            'redo',
                            isMac ? '⌘⇧Z' : 'Ctrl+Y',
                            l10n.shortcutRedo,
                          ),
                          _Shortcut(
                            'undoClearAll',
                            isMac ? '⌘⇧C' : 'Ctrl+Shift+C',
                            l10n.shortcutUndoClearAll,
                          ),
                        ],
                      ),
                      (
                        l10n.shortcutGroupNavigation,
                        [
                          _Shortcut('signal', 'G', l10n.signalTooltip),
                          _Shortcut('settings', 'S', l10n.settingsTooltip),
                          _Shortcut(
                            'save',
                            combo('S'),
                            l10n.shortcutSaveSession,
                          ),
                          _Shortcut('focus', 'Tab', l10n.shortcutFocusTraverse),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleDialogButton(
                    key: const Key('shortcutsHelp_close'),
                    label: l10n.close,
                    tone: ConsoleDialogTone.accent,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The legend's groups, with every description in one column: the key caps
/// all take the widest cap's width (#1590 DLG-1).
class _ShortcutTable extends StatelessWidget {
  const new({required this.groups});

  /// Each group's heading and its rows.
  final List<(String, List<_Shortcut>)> groups;

  /// The cap's padding either side of its keys.
  static const double _capPadding = 8;

  /// The narrowest cap.
  static const double _capMinWidth = 46;

  /// The cap text's style.
  static TextStyle? capStyle(ThemeData theme) =>
      theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = DefaultTextStyle.of(context).style.merge(capStyle(theme));
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    var widest = 0.0;
    for (final (_, rows) in groups) {
      for (final row in rows) {
        painter
          ..text = TextSpan(text: row.chip, style: style)
          ..layout();
        widest = math.max(widest, painter.width);
      }
    }
    painter.dispose();
    // The border's two pixels, and one to spare so rounding never wraps a
    // cap.
    final capWidth = math.max(
      _capMinWidth,
      (widest + _capPadding * 2 + 3).ceilToDouble(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (title, rows) in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 2),
            child: AppText(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final row in rows) _ShortcutRow(row: row, capWidth: capWidth),
        ],
      ],
    );
  }
}

/// One legend entry: its key cap, then its description.
class _ShortcutRow extends StatelessWidget {
  const new({required this.row, required this.capWidth});

  final _Shortcut row;

  /// Every cap's width, so the descriptions line up.
  final double capWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // One merged node reading "<keys>: <description>", excluding the chip and
    // label's own nodes so the pairing is never read as two loose fragments.
    return Semantics(
      key: Key('shortcutRow_${row.id}'),
      container: true,
      label: '${row.chip}: ${row.description}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: Key('shortcutCap_${row.id}'),
                width: capWidth,
                padding: const EdgeInsets.symmetric(
                  horizontal: _ShortcutTable._capPadding,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: AppText(
                  row.chip,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: _ShortcutTable.capStyle(theme),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: AppText(
                    row.description,
                    key: Key('shortcutDescription_${row.id}'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
