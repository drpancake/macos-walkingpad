import Foundation
import CoreBluetooth
import Combine

// MARK: - Device Info UUIDs

private let deviceInfoServiceUUID = CBUUID(string: "180A")
private let manufacturerNameUUID  = CBUUID(string: "2A29")
private let modelNumberUUID       = CBUUID(string: "2A24")
private let serialNumberUUID      = CBUUID(string: "2A25")
private let hardwareRevUUID       = CBUUID(string: "2A27")
private let firmwareRevUUID       = CBUUID(string: "2A26")
private let softwareRevUUID       = CBUUID(string: "2A28")

private let deviceInfoCharUUIDs: Set<CBUUID> = [
    manufacturerNameUUID, modelNumberUUID, serialNumberUUID,
    hardwareRevUUID, firmwareRevUUID, softwareRevUUID
]

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
    var treadmillName: String = ""
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
    let id: String
    let dayLabel: String
    let distance: Int
    let calories: Double
    let isToday: Bool
}

// MARK: - Protocol Registry

private struct ProtocolEntry {
    let namePatterns: [String]
    let factory: () -> TreadmillProtocol
}

// Registered protocols. FTMS goes last — it's the generic fallback.
private let protocolTypes: [ProtocolEntry] = [
    ProtocolEntry(namePatterns: WLT6200Protocol.namePatterns, factory: { WLT6200Protocol() }),
    ProtocolEntry(namePatterns: FTMSProtocol.namePatterns, factory: { FTMSProtocol() }),
]

