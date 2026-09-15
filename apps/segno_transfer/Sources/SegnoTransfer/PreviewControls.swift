import SwiftUI

struct PreviewControls: View {
  @ObservedObject var player: PreviewPlayer
  let title: String
  let close: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button {
        player.playPause()
      } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(
          width: 22, height: 22)
      }.accessibilityLabel(player.isPlaying ? "Pause preview" : "Play preview").disabled(
        player.duration <= 0)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.callout.weight(.medium)).lineLimit(1)
        if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
        HStack {
          Text(PreviewPlayer.timeLabel(player.position)).monospacedDigit().font(.caption)
          Slider(
            value: Binding(get: { player.position }, set: { player.seek($0) }),
            in: 0...max(1, player.duration)
          )
          .accessibilityLabel("Preview position").disabled(player.duration <= 0)
          Text(PreviewPlayer.timeLabel(player.duration)).monospacedDigit().font(.caption)
        }
      }
      Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(
        "Close preview")
    }.padding(16).background(.quaternary.opacity(0.5))
  }
}
