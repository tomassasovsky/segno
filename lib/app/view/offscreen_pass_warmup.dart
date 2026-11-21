import 'package:flutter/widgets.dart';

/// Draws one full-screen offscreen pass, invisibly, right after the app's
/// first frame (#1914).
///
/// A page transition's fade renders through an offscreen pass, which Impeller
/// on the console gives 4x MSAA buffers (about 73 MB at 1080p). Allocating
/// them has the kernel zero all of their pages at once, a burst that stalls
/// the audio callback. The image's Mesa keeps large freed buffers for reuse
/// (`recipes-graphics/mesa`), so after this pass at startup every transition
/// finds them ready, the first one included.
class OffscreenPassWarmup extends StatefulWidget {
  /// Creates the warm-up.
  const new({super.key});

  @override
  State<OffscreenPassWarmup> createState() => _OffscreenPassWarmupState();
}

class _OffscreenPassWarmupState extends State<OffscreenPassWarmup> {
  bool _drawing = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _drawing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _drawing = false;
          _done = true;
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_drawing || _done) return const SizedBox.shrink();
    // Two overlapping draws under a group opacity: the renderer cannot fold
    // the opacity into a single draw, so it takes the offscreen pass a fade
    // takes. Their colour is all but transparent, so nothing shows.
    return const IgnorePointer(
      child: Opacity(
        key: Key('offscreen_pass_warmup'),
        opacity: 0.5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Color(0x01000000)),
            ColoredBox(color: Color(0x01000000)),
          ],
        ),
      ),
    );
  }
}
