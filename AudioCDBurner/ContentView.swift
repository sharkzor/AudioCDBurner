import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: BurnModel
    @StateObject private var devices = DeviceManager()

    @State private var selection = Set<UUID>()
    @State private var showingFileImporter = false

    var body: some View {
        VStack(spacing: 12) {
            header
            tracksTable
            footer
            burnPanel
        }
        .padding(14)
        .onAppear { autoSelectDevice(devices.devices) }
        .onChange(of: devices.devices) { _, newValue in
            if let id = model.selectedDeviceID,
               !newValue.contains(where: { $0.id == id }) {
                model.selectedDeviceID = nil
                model.selectedSpeedKBps = 0
            }
            autoSelectDevice(newValue)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: Self.allowedAudioTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Disc title (CD-Text, max \(cdTextMaxChars) chars)", text: Binding(
                get: { model.discTitle },
                set: { model.discTitle = String($0.prefix(cdTextMaxChars)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            Spacer()

            Button {
                showingFileImporter = true
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            Button(role: .destructive) {
                let toRemove = IndexSet(model.items.enumerated()
                    .filter { selection.contains($0.element.id) }
                    .map { $0.offset })
                model.remove(at: toRemove)
                selection.removeAll()
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty)
        }
    }

    // MARK: - Tracks

    private var tracksTable: some View {
        Table(model.items, selection: $selection) {
            TableColumn("#") { item in
                Text("\(model.items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? 0)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 28, ideal: 36, max: 44)

            TableColumn("Title") { item in
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableColumn("Duration") { item in
                Text(formatDuration(item.duration))
                    .monospacedDigit()
                    .foregroundColor(item.isDecodable ? .primary : .red)
            }
            .width(min: 70, ideal: 80, max: 100)

            TableColumn("Path") { item in
                Text(item.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .frame(minHeight: 220)
        .onDeleteCommand {
            let toRemove = IndexSet(model.items.enumerated()
                .filter { selection.contains($0.element.id) }
                .map { $0.offset })
            model.remove(at: toRemove)
            selection.removeAll()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .contextMenu(forSelectionType: UUID.self) { _ in
            Button("Move Up") { moveSelection(by: -1) }
            Button("Move Down") { moveSelection(by:  1) }
            Divider()
            Button("Remove", role: .destructive) {
                let toRemove = IndexSet(model.items.enumerated()
                    .filter { selection.contains($0.element.id) }.map { $0.offset })
                model.remove(at: toRemove)
                selection.removeAll()
            }
        }
        .overlay(alignment: .center) {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "opticaldisc").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("Drop audio files here, or click “Add Files…”.")
                        .foregroundStyle(.secondary)
                    Text(".flac .mp3 .aac .m4a .wav .aiff .alac")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !selection.isEmpty else { return }
        let indices = model.items.enumerated()
            .filter { selection.contains($0.element.id) }
            .map { $0.offset }
        guard let first = indices.first, let last = indices.last else { return }
        if delta < 0, first > 0 {
            model.move(from: IndexSet(indices), to: first - 1)
        } else if delta > 0, last < model.items.count - 1 {
            model.move(from: IndexSet(indices), to: last + 2)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); collected.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.addFiles(collected)
        }
        return true
    }

    // MARK: - Footer (totals + capacity)

    private var footer: some View {
        HStack {
            Text("\(model.items.count) track\(model.items.count == 1 ? "" : "s")")
            Spacer()
            Text("Total: \(formatDuration(model.totalDuration))")
                .monospacedDigit()
            Text("/ 80:00")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if model.overCapacity {
                Label("Exceeds 80-min CD", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if model.nearCapacity {
                Label("Near capacity", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    // MARK: - Burn panel

    private var burnPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Burner:", selection: Binding(
                        get: { model.selectedDeviceID ?? "" },
                        set: { model.selectedDeviceID = $0.isEmpty ? nil : $0 }
                    )) {
                        if devices.devices.isEmpty {
                            Text("No optical drive found").tag("")
                        } else {
                            ForEach(devices.devices) { d in
                                Text(d.name + (d.writesCD ? "" : "  (read-only)")).tag(d.id)
                            }
                        }
                    }
                    .frame(maxWidth: 320)

                    Button {
                        devices.refresh()
                        autoSelectDevice(devices.devices)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Picker("Speed:", selection: $model.selectedSpeedKBps) {
                        Text("Max").tag(0)
                        ForEach(currentDevice?.supportedSpeedsKBps ?? [], id: \.self) { kbps in
                            let mult = BurnerDevice.multiplier(forKBps: kbps)
                            Text(String(format: "%.0fx (%d kB/s)", mult, kbps)).tag(kbps)
                        }
                    }
                    .frame(maxWidth: 220)
                    .disabled((currentDevice?.supportedSpeedsKBps ?? []).isEmpty)

                    Picker("Gap:", selection: $model.gapMode) {
                        ForEach(GapMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(maxWidth: 180)
                }

                HStack {
                    Button {
                        if let d = currentDevice?.device { model.startBurn(using: d) }
                    } label: {
                        Label("Burn", systemImage: "flame.fill").frame(minWidth: 90)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBurn)

                    if model.phase == .decoding || model.phase == .burning {
                        ProgressView(value: model.progress)
                            .frame(maxWidth: .infinity)
                        Button("Cancel") { model.cancel() }
                    } else {
                        Spacer()
                    }
                }

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.callout)
                        .foregroundStyle(model.phase == .failure ? .red :
                                         model.phase == .success ? .green : .secondary)
                }
            }
            .padding(6)
        }
    }

    private var currentDevice: BurnerDevice? {
        guard let id = model.selectedDeviceID else { return devices.devices.first }
        return devices.devices.first(where: { $0.id == id })
    }

    /// Auto-select the first writable burner if nothing is selected yet, or
    /// fall back to the first device of any kind. Called on appear and after
    /// rescans / hot-plug events.
    private func autoSelectDevice(_ list: [BurnerDevice]) {
        if let id = model.selectedDeviceID,
           list.contains(where: { $0.id == id }) {
            return
        }
        let pick = list.first(where: { $0.writesCD }) ?? list.first
        model.selectedDeviceID = pick?.id
        model.selectedSpeedKBps = 0
    }

    private var canBurn: Bool {
        guard let d = currentDevice, d.writesCD else { return false }
        guard !model.items.isEmpty, !model.overCapacity else { return false }
        return model.phase == .idle || model.phase == .success || model.phase == .failure
    }

    // MARK: - Allowed types

    static let allowedAudioTypes: [UTType] = {
        var t: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        if let flac = UTType("org.xiph.flac") { t.append(flac) }
        if let alac = UTType("public.alac-audio") { t.append(alac) }
        return t
    }()
}
