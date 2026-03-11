import Foundation
import CoreBluetooth
import Combine

// MARK: - FTMS UUIDs

let ftmsServiceUUID       = CBUUID(string: "1826")
let treadmillDataUUID     = CBUUID(string: "2ACD")
let machineStatusUUID     = CBUUID(string: "2ADA")
let controlPointUUID      = CBUUID(string: "2AD9")
let speedRangeUUID        = CBUUID(string: "2AD4")
let trainingStatusUUID    = CBUUID(string: "2AD3")
let machineFeatureUUID    = CBUUID(string: "2ACC")

let deviceInfoServiceUUID = CBUUID(string: "180A")
let manufacturerNameUUID  = CBUUID(string: "2A29")
let modelNumberUUID       = CBUUID(string: "2A24")
let serialNumberUUID      = CBUUID(string: "2A25")
let hardwareRevUUID       = CBUUID(string: "2A27")
let firmwareRevUUID       = CBUUID(string: "2A26")
let softwareRevUUID       = CBUUID(string: "2A28")

let vendorService1UUID    = CBUUID(string: "FFC0")
let vendorNotify1UUID     = CBUUID(string: "FFC1")
let vendorWrite1UUID      = CBUUID(string: "FFC2")
let vendorService2UUID    = CBUUID(string: "FFF0")
let vendorNotify2UUID     = CBUUID(string: "FFF1")
let vendorWrite2UUID      = CBUUID(string: "FFF2")

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
}

func uint16Bytes(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
}

// MARK: - Models

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

// MARK: - Persistence Models

struct DayRecord: Codable {
    var distance: Int = 0
    var calories: Double = 0.0
    var celebrated: Bool = false
}

struct UserProfile: Codable {
    var weightKg: Double = 70.0
    var heightCm: Double = 170.0
    var age: Int = 30
    var isMale: Bool = true
    var defaultSpeedKmh: Double = 2.5
    var dailyGoalKm: Double = 5.0
}

struct WalkPadStore: Codable {
    var days: [String: DayRecord] = [:]
    var lastActivityTime: Double = 0
    var sessionCalories: Double = 0
    var profile: UserProfile = UserProfile()
    var onboardingDone: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([String: DayRecord].self, forKey: .days)) ?? [:]
        lastActivityTime = (try? c.decode(Double.self, forKey: .lastActivityTime)) ?? 0
        sessionCalories = (try? c.decode(Double.self, forKey: .sessionCalories)) ?? 0
        profile = (try? c.decode(UserProfile.self, forKey: .profile)) ?? UserProfile()
        onboardingDone = (try? c.decode(Bool.self, forKey: .onboardingDone)) ?? false
    }
}

struct DayHistoryEntry: Identifiable {
    let id: String          // date string "2026-03-11"
    let dayLabel: String    // "Mon", "Tue", etc.
    let distance: Int       // meters
    let calories: Double
    let isToday: Bool
}

// MARK: - BLE Manager

class BLEManager: NSObject, ObservableObject {
    // Connection
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isConnected = false
    @Published var peripheralName: String = "–"

    // Live data
    @Published var speed: Double = 0.0
    @Published var avgSpeed: Double = 0.0
    @Published var distance: Int = 0
    @Published var elapsed: Int = 0
    @Published var calories: Int = 0
    @Published var beltState: BeltState = .idle
    @Published var steps: Int = 0

    // Speed control
    @Published var targetSpeed: Double = 2.5
    @Published var speedRange: SpeedRange = SpeedRange()

    // Device info
    @Published var deviceInfo: DeviceInfo = DeviceInfo()

    // Speed history for sparkline (last 120 samples)
    @Published var speedHistory: [Double] = []

    // Supported FTMS features
    @Published var supportedFeatures: [String] = []

    // FTMS machine status log
    @Published var lastMachineEvent: String = ""

    // Daily goal & accurate calorie tracking
    @Published var calculatedCalories: Double = 0.0
    @Published var dailyDistance: Int = 0
    @Published var dailyCalories: Double = 0.0
    @Published var goalReached: Bool = false
    @Published var showGoalCelebration: Bool = false
    var dailyGoal: Int { Int(profile.dailyGoalKm * 1000) }

    // User profile
    @Published var profile: UserProfile = UserProfile()
    @Published var needsOnboarding: Bool = true

    // History & streak
    @Published var dayHistory: [DayHistoryEntry] = []
    @Published var currentStreak: Int = 0

