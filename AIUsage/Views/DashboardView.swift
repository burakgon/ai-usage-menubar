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
        DashboardContentView(
            store: store,
            usageDisplayMode: $usageDisplayMode,
            openSettings: openSettings
        )
        .frame(width: 392)
        .background {
            LiquidGlassPanelBackground()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.setRefreshInterval(refreshInterval)
            store.start()
            launchAtLogin.synchronize()
        }
        .onChange(of: refreshInterval) { _, interval in
            store.setRefreshInterval(interval)
        }
    }
}

/// A header glyph: an icon on its own, without a separate material surface.
struct HeaderGlyphButton: View {
    let asset: String
    let help: String
    let accessibilityLabel: String
    var isBusy = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(UsagePalette.Morado.glyph)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LiquidGlassPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency {
                Color.clear
                    .glassEffect(
                        .regular,
                        in: .rect(cornerRadius: 18)
                    )
            }

            LinearGradient(
                colors: reduceTransparency
                    ? [
                        UsagePalette.Morado.panel,
                        UsagePalette.Morado.panelDeep,
                        UsagePalette.Morado.panelViolet
                    ]
                    : [
                        UsagePalette.Morado.panel.opacity(0.46),
                        UsagePalette.Morado.panelDeep.opacity(0.38),
                        UsagePalette.Morado.panelViolet.opacity(0.44)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityHidden(true)
    }
}

struct DashboardContentView: View {
    @Bindable var store: UsageStore
    @Binding var usageDisplayMode: UsageDisplayMode
    var openSettings: @MainActor () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(UsagePalette.Morado.line)

            providerRows
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("AI Usage")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UsagePalette.Morado.ink)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                HeaderGlyphButton(
                    asset: "IconRefresh",
                    help: isRefreshing ? "Refreshing usage" : "Refresh now",
                    accessibilityLabel: isRefreshing
                        ? "Refreshing usage"
                        : "Refresh now",
                    isBusy: isRefreshing
                ) {
                    store.refreshNow()
                }
                .disabled(isRefreshing)

                HeaderGlyphButton(
                    asset: "IconSettings",
                    help: "Settings",
                    accessibilityLabel: "Settings",
                    action: openSettings
                )
            }
        }
        .padding(.leading, 17)
        .padding(.trailing, 15)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private var providerRows: some View {
        if visibleProviders.count > 2 {
            ScrollView {
                providerRowsContent
            }
            .frame(maxHeight: 430)
            .scrollIndicators(.hidden)
        } else {
            providerRowsContent
        }
    }

    private var providerRowsContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visibleProviders.enumerated()), id: \.element) { index, provider in
                if let state = store.states[provider] {
                    ProviderSectionView(
                        state: state,
                        displayMode: usageDisplayMode
                    )

                    if index < visibleProviders.count - 1 {
                        Divider()
                            .overlay(UsagePalette.Morado.line)
                    }
                }
            }
        }
    }

    private var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter(store.isProviderVisibleInDashboard)
    }

    private var isRefreshing: Bool {
        store.states.values.contains(where: \.isRefreshing)
    }
}
