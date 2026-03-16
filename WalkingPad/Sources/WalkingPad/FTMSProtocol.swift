import Foundation
import CoreBluetooth

// MARK: - FTMS Protocol (Fitness Machine Service)
//
// Standard BLE Fitness Machine Service (UUID 0x1826).
// Tested with KingSmith Z1D. Also supports vendor step count via FFC0/FFF0.
//
// BLE Service: 0x1826 (FTMS)
//   0x2ACD — Treadmill Data (notify)
//   0x2ADA — Machine Status (notify)
//   0x2AD9 — Control Point (write + notify)
//   0x2AD4 — Supported Speed Range (read)
//   0x2AD3 — Training Status (notify)
//   0x2ACC — Fitness Machine Feature (read)
//
// Control Point opcodes:
//   0x00 — Request control
//   0x02 [speed_le16] — Set target speed (hundredths km/h)
//   0x07 — Start/resume
//   0x08 0x01 — Stop
//   0x08 0x02 — Pause
//
// Treadmill Data (0x2ACD): flags(u16) + fields per FTMS spec
//   bit 0 clear: instantaneous speed (u16, /100 km/h)
//   bit 1: avg speed
//   bit 2: total distance (u24)
//   bit 7: expended energy
//   bit 10: elapsed time

class FTMSProtocol: TreadmillProtocol {
    static let namePatterns = ["walkingpad", "kingsmith", "ks-", "ph-"]

    var modelName: String { "FTMS Treadmill" }
    var speedRange: SpeedRange { _speedRange }

    private weak var peripheral: CBPeripheral?
    private var controlPointChar: CBCharacteristic?
    private var vendorWriteChar1: CBCharacteristic?
    private var vendorWriteChar2: CBCharacteristic?
    private var hasRequestedControl = false
    private var pendingStartSpeed: Double?
    private var _speedRange = SpeedRange()
    private var lastBeltState: BeltState = .idle
    private(set) var vendorSteps: Int = 0

    private let ftmsServiceUUID    = CBUUID(string: "1826")
    private let treadmillDataUUID  = CBUUID(string: "2ACD")
    private let machineStatusUUID  = CBUUID(string: "2ADA")
    private let controlPointUUID   = CBUUID(string: "2AD9")
    private let speedRangeUUID     = CBUUID(string: "2AD4")
    private let trainingStatusUUID = CBUUID(string: "2AD3")
    private let machineFeatureUUID = CBUUID(string: "2ACC")

    // Vendor services for KingSmith step count (optional bonus)
    private let vendorService1UUID = CBUUID(string: "FFC0")
    private let vendorNotify1UUID  = CBUUID(string: "FFC1")
    private let vendorWrite1UUID   = CBUUID(string: "FFC2")
    private let vendorService2UUID = CBUUID(string: "FFF0")
    private let vendorNotify2UUID  = CBUUID(string: "FFF1")
    private let vendorWrite2UUID   = CBUUID(string: "FFF2")

