import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController
    var showDashboard: @MainActor () -> Void = {}

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 16) {
                header
                providersSection
                generalSection
                footer
            }
        }
        .padding(20)
        .frame(width: MenuBarPanelRoute.settings.width, alignment: .top)
        .onAppear {
            store.setTrackedProviders(preferences.trackedProviderIDs)
            store.setRefreshInterval(preferences.refreshInterval)
            launchAtLogin.synchronize()
        }
        .onChange(of: preferences.refreshInterval) { _, interval in
            store.setRefreshInterval(interval)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: showDashboard) {
                Label("Usage", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Back to usage")
            .accessibilityHint("Shows the usage dashboard")

            Text("Settings")
                .font(.title3.weight(.semibold))

            Spacer()
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Providers",
                systemImage: "switch.2",
                detail: "Choose what to track and what appears in the menu bar."
            )

            providerRows
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var providerRows: some View {
        let descriptors = ProviderCatalog.all
        if descriptors.count > 2 {
            ScrollView {
                providerRowsContent(descriptors)
            }
            .frame(maxHeight: 260)
        } else {
            providerRowsContent(descriptors)
        }
    }

    private func providerRowsContent(
        _ descriptors: [ProviderDescriptor]
    ) -> some View {
        VStack(spacing: 0) {
            ProviderSettingsHeader()

            Divider()

            ForEach(descriptors) { descriptor in
                let availableItems = store.availableMenuBarItems(
                    for: descriptor.id
                )
                ProviderSettingsRow(
                    descriptor: descriptor,
                    state: store.states[descriptor.id],
                    isTracking: preferences.isTracking(descriptor.id),
                    isVisible:
                        store.states[descriptor.id]?.isToolInstalled != false &&
                        preferences.isProviderShownInMenuBar(descriptor.id),
                    selectedMetrics: Set(
                        preferences.selectedMenuBarMetrics(
                            for: descriptor.id
                        )
                    ),
                    availableItems: availableItems,
                    setTracking: { enabled in
                        preferences.setTracking(
                            enabled,
                            for: descriptor.id
                        )
                        store.setTrackedProviders(
                            preferences.trackedProviderIDs
                        )
                    },
                    setVisible: { enabled in
                        preferences.setMenuBarVisibility(
                            enabled,
                            for: descriptor.id,
                            availableItems: availableItems
                        )
                    },
                    setMetric: { item, enabled in
                        preferences.setMenuBarMetric(
                            enabled,
                            item: item,
                            availableItems: availableItems
                        )
                    }
                )

                if descriptor.id != descriptors.last?.id {
                    Divider()
                }
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.headline)

            Grid(
                alignment: .leading,
                horizontalSpacing: 18,
                verticalSpacing: 11
            ) {
                GridRow {
                    Text("Numbers")
                        .foregroundStyle(.secondary)

                    Picker("Numbers", selection: $preferences.usageDisplayMode) {
                        ForEach(UsageDisplayMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }

                GridRow {
                    Text("Refresh")
                        .foregroundStyle(.secondary)

                    Picker("Refresh", selection: $preferences.refreshInterval) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    Text("Startup")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { launchAtLogin.isEnabled },
                                set: { launchAtLogin.setEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if launchAtLogin.requiresApproval {
                            Text("Approval needed in System Settings")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let error = launchAtLogin.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.leading, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(updateController.isChecking)

            if updateController.isChecking {
                ProgressView()
                    .controlSize(.small)
            }

            Link("Star on GitHub", destination: AppLinks.repository)

            Spacer()

            Button("Quit AI Usage") {
                NSApplication.shared.terminate(nil)
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func sectionHeader(
        title: String,
        systemImage: String,
        detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct ProviderSettingsHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Provider")
                .frame(width: 130, alignment: .leading)
            Text("Track")
                .frame(width: 44)
            Label("Menu Bar", systemImage: "menubar.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }
}

private struct ProviderSettingsRow: View {
    let descriptor: ProviderDescriptor
    let state: ProviderState?
    let isTracking: Bool
    let isVisible: Bool
    let selectedMetrics: Set<MenuBarMetricID>
    let availableItems: [MenuBarItemID]
    let setTracking: (Bool) -> Void
    let setVisible: (Bool) -> Void
    let setMetric: (MenuBarItemID, Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: descriptor.id, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.body.weight(.medium))

                    if isTracking {
                        ProviderStatusView(state: state)
                    } else {
                        Label("Off", systemImage: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 130, alignment: .leading)

            Toggle(
                "Track \(descriptor.displayName)",
                isOn: Binding(
                    get: { isTracking },
                    set: { enabled in setTracking(enabled) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 44)
            .accessibilityLabel("Track \(descriptor.displayName)")

            HStack(spacing: 8) {
                Toggle(
                    "Show \(descriptor.displayName) in Menu Bar",
                    isOn: Binding(
                        get: { isVisible },
                        set: { enabled in setVisible(enabled) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: 44)
                .disabled(!isTracking || (!isVisible && !canEnableMenuBar))
                .help(
                    isVisible
                        ? "Hide \(descriptor.displayName) from the menu bar"
                        : "Show \(descriptor.displayName) in the menu bar"
                )

                Divider()
                    .frame(height: 20)

                menuBarMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var menuBarMetrics: some View {
        if availableItems.isEmpty {
            Text(emptyMetricsMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 8) {
                ForEach(availableItems) { item in
                    Toggle(
                        item.metric.title,
                        isOn: Binding(
                            get: {
                                selectedMetrics.contains(item.metric)
                            },
                            set: { enabled in
                                setMetric(item, enabled)
                            }
                        )
                    )
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!isTracking || !isVisible)
                    .help(
                        enabledMetricHelp(
                            item.metric,
                            isSelected:
                                selectedMetrics.contains(item.metric)
                        )
                    )
                }
            }
        }
    }

    private var canEnableMenuBar: Bool {
        state?.isToolInstalled != false &&
            (!selectedMetrics.isEmpty || !availableItems.isEmpty)
    }

    private var emptyMetricsMessage: String {
        if state?.isToolInstalled == false {
            return "Not installed"
        }
        if state?.isRefreshing == true {
            return "Loading available metrics…"
        }
        if state?.failure?.kind == .authentication {
            return "Log in to choose metrics"
        }
        return "No usage metrics returned"
    }

    private func enabledMetricHelp(
        _ metric: MenuBarMetricID,
        isSelected: Bool
    ) -> String {
        isSelected
            ? "Hide \(metric.title) for \(descriptor.displayName)"
            : "Show \(metric.title) for \(descriptor.displayName)"
    }
}

private struct ProviderStatusView: View {
    let state: ProviderState?

    var body: some View {
        let presentation = ProviderStatusPresentation(state: state)

        Label(presentation.text, systemImage: presentation.systemImage)
            .font(.caption)
            .foregroundStyle(presentation.color)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(presentation.text)
    }
}

private struct ProviderStatusPresentation {
    let text: String
    let systemImage: String
    let color: Color

    init(state: ProviderState?) {
        guard let state else {
            text = "Checking…"
            systemImage = "clock"
            color = .secondary
            return
        }

        if state.isToolInstalled == false {
            text = "Not installed"
            systemImage = "minus.circle"
            color = .secondary
            return
        }

        if let failure = state.failure {
            switch failure.kind {
            case .authentication:
                text = "Not logged in"
                systemImage = "person.crop.circle.badge.exclamationmark"
                color = .orange
            case .rateLimited:
                text = "Rate limited"
                systemImage = "hourglass"
                color = .orange
            case .transient, .invalidResponse, .storage:
                text = state.snapshot == nil
                    ? "Temporarily unavailable"
                    : "Showing last update"
                systemImage = "exclamationmark.triangle"
                color = .orange
            }
            return
        }

        if state.snapshot != nil {
            text = "Connected"
            systemImage = "checkmark.circle.fill"
            color = .green
        } else {
            text = state.isRefreshing ? "Checking…" : "Waiting for usage"
            systemImage = "clock"
            color = .secondary
        }
    }
}
