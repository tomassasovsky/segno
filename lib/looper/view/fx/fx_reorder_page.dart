import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// One card on the reorder strip.
class FxReorderCard {
  /// Creates an [FxReorderCard].
  const FxReorderCard({
    required this.id,
    required this.name,
    this.art,
    this.stageTag,
  });

  /// The card's stable identity, which is what the reorder actually moves.
  final String id;

  /// What it is called.
  final String name;

  /// Its artwork asset in the catalogue package, or `null`.
  final String? art;

  /// The stage this card sits in, drawn beside its position number when the
  /// strip holds both stages. Absent when every card is in the same one — a
  /// rack's own pedals are all in one stage by construction.
  ///
  /// It is also the boundary the reorder will not cross: a card can only take
  /// the place of a neighbour with the same tag, because the accepted design
  /// says reorder moves an effect within its stage and the explicit Pre/Post
  /// switch is what moves it between them.
  final String? stageTag;
}

/// The accepted reorder surface (`04 Reorder effects` / `05 Reorder rack
/// chain`): the same horizontal strip of artwork for both jobs, arranging a
/// destination's racks or one rack's pedals.
///
/// **The draft is local, and Cancel discards it.** Nothing is written until
/// Done, which is what makes the accepted "Reorder can be canceled" true even
/// after several moves — and what keeps a pedal press from persisting an order
/// the player was still trying out.
class FxReorderPage extends StatefulWidget {
  /// Creates an [FxReorderPage].
  const FxReorderPage({required this.crumb, required this.cards, super.key});

  /// The breadcrumb over the title.
  final String crumb;

  /// The cards, in their current order.
  final List<FxReorderCard> cards;

  @override
  State<FxReorderPage> createState() => _FxReorderPageState();
}

class _FxReorderPageState extends State<FxReorderPage> {
  late final List<FxReorderCard> _draft = [...widget.cards];
  int _picked = 0;

  /// The pen's card geometry.
  static const double _cardWidth = 340;
  static const double _cardHeight = 440;
  static const double _cardGap = 24;

  void _move(int delta) {
    if (!_canMove(delta)) return;
    final to = _picked + delta;
    setState(() {
      _draft.insert(to, _draft.removeAt(_picked));
      _picked = to;
    });
  }

  /// Whether the picked card can take its neighbour's place — which it cannot
  /// when that neighbour is in the other stage. Read off the DRAFT, so the
  /// answer follows the moves already made rather than the order this page
  /// opened on.
  bool _canMove(int delta) {
    final to = _picked + delta;
    if (to < 0 || to >= _draft.length) return false;
    return _draft[to].stageTag == _draft[_picked].stageTag;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: widget.crumb,
        title: l10n.fxReorderEffects,
        onBack: () => Navigator.of(context).pop(),
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            left: 1635,
            top: 32,
            child: Row(
              children: [
                LoopOutlinedButton(
                  key: const Key('fx_reorder_cancel'),
                  width: 125,
                  label: l10n.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 14),
                LoopOutlinedButton(
                  key: const Key('fx_reorder_done'),
                  width: 110,
                  tone: LoopButtonTone.accent,
                  label: l10n.done,
                  onTap: () => Navigator.of(context).pop(
                    [for (final card in _draft) card.id],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 36,
            top: 172,
            right: 36,
            height: 488,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _draft.length; i++) ...[
                    if (i > 0) _gap(i),
                    _Card(
                      key: Key('fx_reorder_${_draft[i].id}'),
                      card: _draft[i],
                      position: i + 1,
                      total: _draft.length,
                      picked: i == _picked,
                      width: _cardWidth,
                      height: _cardHeight,
                      onTap: () => setState(() => _picked = i),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            left: 36,
            top: 604,
            right: 36,
            height: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LoopOutlinedButton(
                  key: const Key('fx_move_left'),
                  width: 184,
                  leadingIcon: LucideIcons.arrowLeft,
                  label: l10n.fxMoveLeft,
                  onTap: _canMove(-1) ? () => _move(-1) : null,
                ),
                const SizedBox(width: 16),
                LoopOutlinedButton(
                  key: const Key('fx_move_right'),
                  width: 199,
                  leadingIcon: LucideIcons.arrowRight,
                  label: l10n.fxMoveRight,
                  onTap: _canMove(1) ? () => _move(1) : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The space before card [i]: the plain cable, or nothing where the strip
  /// breaks between the two stages.
  Widget _gap(int i) => SizedBox(
    width: _cardGap,
    height: _cardHeight,
    child: _draft[i - 1].stageTag == _draft[i].stageTag
        ? Center(
            child: Container(
              key: Key('fx_reorder_cable_$i'),
              height: 3,
              color: context.surface.borderStrong,
            ),
          )
        : null,
  );
}

/// One card: its position, its artwork, its name and the grip that says it
/// can be moved.
class _Card extends StatelessWidget {
  const _Card({
    required this.card,
    required this.position,
    required this.total,
    required this.picked,
    required this.width,
    required this.height,
    required this.onTap,
    super.key,
  });

  final FxReorderCard card;
  final int position;
  final int total;
  final bool picked;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tag = card.stageTag;
    return Semantics(
      button: true,
      selected: picked,
      label: context.l10n.fxOrderPosition(card.name, position, total),
      child: Material(
        color: picked ? surface.accentSurface : surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: picked ? surface.accent : surface.borderSubtle,
            width: picked ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: Padding(
              padding: const EdgeInsets.all(25),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText(
                    tag == null
                        ? _ordinal(position)
                        : '${_ordinal(position)} · $tag',
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontFamily: SurfaceTheme.monoFont,
                      fontSize: 20,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: card.art == null
                        ? Center(
                            child: Icon(
                              LucideIcons.audioWaveform,
                              size: 56,
                              color: surface.textTertiary,
                            ),
                          )
                        : Image.asset(
                            card.art!,
                            package: FxCatalogueLoader.package,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                  const SizedBox(height: 20),
                  AppText(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 24,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Icon(
                    LucideIcons.gripHorizontal,
                    size: 28,
                    color: surface.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The pen prints positions two-digit in the mono face.
  static String _ordinal(int position) => position.toString().padLeft(2, '0');
}
