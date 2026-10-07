import 'package:flutter/material.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Where a MIDI input stands, as its card says it.
enum MidiDeviceStatus {
  /// The input in use, delivering messages.
  connected,

  /// The input in use, while its port opens.
  connecting,

  /// The input in use, not plugged in.
  disconnected,

  /// The input in use, whose port would not open.
  openFailed,

  /// Plugged in, and not the input in use.
  available,
}

/// One MIDI input the page can configure.
class MidiDeviceCard {
  /// Creates a [MidiDeviceCard].
  const MidiDeviceCard({
    required this.id,
    required this.name,
    required this.status,
  });

  /// The device's stable identity, which its mappings name.
  final String id;

  /// What it is called.
  final String name;

  /// Where it stands.
  final MidiDeviceStatus status;

  /// Whether it is the input in use — the one whose mappings are listed.
  bool get selected => status != MidiDeviceStatus.available;

  /// Whether it is plugged in.
  bool get online =>
      status != MidiDeviceStatus.disconnected &&
      status != MidiDeviceStatus.openFailed;
}

/// The cards [connection] gives: every enumerated input, and the one in use
/// even while it is unplugged, so its mappings stay reachable.
List<MidiDeviceCard> midiDeviceCards(MidiConnection connection) {
  final selectedStatus = connection.pinUncertain
      ? MidiDeviceStatus.disconnected
      : switch (connection.status) {
          MidiConnectionStatus.connected => MidiDeviceStatus.connected,
          MidiConnectionStatus.connecting => MidiDeviceStatus.connecting,
          MidiConnectionStatus.error => MidiDeviceStatus.openFailed,
          MidiConnectionStatus.deviceGone ||
          MidiConnectionStatus.none => MidiDeviceStatus.disconnected,
        };
  return [
    for (final device in connection.devices)
      MidiDeviceCard(
        id: device.id,
        name: device.name,
        status: device.id == connection.selectedId
            ? selectedStatus
            : MidiDeviceStatus.available,
      ),
    if (connection.hasSelection && !connection.isSelectedPresent)
      MidiDeviceCard(
        id: connection.selectedId,
        name: connection.selectedName.isEmpty
            ? connection.selectedId
            : connection.selectedName,
        status: selectedStatus,
      ),
  ];
}

/// The row of MIDI inputs at the top of the MIDI controls page. Choosing one
/// makes it the input in use.
class MidiDeviceCards extends StatefulWidget {
  /// Creates a [MidiDeviceCards].
  const MidiDeviceCards({
    required this.cards,
    required this.onSelect,
    super.key,
  });

  /// The inputs, in the order the host lists them.
  final List<MidiDeviceCard> cards;

  /// Makes an input the one in use.
  final ValueChanged<String> onSelect;

  /// The pen's card.
  static const Size cardSize = Size(320, 100);

  @override
  State<MidiDeviceCards> createState() => _MidiDeviceCardsState();
}

class _MidiDeviceCardsState extends State<MidiDeviceCards> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (widget.cards.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: AppText(
          l10n.midiNoDevices,
          key: const Key('midi_no_devices'),
          style: TextStyle(color: surface.textSecondary, fontSize: 25),
        ),
      );
    }
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      trackVisibility: true,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: widget.cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (context, index) => _DeviceCard(
          card: widget.cards[index],
          onTap: () => widget.onSelect(widget.cards[index].id),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.card, required this.onTap});

  final MidiDeviceCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final status = switch (card.status) {
      MidiDeviceStatus.connected => l10n.midiDeviceConnected,
      MidiDeviceStatus.connecting => l10n.midiDeviceConnecting,
      MidiDeviceStatus.disconnected => l10n.midiDeviceDisconnected,
      MidiDeviceStatus.openFailed => l10n.midiDeviceOpenFailed,
      MidiDeviceStatus.available => l10n.midiDeviceAvailable,
    };
    return Semantics(
      button: true,
      selected: card.selected,
      label: card.name,
      value: status,
      onTap: onTap,
      excludeSemantics: true,
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          key: Key('midi_device_${card.id}'),
          color: card.selected ? surface.accentSurface : surface.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: card.selected ? surface.accent : surface.borderSubtle,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.fromSize(
              size: MidiDeviceCards.cardSize,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: card.online
                            ? surface.textPrimary
                            : surface.textMuted,
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            card.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 25,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          AppText(
                            status,
                            maxLines: 1,
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 18,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
