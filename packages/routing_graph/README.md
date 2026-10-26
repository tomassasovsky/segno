# routing_graph

Flutter UI library for drawing routing graphs: a zoom and pan canvas
(`GraphCanvas`), wires (`GraphEdge`, `GraphEdgePainter`), hardware port chips
(`ChannelChip`), an accessible tap target (`FocusableTapTarget`), and geometry
helpers (`cardColumnXs`, `chainEdges`, `fanEdges`, `positionedNode`). Neutral
colors come from the `RoutingGraphTheme` theme extension. It has no Segno
domain types.

The app registers `RoutingGraphTheme` in `lib/theme/app_theme.dart` and uses
`FocusableTapTarget` in the looper and control views and the console surface.
The canvas, wire and chip widgets currently have no caller outside this
package.

## Usage

```dart
import 'package:routing_graph/routing_graph.dart';

final theme = ThemeData(
  extensions: const [
    RoutingGraphTheme(
      background: Color(0xFF0E0E10),
      surface: Color(0xFF16161A),
      card: Color(0xFF1E1E24),
      cardHigh: Color(0xFF26262E),
      line: Color(0xFF3A3A44),
      textPrimary: Color(0xFFF2F2F5),
      textSecondary: Color(0xFFB0B0B8),
      textTertiary: Color(0xFF70707A),
    ),
  ],
);

FocusableTapTarget(
  onTap: onSelect,
  semanticLabel: 'Track 1',
  selected: isSelected,
  child: const TrackTile(),
);
```

In a widget, read the tokens with `context.routingGraph`, for example
`context.routingGraph.card`.

## Notes

- The barrel re-exports `package:flutter/material.dart`.
- Only neutral colors are in the theme. Semantic colors, such as a lane color
  or a wet or dry send, are constructor parameters on each widget.
- `FocusableTapTarget` is keyboard focusable, activates on Enter and Space,
  draws a focus ring, and reports a button role to screen readers. It uses no
  `InkWell`, so it can sit directly in a `Stack`.
- `GraphCanvas` fits its content once and fits again only when `fitIdentity`
  changes. It always shows zoom and fit buttons as an alternative to dragging.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
