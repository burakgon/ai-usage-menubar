import AppKit
import Observation
import SwiftUI

struct PanelToggleGate {
    private(set) var suppressesNextToggle = false

    mutating func panelDidClose() {
        suppressesNextToggle = true
    }

    mutating func consumeSuppression() -> Bool {
        guard suppressesNextToggle else { return false }
        suppressesNextToggle = false
        return true
    }

    mutating func clearSuppression() {
        suppressesNextToggle = false
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private static let panelWidth: CGFloat = 392

    private let store: UsageStore
    private let preferences: AppPreferences
    private let launchAtLogin: LaunchAtLoginController
    private let updateController: UpdateController
    private let statusBar: NSStatusBar

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var isStarted = false
    private var toggleGate = PanelToggleGate()

    init(
        store: UsageStore,
        preferences: AppPreferences,
        launchAtLogin: LaunchAtLoginController,
        updateController: UpdateController,
        statusBar: NSStatusBar = .system
    ) {
        self.store = store
        self.preferences = preferences
        self.launchAtLogin = launchAtLogin
        self.updateController = updateController
        self.statusBar = statusBar
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
        }

        trackMenuBarState()
        store.start()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        store.stop()
        popover?.performClose(nil)
        releasePanel()

        if let statusItem {
            statusBar.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc
    private func togglePanel(_ sender: Any?) {
        guard !toggleGate.consumeSuppression() else { return }

        if popover?.isShown == true {
            popover?.performClose(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }

        let rootView = DashboardRootView(
            store: store,
            launchAtLogin: launchAtLogin,
            preferences: preferences,
            updateController: updateController
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        let measuredSize = hostingController.sizeThatFits(
            in: NSSize(
                width: Self.panelWidth,
                height: .greatestFiniteMagnitude
            )
        )
        let contentSize = NSSize(
            width: Self.panelWidth,
            height: ceil(measuredSize.height)
        )
        hostingController.preferredContentSize = contentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = contentSize
        popover.contentViewController = hostingController
        self.popover = popover

        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === popover else {
            return
        }
        toggleGate.panelDidClose()
        releasePanel()
        DispatchQueue.main.async { [weak self] in
            self?.toggleGate.clearSuppression()
        }
    }

    private func releasePanel() {
        popover?.delegate = nil
        popover?.contentViewController = nil
        popover = nil
    }

    private func trackMenuBarState() {
        guard isStarted else { return }

        let state = withObservationTracking {
            (
                reading: store.menuBarReading(
                    for: preferences.menuBarSelection,
                    window: preferences.menuBarWindow,
                    displayMode: preferences.usageDisplayMode
                ),
                refreshInterval: preferences.refreshInterval
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.trackMenuBarState()
            }
        }

        store.setRefreshInterval(state.refreshInterval)
        updateStatusItem(with: state.reading)
    }

    private func updateStatusItem(with reading: MenuBarReading) {
        guard let button = statusItem?.button else { return }

        let presentation = MenuBarPresentation(reading: reading)
        var title = presentation.valueText ?? ""
        if presentation.showsStaleIndicator {
            title = title.isEmpty ? "⚠︎" : "\(title) ⚠︎"
        }

        button.image = statusImage(for: reading.provider)
        button.title = title
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func statusImage(for provider: ProviderID?) -> NSImage {
        if let provider {
            return ProviderIcon.templateImage(for: provider, size: 15)
        }

        guard let source = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: nil
        ), let image = source.copy() as? NSImage else {
            return NSImage(size: NSSize(width: 15, height: 15))
        }
        image.size = NSSize(width: 15, height: 15)
        image.isTemplate = true
        return image
    }
}

private struct DashboardRootView: View {
    let store: UsageStore
    let launchAtLogin: LaunchAtLoginController
    @Bindable var preferences: AppPreferences
    @Bindable var updateController: UpdateController

    var body: some View {
        DashboardView(
            store: store,
            launchAtLogin: launchAtLogin,
            menuBarSelection: $preferences.menuBarSelection,
            menuBarWindow: $preferences.menuBarWindow,
            usageDisplayMode: $preferences.usageDisplayMode,
            refreshInterval: $preferences.refreshInterval,
            availableUpdateVersion: updateController.availableVersion,
            isCheckingForUpdates: updateController.isChecking,
            checkForUpdates: updateController.checkForUpdates
        )
    }
}
