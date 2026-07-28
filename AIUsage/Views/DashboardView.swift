import AppKit
import SwiftUI

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Binding var menuBarSelection: MenuBarSelection
    @Binding var menuBarWindow: MenuBarWindow
    @Binding var usageDisplayMode: UsageDisplayMode
    @Binding var refreshInterval: RefreshIntervalOption
    let availableUpdateVersion: String?
    let isCheckingForUpdates: Bool
    var checkForUpdates: @MainActor () -> Void = {}

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

                Menu {
                    Picker("Menu Bar Provider", selection: $menuBarSelection) {
                        ForEach(MenuBarSelection.allCases) { option in
                            Label {
                                Text(option.title)
                            } icon: {
                                if let provider = option.provider {
                                    ProviderIcon(provider: provider, size: 13)
                                } else if option == .all {
                                    Image(systemName: "rectangle.3.group")
                                } else {
                                    Image(systemName: "gauge.with.dots.needle.50percent")
                                }
                            }
                            .tag(option)
                        }
                    }

                    Picker("Menu Bar Period", selection: $menuBarWindow) {
                        ForEach(MenuBarWindow.allCases) { option in
                            Label(
                                option.title,
                                systemImage: option == .session
                                    ? "clock"
                                    : "calendar"
                            )
                            .tag(option)
                        }
                    }

                    Picker("Refresh", selection: $refreshInterval) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }

                    Divider()

                    Toggle(
                        "Launch at Login",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )

                    if launchAtLogin.requiresApproval {
                        Text("Approval needed in System Settings")
                    }
                    if let error = launchAtLogin.errorMessage {
                        Text(error)
                    }

                    Divider()

                    Button(action: checkForUpdates) {
                        Label(
                            "Check for Updates…",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(isCheckingForUpdates)

                    Link(destination: AppLinks.repository) {
                        Label("Star AI Usage on GitHub", systemImage: "star")
                    }

                    Button("Quit AI Usage") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    SettingsButtonLabel()
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens preferences and app actions")
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
                   state.isVisibleInDashboard {
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
