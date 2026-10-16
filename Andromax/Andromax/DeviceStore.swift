import Foundation
import IOKit
import IOKit.usb

/// Fires whenever a USB device is plugged in or removed, and describes what is on the bus.
final class USBWatcher {
    struct Info {
        let bus: UInt32
        let address: UInt8
        let serial: String?
        let vendor: String?
        let product: String?
        /// The phone currently exposes a file-transfer (MTP/PTP) interface, i.e. it isn't in "charging only".
        let offersMTP: Bool
    }

    var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { context, iterator in
            USBWatcher.drain(iterator)
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onChange?()
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let context = Unmanaged.passUnretained(self).toOpaque()
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOUSBHostDevice"), callback, context, &iterator) == KERN_SUCCESS {
                // The notification only arms once the iterator has been emptied.
                USBWatcher.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }

    /// Still-image class (6) is what modern Android uses for MTP; older phones use a vendor interface named "MTP".
    private static func offersMTP(_ device: io_object_t) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            let interfaceClass = IORegistryEntryCreateCFProperty(child, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let name = IORegistryEntryCreateCFProperty(child, "USB Interface Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if interfaceClass?.intValue == 6 || name?.contains("MTP") == true { return true }
        }
        return false
    }

    /// Bus number and address use the same scheme as libusb, so they line up with `MTPRef`.
    static func snapshot() -> [Info] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [Info] = []
        while case let object = IOIteratorNext(iterator), object != 0 {
            defer { IOObjectRelease(object) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(object, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let location = property("locationID") as? NSNumber,
                  let address = property("USB Address") as? NSNumber else { continue }
            result.append(Info(
                bus: location.uint32Value >> 24,
                address: address.uint8Value,
                serial: property("USB Serial Number") as? String,
                vendor: property("USB Vendor Name") as? String,
                product: property("USB Product Name") as? String,
                offersMTP: offersMTP(object)))
        }
        return result
    }
}

/// Watches ADB and MTP and publishes one entry per physical phone.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [PhoneDevice] = []
    @Published private(set) var adbMissing = false
    @Published private(set) var adbInstalling = false

    private struct ADBEntry: Equatable {
        let serial: String
        let state: String
        let model: String?
    }

    private struct MTPEntry: Equatable {
        let ref: MTPRef
        let serial: String?
        let name: String?
    }

    private let usb = USBWatcher()
    private var adbEntries: [ADBEntry] = []
    private var mtpEntries: [MTPEntry] = []
    private var adbNames: [String: String] = [:]
    private var started = false
    private var mtpScan: Task<Void, Never>?
    private var removalChecks = 0

    func start() {
        guard !started else { return }
        started = true

        usb.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleMTPScan() }
        }
        usb.start()
        scheduleMTPScan(delay: 0)

        Task {
            if !ADB.isAvailable {
                adbInstalling = true
                do {
                    try await ADB.install()
                } catch {
                    NSLog("Andromax: adb install failed: \(error.localizedDescription)")
                }
                adbInstalling = false
            }
            adbMissing = !ADB.isAvailable
            guard ADB.isAvailable else { return }
            while true {
                await refreshADB()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - MTP

    /// Phones re-enumerate a couple of times while switching USB mode, so wait for the bus to settle.
    private func scheduleMTPScan(delay: Double = 0.8) {
        mtpScan?.cancel()
        mtpScan = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            let detected = await MTP.detect()
            if Task.isCancelled { return }
            let bus = USBWatcher.snapshot()
            var entries = detected.map { device in
                let info = bus.first { $0.bus == device.ref.bus && $0.address == device.ref.address }
                let name = Self.displayName(vendor: info?.vendor, product: info?.product)
                    ?? Self.displayName(vendor: device.vendor, product: device.product)
                return MTPEntry(ref: device.ref, serial: info?.serial, name: name)
            }
            // libmtp can miss a phone that is busy with our own session; trust the bus while the
            // phone still offers file transfer there.
            for old in mtpEntries where !entries.contains(where: { $0.serial == old.serial }) {
                if let serial = old.serial, let info = bus.first(where: { $0.serial == serial && $0.offersMTP }) {
                    entries.append(MTPEntry(ref: MTPRef(bus: info.bus, address: info.address), serial: serial, name: old.name))
                }
            }
            // Opening a session can reset the phone's USB link, sometimes more than once; only
            // believe it left after a couple of later looks agree, or the browser drops a working session.
            let vanished = mtpEntries.contains { old in !entries.contains { $0.serial == old.serial } }
            if vanished && removalChecks < 2 {
                removalChecks += 1
                scheduleMTPScan(delay: 3)
                return
            }
            removalChecks = 0
            mtpEntries = entries
            merge()
        }
    }

    // MARK: - ADB

    private func refreshADB() async {
        let result = await ADB.run(["devices", "-l"])
        guard result.status == 0 else { return }
        let entries = Self.parseDevices(result.out)
        for entry in entries where entry.state == "device" && adbNames[entry.serial] == nil {
            let props = await ADB.shell(entry.serial, "getprop ro.product.brand; getprop ro.product.model")
            let lines = props.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if props.status == 0, lines.count >= 2 {
                adbNames[entry.serial] = Self.displayName(vendor: lines[0].capitalized, product: lines[1])
            }
        }
        if entries != adbEntries {
            adbEntries = entries
        }
        merge()
    }

    private static func parseDevices(_ output: String) -> [ADBEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            if line.hasPrefix("List of devices") || line.hasPrefix("*") { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: " ")
            return ADBEntry(serial: String(fields[0]), state: String(fields[1]), model: model)
        }
    }

    // MARK: - Merge

    /// A phone in File Transfer mode with USB debugging on shows up on both sides with the same
    /// USB serial number; fold those into a single device.
    private func merge() {
        var merged: [PhoneDevice] = []
        var claimed = Set<String>()

        for entry in mtpEntries {
            let adb = adbEntries.first { $0.serial == entry.serial }
            if let adb { claimed.insert(adb.serial) }
            merged.append(PhoneDevice(
                id: entry.serial ?? "usb-\(entry.ref.bus)-\(entry.ref.address)",
                name: adb.flatMap(name(for:)) ?? entry.name ?? "Android Phone",
                adbSerial: adb?.serial,
                adbState: adb?.state,
                mtp: entry.ref))
        }
        for adb in adbEntries where !claimed.contains(adb.serial) {
            merged.append(PhoneDevice(
                id: adb.serial,
                name: name(for: adb) ?? adb.serial,
                adbSerial: adb.serial,
                adbState: adb.state,
                mtp: nil))
        }
        if merged != devices {
            devices = merged
        }
    }

    private func name(for entry: ADBEntry) -> String? {
        adbNames[entry.serial] ?? entry.model
    }

    private static func displayName(vendor: String?, product: String?) -> String? {
        let vendor = vendor?.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
        let product = product?.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
        if product.isEmpty { return vendor.isEmpty ? nil : vendor }
        if vendor.isEmpty || product.lowercased().hasPrefix(vendor.lowercased()) { return product }
        return "\(vendor) \(product)"
    }
}