    func configure(peripheral: CBPeripheral, services: [CBService]) -> Bool {
        guard let service = services.first(where: { $0.uuid == ftmsServiceUUID }) else {
            return false
        }
        var foundControl = false
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case treadmillDataUUID, machineStatusUUID, trainingStatusUUID:
                peripheral.setNotifyValue(true, for: char)
            case controlPointUUID:
                controlPointChar = char
                peripheral.setNotifyValue(true, for: char)
                foundControl = true
            case speedRangeUUID, machineFeatureUUID:
                peripheral.readValue(for: char)
            default:
                break
            }
        }
        guard foundControl else { return false }
        self.peripheral = peripheral

        // Subscribe to vendor services for step count (optional, KingSmith bonus)
        for vendorService in services {
            if vendorService.uuid == vendorService1UUID || vendorService.uuid == vendorService2UUID {
                for char in vendorService.characteristics ?? [] {
                    switch char.uuid {
                    case vendorNotify1UUID, vendorNotify2UUID:
                        peripheral.setNotifyValue(true, for: char)
                    case vendorWrite1UUID:
                        vendorWriteChar1 = char
                    case vendorWrite2UUID:
                        vendorWriteChar2 = char
                    default:
                        break
                    }
                }
            }
        }

        bleLog("FTMS: configured via 0x1826 service")
        return true
    }

    func start(speed: Double) {
        // Send start first, then set speed once belt is actually running
        // (detected via treadmill data notification in handleNotification)
        pendingStartSpeed = speed
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.writeControlPoint(0x07)
        }
    }

    func stop() {
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.writeControlPoint(0x08, params: Data([0x01]))
        }
    }

    func pause() {
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.writeControlPoint(0x08, params: Data([0x02]))
        }
    }

    func setSpeed(_ kmh: Double) {
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let raw = UInt16(kmh * 100)
            self?.writeControlPoint(0x02, params: uint16Bytes(raw))
        }
    }

    func handleNotification(characteristic: CBCharacteristic, data: Data) -> TreadmillStatus? {
        switch characteristic.uuid {
        case treadmillDataUUID:
            return parseTreadmillData(data)
        case vendorNotify1UUID, vendorNotify2UUID:
            return parseVendorData(data)
        default:
            return nil
        }
    }

    func handleReadValue(characteristic: CBCharacteristic, data: Data) -> ReadResult? {
        switch characteristic.uuid {
        case speedRangeUUID:
            guard data.count >= 6 else { return nil }
            _speedRange = SpeedRange(
                min: Double(data.uint16(at: 0)) / 100.0,
                max: Double(data.uint16(at: 2)) / 100.0,
                increment: Double(data.uint16(at: 4)) / 100.0
            )
            return .speedRange(_speedRange)
        case machineFeatureUUID:
            return .machineFeatures(parseMachineFeatures(data))
        case controlPointUUID:
            if data.count >= 3 && data[0] == 0x80 && data[1] == 0x00 && data[2] == 0x01 {
                hasRequestedControl = true
                return .controlResponse(success: true)
            }
            return nil
        case machineStatusUUID:
            return parseMachineStatusRead(data)
        case trainingStatusUUID:
            return parseTrainingStatus(data)
        default:
            return nil
        }
    }

    func tick() {
        // FTMS uses notifications for core data, but poll vendor stats for step count
        queryVendorStats()
    }

    func reset() {
        peripheral = nil
        controlPointChar = nil
        vendorWriteChar1 = nil
        vendorWriteChar2 = nil
        hasRequestedControl = false
        pendingStartSpeed = nil
        lastBeltState = .idle
    }

    // MARK: - Private

    private func requestControl() {
        writeControlPoint(0x00)
    }

    private func writeControlPoint(_ opcode: UInt8, params: Data = Data()) {
        guard let char = controlPointChar, let p = peripheral else { return }
        var payload = Data([opcode])
        payload.append(params)
        p.writeValue(payload, for: char, type: .withResponse)
    }

    private func parseTreadmillData(_ data: Data) -> TreadmillStatus? {
        guard data.count >= 4 else { return nil }
        let flags = data.uint16(at: 0)
        var offset = 2

        var speed: Double = 0
        var avgSpeed: Double = 0
        var distance: Int = 0
        var elapsed: Int = 0
        var calories: Int? = nil

        if (flags & 0x0001) == 0 && offset + 2 <= data.count {
            speed = Double(data.uint16(at: offset)) / 100.0
            offset += 2
        }
        if (flags & 0x0002) != 0 && offset + 2 <= data.count {
            avgSpeed = Double(data.uint16(at: offset)) / 100.0
            offset += 2
        }
        if (flags & 0x0004) != 0 && offset + 3 <= data.count {
            distance = Int(data.uint24(at: offset))
            offset += 3
        }
        if (flags & 0x0008) != 0 { offset += 4 }
        if (flags & 0x0010) != 0 { offset += 4 }
        if (flags & 0x0020) != 0 { offset += 1 }
        if (flags & 0x0040) != 0 { offset += 1 }
        if (flags & 0x0080) != 0 && offset + 2 <= data.count {
            calories = Int(data.uint16(at: offset))
            offset += 5
        }
        if (flags & 0x0100) != 0 { offset += 1 }
        if (flags & 0x0200) != 0 { offset += 1 }
        if (flags & 0x0400) != 0 && offset + 2 <= data.count {
            elapsed = Int(data.uint16(at: offset))
            offset += 2
        }

        // Belt state: only transition to idle from running (preserve paused/unknown)
        let state: BeltState
        if speed > 0 {
            state = .running
        } else if lastBeltState == .running {
            state = .idle
        } else {
            state = lastBeltState
        }
        lastBeltState = state

        // Once the belt starts running, send the pending start speed
        if state == .running, let pending = pendingStartSpeed {
            pendingStartSpeed = nil
            requestControl()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                let raw = UInt16(pending * 100)
                self?.writeControlPoint(0x02, params: uint16Bytes(raw))
            }
        }

        return TreadmillStatus(
            beltState: state,
            speed: speed,
            avgSpeed: avgSpeed > 0 ? avgSpeed : nil,
            distance: distance,
            elapsed: elapsed,
            steps: nil,
            calories: calories
        )
    }

    private func parseMachineStatusRead(_ data: Data) -> ReadResult? {
        guard !data.isEmpty else { return nil }
        let names: [UInt8: String] = [
            0x01: "Reset",
            0x02: "Stopped (safety key)",
            0x03: "Stopped by user",
            0x04: "Started / Resumed",
            0x05: "Target speed changed",
            0x06: "Target incline changed",
            0x07: "Control permission lost",
            0x08: "Paused by user",
            0x09: "Paused (safety key)",
            0x0A: "Resumed by user",
            0xFF: "Control request OK",
        ]
        let event = names[data[0]] ?? String(format: "Event 0x%02X", data[0])
        let state: BeltState
        switch data[0] {
        case 0x02, 0x03: state = .idle
        case 0x04, 0x0A: state = .running
        case 0x08, 0x09: state = .paused
        default: state = .unknown
        }
        // Keep internal state in sync so parseTreadmillData uses correct lastBeltState
        if state != .unknown { lastBeltState = state }
        return .machineStatus(state, event)
    }

    private func parseTrainingStatus(_ data: Data) -> ReadResult? {
        guard data.count >= 1 else { return nil }
        if data[0] == 0x01 {
            return .trainingStatus(.idle)
        }
        return .trainingStatus(nil)
    }

    private func queryVendorStats() {
        let sub: UInt8 = 0x01
        let checksum = 0xa2 ^ sub
        let cmd = Data([0xf7, 0xa2, sub, checksum, 0xfd])
        if let char = vendorWriteChar1, let p = peripheral {
            p.writeValue(cmd, for: char, type: .withoutResponse)
        }
        if let char = vendorWriteChar2, let p = peripheral {
            p.writeValue(cmd, for: char, type: .withoutResponse)
        }
    }

    private func parseVendorData(_ data: Data) -> TreadmillStatus? {
        guard data.count >= 3, data[0] == 0xf7 else { return nil }
        if data[1] == 0xa2 && data.count >= 18 {
            let s = Int(data.uint16(at: 7)) | (Int(data.uint16(at: 9)) << 16)
            if s > 0 && s < 1_000_000 {
                vendorSteps = s
            }
        }
        return nil
    }

    private func parseMachineFeatures(_ data: Data) -> [String] {
        guard data.count >= 4 else { return [] }
        let bits = UInt32(data.uint16(at: 0)) | (UInt32(data.uint16(at: 2)) << 16)
        let featureNames = [
            "Avg Speed", "Cadence", "Total Distance", "Inclination",
            "Elevation Gain", "Pace", "Step Count", "Resistance Level",
            "Stair Count", "Expended Energy", "Heart Rate", "Metabolic Equivalent",
            "Elapsed Time", "Remaining Time", "Power Measurement", "Force on Belt",
            "User Data Retention"
        ]
        var features: [String] = []
        for (i, name) in featureNames.enumerated() {
            if bits & (1 << i) != 0 { features.append(name) }
        }
        return features
    }
}
