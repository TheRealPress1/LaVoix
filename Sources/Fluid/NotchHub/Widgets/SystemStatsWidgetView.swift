import SwiftUI

/// RAM, swap, CPU, storage, battery and the apps using the most memory.
struct SystemStatsWidgetView: View {
    @StateObject private var sampler = SystemStatsSampler()
    @Environment(\.notchWidgetActive) private var active

    var body: some View {
        let s = self.sampler.snapshot
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatTile(
                        title: "Memory",
                        value: Self.gigabytes(s.memoryUsed),
                        detail: "of \(Self.gigabytes(s.memoryTotal))",
                        fraction: Self.fraction(s.memoryUsed, s.memoryTotal),
                        tint: Self.tint(for: s.pressure)
                    )
                    StatTile(
                        title: "CPU",
                        value: "\(Int((s.cpu * 100).rounded()))%",
                        detail: "in use",
                        fraction: s.cpu,
                        tint: s.cpu > 0.85 ? .orange : .white
                    )
                }
                HStack(spacing: 10) {
                    StatTile(
                        title: "Storage",
                        value: Self.gigabytes(s.diskFree),
                        detail: "free",
                        fraction: 1 - Self.fraction(s.diskFree, s.diskTotal),
                        tint: Self.fraction(s.diskFree, s.diskTotal) < 0.1 ? .orange : .white
                    )
                    self.batteryTile(s.battery)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Using the most memory")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                    Spacer()
                }
                if s.topApps.isEmpty {
                    Text("Reading…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                ForEach(s.topApps) { app in
                    HStack {
                        Text(app.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.gigabytes(app.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                Spacer(minLength: 0)
                if s.swapTotal > 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.swapIsHigh(s) ? Color.orange : Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text("Swap \(Self.gigabytes(s.swapUsed)) of \(Self.gigabytes(s.swapTotal))")
                            .font(.system(size: 11))
                            .foregroundStyle(Self.swapIsHigh(s) ? Color.orange : .white.opacity(0.5))
                    }
                }
            }
            .frame(width: 210)
            // The Swap line sits at the bottom; keep it clear of the notch's rounded corner.
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
        .onChange(of: self.active, initial: true) { _, active in
            if active { self.sampler.start() } else { self.sampler.stop() }
        }
        .onDisappear { self.sampler.stop() }
    }

    private func batteryTile(_ battery: SystemStatsSampler.Battery?) -> some View {
        if let battery {
            return AnyView(StatTile(
                title: "Battery",
                value: "\(battery.percent)%",
                detail: battery.isCharging ? "charging" : (battery.isOnAC ? "plugged in" : "on battery"),
                fraction: Double(battery.percent) / 100,
                tint: battery.percent <= 20 && !battery.isOnAC ? .red : (battery.isCharging ? .green : .white)
            ))
        }
        return AnyView(StatTile(title: "Power", value: "AC", detail: "desktop", fraction: 1, tint: .white))
    }

    // MARK: - Formatting

    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value >= 100 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    private static func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
        whole == 0 ? 0 : min(max(Double(part) / Double(whole), 0), 1)
    }

    private static func tint(for pressure: SystemStatsSampler.MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .white
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private static func swapIsHigh(_ s: SystemStatsSampler.Snapshot) -> Bool {
        s.swapTotal > 0 && Double(s.swapUsed) / Double(s.swapTotal) > 0.7
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(self.value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(self.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(self.tint)
                        .frame(width: max(4, proxy.size.width * min(max(self.fraction, 0), 1)))
                }
            }
            .frame(height: 4)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}
