import AppKit
import SwiftUI

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Binding var usageDisplayMode: UsageDisplayMode
    @Binding var refreshInterval: RefreshIntervalOption
    let availableUpdateVersion: String?
    let isCheckingForUpdates: Bool
    var checkForUpdates: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            DashboardContentView(
                store: store,
                usageDisplayMode: $usageDisplayMode
            )
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    footer
                }
        }
        .frame(width: 392)
        .onAppear {
            store.setRefreshInterval(refreshInterval)
            store.start()
            launchAtLogin.synchronize()
        }
        .onChange(of: refreshInterval) { _, interval in
            store.setRefreshInterval(interval)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: freshnessSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(freshnessTint)

                Group {
                    if let updated = store.lastSuccessfulRefreshAt {
                        HStack(spacing: 3) {
                            Text("Updated")
                            Text(updated, style: .relative)
                        }
                    } else if store.lastAttemptAt != nil {
                        Text("Not updated")
                    } else {
                        Text("Waiting to refresh")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer()

            if let version = availableUpdateVersion {
                Button(action: checkForUpdates) {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(UsagePalette.accent)
                .controlSize(.small)
                .disabled(isCheckingForUpdates)
                .help("Update AI Usage to \(version)")
            }

            HStack(spacing: 0) {
                Button {
                    store.refreshNow()
                } label: {
                    RefreshButtonLabel(isRefreshing: isRefreshing)
                }
                .help(isRefreshing ? "Refreshing usage" : "Refresh now")
                .disabled(isRefreshing)

                Button(action: openSettings) {
                    SettingsButtonLabel()
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Shows settings in the menu bar panel")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 7)
    }

    private var freshnessSymbol: String {
        store.lastSuccessfulRefreshAt == nil ? "clock" : "checkmark.circle.fill"
    }

    private var freshnessTint: Color {
        store.lastSuccessfulRefreshAt == nil ? .secondary : UsagePalette.success
    }

    private var isRefreshing: Bool {
        store.states.values.contains(where: \.isRefreshing)
    }
}

struct SettingsButtonLabel: View {
    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: RefreshButtonLabel.symbolSize, weight: .medium))
            .frame(width: RefreshButtonLabel.size, height: RefreshButtonLabel.size)
            .contentShape(Circle())
    }
}

struct RefreshButtonLabel: View {
    static let size: CGFloat = 28
    static let symbolSize: CGFloat = 14

    let isRefreshing: Bool

    var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .font(.system(size: Self.symbolSize, weight: .medium))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .accessibilityLabel(isRefreshing ? "Refreshing usage" : "Refresh now")
    }
}

struct DashboardContentView: View {
    @Bindable var store: UsageStore
    @Binding var usageDisplayMode: UsageDisplayMode

    var body: some View {
        VStack(spacing: 8) {
            header
            ForEach(ProviderID.allCases) { provider in
                if let state = store.states[provider],
                   store.isProviderVisibleInDashboard(provider) {
                    ProviderSectionView(
                        state: state,
                        displayMode: usageDisplayMode
                    )
                }
            }
        }
        .padding([.horizontal, .top], 10)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack {
            Text("AI Usage")
                .font(.headline.weight(.semibold))
            Spacer()
            Picker("Numbers", selection: $usageDisplayMode) {
                ForEach(UsageDisplayMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 112)
            .accessibilityLabel("Usage numbers")
            .accessibilityHint("Choose whether percentages show usage left or used")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }
}
