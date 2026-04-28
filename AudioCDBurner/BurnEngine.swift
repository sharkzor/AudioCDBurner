import Foundation
import DiscRecording
import Combine

/// Forwards DRNotificationCenter callbacks (which are selector-based) into a
/// Swift closure. Required because DRNotificationCenter is the only center
/// that actually posts DiscRecording notifications.
private final class DRObserverShim: NSObject {
    let handler: (Notification) -> Void
    init(_ handler: @escaping (Notification) -> Void) { self.handler = handler }
    @objc func handle(_ note: Notification) { handler(note) }
}

@MainActor
final class BurnModel: ObservableObject {
    // MARK: - Track list
    @Published var items: [AudioItem] = []
    @Published var discTitle: String = ""

    // MARK: - Burn options
    @Published var gapMode: GapMode = .twoSeconds
    @Published var selectedDeviceID: String?
    @Published var selectedSpeedKBps: Int = 0   // 0 = "max supported"

    // MARK: - Status
    enum Phase { case idle, decoding, burning, success, failure }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""

    // MARK: - Derived
    var totalDuration: TimeInterval { items.reduce(0) { $0 + $1.duration } }
    var overCapacity: Bool { totalDuration > cdCapacitySeconds }
    var nearCapacity: Bool { totalDuration > cdSoftLimitSeconds && !overCapacity }

    // MARK: - List management

    /// URLs we've called startAccessingSecurityScopedResource() on. We have to
    /// keep this until the URL is removed from the list, otherwise sandboxed
    /// reads (AVAudioFile, AVAssetReader) will silently fail.
    private var scopedURLs: [URL: Bool] = [:]

    func addFiles(_ urls: [URL]) {
        let allowed: Set<String> = ["mp3","m4a","aac","aif","aiff","wav","wave","flac","caf","alac","mp4"]
        var added = 0
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard allowed.contains(ext) else { continue }
            if items.contains(where: { $0.url == u }) { continue }

            // Start security-scoped access (no-op for non-scoped URLs, returns
            // false). Keep it open for the lifetime of the item.
            if scopedURLs[u] == nil {
                scopedURLs[u] = u.startAccessingSecurityScopedResource()
            }

            items.append(AudioItem.from(url: u))
            added += 1
        }
        if added > 0 { statusMessage = "Added \(added) file\(added == 1 ? "" : "s")." }

