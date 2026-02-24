import SwiftUI

// MARK: - Main Popover

struct PopoverView: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var spotify: SpotifyManager

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(ble: ble)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    SpeedDisplayView(ble: ble)
                    ControlsView(ble: ble)
                    SpeedControlView(ble: ble)

                    if ble.beltState == .running {
                        Divider()
                        MusicView(spotify: spotify)
                    }

                    Divider()

                    StatsView(ble: ble)

                    Divider()

                    DeviceInfoView(ble: ble)

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()

            FooterView(ble: ble)
        }
        .frame(width: 320, height: 700)
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var ble: BLEManager

    var statusColor: Color {
        switch ble.connectionState {
        case .connected: return .green
        case .scanning, .connecting, .discovering: return .orange
        case .bluetoothOff, .unauthorized: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Speed Display

struct SpeedDisplayView: View {
    @ObservedObject var ble: BLEManager

    var speedColor: Color {
        guard ble.speed > 0 else { return .secondary }
        let ratio = ble.speed / max(ble.speedRange.max, 1)
        let hue = 0.35 * (1 - ratio)
        return Color(hue: hue, saturation: 0.7, brightness: 0.85)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", ble.speed))
                    .font(.system(size: 52, weight: .ultraLight, design: .rounded))
                    .foregroundColor(speedColor)
                    .monospacedDigit()
                    .animation(.easeOut(duration: 0.3), value: ble.speed)
                Text("km/h")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                beltStateIcon
                Text(ble.beltState.rawValue)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(beltStateColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(beltStateColor.opacity(0.12))
            .cornerRadius(10)

            if ble.speedHistory.count > 2 {
                SparklineView(
                    data: ble.speedHistory,
                    maxValue: ble.speedRange.max,
                    color: speedColor
                )
                .frame(height: 30)
                .padding(.top, 4)
            }
        }
    }

    var beltStateColor: Color {
        switch ble.beltState {
        case .running: return .green
        case .paused: return .orange
        case .idle: return .secondary
        case .unknown: return .gray
        }
    }

    @ViewBuilder
    var beltStateIcon: some View {
        switch ble.beltState {
        case .running: Image(systemName: "figure.walk")
        case .paused: Image(systemName: "pause.fill")
        case .idle: Image(systemName: "powersleep")
        case .unknown: Image(systemName: "questionmark")
        }
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let data: [Double]
    let maxValue: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if data.count > 1 {
                let w = geo.size.width
                let h = geo.size.height
                let count = data.count
                let stepX = w / CGFloat(count - 1)
                let maxY = max(maxValue, 0.1)

                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for i in 0..<count {
                            let x = CGFloat(i) * stepX
                            let y = h - h * CGFloat(data[i] / maxY)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: CGFloat(count - 1) * stepX, y: h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.25), color.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    Path { path in
                        for i in 0..<count {
                            let x = CGFloat(i) * stepX
                            let y = h - h * CGFloat(data[i] / maxY)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, lineWidth: 1.5)
                }
            }
        }
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

// MARK: - Speed Control

struct SpeedControlView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: nudgeDown) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                VStack(spacing: 2) {
                    Slider(
                        value: $ble.targetSpeed,
                        in: ble.speedRange.min...ble.speedRange.max,
                        step: ble.speedRange.increment
                    ) { editing in
                        if !editing {
                            ble.setSpeed(ble.targetSpeed)
                        }
                    }
                    .tint(.accentColor)

                    HStack {
                        Text(String(format: "%.0f", ble.speedRange.min))
                        Spacer()
                        Text(String(format: "Target: %.1f km/h", ble.targetSpeed))
                            .fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.0f", ble.speedRange.max))
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }

                Button(action: nudgeUp) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { speed in
                    Button(action: {
                        ble.targetSpeed = speed
                        ble.setSpeed(speed)
                    }) {
                        Text(String(format: "%.0f", speed))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        abs(ble.targetSpeed - speed) < 0.05
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.08)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        abs(ble.targetSpeed - speed) < 0.05
                                            ? Color.accentColor.opacity(0.5)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var presets: [Double] {
        var result: [Double] = []
        var v = ceil(ble.speedRange.min)
        while v <= ble.speedRange.max {
            result.append(v)
            v += 1.0
        }
        return result
    }

    func nudgeUp() {
        let next = min(ble.targetSpeed + 0.5, ble.speedRange.max)
        ble.targetSpeed = next
        ble.setSpeed(next)
    }

    func nudgeDown() {
        let next = max(ble.targetSpeed - 0.5, ble.speedRange.min)
        ble.targetSpeed = next
        ble.setSpeed(next)
    }
}

// MARK: - Music Zones

struct MusicView: View {
    @ObservedObject var spotify: SpotifyManager

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                SectionHeader(title: "AUTO MUSIC")
                Spacer()
                Toggle("", isOn: $spotify.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if !spotify.currentTrack.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11))
                        .foregroundColor(zoneColor(spotify.currentZoneIndex))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(spotify.currentTrack)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(spotify.currentArtist)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(zoneColor(spotify.currentZoneIndex).opacity(0.08))
                )
            }
        }
    }

    func zoneColor(_ index: Int) -> Color {
        switch index {
        case 0: return .cyan
        case 1: return .purple
        case 2: return .orange
        case 3: return .red
        default: return .secondary
        }
    }
}

