import 'dart:async';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/update/appliance/appliance_env.dart';
import 'package:segno/visualizer/screen_link.dart';

/// Where the console's screen captures land (#1555).
const screenCaptureDirectory = '/data/capture';

/// How many captures of each screen are kept. Older ones are deleted as a new
/// one lands, so repeated captures cannot fill `/data`.
const screenCapturesKept = 5;

/// What asks this engine for a capture: SIGUSR1 on the console, which
/// `segno-capture` sends, and nothing anywhere else.
///
/// Both of the console's Flutter engines run in one process, and the Dart VM
/// delivers a watched signal to every isolate that watches it, so one SIGUSR1
/// reaches both screens.
///
/// Watching SIGUSR1 replaces its default action, which ends the process, for
/// the whole process. [appliance] defaults to [isAppliance].
Stream<void> screenCaptureRequests({bool? appliance}) =>
    (appliance ?? isAppliance())
    ? ProcessSignal.sigusr1.watch()
    : const Stream<void>.empty();

/// The file name of [screen]'s capture taken at [at]:
/// `<screen>-<UTC time>.png`, for example `main-20261103T142233.123Z.png`.
/// Names of one screen sort by time.
String screenCaptureName(SegnoScreen screen, DateTime at) {
  final t = at.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final ms = t.millisecond.toString().padLeft(3, '0');
  return '${screen.name}-${t.year}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}.${ms}Z.png';
}

/// Writes [png] as [screen]'s capture taken at [at] into [directory], creating
/// it, and deletes all but the newest [kept] captures of that screen.
///
/// The PNG is written under a `.part` name and renamed, so a reader that
/// waits for `<screen>-*.png` never sees a half-written file. Returns the
/// capture's path.
Future<String> saveScreenCapture({
  required String directory,
  required SegnoScreen screen,
  required DateTime at,
  required List<int> png,
  int kept = screenCapturesKept,
}) async {
  final dir = await Directory(directory).create(recursive: true);
  final path = '${dir.path}/${screenCaptureName(screen, at)}';
  final part = File('$path.part');
  await part.writeAsBytes(png, flush: true);
  await part.rename(path);

  final prefix = '${screen.name}-';
  final captures = <File>[
    await for (final entry in dir.list())
      if (entry is File &&
          entry.uri.pathSegments.last.startsWith(prefix) &&
          entry.path.endsWith('.png'))
        entry,
  ]..sort((a, b) => a.path.compareTo(b.path));
  for (final old in captures.take(max(0, captures.length - kept))) {
    try {
      await old.delete();
    } on FileSystemException {
      // Already gone; the next capture prunes again.
    }
  }
  return path;
}

/// Draws [child] inside a repaint boundary and, on each of [requests], saves
/// what the boundary last painted as [screen]'s PNG in [directory].
///
/// The capture is the frame Flutter rendered through the engine's active
/// renderer (Impeller or Skia), at the view's device pixel ratio, so it shows
/// renderer faults such as missing glyphs. It is not the display's scanout.
class ScreenCapture extends StatefulWidget {
  /// Creates a [ScreenCapture] around [child].
  const ScreenCapture({
    required this.screen,
    required this.requests,
    required this.child,
    this.directory = screenCaptureDirectory,
    super.key,
  });

  /// The screen this engine draws, which names its captures.
  final SegnoScreen screen;

  /// Each event asks for one capture.
  final Stream<void> requests;

  /// Where the captures are written.
  final String directory;

  /// The screen's root widget.
  final Widget child;

  @override
  State<ScreenCapture> createState() => _ScreenCaptureState();
}

class _ScreenCaptureState extends State<ScreenCapture> {
  final GlobalKey _boundary = GlobalKey();
  StreamSubscription<void>? _requests;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ScreenCapture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requests != widget.requests) {
      unawaited(_requests?.cancel());
      _listen();
    }
  }

  @override
  void dispose() {
    unawaited(_requests?.cancel());
    super.dispose();
  }

  void _listen() {
    _requests = widget.requests.listen((_) => unawaited(_capture()));
  }

  Future<void> _capture() async {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (!mounted || boundary is! RenderRepaintBoundary) return;
    final screen = widget.screen;
    final directory = widget.directory;
    final pixelRatio = View.of(context).devicePixelRatio;
    final at = DateTime.now();
    try {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final ByteData? png;
      try {
        png = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (png == null) throw StateError('the PNG encoder returned nothing');
      final path = await saveScreenCapture(
        directory: directory,
        screen: screen,
        at: at,
        png: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      AppLog.info('capture: ${screen.name} wrote $path');
    } on Object catch (error, stack) {
      AppLog.error(
        'capture: ${screen.name} failed',
        error: error,
        stack: stack,
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundary, child: widget.child);
}
