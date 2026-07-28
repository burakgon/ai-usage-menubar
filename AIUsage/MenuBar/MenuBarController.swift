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
enum MenuBarStatusImageRenderer {
    private static let iconSize: CGFloat = 15
    private static let iconTextSpacing: CGFloat = 4
    private static let itemSpacing: CGFloat = 8

    static func image(
        for readings: [MenuBarReading],
        font: NSFont
    ) -> NSImage {
        let entries = readings.map { reading in
            (
                reading: reading,
                presentation: MenuBarPresentation(reading: reading)
            )
        }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let metrics = entries.map { entry in
            let text = titleText(for: entry.presentation)
            let textSize = (text as NSString).size(withAttributes: textAttributes)
            let width = iconSize + (
                text.isEmpty ? 0 : iconTextSpacing + ceil(textSize.width)
            )
            return (text: text, textSize: textSize, width: width)
        }
        let width = metrics.map(\.width).reduce(0, +) +
            itemSpacing * CGFloat(max(entries.count - 1, 0))
        let height = max(
            iconSize,
            ceil(font.ascender - font.descender + font.leading)
        )

        let image = NSImage(
            size: NSSize(width: ceil(width), height: ceil(height)),
            flipped: false
        ) { destination in
            var x = destination.minX

            for (index, entry) in entries.enumerated() {
                let metric = metrics[index]
                let icon = icon(for: entry.reading.provider)
                icon.draw(
                    in: NSRect(
                        x: x,
                        y: destination.midY - iconSize / 2,
                        width: iconSize,
                        height: iconSize
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += iconSize

                if !metric.text.isEmpty {
                    x += iconTextSpacing
                    (metric.text as NSString).draw(
                        at: NSPoint(
                            x: x,
                            y: destination.midY - metric.textSize.height / 2
                        ),
                        withAttributes: textAttributes
                    )
                    x += ceil(metric.textSize.width)
                }

                if index < entries.count - 1 {
                    x += itemSpacing
                }
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    private static func titleText(
        for presentation: MenuBarPresentation
    ) -> String {
        var title = presentation.valueText ?? ""
        if presentation.showsStaleIndicator {
            title = title.isEmpty ? "⚠︎" : "\(title) ⚠︎"
        }
        return title
    }

    private static func icon(for provider: ProviderID?) -> NSImage {
        if let provider {
            return ProviderIcon.templateImage(for: provider, size: iconSize)
        }

        guard let source = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: nil
        ), let image = source.copy() as? NSImage else {
            return NSImage(size: NSSize(width: iconSize, height: iconSize))
        }
        image.size = NSSize(width: iconSize, height: iconSize)
        image.isTemplate = true
        return image
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
                readings: store.menuBarReadings(
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
        updateStatusItem(with: state.readings)
    }

    private func updateStatusItem(with readings: [MenuBarReading]) {
        guard let button = statusItem?.button else { return }

        let collectionPresentation = MenuBarReadingsPresentation(
            readings: readings
        )
        button.toolTip = collectionPresentation.accessibilityLabel
        button.setAccessibilityLabel(collectionPresentation.accessibilityLabel)

        guard readings.count != 1 else {
            updateStatusItem(
                button,
                with: readings[0],
                presentation: collectionPresentation.items[0]
            )
            return
        }

        guard !readings.isEmpty else {
            button.attributedTitle = NSAttributedString()
            button.image = statusImage(for: nil)
            button.title = ""
            return
        }

        button.attributedTitle = NSAttributedString()
        button.image = nil
        button.title = ""
        button.image = MenuBarStatusImageRenderer.image(
            for: readings,
            font: button.font ?? NSFont.menuBarFont(ofSize: 0)
        )
    }

    private func updateStatusItem(
        _ button: NSStatusBarButton,
        with reading: MenuBarReading,
        presentation: MenuBarPresentation
    ) {
        button.attributedTitle = NSAttributedString()
        var title = presentation.valueText ?? ""
        if presentation.showsStaleIndicator {
            title = title.isEmpty ? "⚠︎" : "\(title) ⚠︎"
        }

        button.image = statusImage(for: reading.provider)
        button.title = title
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
