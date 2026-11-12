import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show LooperModeGate;
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/control/model/foot_length.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/foot_length_view.dart';
import 'package:segno/looper/view/foot_peel_view.dart';
import 'package:segno/looper/view/looper_mode_change.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/view/foot_tuner_view.dart';

import '../helpers/text_fit.dart';

/// One message as the top bar draws it.
typedef _Copy = ({
  String name,
  NoticeTone tone,
  NoticeText title,
  NoticeText? body,
  NoticeText? action,
  NoticeText? secondary,
});

_Copy _copy(
  String name,
  NoticeText title, {
  NoticeTone tone = NoticeTone.warning,
  NoticeText? body,
  NoticeText? action,
  NoticeText? secondary,
}) => (
  name: name,
  tone: tone,
  title: title,
  body: body,
  action: action,
  secondary: secondary,
);

/// Every message the console says in its top bar (#1562), with the longest
/// values its placeholders take on the console.
final _messages = <_Copy>[
  // Must-act.
  _copy(
    'device lost',
    (l) => l.deviceLostNamedBanner('Scarlett 18i20 4th Gen'),
    tone: NoticeTone.critical,
    action: (l) => l.deviceLostBannerAction,
  ),
  _copy(
    'waiting for the device',
    (l) => l.audioRecoveryWaitingBanner,
    tone: NoticeTone.critical,
    body: (l) => l.audioRecoveryWaitingBody,
    action: (l) => l.deviceLostBannerAction,
  ),
  _copy(
    'loops cleared',
    (l) => l.deviceRestoredClearedTitle,
    tone: NoticeTone.critical,
    body: (l) => l.deviceRestoredClearedBanner(44100, 48000),
    action: (l) => l.stageLibrary,
  ),
  _copy(
    'engine stopped',
    (l) => l.engineStoppedBanner,
    tone: NoticeTone.critical,
    action: (l) => l.deviceLostBannerAction,
  ),
  _copy('audio starting', (l) => l.audioStartingBanner),
  _copy(
    'effects held',
    (l) => l.fxHeldTitle,
    body: (l) => l.fxHeldBanner('TRACK 8', 1),
    action: (l) => l.fxHeldOpen,
    secondary: (l) => l.dismiss,
  ),
  _copy(
    'session boot',
    (l) => l.sessionBootRecoveryTitle,
    tone: NoticeTone.critical,
    body: (l) => l.sessionBootRecoveryBody,
    action: (l) => l.powerRetry,
  ),
  _copy(
    'monitor',
    (l) => l.monitorRestoreFailedTitle,
    action: (l) => l.powerRetry,
  ),
  _copy(
    'mix',
    (l) => l.mixSettingsRecoveryTitle,
    tone: NoticeTone.critical,
    body: (l) => l.mixSettingsStoppedBody,
    action: (l) => l.powerRetry,
  ),
  for (final title in <NoticeText>[
    (l) => l.clickSettingsRecoveryTitle,
    (l) => l.clickModeSettingsRecoveryTitle,
    (l) => l.recordStartSettingsRecoveryTitle,
    (l) => l.decaySettingsRecoveryTitle,
    (l) => l.oneShotSettingsRecoveryTitle,
    (l) => l.recordLengthSettingsRecoveryTitle,
    (l) => l.recordTimingSettingsRecoveryTitle,
    (l) => l.fadeSettingsRecoveryTitle,
    (l) => l.backingMixSettingsRecoveryTitle,
    (l) => l.clickPanSettingsRecoveryTitle,
    (l) => l.followTempoSettingsRecoveryTitle,
    (l) => l.pitchModeSettingsRecoveryTitle,
    (l) => l.instrumentsSettingsRecoveryTitle,
  ])
    _copy('settings recovery', title, action: (l) => l.powerRetry),
  _copy(
    'power cycle',
    (l) => l.powerCycleBannerTitle('100'),
    action: (l) => l.powerCycleBannerPowerOff,
    secondary: (l) => l.powerCycleBannerDismiss,
  ),
  // Passing.
  for (final title in <NoticeText>[
    (l) => l.clickSettingsRefusedTitle,
    (l) => l.clickModeSettingsRefusedTitle,
    (l) => l.recordStartSettingsRefusedTitle,
    (l) => l.decaySettingsRefusedTitle,
    (l) => l.oneShotSettingsRefusedTitle,
    (l) => l.recordLengthSettingsRefusedTitle,
    (l) => l.recordTimingSettingsRefusedTitle,
    (l) => l.fadeSettingsRefusedTitle,
    (l) => l.backingMixSettingsRefusedTitle,
    (l) => l.clickPanSettingsRefusedTitle,
    (l) => l.followTempoSettingsRefusedTitle,
    (l) => l.pitchModeSettingsRefusedTitle,
    (l) => l.instrumentsSettingsRefusedTitle,
    (l) => l.mixSettingsNotSaved,
    (l) => l.mixSettingsNotApplied,
  ])
    _copy('settings refused', title),
  _copy(
    'bluetooth',
    (l) => l.bluetoothRetiredTitle,
    tone: NoticeTone.neutral,
    body: (l) => l.bluetoothRetiredNotice(2),
  ),
  _copy(
    'recovery wait',
    (l) => l.recoveryWaitTitle,
    body: (l) => l.recoveryWaitBody,
  ),
  _copy(
    'recovery mode',
    (l) => l.recoveryModeTitle,
    body: (l) => l.recoveryModeRedoBody,
  ),
  _copy(
    'device back',
    (l) => l.deviceReconnectedSnackbar('Scarlett 18i20 4th Gen'),
    tone: NoticeTone.success,
  ),
  _copy(
    'device back, a track dropped',
    (l) => l.deviceReconnectedSnackbar('Scarlett 4i4'),
    body: (l) => l.deviceRestoredPartialToastBody(2, '3, 7'),
  ),
  _copy(
    'midi lost',
    (l) => l.midiLostToastTitle,
    body: (l) => l.midiLostToastBody,
  ),
  _copy(
    'midi back',
    (l) => l.midiReconnectedSnackbar('nanoKONTROL2'),
    tone: NoticeTone.success,
  ),
  _copy(
    'weak charger',
    (l) => l.weakChargerToast('45'),
    body: (l) => l.weakChargerBody,
  ),
  _copy(
    'update',
    (l) => l.updateBannerTitle('1.62.0'),
    tone: NoticeTone.neutral,
    action: (l) => l.updateBannerUpdateAction,
  ),
  _copy('waveform window', (l) => l.waveformWindowFailedBanner),
  _copy(
    'fx stop changed',
    (l) => l.footFxStopChanged,
    tone: NoticeTone.neutral,
    body: (l) => l.footFxModeChanged,
  ),
  _copy(
    'save to fell back',
    (l) => l.saveToFellBack('SanDisk Ultra'),
    body: (l) => l.saveToFellBackBody,
  ),
  _copy(
    'boot mode',
    (l) => l.bootModeRetiredNotice,
    tone: NoticeTone.neutral,
    body: (l) => l.bootModeRetiredBody,
  ),
  _copy(
    'tuner seeded',
    (l) => l.footTunerSeeded,
    tone: NoticeTone.neutral,
    body: (l) => l.footTunerSeededBody,
  ),
  _copy(
    'undo clear all',
    (l) => l.undoClearAllToast,
    tone: NoticeTone.neutral,
    action: (l) => l.undoClearAllAction,
  ),
  _copy('foot mixer', (l) => l.footMixerFailure),
  _copy('fade empty', (l) => l.footFadeRefusedEmpty(2)),
  _copy('fade failure', (l) => l.footFadeFailure),
  _copy('fx unavailable', (l) => l.footFxUnavailable),
  _copy('fx failure', (l) => l.footFxFailure),
  _copy('reverse empty', (l) => l.footReverseRefusedEmpty(2)),
  _copy('reverse failure', (l) => l.footReverseFailure),
  for (final refusal in FootPeelRefusal.values)
    _copy('peel ${refusal.name}', (l) => footPeelRefusalText(l, refusal)),
  for (final refusal in FootTunerRefusal.values)
    _copy('tuner ${refusal.name}', (l) => footTunerRefusalText(l, refusal)),
  for (final refusal in FootLengthRefusal.values)
    _copy('length ${refusal.name}', (l) => footLengthRefusalText(l, refusal)),
  _copy('action unknown', (l) => l.assignedActionUnknownRefused),
  _copy(
    'action refused',
    (l) => l.assignedActionRefused('Selected track · Overdub'),
  ),
  _copy('session saved', (l) => l.sessionSaved, tone: NoticeTone.success),
  _copy(
    'session saved as',
    (l) => l.sessionSavedAs('Night set, second half'),
    tone: NoticeTone.success,
  ),
  _copy('session loaded', (l) => l.sessionLoaded, tone: NoticeTone.success),
  _copy(
    'session converted',
    (l) => l.sessionLoadedConverted,
    tone: NoticeTone.success,
    body: (l) => l.sessionConvertedKept,
  ),
  _copy(
    'session converted for now',
    (l) => l.sessionLoadedConvertedUnsaved,
    tone: NoticeTone.success,
    body: (l) => l.sessionConvertedNotWritten,
  ),
  _copy(
    'session sample rate',
    (l) => l.sessionLoadFailed,
    body: (l) => l.sessionLoadSampleRate,
    action: (l) => l.deviceLostBannerAction,
  ),
  _copy(
    'session newer',
    (l) => l.sessionLoadFailed,
    body: (l) => l.sessionLoadNewer,
  ),
  _copy(
    'session unconvertible',
    (l) => l.sessionLoadFailed,
    body: (l) => l.sessionLoadUnconvertible,
  ),
  for (final kind in GuardKind.values)
    _copy('busy ${kind.name}', (l) => l.operationBusy(kind.name)),
  _copy('save failed', (l) => l.librarySaveFailed),
  _copy('open session protected', (l) => l.libraryDeleteCurrentRefused),
  _copy('folder not empty', (l) => l.libraryFolderNotEmpty),
  _copy('take running', (l) => l.libraryTakeStillRunning),
  _copy('template', (l) => l.sessionTemplateDoesNotFit),
  _copy('new loop not saved', (l) => l.sessionNewLoopNotSaved('New loop 12')),
  _copy('track names', (l) => l.sessionTrackNamesNotSaved),
  _copy('low disk', (l) => l.perfLowDiskBlocked),
  _copy('interface switch refused', (l) => l.routingInterfaceRefused),
  _copy('drive unavailable', (l) => l.perfArmDriveUnavailable),
  for (final kind in GuardKind.values)
    _copy(
      'arm refused ${kind.name}',
      (l) => l.perfArmRefused,
      body: (l) => l.operationBusy(kind.name),
    ),
  _copy(
    'not recovered',
    (l) => l.perfTakesNotRecovered(3),
    body: (l) => l.perfTakesNotRecoveredBody(3),
    action: (l) => l.consoleTryAgain,
  ),
  _copy(
    'recovering',
    (l) => l.perfTakesRecovering(3),
    tone: NoticeTone.neutral,
  ),
  _copy('recovered', (l) => l.perfTakesRecovered(3), tone: NoticeTone.success),
  _copy('discarded', (l) => l.perfDiscarded, tone: NoticeTone.neutral),
  _copy(
    'stopped idle',
    (l) => l.perfStoppedIdle(20),
    body: (l) => l.perfStoppedKept,
  ),
  _copy(
    'stopped at the longest length',
    (l) => l.perfStoppedLengthLimit,
    body: (l) => l.perfStoppedKept,
  ),
  for (final gate in [
    LooperModeGate.capturing,
    LooperModeGate.queued,
    LooperModeGate.spans,
  ])
    _copy('mode ${gate.name}', (l) => looperModeRefusal(l, gate)!),
  _copy(
    'loop settings',
    (l) => l.loopSettingsRefused,
    body: (l) => l.loopSettingsRefusedBody,
  ),
  _copy('fx refused', (l) => l.fxChangeNotApplied),
  _copy('fx over budget', (l) => l.fxOverBudget),
  _copy('storage', (l) => l.storageActionFailed),
  _copy(
    'rack removed',
    (l) => l.fxRackRemoved('Funk Wah'),
    tone: NoticeTone.success,
  ),
  _copy(
    'preset saved',
    (l) => l.fxPresetSaved('Clean shimmer'),
    tone: NoticeTone.success,
  ),
  _copy('display not saved', (l) => l.displayBrightnessSaveFailed),
];