    // Internals
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlPointChar: CBCharacteristic?
    private var vendorWriteChar1: CBCharacteristic?
    private var vendorWriteChar2: CBCharacteristic?
    private var shouldReconnect = true
    private var hasRequestedControl = false
    private var lastRawDistance: Int = -1
    private var lastCalorieTimestamp: Date?
    private var lastSaveTime: Date = .distantPast
    private var store = WalkPadStore()

    private static let dataDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".walkingpad")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let dataFile = dataDir.appendingPathComponent("data.json")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadFromFile()
    }

    // MARK: - Commands

    func startBelt() {
        let startSpeed = profile.defaultSpeedKmh
        targetSpeed = startSpeed
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let raw = UInt16(startSpeed * 100)
            self.writeControlPoint(0x02, params: uint16Bytes(raw))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.writeControlPoint(0x07)
            }
        }
    }

    func stopBelt() {
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.writeControlPoint(0x08, params: Data([0x01]))
        }
    }

    func pauseBelt() {
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.writeControlPoint(0x08, params: Data([0x02]))
        }
    }

    func setSpeed(_ kmh: Double) {
        targetSpeed = kmh
        guard beltState == .running else { return }
        requestControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let raw = UInt16(kmh * 100)
            self?.writeControlPoint(0x02, params: uint16Bytes(raw))
        }
    }

    func reconnect() {
        shouldReconnect = true
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        connectionState = .scanning
        startScanning()
    }

    func disconnect() {
        shouldReconnect = false
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Private

    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [ftmsServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func requestControl() {
        writeControlPoint(0x00)
    }

    private func writeControlPoint(_ opcode: UInt8, params: Data = Data()) {
        guard let char = controlPointChar, let p = peripheral else { return }
        var payload = Data([opcode])
        payload.append(params)
        p.writeValue(payload, for: char, type: .withResponse)
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

    // MARK: - Calorie Calculation (ACSM Metabolic Equations)
    //
    // Walking (<=6 km/h): VO2 = 0.1 * speed(m/min) + 3.5 ml/kg/min
    // Running (>6 km/h):  VO2 = 0.2 * speed(m/min) + 3.5 ml/kg/min
    // kcal/min = VO2 * bodyMass(kg) / 1000 * 5.0

    private func caloriesPerMinute(atSpeedKmh kmh: Double) -> Double {
        guard kmh > 0.5 else { return 0 }
        let p = store.profile
        let speedMpm = kmh * 1000.0 / 60.0

        // Personalized resting VO2 via Mifflin-St Jeor BMR
        let bmr = 10 * p.weightKg + 6.25 * p.heightCm - 5 * Double(p.age) + (p.isMale ? 5 : -161)
        let restingVO2 = (bmr / 1440.0) * 1000.0 / (p.weightKg * 5.0)

        // ACSM walking/running exercise component + personalized resting
        let exerciseVO2 = (kmh <= 6.0 ? 0.1 : 0.2) * speedMpm
        let totalVO2 = exerciseVO2 + restingVO2
        return totalVO2 * p.weightKg / 1000.0 * 5.0
    }

    // MARK: - File Persistence

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func loadFromFile() {
        if let data = try? Data(contentsOf: Self.dataFile),
           let decoded = try? JSONDecoder().decode(WalkPadStore.self, from: data) {
            store = decoded
        }

        let today = todayString()
        let todayData = store.days[today] ?? DayRecord()
        dailyDistance = todayData.distance
        dailyCalories = todayData.calories
        goalReached = dailyDistance >= dailyGoal

        // Restore session calories if active within last 30 min, otherwise fresh session
        let inactiveSecs = Date().timeIntervalSince1970 - store.lastActivityTime
        if inactiveSecs <= 1800 {
            calculatedCalories = store.sessionCalories
        } else {
            calculatedCalories = 0
            speedHistory = []
        }

        profile = store.profile
        needsOnboarding = !store.onboardingDone
        targetSpeed = profile.defaultSpeedKmh
        updateHistoryAndStreak()
    }

    func saveProfile() {
        store.profile = profile
        store.onboardingDone = true
        needsOnboarding = false
        targetSpeed = profile.defaultSpeedKmh
        let wasReached = goalReached
        goalReached = dailyDistance >= dailyGoal
        // If goal was raised above current distance, reset celebrated so celebration can re-trigger
        if wasReached && !goalReached {
            let today = todayString()
            store.days[today]?.celebrated = false
            showGoalCelebration = false
        }
        saveToFile()
    }

    private func saveToFile() {
        let today = todayString()
        var record = store.days[today] ?? DayRecord()
        record.distance = dailyDistance
        record.calories = dailyCalories
        store.days[today] = record
        store.sessionCalories = calculatedCalories

        // Prune entries older than 60 days
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) {
            store.days = store.days.filter { key, _ in
                if let d = f.date(from: key) { return d >= cutoff }
                return false
            }
        }

        if let encoded = try? JSONEncoder().encode(store) {
            try? encoded.write(to: Self.dataFile, options: .atomic)
        }
    }

    func updateHistoryAndStreak() {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let dayF = DateFormatter()
        dayF.dateFormat = "EEE"
        let today = Date()
        let todayStr = f.string(from: today)

        var entries: [DayHistoryEntry] = []
        for i in (0..<7).reversed() {
            guard let date = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let dateStr = f.string(from: date)
            let data = store.days[dateStr] ?? DayRecord()
            entries.append(DayHistoryEntry(
                id: dateStr,
                dayLabel: dayF.string(from: date),
                distance: dateStr == todayStr ? dailyDistance : data.distance,
                calories: dateStr == todayStr ? dailyCalories : data.calories,
                isToday: dateStr == todayStr
            ))
        }
        dayHistory = entries

        // Streak: consecutive days hitting goal (today counts if reached)
        var streak = 0
        var checkDate = today
        if dailyDistance >= dailyGoal {
            streak += 1
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        } else {
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }
        for _ in 0..<365 {
            let dateStr = f.string(from: checkDate)
            let data = store.days[dateStr] ?? DayRecord()
            if data.distance >= dailyGoal {
                streak += 1
                checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        currentStreak = streak
    }

    // MARK: - FTMS Parsing

    fileprivate func parseTreadmillData(_ data: Data) {
        guard data.count >= 4 else { return }
        let flags = data.uint16(at: 0)
        var offset = 2

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

        // Infer belt state
        if speed > 0 {
            beltState = .running
        } else if beltState == .running {
            beltState = .idle
        }

        // Speed history
        speedHistory.append(speed)
        if speedHistory.count > 120 { speedHistory.removeFirst() }

        // Accumulate calculated calories (ACSM-based, 78kg male)
        let now = Date()
        if speed > 0 {
            if let lastTs = lastCalorieTimestamp {
                let dt = now.timeIntervalSince(lastTs)
                if dt > 0 && dt < 5 {
                    let cals = caloriesPerMinute(atSpeedKmh: speed) * dt / 60.0
                    calculatedCalories += cals
                    dailyCalories += cals
                }
            }
            lastCalorieTimestamp = now
            store.lastActivityTime = now.timeIntervalSince1970
        } else {
            lastCalorieTimestamp = nil
        }

        // Track daily distance (delta-based)
        if lastRawDistance < 0 {
            // First reading after (re)connection — catch up if treadmill is ahead
            if distance > dailyDistance {
                let gap = distance - dailyDistance
                dailyDistance = distance
                // Estimate calories for the gap using avg speed
                let pace = avgSpeed > 0.5 ? avgSpeed : (speed > 0.5 ? speed : profile.defaultSpeedKmh)
                let gapMinutes = (Double(gap) / 1000.0 / pace) * 60.0
                let gapCals = caloriesPerMinute(atSpeedKmh: pace) * gapMinutes
                dailyCalories += gapCals
                calculatedCalories += gapCals
            }
        } else {
            let delta = distance - lastRawDistance
            if delta > 0 { dailyDistance += delta }
        }
        lastRawDistance = distance

        // Check daily goal
        if dailyDistance >= dailyGoal && !goalReached {
            goalReached = true
            let today = todayString()
            if !(store.days[today]?.celebrated ?? false) {
                showGoalCelebration = true
                var rec = store.days[today] ?? DayRecord()
                rec.celebrated = true
                store.days[today] = rec
            }
            saveToFile()
            updateHistoryAndStreak()
            lastSaveTime = now
        }

        // Periodic save (every 5s)
        if now.timeIntervalSince(lastSaveTime) > 5 {
            saveToFile()
            updateHistoryAndStreak()
            lastSaveTime = now
        }
    }

    fileprivate func parseMachineStatus(_ data: Data) {
        guard !data.isEmpty else { return }
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
        lastMachineEvent = event

        switch data[0] {
        case 0x02, 0x03: beltState = .idle
        case 0x04, 0x0A: beltState = .running
        case 0x08, 0x09: beltState = .paused
        default: break
        }
    }

    fileprivate func parseSpeedRange(_ data: Data) {
        guard data.count >= 6 else { return }
        speedRange = SpeedRange(
            min: Double(data.uint16(at: 0)) / 100.0,
            max: Double(data.uint16(at: 2)) / 100.0,
            increment: Double(data.uint16(at: 4)) / 100.0
        )
    }

    fileprivate func parseMachineFeatures(_ data: Data) {
        guard data.count >= 4 else { return }
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
        supportedFeatures = features
    }

    fileprivate func parseVendorData(_ data: Data) {
        guard data.count >= 3, data[0] == 0xf7 else { return }
        if data[1] == 0xa2 && data.count >= 18 {
            let s = Int(data.uint16(at: 7)) | (Int(data.uint16(at: 9)) << 16)
            if s > 0 && s < 1_000_000 { steps = s }
        }
    }

    fileprivate func parseTrainingStatus(_ data: Data) {
        guard data.count >= 1 else { return }
        switch data[0] {
        case 0x01: if beltState != .running { beltState = .idle }
        default: break
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionState = .scanning
            startScanning()
        case .poweredOff:
            connectionState = .bluetoothOff
            isConnected = false
        case .unauthorized:
            connectionState = .unauthorized
            isConnected = false
        default:
            connectionState = .disconnected
            isConnected = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        self.peripheralName = peripheral.name ?? "WalkingPad"
        centralManager.stopScan()
        connectionState = .connecting
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        isConnected = true
        peripheral.discoverServices([ftmsServiceUUID, deviceInfoServiceUUID, vendorService1UUID, vendorService2UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectionState = .disconnected
        retryConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        hasRequestedControl = false
        controlPointChar = nil
        vendorWriteChar1 = nil
        vendorWriteChar2 = nil
        connectionState = .disconnected
        beltState = .unknown
        lastRawDistance = -1
        lastCalorieTimestamp = nil
        retryConnection()
    }

    private func retryConnection() {
        guard shouldReconnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            self.connectionState = .scanning
            self.startScanning()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case treadmillDataUUID, machineStatusUUID, trainingStatusUUID:
                peripheral.setNotifyValue(true, for: char)
            case controlPointUUID:
                controlPointChar = char
                peripheral.setNotifyValue(true, for: char)
            case speedRangeUUID, machineFeatureUUID:
                peripheral.readValue(for: char)
            case manufacturerNameUUID, modelNumberUUID, serialNumberUUID,
                 hardwareRevUUID, firmwareRevUUID, softwareRevUUID:
                peripheral.readValue(for: char)
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

        if service.uuid == ftmsServiceUUID {
            connectionState = .connected
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.queryVendorStats()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        switch characteristic.uuid {
        case treadmillDataUUID:
            parseTreadmillData(data)
        case machineStatusUUID:
            parseMachineStatus(data)
        case controlPointUUID:
            if data.count >= 3 && data[0] == 0x80 && data[1] == 0x00 && data[2] == 0x01 {
                hasRequestedControl = true
            }
        case speedRangeUUID:
            parseSpeedRange(data)
        case machineFeatureUUID:
            parseMachineFeatures(data)
        case trainingStatusUUID:
            parseTrainingStatus(data)
        case manufacturerNameUUID:
            deviceInfo.manufacturer = String(data: data, encoding: .utf8) ?? "–"
        case modelNumberUUID:
            deviceInfo.model = String(data: data, encoding: .utf8) ?? "–"
        case serialNumberUUID:
            deviceInfo.serial = String(data: data, encoding: .utf8) ?? "–"
        case hardwareRevUUID:
            deviceInfo.hardware = String(data: data, encoding: .utf8) ?? "–"
        case firmwareRevUUID:
            deviceInfo.firmware = String(data: data, encoding: .utf8) ?? "–"
        case softwareRevUUID:
            deviceInfo.software = String(data: data, encoding: .utf8) ?? "–"
        case vendorNotify1UUID, vendorNotify2UUID:
            parseVendorData(data)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write error: \(error.localizedDescription)")
        }
    }
}
