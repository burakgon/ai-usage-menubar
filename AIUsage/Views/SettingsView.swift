import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController
    var showDashboard: @MainActor () -> Void = {}

    @State private var rowFrames: [ProviderID: CGRect] = [:]
    @State private var draggingProvider: ProviderID?

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

    private var providerRows: some View {
        providerRowsContent(preferences.providerOrder.map(\.descriptor))
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
                    },
                    isDragging: draggingProvider == descriptor.id,
                    reportFrame: { rowFrames[descriptor.id] = $0 },
                    dragChanged: { handleDrag(of: descriptor.id, at: $0) },
                    dragEnded: { draggingProvider = nil },
                    move: { offset in
                        withAnimation(.snappy(duration: 0.2)) {
                            preferences.moveProvider(descriptor.id, by: offset)
                        }
                    },
                    rowsSpace: Self.rowsSpace
                )

                if descriptor.id != descriptors.last?.id {
                    Divider()
                }
            }
        }
        .coordinateSpace(.named(Self.rowsSpace))
    }

    private static let rowsSpace = "providerRows"

    /// Live reorder: the dragged provider takes the place of the row the
    /// pointer has moved past.
    private func handleDrag(of provider: ProviderID, at point: CGPoint) {
        draggingProvider = provider
        guard let target = ProviderRowDrag.target(
            of: provider,
            at: point.y,
            order: preferences.providerOrder,
            frames: rowFrames
        ) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            preferences.moveProvider(provider, to: target)
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
    let isDragging: Bool
    let reportFrame: (CGRect) -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: () -> Void
    let move: (Int) -> Void
    let rowsSpace: String

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

            dragHandle
        }
        .padding(.vertical, 9)
        .background(
            isDragging ? Color.accentColor.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(rowsSpace))
        } action: {
            reportFrame($0)
        }
        .accessibilityElement(children: .contain)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(
                    minimumDistance: 2,
                    coordinateSpace: .named(rowsSpace)
                )
                .onChanged { dragChanged($0.location) }
                .onEnded { _ in dragEnded() }
            )
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
            .help("Drag to reorder \(descriptor.displayName)")
            .accessibilityLabel("Reorder \(descriptor.displayName)")
            .accessibilityAction(named: "Move Up") { move(-1) }
            .accessibilityAction(named: "Move Down") { move(1) }
    }

    @ViewBuilder
    private var menuBarMetrics: some View {
        if availableItems.isEmpty {
            Text(emptyMetricsMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            WrappingHStack(spacing: 8, lineSpacing: 4) {
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

/// Where a dragged provider row belongs.
enum ProviderRowDrag {
    /// The provider whose place the dragged row takes, or `nil` to stay.
    ///
    /// A row is passed only once the pointer crosses its middle. Rows differ
    /// in height, so swapping as soon as the pointer entered one would leave
    /// the pointer over the row it had just swapped with, and the two would
    /// trade places on every move. Direction comes from the order rather than
    /// the frames, which still describe the old layout until it is redrawn.
    static func target(
        of provider: ProviderID,
        at y: CGFloat,
        order: [ProviderID],
        frames: [ProviderID: CGRect]
    ) -> ProviderID? {
        guard let index = order.firstIndex(of: provider) else { return nil }
        let passedBelow = order[(index + 1)...].last { below in
            frames[below].map { y > $0.midY } ?? false
        }
        let passedAbove = order[..<index].first { above in
            frames[above].map { y < $0.midY } ?? false
        }
        return passedBelow ?? passedAbove
    }
}

/// Lays out its views in a row and continues on the next line when the
/// row is full, so a provider with many metrics never truncates one.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width ?? .infinity)
        let height = lines.map(\.height).reduce(0, +) +
            lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty,
               current.width + spacing + size.width > maxWidth {
                lines.append(current)
                current = Line()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            lines.append(current)
        }
        return lines
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