/// The stage's top bar at 1920 x 1080: its side groups are 296 and 312
/// wide, which leaves the centre 1128 (the room on every other screen is
/// wider).
class _StageBar extends StatelessWidget {
  const _StageBar();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: 96,
        child: NoticeBar(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 60),
            child: TopBarLayout(
              leading: SizedBox(width: 296, height: 60),
              centre: NoticeBarMessage(),
              trailing: SizedBox(width: 312, height: 60),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Every message is said whole in the stage's top bar at 1920 x 1080, in
/// every language the console ships: the title is never cut, and the body
/// and the buttons all show (#1562).
void main() {
  setUpAll(loadBundledFonts);

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('every message fits the stage bar whole '
        '(${locale.languageCode})', (tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notices = NoticesCubit();
      addTearDown(notices.close);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          theme: AppTheme.neon,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider.value(value: notices, child: const _StageBar()),
        ),
      );
      final l10n = lookupAppLocalizations(locale);
      final cut = <String>[];
      for (final (index, copy) in _messages.indexed) {
        final notice = Notice(
          id: 'copy_$index',
          tone: copy.tone,
          title: copy.title,
          body: copy.body,
          action: copy.action == null
              ? null
              : NoticeAction(label: copy.action!, onPressed: () {}),
          secondary: copy.secondary == null
              ? null
              : NoticeAction(label: copy.secondary!, onPressed: () {}),
        );
        if (copy.tone == NoticeTone.critical) {
          notices.raise(notice);
        } else {
          notices.show(notice);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final row = find.byKey(Key('notice_bar_copy_$index'));
        final title = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.descendant(
              of: row,
              matching: find.byKey(const Key('notice_sentence_title')),
            ),
            matching: find.byType(RichText),
          ),
        );
        final problems = [
          if (title.didExceedMaxLines) 'title cut',
          if (copy.body != null &&
              find
                  .descendant(
                    of: row,
                    matching: find.byKey(const Key('notice_sentence_body')),
                  )
                  .evaluate()
                  .isEmpty)
            'body left out',
          if (copy.action != null &&
              find
                  .descendant(of: row, matching: find.text(copy.action!(l10n)))
                  .evaluate()
                  .isEmpty)
            'action left out',
        ];
        if (problems.isNotEmpty) {
          cut.add('${copy.name}: "${copy.title(l10n)}" ${problems.join(', ')}');
        }
        notices.clear(notice.id);
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(cut, isEmpty, reason: cut.join('\n'));
    });
  }
}