/// All name patterns across all registered protocols, for BLE scan filtering.
private let allNamePatterns: [String] = protocolTypes.flatMap(\.namePatterns)

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
    private var activeProtocol: TreadmillProtocol?
    private var tickTimer: Timer?
    private var shouldReconnect = true
    private var lastRawDistance: Int = -1
    private var lastCalorieTimestamp: Date?
    private var lastSaveTime: Date = .distantPast
    private var store = WalkPadStore()
    private var pendingServiceCount = 0
    private var completedServiceCount = 0

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
        activeProtocol?.start(speed: startSpeed)
    }

    func stopBelt() {
        activeProtocol?.stop()
    }

    func pauseBelt() {
        activeProtocol?.pause()
    }

    func setSpeed(_ kmh: Double) {
        targetSpeed = kmh
        guard beltState == .running else { return }
        activeProtocol?.setSpeed(kmh)
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

    // MARK: - Protocol Selection

    private func selectProtocol() {
        guard let peripheral = peripheral else { return }
        let services = peripheral.services ?? []
        let name = (peripheral.name ?? "").lowercased()

        // Try name-matched protocols first, then all others
        var tried = Set<String>()

        // Name-matched first
        for entry in protocolTypes {
            if entry.namePatterns.contains(where: { name.contains($0) }) {
                let proto = entry.factory()
                tried.insert(proto.modelName)
                if proto.configure(peripheral: peripheral, services: services) {
                    activateProtocol(proto)
                    return
                }
            }
        }

        // Then try remaining
        for entry in protocolTypes {
            let proto = entry.factory()
            guard !tried.contains(proto.modelName) else { continue }
            if proto.configure(peripheral: peripheral, services: services) {
                activateProtocol(proto)
                return
            }
        }

        // No protocol matched — connect anyway so UI shows green
        bleLog("connected but no known protocol matched")
        connectionState = .connected
    }

    private func activateProtocol(_ proto: TreadmillProtocol) {
        activeProtocol = proto
        speedRange = proto.speedRange
        connectionState = .connected
        bleLog("activated protocol: \(proto.modelName)")
        startTicking()
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.activeProtocol?.tick()
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Status Application

    private func applyStatus(_ status: TreadmillStatus) {
        beltState = status.beltState
        speed = status.speed
        distance = status.distance
        elapsed = status.elapsed
        if let s = status.steps { steps = s }
        if let c = status.calories { calories = c }

        // Speed history
        speedHistory.append(speed)
        if speedHistory.count > 120 { speedHistory.removeFirst() }

        // Accumulate calculated calories (ACSM-based)
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
            if distance > dailyDistance {
                let gap = distance - dailyDistance
                dailyDistance = distance
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

    private func applyReadResult(_ result: ReadResult) {
        switch result {
        case .speedRange(let range):
            speedRange = range
        case .machineFeatures(let features):
            supportedFeatures = features
        case .machineStatus(let state, let event):
            if state != .unknown { beltState = state }
            lastMachineEvent = event
        case .trainingStatus(let state):
            if let s = state, beltState != .running { beltState = s }
        case .controlResponse:
            break
        case .deviceInfo:
            break  // handled separately
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    // MARK: - Calorie Calculation (ACSM Metabolic Equations)

    private func caloriesPerMinute(atSpeedKmh kmh: Double) -> Double {
        guard kmh > 0.5 else { return 0 }
        let p = store.profile
        let speedMpm = kmh * 1000.0 / 60.0
        let bmr = 10 * p.weightKg + 6.25 * p.heightCm - 5 * Double(p.age) + (p.isMale ? 5 : -161)
        let restingVO2 = (bmr / 1440.0) * 1000.0 / (p.weightKg * 5.0)
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
        if !profile.treadmillName.isEmpty {
            peripheralName = profile.treadmillName
        }
        // If goal was raised above current distance, reset celebrated so celebration can re-trigger
        let wasReached = goalReached
        goalReached = dailyDistance >= dailyGoal
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
        let name = (peripheral.name ?? "").lowercased()
        let nameMatch = allNamePatterns.contains(where: { name.contains($0) }) && !name.contains("remote")

        guard nameMatch else {
            bleLog("skip: \(peripheral.name ?? "nil")")
            return
        }

        bleLog("MATCH: \(peripheral.name ?? "nil")")
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        self.peripheralName = profile.treadmillName.isEmpty ? (peripheral.name ?? "WalkingPad") : profile.treadmillName
        centralManager.stopScan()
        connectionState = .connecting
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        isConnected = true
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectionState = .disconnected
        retryConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        activeProtocol?.reset()
        activeProtocol = nil
        stopTicking()
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
        let services = peripheral.services ?? []
        pendingServiceCount = services.count
        completedServiceCount = 0
        for service in services {
            bleLog("service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Read device info characteristics
        if service.uuid == deviceInfoServiceUUID {
            for char in service.characteristics ?? [] {
                if deviceInfoCharUUIDs.contains(char.uuid) {
                    peripheral.readValue(for: char)
                }
            }
        }

        completedServiceCount += 1
        if completedServiceCount >= pendingServiceCount {
            selectProtocol()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        bleLog("NOTIFY: char=\(characteristic.uuid) len=\(data.count) data=\(data.map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Device info (handled by BLEManager, not protocol)
        switch characteristic.uuid {
        case manufacturerNameUUID:
            deviceInfo.manufacturer = String(data: data, encoding: .utf8) ?? "–"
            return
        case modelNumberUUID:
            deviceInfo.model = String(data: data, encoding: .utf8) ?? "–"
            return
        case serialNumberUUID:
            deviceInfo.serial = String(data: data, encoding: .utf8) ?? "–"
            return
        case hardwareRevUUID:
            deviceInfo.hardware = String(data: data, encoding: .utf8) ?? "–"
            return
        case firmwareRevUUID:
            deviceInfo.firmware = String(data: data, encoding: .utf8) ?? "–"
            return
        case softwareRevUUID:
            deviceInfo.software = String(data: data, encoding: .utf8) ?? "–"
            return
        default:
            break
        }

        // Delegate to active protocol
        guard let proto = activeProtocol else { return }

        if let status = proto.handleNotification(characteristic: characteristic, data: data) {
            applyStatus(status)
        } else if let result = proto.handleReadValue(characteristic: characteristic, data: data) {
            applyReadResult(result)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            bleLog("WRITE ERROR: \(characteristic.uuid) \(error.localizedDescription)")
        }
    }
}
