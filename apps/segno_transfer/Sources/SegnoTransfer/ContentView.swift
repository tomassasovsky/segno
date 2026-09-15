import SwiftUI
import TransferCore

struct ContentView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      connectionBar
      Divider()
      HSplitView {
        browser.frame(minWidth: 290, idealWidth: 340, maxWidth: 410)
        detail.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error = model.error {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          ScrollView {
            Text(error).font(.callout).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 72)
          Button {
            model.error = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(14).background(Color.orange.opacity(0.08))
      }
      Divider()
      if let title = model.previewTitle {
        PreviewControls(player: model.previewPlayer, title: title, close: model.closePreview)
        Divider()
      }
      downloadBar
    }
    .sheet(isPresented: $model.settingsPresented) { connectionSettings }
  }

  private var connectionBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform").font(.system(size: 27, weight: .medium)).foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Segno Transfer").font(.title3.weight(.semibold))
        Text("Your performances, on your Mac").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      TextField("Appliance address", text: $model.connection.host)
        .textFieldStyle(.roundedBorder).frame(width: 190)
        .disabled(model.busy).onSubmit { model.connect() }.accessibilityIdentifier(
          "applianceAddress")
      Button(model.connected ? "Refresh" : "Connect") { model.connect() }
        .disabled(model.busy).keyboardShortcut("r", modifiers: .command)
      Button {
        model.settingsPresented = true
      } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .help("Connection settings").accessibilityLabel("Connection settings").disabled(model.busy)
    }.padding(20)
  }

  private var browser: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("PERFORMANCES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Menu("Select") {
          Button("Main recordings shown") {
            for recording in model.visibleRecordings { model.selectMain(recording, true) }
          }
          Button("Deselect all") { model.selected.removeAll() }
        }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy || model.recordings.isEmpty)
      }.padding([.horizontal, .top], 16).padding(.bottom, 10)
      TextField("Search recordings", text: $model.search).textFieldStyle(.roundedBorder).padding(
        .horizontal, 14
      ).padding(.bottom, 10)
      List(selection: $model.focusedID) {
        ForEach(model.visibleRecordings) { recording in
          HStack(alignment: .top, spacing: 10) {
            Toggle(
              "Select \(recording.name)",
              isOn: Binding(
                get: { model.hasSelection(recording) }, set: { model.selectMain(recording, $0) })
            )
            .labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 6) {
              Text(recording.date.formatted(date: .abbreviated, time: .shortened)).font(
                .body.weight(.medium))
              Text(recording.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              Text("\(recording.durationLabel) · \(recording.files.count) audio files").font(
                .caption
              ).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 7).tag(recording.id)
        }
      }.listStyle(.sidebar)
      Text(model.status).font(.caption).foregroundStyle(.secondary).padding(16).textSelection(
        .enabled)
    }
  }

  @ViewBuilder private var detail: some View {
    if let recording = model.focused {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text(recording.date.formatted(date: .long, time: .shortened)).font(
            .title2.weight(.semibold))
          Text("\(recording.durationLabel) · Choose the audio you want to keep").foregroundStyle(
            .secondary)
          HStack {
            Button("Main recording only") {
              model.selectMain(recording, false)
              model.selectMain(recording, true)
            }
            Button("Select all audio") {
              for file in recording.files { model.toggle(recording, file, selected: true) }
            }
            Spacer()
          }.padding(.top, 8).disabled(model.busy)
        }.padding(24)
        Divider()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(recording.files) { file in
              AudioFileRow(model: model, recording: recording, file: file)
              Divider().padding(.leading, 54)
            }
          }.padding(.horizontal, 20)
        }
        Text("Names apply to your downloaded copies. Matching filenames get a numbered suffix.")
          .font(.caption).foregroundStyle(.secondary).padding(20)
      }
    } else {
      ContentUnavailableView(
        model.busy ? "Loading recordings" : "Your recordings belong here",
        systemImage: "waveform",
        description: Text(
          model.busy
            ? "Reading the appliance's recording list…"
            : "Connect to your appliance, then choose a performance to see its audio files."))
    }
  }

  private var downloadBar: some View {
    VStack(spacing: 12) {
      if model.busy {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text(model.progressTitle).font(.callout).lineLimit(1)
            ProgressView(value: model.progress).progressViewStyle(.linear)
          }
          Button("Cancel") { model.cancel() }
        }
      }
      HStack(spacing: 12) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text("Save to \(model.destination.lastPathComponent)").font(.callout.weight(.medium))
          Text(model.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle)
        }
        Button("Change…") { model.chooseFolder() }.disabled(model.busy)
        Spacer()
        if !model.downloaded.isEmpty { Button("Show in Finder") { model.reveal() } }
        VStack(alignment: .trailing, spacing: 3) {
          Button(
            "Download \(model.selection.count) \(model.selection.count == 1 ? "file" : "files")"
          ) { model.download() }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .disabled(model.busy || model.selection.isEmpty || !model.connected)
          .accessibilityIdentifier("downloadSelection")
          Text(ByteCountFormatter.string(fromByteCount: model.selectionBytes, countStyle: .file))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.padding(18)
  }

  private var connectionSettings: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connection settings").font(.title2.weight(.semibold))
      Text("Use the same connection details and SSH key you use for your appliance.")
        .foregroundStyle(.secondary)
      Form {
        TextField("Appliance", text: $model.connection.host)
        TextField("Username", text: $model.connection.user)
        TextField("Recordings folder", text: $model.connection.root)
        HStack {
          TextField("SSH key (optional)", text: $model.connection.identityFile)
          Button("Choose…") { model.chooseIdentity() }
        }
      }.textFieldStyle(.roundedBorder)
      Text(
        "Leave the key blank to use your Mac's SSH configuration and key agent. The appliance's identity must already be trusted by SSH."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Done") { model.settingsPresented = false }.keyboardShortcut(.defaultAction)
      }
    }.padding(26).frame(width: 540)
  }
}

private struct AudioFileRow: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  let file: RecordingFile

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Toggle(
        "Select \(file.role)",
        isOn: Binding(
          get: { model.isSelected(recording, file) },
          set: { model.toggle(recording, file, selected: $0) })
      )
      .labelsHidden().toggleStyle(.checkbox).padding(.top, 3).disabled(model.busy)
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text(file.role).font(.body.weight(.medium))
          Spacer()
          Text(file.sizeLabel).font(.callout).foregroundStyle(.secondary)
          Button {
            model.preparePreview(recording, file)
          } label: {
            Image(systemName: "play.circle")
          }
          .buttonStyle(.plain).font(.title3).accessibilityLabel("Preview \(file.role)").help(
            "Listen before downloading"
          ).disabled(model.busy)
        }
        Text(file.path).font(.caption).foregroundStyle(.secondary)
        if model.isSelected(recording, file) {
          HStack(spacing: 8) {
            Text("Save as").font(.caption).foregroundStyle(.secondary)
            TextField(
              "Download filename",
              text: Binding(
                get: { model.name(recording, file) },
                set: { model.names[model.key(recording, file)] = $0 })
            )
            .textFieldStyle(.roundedBorder).disabled(model.busy)
            .accessibilityLabel("Download name for \(file.role)")
          }
        }
      }
    }.padding(.vertical, 16)
  }
}