        // Auto-fill disc title from the first track's album tag if user
        // hasn't typed one yet.
        if discTitle.isEmpty,
           let album = items.first?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !album.isEmpty {
            discTitle = String(album.prefix(cdTextMaxChars))
        }
    }

    func remove(at offsets: IndexSet) {
        for idx in offsets {
            let u = items[idx].url
            if scopedURLs[u] == true { u.stopAccessingSecurityScopedResource() }
            scopedURLs.removeValue(forKey: u)
        }
        items.remove(atOffsets: offsets)
    }
    func move(from source: IndexSet, to destination: Int) { items.move(fromOffsets: source, toOffset: destination) }

    deinit {
        for (u, started) in scopedURLs where started {
            u.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Burn pipeline
    private var burnTask: Task<Void, Never>?
    private var activeBurn: DRBurn?
    private var burnObserverShim: DRObserverShim?
    private var tempDir: URL?

    func startBurn(using device: DRDevice) {
        guard !items.isEmpty else { return }
        guard phase == .idle || phase == .success || phase == .failure else { return }

        phase = .decoding
        progress = 0
        statusMessage = "Preparing audio…"
        let snapshot = items
        let title = String(discTitle.prefix(cdTextMaxChars))
        let gap = gapMode
        let speed = selectedSpeedKBps

        burnTask = Task { [weak self] in
            await self?.runBurn(items: snapshot, title: title, gap: gap, device: device, speedKBps: speed)
        }
    }

    func cancel() {
        // Cancelling the Task aborts decoding; if we're already burning, also
        // tell the drive to stop. A drive abort produces a Failed status.
        burnTask?.cancel()
        activeBurn?.abort()
    }

    // MARK: - Internal worker

    private func runBurn(items: [AudioItem],
                         title: String,
                         gap: GapMode,
                         device: DRDevice,
                         speedKBps: Int) async {

        // 1. Decode every track to a CD-DA AIFF in a temporary directory.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCDBurner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.tempDir = tmp

        var decoded: [DecodedTrack] = []
        for (i, item) in items.enumerated() {
            if Task.isCancelled { fail("Cancelled."); cleanup(); return }
            phase = .decoding
            progress = Double(i) / Double(items.count)
            statusMessage = "Decoding \(i+1)/\(items.count): \(item.displayName)"

            do {
                let url = item.url
                let d = try await Task.detached(priority: .userInitiated) { () throws -> DecodedTrack in
                    try AudioDecoder.decodeToCDA(source: url, tmpDir: tmp)
                }.value
                decoded.append(d)
            } catch {
                fail("Decode error on \(item.displayName): \(error.localizedDescription)")
                cleanup()
                return
            }
        }

        // 2. Build DRTracks from the decoded AIFFs.
        var drTracks: [DRTrack] = []
        for (i, d) in decoded.enumerated() {
            // Public DiscRecording API takes a *path*, not a URL.
            guard let t = DRTrack(forAudioFile: d.aiffURL.path) else {
                fail("Cannot create DRTrack for track \(i+1).")
                cleanup()
                return
            }

            if i > 0 && gap == .gapless {
                var props = t.properties() ?? [:]
                if let zeroMSF = DRMSF(frames: 0) {
                    props[DRPreGapLengthKey as AnyHashable] = zeroMSF
                    t.setProperties(props as NSDictionary as! [AnyHashable: Any])
                }
            }
            drTracks.append(t)
        }

        // 3. Configure DRBurn.
        guard let burn = DRBurn(device: device) else {
            fail("Cannot create burn session for device.")
            cleanup()
            return
        }
        var burnProps: [AnyHashable: Any] = [:]
        burnProps[DRBurnCompletionActionKey as AnyHashable] = DRBurnCompletionActionEject
        burnProps[DRBurnFailureActionKey   as AnyHashable] = DRBurnFailureActionEject
        burnProps[DRBurnVerifyDiscKey      as AnyHashable] = NSNumber(value: false)
        burnProps[DRBurnUnderrunProtectionKey as AnyHashable] = NSNumber(value: true)
        if speedKBps > 0 {
            burnProps[DRBurnRequestedSpeedKey as AnyHashable] = NSNumber(value: Float(speedKBps))
        } else {
            burnProps[DRBurnRequestedSpeedKey as AnyHashable] = NSNumber(value: Float(DRDeviceBurnSpeedMax))
        }

        // 4. CD-Text (disc title only). Index 0 is the disc, indices 1...n are tracks.
        if !title.isEmpty {
            if let block = DRCDTextBlock(language: "English",
                                         encoding: String.Encoding.isoLatin1.rawValue) {
                var dicts: [[String: Any]] = Array(repeating: [:], count: drTracks.count + 1)
                dicts[0][DRCDTextTitleKey] = title
                block.setTrackDictionaries(dicts)
                burnProps[DRCDTextKey as AnyHashable] = [block]
            }
        }
        burn.setProperties(burnProps as NSDictionary as! [AnyHashable: Any])
        self.activeBurn = burn

        // 5. Subscribe to burn-status notifications via DRNotificationCenter.
        let drCenter = DRNotificationCenter.currentRunLoop()
        let shim = DRObserverShim { [weak self] note in
            Task { @MainActor in self?.handleBurnStatus(note) }
        }
        self.burnObserverShim = shim
        drCenter?.addObserver(shim,
                             selector: #selector(DRObserverShim.handle(_:)),
                             name: NSNotification.Name.DRBurnStatusChanged.rawValue,
                             object: burn)

        phase = .burning
        progress = 0
        statusMessage = "Burning…"

        // 6. Start the burn. writeLayout returns void; status is observed.
        burn.writeLayout(drTracks as NSArray)

        // 7. Wait for terminal state. Polling acts as a safety net alongside the
        //    notification observer.
        while !Task.isCancelled {
            let st: [AnyHashable: Any] = burn.status() ?? [:]
            let state = (st[DRStatusStateKey as AnyHashable] as? String) ?? ""
            if state == (DRStatusStateDone as String) || state == (DRStatusStateFailed as String) {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        drCenter?.removeObserver(shim, name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
        self.burnObserverShim = nil
        self.activeBurn = nil
        cleanup()
    }

    private func handleBurnStatus(_ note: Notification) {
        let burn = (note.object as? DRBurn) ?? activeBurn
        guard let st = burn?.status() else { return }
        let state = (st[DRStatusStateKey as AnyHashable] as? String) ?? ""
        let pct   = (st[DRStatusPercentCompleteKey as AnyHashable] as? NSNumber)?.doubleValue ?? 0
        progress = pct
        if state == (DRStatusStateDone as String) {
            phase = .success
            statusMessage = "Burn complete. Disc ejecting."
        } else if state == (DRStatusStateFailed as String) {
            phase = .failure
            let err = st[DRErrorStatusKey as AnyHashable] as? [AnyHashable: Any]
            let msg = (err?[DRErrorStatusErrorStringKey as AnyHashable] as? String) ?? "Burn failed."
            statusMessage = msg
        } else if !state.isEmpty {
            statusMessage = state
        }
    }

    private func cleanup() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
    }

    private func fail(_ msg: String) {
        phase = .failure
        statusMessage = msg
    }
}
