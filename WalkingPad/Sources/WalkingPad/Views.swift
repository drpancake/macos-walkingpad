import SwiftUI

// MARK: - Main Popover

struct PopoverView: View {
    @ObservedObject var ble: BLEManager
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if ble.needsOnboarding {
                OnboardingView(ble: ble)
            } else {
                VStack(spacing: 0) {
                    HeaderView(ble: ble, showSettings: $showSettings)

                    Divider()

                    if showSettings {
                        SettingsView(ble: ble, showSettings: $showSettings)
                    } else {
                        VStack(spacing: 16) {
                            MetricsGridView(ble: ble)

                            DailyGoalView(ble: ble)

                            ControlsView(ble: ble)

                            SpeedPresetsView(ble: ble)

                            Divider()

                            WeekHistoryView(ble: ble)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    }

                    Divider()

                    FooterView(ble: ble)
                }

                if ble.showGoalCelebration {
                    GoalCelebrationView(ble: ble)
                }
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var ble: BLEManager
    @Binding var showSettings: Bool

    var statusColor: Color {
        switch ble.connectionState {
        case .connected: return .green
        case .scanning, .connecting, .discovering: return .orange
        case .bluetoothOff, .unauthorized: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WALKINGPAD")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Text(ble.peripheralName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(ble.connectionState.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)

            Button(action: { showSettings.toggle() }) {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Metrics Grid (2x2)

struct MetricsGridView: View {
    @ObservedObject var ble: BLEManager

    var speedColor: Color {
        guard ble.speed > 0 else { return .secondary }
        let ratio = ble.speed / max(ble.speedRange.max, 1)
        let hue = 0.35 * (1 - ratio)
        return Color(hue: hue, saturation: 0.7, brightness: 0.85)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                MetricCell(
                    value: String(format: "%.1f", ble.speed),
                    unit: "km/h",
                    color: speedColor,
                    icon: "gauge.medium"
                )
                MetricCell(
                    value: String(format: "%.0f", ble.dailyCalories),
                    unit: "kcal",
                    color: .orange,
                    icon: "flame.fill"
                )
            }
            HStack(spacing: 0) {
                MetricCell(
                    value: formatDist(ble.distance),
                    unit: distUnit(ble.distance),
                    color: .blue,
                    icon: "figure.walk"
                )
                MetricCell(
                    value: formatElapsed(ble.elapsed),
                    unit: "elapsed",
                    color: .purple,
                    icon: "clock"
                )
            }
        }
    }

    func formatDist(_ m: Int) -> String {
        if m < 1000 { return "\(m)" }
        return String(format: "%.2f", Double(m) / 1000.0)
    }

    func distUnit(_ m: Int) -> String {
        m < 1000 ? "m" : "km"
    }

    func formatElapsed(_ s: Int) -> String {
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

struct MetricCell: View {
    let value: String
    let unit: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color.opacity(0.5))
            Text(value)
                .font(.system(size: 32, weight: .ultraLight, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Daily Goal

struct DailyGoalView: View {
    @ObservedObject var ble: BLEManager

    var progress: Double {
        min(Double(ble.dailyDistance) / Double(max(ble.dailyGoal, 1)), 1.0)
    }

    var progressMarkers: [Int] {
        let goal = Int(ble.profile.dailyGoalKm)
        guard goal > 0 else { return [1] }
        return Array(1...goal)
    }

    var effectivePace: Double {
        if ble.speed > 0.5 { return ble.speed }
        if ble.avgSpeed > 0.5 { return ble.avgSpeed }
        return ble.profile.defaultSpeedKmh
    }

    var timeRemainingText: String {
        let remaining = Double(ble.dailyGoal - ble.dailyDistance)
        guard remaining > 0 else { return "" }
        let minutes = Int((remaining / 1000.0 / effectivePace) * 60)
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m left" : "\(h)h left"
        }
        if minutes <= 0 { return "<1 min left" }
        return "\(minutes)m left"
    }

    var paceNote: String {
        if ble.speed > 0.5 { return "at current pace" }
        return String(format: "at %.1f km/h", effectivePace)
    }

    var encouragement: String {
        if ble.dailyDistance == 0 { return "Let's get moving!" }
        if progress < 0.25 { return "Every step counts!" }
        if progress < 0.50 { return "Great start!" }
        if progress < 0.75 { return "Over halfway!" }
        if progress < 1.00 { return "Almost there!" }
        return "Goal crushed!"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TODAY'S GOAL")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                Text(encouragement)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(progress >= 1.0 ? .orange : .secondary)
            }

            // Time remaining (prominent)
            if ble.goalReached {
                Text("Goal crushed!")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            } else {
                VStack(spacing: 2) {
                    Text(timeRemainingText)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                    Text(paceNote)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar with walker
            progressBar

            // Distance label
            HStack {
                Text(String(format: "%.2f km", Double(ble.dailyDistance) / 1000.0))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(String(format: "/ %.2f km", ble.profile.dailyGoalKm))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(progress >= 1.0 ? Color.orange.opacity(0.06) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    progress >= 1.0 ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.1),
                    lineWidth: 1
                )
        )
    }

    var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 28)

                if progress > 0 {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(progress >= 1.0 ? Color.orange : Color(hue: 0.35, saturation: 0.7, brightness: 0.85))
                        .frame(width: max(8, w * progress), height: 28)
                        .animation(.easeInOut(duration: 0.5), value: ble.dailyDistance)
                }

                ForEach(progressMarkers, id: \.self) { km in
                    let frac = Double(km) / ble.profile.dailyGoalKm
                    Text("\(km)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(
                            progress >= frac ? .white.opacity(0.9) : .secondary.opacity(0.4)
                        )
                        .position(x: w * frac - 8, y: 14)
                }
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Controls

struct ControlsView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 10) {
            ControlButton(
                label: "Start", icon: "play.fill", color: .green,
                disabled: !ble.isConnected || ble.beltState == .running
            ) { ble.startBelt() }

            ControlButton(
                label: "Pause", icon: "pause.fill", color: .orange,
                disabled: !ble.isConnected || ble.beltState != .running
            ) { ble.pauseBelt() }

            ControlButton(
                label: "Stop", icon: "stop.fill", color: .red,
                disabled: !ble.isConnected || ble.beltState == .idle
            ) { ble.stopBelt() }
        }
    }
}

struct ControlButton: View {
    let label: String
    let icon: String
    let color: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundColor(disabled ? .secondary : color)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(disabled ? Color.secondary.opacity(0.08) : color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(disabled ? Color.clear : color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Speed Presets

struct SpeedPresetsView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 8) {
            presetButton("1", speed: 1.0)
            presetButton("2.5", speed: 2.5)
            presetButton("3", speed: 3.0)
            presetButton("6", speed: 6.0)
        }
    }

    func presetButton(_ label: String, speed: Double) -> some View {
        let selected = abs(ble.targetSpeed - speed) < 0.05
        return Button(action: {
            ble.targetSpeed = speed
            ble.setSpeed(speed)
        }) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("km/h")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Week History

struct WeekHistoryView: View {
    @ObservedObject var ble: BLEManager

    var maxDist: Double {
        let m = ble.dayHistory.map(\.distance).max() ?? 0
        return max(Double(m), Double(ble.dailyGoal))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("LAST 7 DAYS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                if ble.currentStreak > 0 {
                    HStack(spacing: 3) {
                        Text("🔥")
                            .font(.system(size: 10))
                        Text("\(ble.currentStreak) day streak")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(ble.dayHistory) { entry in
                    VStack(spacing: 3) {
                        // Distance label
                        if entry.distance > 0 {
                            Text(String(format: "%.1fkm", Double(entry.distance) / 1000.0))
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        } else {
                            Text(" ")
                                .font(.system(size: 8))
                        }

                        // Bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(entry))
                            .frame(height: barHeight(entry.distance))

                        // Day label
                        Text(entry.dayLabel)
                            .font(.system(size: 9, weight: entry.isToday ? .bold : .regular, design: .rounded))
                            .foregroundColor(entry.isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 100)
        }
    }

    func barHeight(_ distance: Int) -> CGFloat {
        guard distance > 0 else { return 2 }
        return max(4, 70 * CGFloat(Double(distance) / maxDist))
    }

    func barColor(_ entry: DayHistoryEntry) -> Color {
        if entry.distance >= ble.dailyGoal { return .green }
        if entry.distance > 0 { return .blue.opacity(0.5) }
        return .secondary.opacity(0.15)
    }
}

// MARK: - Goal Celebration

struct GoalCelebrationView: View {
    @ObservedObject var ble: BLEManager
    @State private var appear = false
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(appear ? 0.75 : 0)

            VStack(spacing: 16) {
                Text("🎉🏆🎉")
                    .font(.system(size: 44))

                Text(String(format: "%.0f KM", ble.profile.dailyGoalKm))
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: .orange.opacity(glowPulse ? 0.9 : 0.3), radius: glowPulse ? 30 : 10)

                Text("DAILY GOAL COMPLETE!")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .tracking(2)

                VStack(spacing: 4) {
                    Text(String(format: "%.0f kcal burned", ble.dailyCalories))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange)
                    Text(String(format: "%.2f km walked today", Double(ble.dailyDistance) / 1000.0))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 8)

                Button(action: { ble.showGoalCelebration = false }) {
                    Text("KEEP GOING")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.yellow, .orange],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .scaleEffect(appear ? 1.0 : 0.3)
            .opacity(appear ? 1.0 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) {
                appear = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var ble: BLEManager

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    var body: some View {
        HStack {
            Button(action: {
                if ble.isConnected { ble.disconnect() }
                else { ble.reconnect() }
            }) {
                Text(ble.isConnected ? "Disconnect" : "Reconnect")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            Text("v\(appVersion)")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to WalkingPad")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.top, 4)

            Text("Set up your profile for accurate calorie tracking.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                onboardRow("Weight", value: Binding(
                    get: { String(format: "%.0f", ble.profile.weightKg) },
                    set: { if let v = Double($0), v > 0 { ble.profile.weightKg = v } }
                ), unit: "kg")

                onboardRow("Height", value: Binding(
                    get: { String(format: "%.0f", ble.profile.heightCm) },
                    set: { if let v = Double($0), v > 0 { ble.profile.heightCm = v } }
                ), unit: "cm")

                onboardRow("Age", value: Binding(
                    get: { "\(ble.profile.age)" },
                    set: { if let v = Int($0), v > 0 { ble.profile.age = v } }
                ), unit: "years")

                HStack {
                    Text("Gender")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $ble.profile.isMale) {
                        Text("Male").tag(true)
                        Text("Female").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                Divider()

                onboardRow("Daily goal", value: Binding(
                    get: { String(format: "%.1f", ble.profile.dailyGoalKm) },
                    set: { if let v = Double($0), v > 0 { ble.profile.dailyGoalKm = v } }
                ), unit: "km")

                onboardRow("Start speed", value: Binding(
                    get: { String(format: "%.1f", ble.profile.defaultSpeedKmh) },
                    set: { if let v = Double($0), v > 0 { ble.profile.defaultSpeedKmh = v } }
                ), unit: "km/h")
            }

            Button(action: { ble.saveProfile() }) {
                Text("Get Started")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .foregroundColor(.white)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    func onboardRow(_ label: String, value: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            TextField("", text: value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)
            Text(unit)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .leading)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var ble: BLEManager
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: "PROFILE")

            VStack(spacing: 10) {
                settingsRow("Weight", value: Binding(
                    get: { String(format: "%.0f", ble.profile.weightKg) },
                    set: { if let v = Double($0), v > 0 { ble.profile.weightKg = v } }
                ), unit: "kg")

                settingsRow("Height", value: Binding(
                    get: { String(format: "%.0f", ble.profile.heightCm) },
                    set: { if let v = Double($0), v > 0 { ble.profile.heightCm = v } }
                ), unit: "cm")

                settingsRow("Age", value: Binding(
                    get: { "\(ble.profile.age)" },
                    set: { if let v = Int($0), v > 0 { ble.profile.age = v } }
                ), unit: "years")

                HStack {
                    Text("Gender")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $ble.profile.isMale) {
                        Text("Male").tag(true)
                        Text("Female").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }

            SectionHeader(title: "TREADMILL")

            VStack(spacing: 10) {
                HStack {
                    Text("Name")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("e.g. Kingsmith R2 Pro", text: $ble.profile.treadmillName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                        .textFieldStyle(.roundedBorder)
                }

                settingsRow("Daily goal", value: Binding(
                    get: { String(format: "%.1f", ble.profile.dailyGoalKm) },
                    set: { if let v = Double($0), v > 0 { ble.profile.dailyGoalKm = v } }
                ), unit: "km")

                settingsRow("Start speed", value: Binding(
                    get: { String(format: "%.1f", ble.profile.defaultSpeedKmh) },
                    set: { if let v = Double($0), v > 0 { ble.profile.defaultSpeedKmh = v } }
                ), unit: "km/h")
            }

            Button(action: {
                ble.saveProfile()
                showSettings = false
            }) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func settingsRow(_ label: String, value: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            TextField("", text: value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)
            Text(unit)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .leading)
        }
    }
}
