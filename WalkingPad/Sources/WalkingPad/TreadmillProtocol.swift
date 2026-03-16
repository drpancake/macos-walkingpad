import Foundation
import CoreBluetooth

// MARK: - Shared Types

enum BeltState: String {
    case idle = "Idle"
    case running = "Running"
    case paused = "Paused"
    case unknown = "Unknown"
}

enum ConnectionState: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning"
    case connecting = "Connecting"
    case discovering = "Discovering"
    case connected = "Connected"
    case bluetoothOff = "Bluetooth Off"
    case unauthorized = "Unauthorized"
}

struct DeviceInfo {
    var manufacturer: String = "–"
    var model: String = "–"
    var serial: String = "–"
    var hardware: String = "–"
    var firmware: String = "–"
    var software: String = "–"
}

struct SpeedRange {
    var min: Double = 1.0
    var max: Double = 6.0
    var increment: Double = 0.1
}

// MARK: - Protocol Status

struct TreadmillStatus {
    var beltState: BeltState
    var speed: Double
    var avgSpeed: Double?
    var distance: Int      // meters
    var elapsed: Int        // seconds
    var steps: Int?
    var calories: Int?
}

enum ReadResult {
    case deviceInfo(field: DeviceInfoField, value: String)
    case speedRange(SpeedRange)
    case machineFeatures([String])
    case machineStatus(BeltState, String)  // state + event description
    case trainingStatus(BeltState?)
    case controlResponse(success: Bool)
}

enum DeviceInfoField {
    case manufacturer, model, serial, hardware, firmware, software
}

// MARK: - Treadmill Protocol

protocol TreadmillProtocol: AnyObject {
    static var namePatterns: [String] { get }

    var modelName: String { get }
    var speedRange: SpeedRange { get }

    /// Try to configure using discovered services. Returns true if this protocol owns the device.
    func configure(peripheral: CBPeripheral, services: [CBService]) -> Bool

    func start(speed: Double)
    func stop()
    func pause()
    func setSpeed(_ kmh: Double)

    /// Parse a notification. Returns TreadmillStatus if this is a data update, nil otherwise.
    func handleNotification(characteristic: CBCharacteristic, data: Data) -> TreadmillStatus?

    /// Parse a read value response. Returns ReadResult if recognized, nil otherwise.
    func handleReadValue(characteristic: CBCharacteristic, data: Data) -> ReadResult?

    /// Called every 1s for polling/keepalive.
    func tick()

    /// Clean up on disconnect.
    func reset()
}

// MARK: - Data Helpers

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func uint24(at offset: Int) -> UInt32 {
        guard offset + 2 < count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16)
    }
    func uint24BE(at offset: Int) -> UInt32 {
        guard offset + 2 < count else { return 0 }
        return (UInt32(self[offset]) << 16) | (UInt32(self[offset + 1]) << 8) | UInt32(self[offset + 2])
    }
}

func uint16Bytes(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
}

func bleLog(_ msg: String) {
    #if DEBUG
    print("[BLE] \(msg)")
    #endif
}
