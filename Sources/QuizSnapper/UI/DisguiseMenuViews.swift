import SwiftUI

// MARK: - Fake menu views (styled after the system menus)

private struct MenuHeader: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .bold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
}

struct WeatherMenuView: View {
    @ObservedObject var engine: DisguiseEngine
    let location: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "location.fill").font(.system(size: 10))
                Text(location).font(.system(size: 13, weight: .bold))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: engine.weatherLoading ? "cloud" : "exclamationmark.icloud")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    if engine.weatherLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Updating…").font(.system(size: 13, weight: .semibold))
                        }
                    } else {
                        Text("Weather Unavailable").font(.system(size: 13, weight: .semibold))
                        Text("The forecast couldn’t be loaded. Check your internet connection and try again.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let last = engine.weatherLastAttempt, !engine.weatherLoading {
                Text("Last attempt \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct BatteryMenuView: View {
    let battery: BatteryInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MenuHeader(title: "Battery", trailing: "\(battery.percent)%")
            Text("Power Source: \(battery.onAC ? "Power Adapter" : "Battery")")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let m = battery.minutesRemaining {
                Text("\(m / 60):\(String(format: "%02d", m % 60)) remaining").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if battery.onAC && battery.percent >= 100 {
                Text("Fully Charged").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if battery.isCharging {
                Text("Charging").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct WifiHeaderView: View {
    @ObservedObject var engine: DisguiseEngine
    var body: some View {
        HStack {
            Text("Wi‑Fi").font(.system(size: 13, weight: .bold))
            Spacer()
            Toggle("", isOn: $engine.wifiOn).toggleStyle(MenuSwitchStyle()).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

struct WifiNetworkRow: View {
    let name: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(name).font(.system(size: 13))
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

struct VPNMenuView: View {
    @ObservedObject var engine: DisguiseEngine
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VPN").font(.system(size: 13, weight: .bold))
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13))
                    Text(status).font(.system(size: 11)).foregroundStyle(engine.vpnState == .failed ? .red : .secondary)
                }
                Spacer()
                if engine.vpnState == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { false }, set: { if $0 { engine.connectVPN() } }))
                        .toggleStyle(MenuSwitchStyle()).labelsHidden()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var status: String {
        switch engine.vpnState {
        case .disconnected: return "Not Connected"
        case .connecting: return "Connecting…"
        case .failed: return "The VPN server did not respond."
        }
    }
}

struct CloudMenuView: View {
    private var lastSync: Date {
        Date().addingTimeInterval(-Double((Calendar.current.component(.minute, from: Date()) % 7 + 2) * 60))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.icloud.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Drive").font(.system(size: 13, weight: .bold))
                Text("Up to date").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Last synced today at \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ResourceMenuView: View {
    @ObservedObject var engine: DisguiseEngine

    var body: some View {
        let s = engine.stats
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("CPU").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("\(Int((s.cpu * 100).rounded()))%").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(s.history.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.85))
                            .frame(height: max(2, 34 * v))
                    }
                }
                .frame(height: 34, alignment: .bottom)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                HStack(spacing: 14) {
                    stat("User", String(format: "%.1f%%", s.cpuUser * 100))
                    stat("System", String(format: "%.1f%%", s.cpuSystem * 100))
                    stat("Idle", String(format: "%.1f%%", max(0, 1 - s.cpu) * 100))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Memory").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("\(SystemStats.formatBytes(s.memoryUsed)) of \(SystemStats.formatBytes(s.memoryTotal))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: min(s.memoryFraction, 1)).tint(s.memoryFraction > 0.9 ? .red : (s.memoryFraction > 0.75 ? .yellow : .green))
                HStack(spacing: 14) {
                    stat("Compressed", SystemStats.formatBytes(s.compressed))
                    stat("Pressure", s.memoryFraction > 0.9 ? "High" : (s.memoryFraction > 0.75 ? "Elevated" : "Normal"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, weight: .medium).monospacedDigit())
        }
    }
}

/// Switch drawn like the system menu-extra switches (stays blue even though menus aren't "key").
struct MenuSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 32, height: 19)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(radius: 0.6, y: 0.4).padding(2)
            }
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
    }
}