struct ZonePill: View {
    let zone: MusicZone
    let isActive: Bool
    let isPending: Bool

    var color: Color {
        switch zone.id {
        case 0: return .cyan
        case 1: return .purple
        case 2: return .orange
        case 3: return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(zone.emoji)
                .font(.system(size: 16))
            Text(zone.name)
                .font(.system(size: 8, weight: .bold))
            Text(zone.maxSpeed.isFinite ? "≤\(String(format: "%.0f", zone.maxSpeed))" : "MAX")
                .font(.system(size: 7))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? color.opacity(0.2) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? color : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Stats

struct StatsView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "SESSION")

            StatRow(icon: "timer", label: "Time", value: formatTime(ble.elapsed))
            StatRow(icon: "point.topleft.down.to.point.bottomright.curvepath", label: "Distance", value: formatDistance(ble.distance))
            StatRow(icon: "flame.fill", label: "Calories", value: "\(ble.calories) kcal")
            StatRow(icon: "speedometer", label: "Avg Speed", value: String(format: "%.1f km/h", ble.avgSpeed))
            StatRow(icon: "figure.walk", label: "Pace", value: formatPace(ble.speed))

            if ble.steps > 0 {
                StatRow(icon: "shoeprints.fill", label: "Steps", value: "\(ble.steps)")
            }

            if !ble.lastMachineEvent.isEmpty {
                StatRow(icon: "bell.fill", label: "Last Event", value: ble.lastMachineEvent)
            }
        }
    }

    func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    func formatDistance(_ meters: Int) -> String {
        if meters < 1000 { return "\(meters) m" }
        return String(format: "%.2f km", Double(meters) / 1000.0)
    }

    func formatPace(_ speedKmh: Double) -> String {
        guard speedKmh > 0 else { return "–" }
        let totalSeconds = Int(3600.0 / speedKmh)
        return String(format: "%d:%02d /km", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Device Info

struct DeviceInfoView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "DEVICE")

            StatRow(icon: "building.2", label: "Manufacturer", value: ble.deviceInfo.manufacturer)
            StatRow(icon: "tag", label: "Model", value: ble.deviceInfo.model)
            StatRow(icon: "number", label: "Serial", value: ble.deviceInfo.serial)
            StatRow(icon: "cpu", label: "Hardware", value: ble.deviceInfo.hardware)
            StatRow(icon: "memorychip", label: "Firmware", value: ble.deviceInfo.firmware)
            StatRow(icon: "chevron.left.forwardslash.chevron.right", label: "Software", value: ble.deviceInfo.software)
            StatRow(
                icon: "gauge.with.dots.needle.33percent",
                label: "Speed Range",
                value: String(format: "%.1f – %.1f km/h", ble.speedRange.min, ble.speedRange.max)
            )
        }
    }
}

// MARK: - Features

struct FeaturesView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "FTMS FEATURES")

            FlowLayout(spacing: 4) {
                ForEach(ble.supportedFeatures, id: \.self) { feature in
                    Text(feature)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            if index < result.positions.count {
                let pos = result.positions[index]
                subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var ble: BLEManager

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

// MARK: - Shared Components

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.bottom, 6)
    }
}

struct StatRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
