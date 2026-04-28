import Foundation
import DiscRecording
import Combine

/// Wraps a DRDevice for SwiftUI display.
struct BurnerDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let writesCD: Bool
    let supportedSpeedsKBps: [Int]
    let device: DRDevice

    /// 1x CD-DA = 176.4 kB/s.
    static func multiplier(forKBps k: Int) -> Double { Double(k) / 176.4 }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: BurnerDevice, r: BurnerDevice) -> Bool { l.id == r.id }
}

/// Discovers and tracks CD/DVD burners on the system. Updates publish on the main thread.
///
/// IMPORTANT: DiscRecording posts its notifications on `DRNotificationCenter`, not
/// Foundation's default NotificationCenter. We therefore subscribe via the run-loop
/// DR center using selector-based observation.
@MainActor
final class DeviceManager: NSObject, ObservableObject {
    @Published private(set) var devices: [BurnerDevice] = []

    private let drCenter: DRNotificationCenter? = DRNotificationCenter.currentRunLoop()

    override init() {
        super.init()
        drCenter?.addObserver(self,
                             selector: #selector(handleDRNotification(_:)),
                             name: NSNotification.Name.DRDeviceAppeared.rawValue,
                             object: nil)
        drCenter?.addObserver(self,
                             selector: #selector(handleDRNotification(_:)),
                             name: NSNotification.Name.DRDeviceDisappeared.rawValue,
                             object: nil)
        drCenter?.addObserver(self,
                             selector: #selector(handleDRNotification(_:)),
                             name: NSNotification.Name.DRDeviceStatusChanged.rawValue,
                             object: nil)
        refresh()
    }

    deinit {
        drCenter?.removeObserver(self, name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
        drCenter?.removeObserver(self, name: NSNotification.Name.DRDeviceDisappeared.rawValue, object: nil)
        drCenter?.removeObserver(self, name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: nil)
    }

    @objc private func handleDRNotification(_ note: Notification) {
        // DR notifications are delivered on the run loop they were registered on
        // (the main run loop here), so we can update @Published directly.
        refresh()
    }

    /// Force re-enumeration of attached optical drives.
    func refresh() {
        let drives = (DRDevice.devices() as? [DRDevice]) ?? []
        var out: [BurnerDevice] = []
        for drive in drives {
            let info   = drive.info() ?? [:]
            let status = drive.status() ?? [:]

            let name   = (info[DRDeviceProductNameKey] as? String) ?? "Optical Drive"
            let vendor = (info[DRDeviceVendorNameKey]  as? String) ?? ""

            var writesCD = false
            if let caps = info[DRDeviceWriteCapabilitiesKey] as? [String: Any] {
                writesCD = (caps[DRDeviceCanWriteCDKey] as? Bool) ?? false
            }

            // DRDeviceBurnSpeedsKey is at the top level of status(), not inside mediaInfo.
            let speeds = (status[DRDeviceBurnSpeedsKey] as? [NSNumber])?
                .map { $0.intValue }.sorted() ?? []

            let id = (info[DRDeviceIORegistryEntryPathKey] as? String)
                ?? "\(vendor)-\(name)"

            out.append(BurnerDevice(id: id,
                                    name: vendor.isEmpty ? name : "\(vendor) \(name)",
                                    writesCD: writesCD,
                                    supportedSpeedsKBps: speeds,
                                    device: drive))
        }
        self.devices = out
    }
}
