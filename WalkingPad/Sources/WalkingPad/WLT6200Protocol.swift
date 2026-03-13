import Foundation
import CoreBluetooth

// MARK: - WLT6200 Protocol (KingSmith R2 Pro)
//
// Reverse-engineered from live testing, March 2026.
// Full docs: WLT6200-PROTOCOL.md
//
// BLE Service: FE00
//   FE01 (notify) — status notifications from treadmill
//   FE02 (write-without-response) — commands to treadmill
//
// Command format: [0xF7] [0xA2] [subcmd] [param] [checksum] [0xFD]
// Checksum: (0xA2 + subcmd + param) & 0xFF
//
// Commands:
//   0x00 0x00 — query status
//   0x01 N    — set speed (N = kmh * 10)
//   0x02 0x01 — set manual mode (required before start)
//   0x02 0x02 — set standby mode
//   0x04 0x01 — start belt (3s countdown)
//
// Start sequence: manual mode → 0.7s → start → ~5s countdown → set speed
// Stop sequence:  speed 0 → 2s → standby mode
//
// Status notification (20 bytes): [0xF8] [0xA2] [state] [speed] [mode]
//   [time_h time_m time_l] [dist_h dist_m dist_l] [step_h step_m step_l]
//   [app_speed] [?] [ctrl_btn] [?] [checksum] [0xFD]
//
// Belt states: 0=idle, 1=running, 4=standby, 6-9=countdown

class WLT6200Protocol: TreadmillProtocol {
    static let namePatterns = ["wlt6200"]

    var modelName: String { "WLT6200" }
    var speedRange: SpeedRange { SpeedRange(min: 0.5, max: 6.0, increment: 0.1) }

    private weak var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?   // FE01
    private var writeChar: CBCharacteristic?     // FE02

    private let vendorServiceUUID = CBUUID(string: "FE00")
    private let vendorNotifyUUID  = CBUUID(string: "FE01")
    private let vendorWriteUUID   = CBUUID(string: "FE02")

    func configure(peripheral: CBPeripheral, services: [CBService]) -> Bool {
        guard let service = services.first(where: { $0.uuid == vendorServiceUUID }) else {
            return false
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case vendorNotifyUUID:
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
            case vendorWriteUUID:
                writeChar = char
            default:
                break
            }
        }
        guard writeChar != nil else { return false }
        self.peripheral = peripheral
        bleLog("WLT6200: configured via FE00 service")
        return true
    }

    func start(speed: Double) {
        // Manual mode → wait → start → wait for countdown → set speed
        writeCommand(subcmd: 0x02, param: 0x01)  // manual mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.writeCommand(subcmd: 0x04, param: 0x01)  // start
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.setSpeed(speed)
            }
        }
    }

    func stop() {
        writeCommand(subcmd: 0x01, param: 0x00)  // speed 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.writeCommand(subcmd: 0x02, param: 0x02)  // standby
        }
    }

    func pause() {
        writeCommand(subcmd: 0x02, param: 0x02)  // standby
    }

    func setSpeed(_ kmh: Double) {
        let speedByte = UInt8(min(max(kmh * 10, 0), 255))
        writeCommand(subcmd: 0x01, param: speedByte)
    }

    func handleNotification(characteristic: CBCharacteristic, data: Data) -> TreadmillStatus? {
        guard characteristic.uuid == vendorNotifyUUID else { return nil }
        guard data.count >= 14, data[0] == 0xF8, data[1] == 0xA2 else { return nil }

        let state: BeltState
        switch data[2] {
        case 0: state = .idle
        case 1: state = .running
        default: state = .paused
        }

        let speed = Double(data[3]) / 10.0

        var elapsed = 0
        if data.count >= 8 {
            let t = Int(data.uint24BE(at: 5))
            if t >= 0 && t < 86400 { elapsed = t }
        }

        var distance = 0
        if data.count >= 11 {
            let rawDist = Int(data.uint24BE(at: 8))
            let d = rawDist * 10  // 10m units -> meters
            if d >= 0 && d < 1_000_000 { distance = d }
        }

        var steps = 0
        if data.count >= 14 {
            let s = Int(data.uint24BE(at: 11))
            if s >= 0 && s < 1_000_000 { steps = s }
        }

        return TreadmillStatus(
            beltState: state,
            speed: speed,
            distance: distance,
            elapsed: elapsed,
            steps: steps,
            calories: nil
        )
    }

    func handleReadValue(characteristic: CBCharacteristic, data: Data) -> ReadResult? {
        // WLT6200 doesn't use read values for protocol data
        return nil
    }

    func tick() {
        writeCommand(subcmd: 0x00, param: 0x00)  // query status
    }

    func reset() {
        peripheral = nil
        notifyChar = nil
        writeChar = nil
    }

    // MARK: - Private

    private func writeCommand(subcmd: UInt8, param: UInt8) {
        guard let char = writeChar, let p = peripheral else { return }
        let checksum = UInt8((UInt16(0xA2) + UInt16(subcmd) + UInt16(param)) & 0xFF)
        let cmd = Data([0xF7, 0xA2, subcmd, param, checksum, 0xFD])
        bleLog("WLT6200 WRITE: \(cmd.map { String(format: "%02x", $0) }.joined(separator: " "))")
        p.writeValue(cmd, for: char, type: .withoutResponse)
    }
}
