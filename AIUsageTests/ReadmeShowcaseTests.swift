import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

/// Renders the README and social preview images from the app's real views.
///
/// Skipped unless `AIUSAGE_SHOWCASE_DIR` is set. Run
/// `scripts/render_readme_images.sh` instead of running this directly: each
/// scene is shown on screen and its windows are captured by the window server,
/// so Liquid Glass looks exactly as it does in the menu bar panel. All data is
/// made up.
@MainActor
final class ReadmeShowcaseTests: XCTestCase {
    func testRenderReadmeShowcase() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["AIUSAGE_SHOWCASE_DIR"], !path.isEmpty else {
            throw XCTSkip("Set AIUSAGE_SHOWCASE_DIR to render the README images.")
        }
        let only = environment["AIUSAGE_SHOWCASE_ONLY"]
            .map { $0.split(separator: ",").map(String.init) }
            .flatMap { $0.isEmpty ? nil : Set($0) }
        let studio = ShowcaseStudio(
            directory: URL(fileURLWithPath: path, isDirectory: true),
            only: only
        )
        try await studio.renderAll()
    }
}

// MARK: - Studio

@MainActor
private final class ShowcaseStudio {
    static let locale = Locale(identifier: "en_US")
    private static let sceneWidth: CGFloat = 960
    private static let menuBarHeight: CGFloat = 32

    private let directory: URL
    private let only: Set<String>?
    private let registry = ShowcaseAnchorRegistry()
    private var log: [String] = []

    init(directory: URL, only: Set<String>?) {
        self.directory = directory
        self.only = only
    }

    func renderAll() async throws {
        let now = Date()
        let store = await ShowcaseData.store(now: now, detailed: true)
        let heroStore = await ShowcaseData.store(now: now, detailed: false)
        defer {
            store.stop()
            heroStore.stop()
        }

        try renderDownloadButton()
        try await bringToFront()
        for look in ShowcaseLook.allCases {
            try await renderHero(look: look, store: heroStore)
            try await renderProviders(look: look, store: store)
            try await renderMenuBarStyles(look: look, store: store)
            try await renderSettings(look: look, store: store)
        }
        try await renderSocialPreview(store: heroStore)

        try log.joined(separator: "\n").write(
            to: directory.appendingPathComponent("showcase.log"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: Scenes

    private func renderHero(look: ShowcaseLook, store: UsageStore) async throws {
        let name = "hero-\(look.rawValue)"
        guard shouldRender(name) else { return }

        let panel = makePanel(
            DashboardView(
                store: store,
                launchAtLogin: LaunchAtLoginController(
                    service: ShowcaseLoginService()
                ),
                usageDisplayMode: .constant(.remaining),
                refreshInterval: .constant(.fiveMinutes),
                availableUpdateVersion: nil,
                isCheckingForUpdates: false
            ),
            width: MenuBarPanelRoute.dashboard.width
        )
        let size = CGSize(
            width: Self.sceneWidth,
            height: Self.menuBarHeight + 14 + panel.size.height + 72
        )
        let scene = DesktopScene(
            look: look,
            statusImage: heroStatusImage(store: store),
            registry: registry
        )
        try await present(name, look: look, size: size, scene: scene, panel: panel)
    }

    private func renderSettings(look: ShowcaseLook, store: UsageStore) async throws {
        let name = "settings-\(look.rawValue)"
        guard shouldRender(name) else { return }

        let suiteName = "ReadmeShowcase.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: store.availableMenuBarItemsByProvider
        )
        preferences.setMenuBarMetric(
            true,
            item: MenuBarItemID(provider: .claude, metric: .session),
            availableItems: store.availableMenuBarItems(for: .claude)
        )

        let panel = makePanel(
            SettingsView(
                store: store,
                preferences: preferences,
                launchAtLogin: LaunchAtLoginController(
                    service: ShowcaseLoginService()
                ),
                updateController: UpdateController(startingUpdater: false)
            ),
            width: MenuBarPanelRoute.settings.width
        )
        let size = CGSize(
            width: Self.sceneWidth,
            height: Self.menuBarHeight + 14 + panel.size.height + 64
        )
        let scene = DesktopScene(
            look: look,
            statusImage: heroStatusImage(store: store),
            registry: registry
        )
        try await present(name, look: look, size: size, scene: scene, panel: panel)
    }

    private func renderProviders(look: ShowcaseLook, store: UsageStore) async throws {
        let name = "providers-\(look.rawValue)"
        guard shouldRender(name) else { return }

        let wall = ProviderWall(store: store)
        let measured = NSHostingController(rootView: wall)
            .sizeThatFits(in: CGSize(width: Self.sceneWidth, height: 4_000))
        let size = CGSize(width: Self.sceneWidth, height: ceil(measured.height))
        let scene = ZStack {
            ShowcaseWallpaper(look: look, topInset: 0)
            wall
        }
        try await present(name, look: look, size: size, scene: scene, panel: nil)
    }

    private func renderMenuBarStyles(
        look: ShowcaseLook,
        store: UsageStore
    ) async throws {
        let name = "menubar-\(look.rawValue)"
        guard shouldRender(name) else { return }

        let rows = [
            MenuBarStyleRow(
                title: "One limit",
                detail: "Claude Code's weekly limit",
                image: statusImage(store: store, [
                    .init(provider: .claude, metrics: [.weekly])
                ])
            ),
            MenuBarStyleRow(
                title: "Several limits",
                detail: "Session and weekly, with tiny labels",
                image: statusImage(store: store, [
                    .init(provider: .claude, metrics: [.session, .weekly])
                ])
            ),
            MenuBarStyleRow(
                title: "Several tools",
                detail: "Claude Code, Codex, Cursor, and Antigravity",
                image: statusImage(store: store, [
                    .init(provider: .claude, metrics: [.weekly]),
                    .init(provider: .codex, metrics: [.weekly]),
                    .init(provider: .cursor, metrics: [.totalUsage]),
                    .init(provider: .antigravity, metrics: [.weekly])
                ])
            ),
            MenuBarStyleRow(
                title: "Banked resets",
                detail: "Codex's weekly limit and 3 resets to spend",
                image: statusImage(store: store, [
                    .init(provider: .codex, metrics: [.weekly, .resets])
                ])
            )
        ]
        let content = MenuBarStylesView(look: look, rows: rows)
        let measured = NSHostingController(rootView: content)
            .sizeThatFits(in: CGSize(width: Self.sceneWidth, height: 4_000))
        let size = CGSize(width: Self.sceneWidth, height: ceil(measured.height))
        let scene = ZStack {
            ShowcaseWallpaper(look: look, topInset: 0)
            content
        }
        try await present(name, look: look, size: size, scene: scene, panel: nil)
    }

    private func renderSocialPreview(store: UsageStore) async throws {
        let name = "social-preview"
        guard shouldRender(name) else { return }

        let look = ShowcaseLook.dark
        let panel = makePanel(
            DashboardView(
                store: store,
                launchAtLogin: LaunchAtLoginController(
                    service: ShowcaseLoginService()
                ),
                usageDisplayMode: .constant(.remaining),
                refreshInterval: .constant(.fiveMinutes),
                availableUpdateVersion: nil,
                isCheckingForUpdates: false
            ),
            width: MenuBarPanelRoute.dashboard.width
        )
        let scene = DesktopScene(
            look: look,
            statusImage: heroStatusImage(store: store),
            registry: registry,
            overlay: AnyView(SocialTitle(icon: Self.appIcon(look: look)))
        )
        try await present(
            name,
            look: look,
            size: CGSize(width: 1_280, height: 640),
            scene: scene,
            panel: panel
        )
    }

    private func renderDownloadButton() throws {
        let name = "download-button"
        guard shouldRender(name) else { return }

        let renderer = ImageRenderer(content: DownloadButtonArt())
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.cgImage else {
            throw ShowcaseError.renderFailed(name)
        }
        try writePNG(image, name: name)
    }

    // MARK: Presentation

    /// People open the panel by clicking its menu bar item, which makes AI
    /// Usage the active app, and controls and Liquid Glass only draw their
    /// active appearance there. A test host can't take activation from the
    /// frontmost app through public API, so ask the window server directly,
    /// as window switchers do. If that fails, scenes render inactive.
    private func bringToFront() async throws {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        typealias ProcessForPID = @convention(c) (
            pid_t,
            UnsafeMutablePointer<ProcessSerialNumber>
        ) -> OSStatus
        typealias SetFrontProcess = @convention(c) (
            UnsafeMutablePointer<ProcessSerialNumber>,
            UInt32,
            UInt32
        ) -> Int32
        if !NSApp.isActive,
           let processSymbol = dlsym(defaultHandle, "GetProcessForPID"),
           let frontSymbol = dlsym(defaultHandle, "_SLPSSetFrontProcessWithOptions") {
            var process = ProcessSerialNumber()
            let processForPID = unsafeBitCast(processSymbol, to: ProcessForPID.self)
            if processForPID(getpid(), &process) == noErr {
                let setFront = unsafeBitCast(frontSymbol, to: SetFrontProcess.self)
                let userGenerated: UInt32 = 0x200
                _ = setFront(&process, 0, userGenerated)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !NSApp.isActive, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        log.append("active=\(NSApp.isActive)")
    }

    private struct Panel {
        let controller: NSHostingController<AnyView>
        let size: CGSize
    }

    private func makePanel(_ view: some View, width: CGFloat) -> Panel {
        let controller = NSHostingController(
            rootView: AnyView(view.environment(\.locale, Self.locale))
        )
        controller.sizingOptions = [.preferredContentSize]
        let measured = controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let size = CGSize(width: width, height: ceil(measured.height))
        controller.preferredContentSize = size
        return Panel(controller: controller, size: size)
    }

    private func present(
        _ name: String,
        look: ShowcaseLook,
        size: CGSize,
        scene: some View,
        panel: Panel?
    ) async throws {
        registry.views.removeAll()
        let window = makeWindow(size: size, look: look, root: scene)
        defer { window.orderOut(nil) }
        try await settle(0.8)

        var popover: NSPopover?
        if let panel {
            guard let anchor = registry.views[DesktopScene.statusAnchorID] else {
                throw ShowcaseError.missingAnchor(name)
            }
            let shown = NSPopover()
            shown.behavior = .applicationDefined
            shown.animates = false
            shown.appearance = look.appearance
            shown.contentViewController = panel.controller
            shown.contentSize = panel.size
            shown.show(
                relativeTo: anchor.bounds,
                of: anchor,
                preferredEdge: .minY
            )
            if let popoverWindow = shown.contentViewController?.view.window {
                popoverWindow.level = NSWindow.Level(
                    rawValue: NSWindow.Level.statusBar.rawValue + 1
                )
                popoverWindow.makeKey()
                Self.hideScrollBars(in: popoverWindow.contentView)
            }
            popover = shown
        }

        try await settle(1.2)
        if let popoverWindow = popover?.contentViewController?.view.window {
            Self.hideScrollBars(in: popoverWindow.contentView)
        }
        try await settle(1.4)
        log.append(
            "\(name): \(Int(size.width))x\(Int(size.height)) " +
                "active=\(NSApp.isActive) " +
                "panelKey=\(popover?.contentViewController?.view.window?.isKeyWindow ?? false)"
        )
        let windows = [popover?.contentViewController?.view.window, window]
            .compactMap { $0 }
        try await capture(name, frame: window.frame, windows: windows)

        popover?.close()
        popover?.contentViewController = nil
        try await settle(0.3)
    }

    /// The panel asks for hidden scroll indicators. A connected mouse can
    /// still show legacy scroll bars, so hide them as a trackpad would.
    private static func hideScrollBars(in view: NSView?) {
        guard let view else { return }
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
        }
        view.subviews.forEach(hideScrollBars)
    }

    private func makeWindow(
        size: CGSize,
        look: ShowcaseLook,
        root: some View
    ) -> NSWindow {
        let visible = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = CGRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = look.fallbackBackground
        window.appearance = look.appearance
        window.contentView = NSHostingView(
            rootView: root.environment(\.locale, Self.locale)
        )
        window.orderFrontRegardless()
        return window
    }

    /// Hands the scene to the capture script and waits until it is saved.
    /// The first line is the frame in screen points from the top left, the
    /// second the scene's windows from front to back.
    private func capture(
        _ name: String,
        frame: CGRect,
        windows: [NSWindow]
    ) async throws {
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let top = screenHeight - frame.maxY
        let rect = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        let windowIDs = windows.map { String($0.windowNumber) }.joined(separator: " ")
        let ready = directory.appendingPathComponent("\(name).ready")
        let done = directory.appendingPathComponent("\(name).done")
        try? FileManager.default.removeItem(at: done)
        try "\(rect)\n\(windowIDs)\n".write(to: ready, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: done.path) {
            guard Date() < deadline else {
                throw ShowcaseError.captureTimedOut(name)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func shouldRender(_ name: String) -> Bool {
        only?.contains(name) ?? true
    }

    private func writePNG(_ image: CGImage, name: String) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ShowcaseError.renderFailed(name)
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Menu bar images

    private func heroStatusImage(store: UsageStore) -> NSImage {
        statusImage(store: store, [
            .init(provider: .claude, metrics: [.session, .weekly]),
            .init(provider: .codex, metrics: [.weekly])
        ])
    }

    private func statusImage(
        store: UsageStore,
        _ configurations: [MenuBarProviderConfiguration]
    ) -> NSImage {
        MenuBarStatusImageRenderer.image(
            for: store.menuBarProviderReadings(
                for: configurations,
                displayMode: .remaining
            ),
            font: .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
        )
    }

    private static func appIcon(look: ShowcaseLook) -> NSImage {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let icon = repository
            .appendingPathComponent("docs/images/app-icon-\(look.rawValue).png")
        return NSImage(contentsOf: icon) ?? NSApp.applicationIconImage
    }
}

private enum ShowcaseError: Error {
    case missingAnchor(String)
    case captureTimedOut(String)
    case renderFailed(String)
}

// MARK: - Looks

private enum ShowcaseLook: String, CaseIterable {
    case dark
    case light

    struct Bar {
        let colors: [Color]
        let length: CGFloat
        let center: CGFloat
    }

    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }

    var fallbackBackground: NSColor {
        self == .dark
            ? NSColor(srgbRed: 0.04, green: 0.11, blue: 0.17, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.97, blue: 0.97, alpha: 1)
    }

    var backdrop: [Color] {
        switch self {
        case .dark: [Color(hex: 0x0B1A2E), Color(hex: 0x0A2A33)]
        case .light: [Color(hex: 0xF5F8F8), Color(hex: 0xE7EFF6)]
        }
    }

    var track: Color {
        self == .dark ? .white.opacity(0.045) : .black.opacity(0.035)
    }

    /// The app icon's three usage bars, scaled up into the desktop.
    var bars: [Bar] {
        switch self {
        case .dark:
            [
                Bar(colors: [Color(hex: 0x0D9488), Color(hex: 0x2DD4BF)], length: 0.84, center: 0.34),
                Bar(colors: [Color(hex: 0x1D4ED8), Color(hex: 0x60A5FA)], length: 0.58, center: 0.59),
                Bar(colors: [Color(hex: 0xEA580C), Color(hex: 0xFDBA74)], length: 0.31, center: 0.84)
            ]
        case .light:
            [
                Bar(colors: [Color(hex: 0x2DD4BF), Color(hex: 0x99F6E4)], length: 0.84, center: 0.34),
                Bar(colors: [Color(hex: 0x60A5FA), Color(hex: 0xBFDBFE)], length: 0.58, center: 0.59),
                Bar(colors: [Color(hex: 0xFB923C), Color(hex: 0xFED7AA)], length: 0.31, center: 0.84)
            ]
        }
    }

    var barBlur: CGFloat { 20 }

    var menuBarText: Color {
        self == .dark ? .white : .black.opacity(0.86)
    }

    var menuBarTint: Color {
        self == .dark ? .black.opacity(0.14) : .white.opacity(0.32)
    }

    var statusHighlight: Color {
        self == .dark ? .white.opacity(0.2) : .black.opacity(0.09)
    }

    var stripFill: Color {
        self == .dark ? .black.opacity(0.22) : .white.opacity(0.5)
    }

    var stripStroke: Color {
        self == .dark ? .white.opacity(0.1) : .black.opacity(0.06)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Scene views

@MainActor
private final class ShowcaseAnchorRegistry {
    var views: [String: NSView] = [:]
}

private struct ShowcaseAnchor: NSViewRepresentable {
    let id: String
    let registry: ShowcaseAnchorRegistry

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registry.views[id] = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registry.views[id] = nsView
    }
}

private struct ShowcaseWallpaper: View {
    let look: ShowcaseLook
    var topInset: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = max(proxy.size.height - topInset, 1)
            let barHeight = min(height * 0.2, 150)

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: look.backdrop,
                    startPoint: .top,
                    endPoint: .bottom
                )

                ForEach(Array(look.bars.enumerated()), id: \.offset) { _, bar in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(look.track)
                            .frame(width: width * 1.3, height: barHeight)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: bar.colors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: width * (bar.length + 0.12),
                                height: barHeight
                            )
                    }
                    .offset(
                        x: -width * 0.12,
                        y: topInset + height * bar.center - barHeight / 2
                    )
                }
                .blur(radius: look.barBlur)
            }
        }
        .clipped()
    }
}

private struct DesktopScene: View {
    static let statusAnchorID = "status"

    let look: ShowcaseLook
    let statusImage: NSImage
    let registry: ShowcaseAnchorRegistry
    var overlay: AnyView?

    var body: some View {
        ZStack(alignment: .top) {
            ShowcaseWallpaper(look: look)
            if let overlay {
                overlay
            }
            ShowcaseMenuBar(
                look: look,
                statusImage: statusImage,
                registry: registry
            )
        }
    }
}

private struct ShowcaseMenuBar: View {
    let look: ShowcaseLook
    let statusImage: NSImage
    let registry: ShowcaseAnchorRegistry

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 21) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 15, weight: .medium))
                    .offset(y: -1)
                Text("Terminal")
                    .fontWeight(.bold)
                ForEach(["Shell", "Edit", "View", "Window", "Help"], id: \.self) {
                    Text($0)
                }
            }

            Spacer(minLength: 24)

            HStack(spacing: 17) {
                Image(nsImage: statusImage)
                    .renderingMode(.template)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(look.statusHighlight))
                    .background(
                        ShowcaseAnchor(
                            id: DesktopScene.statusAnchorID,
                            registry: registry
                        )
                    )
                SystemMenuBarItems()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(look.menuBarText)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(look.menuBarTint)
    }
}

private struct SystemMenuBarItems: View {
    var compact = false

    var body: some View {
        HStack(spacing: 17) {
            Image(systemName: "battery.75percent")
                .font(.system(size: 15))
            Image(systemName: "wifi")
            if !compact {
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
            }
            Text(compact ? "9:41" : "Fri Nov 6  9:41")
        }
        .fixedSize()
    }
}

private struct ProviderWall: View {
    let store: UsageStore

    private let columns: [[ProviderID]] = [
        [.claude, .antigravity, .devin, .grok, .kiro],
        [.codex, .cursor, .copilot, .zai]
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(columns.indices, id: \.self) { column in
                VStack(spacing: 16) {
                    ForEach(columns[column], id: \.self) { provider in
                        if let state = store.states[provider] {
                            ProviderSectionView(
                                state: state,
                                displayMode: .remaining
                            )
                            .frame(width: 372)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

private struct MenuBarStyleRow {
    let title: String
    let detail: String
    let image: NSImage
}

private struct MenuBarStylesView: View {
    let look: ShowcaseLook
    let rows: [MenuBarStyleRow]

    var body: some View {
        VStack(spacing: 18) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text(row.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 300, alignment: .leading)
                    HStack(spacing: 17) {
                        Image(nsImage: row.image)
                            .renderingMode(.template)
                        SystemMenuBarItems(compact: true)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(look.menuBarText)
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(look.stripFill))
                    .overlay(Capsule().strokeBorder(look.stripStroke))
                    .frame(width: 400, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

private struct SocialTitle: View {
    let icon: NSImage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .padding(.leading, -10)
                    .padding(.bottom, 18)
                Text("AI Usage")
                    .font(.system(size: 88, weight: .bold))
                    .tracking(-1.5)
                Text("Every AI coding limit,\nright in your menu bar.")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineSpacing(4)
                    .padding(.top, 6)
                HStack(spacing: 20) {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        ProviderIcon(provider: provider, size: 30)
                    }
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.top, 38)
            }
            .foregroundStyle(.white)
            Spacer()
        }
        .padding(.leading, 80)
        .padding(.top, 32)
        .frame(maxHeight: .infinity)
    }
}

private struct DownloadButtonArt: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
                .font(.system(size: 19, weight: .semibold))
                .offset(y: -1)
            Text("Download for macOS")
                .font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .frame(height: 50)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: [Color(hex: 0x14A394), Color(hex: 0x0B7F86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        .padding(6)
    }
}

// MARK: - Demo data

@MainActor
private enum ShowcaseData {
    /// `detailed` adds Claude Code's model-specific limit, which the hero
    /// leaves out so the next provider peeks into the scrolling panel.
    static func store(now: Date, detailed: Bool) async -> UsageStore {
        let providers = snapshots(now: now, detailed: detailed)
            .map(ShowcaseProvider.init)
        let store = UsageStore(
            providers: providers,
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: Set(ProviderID.allCases)
            )
        )
        await store.refresh()
        return store
    }

    private static func snapshots(now: Date, detailed: Bool) -> [ProviderSnapshot] {
        func window(_ kind: QuotaKind, used: Double, in seconds: TimeInterval?) -> QuotaWindow {
            QuotaWindow(
                kind: kind,
                usedPercent: used,
                resetsAt: seconds.map { now.addingTimeInterval($0) }
            )
        }
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        return [
            ProviderSnapshot(
                provider: .claude,
                planName: "Max",
                windows: [
                    window(.session, used: 38, in: 1 * hour + 52 * 60),
                    window(.weekly, used: 64, in: 2 * day + 19 * hour)
                ] + (detailed ? [window(.fable, used: 21, in: 2 * day + 19 * hour)] : []),
                billingUsage: .boundedSpend(
                    usedAmount: 18.4,
                    limitAmount: 50,
                    currencyCode: "USD"
                ),
                resets: UsageResets(
                    availableCount: 2,
                    expirations: [now + 19 * hour, now + 5 * day]
                ),
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .codex,
                planName: "Pro 200",
                windows: [
                    window(.session, used: 12, in: 3 * hour + 41 * 60),
                    window(.weekly, used: 26, in: 5 * day + 2 * hour)
                ],
                resets: UsageResets(
                    availableCount: 3,
                    expirations: [now + 2 * day + 6 * hour, now + 9 * day, now + 16 * day]
                ),
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .cursor,
                planName: "Pro",
                windows: [
                    window(.totalUsage, used: 47, in: 12 * day),
                    window(.autoUsage, used: 31, in: 12 * day),
                    window(.apiUsage, used: 18, in: 12 * day)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .antigravity,
                planName: "Google AI Pro",
                windows: [
                    window(.session, used: 24, in: 3 * hour + 10 * 60),
                    window(.weekly, used: 41, in: 4 * day + 7 * hour),
                    window(.argonWeekly, used: 9, in: 4 * day + 7 * hour),
                    window(.claudePool, used: 55, in: 2 * hour + 25 * 60)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .copilot,
                planName: "Individual Pro",
                windows: [
                    window(.credits, used: 33, in: 18 * day),
                    window(.chat, used: 12, in: 18 * day),
                    window(.completions, used: 4, in: 18 * day)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .devin,
                planName: "Team",
                windows: [
                    window(.daily, used: 45, in: 9 * hour),
                    window(.weekly, used: 72, in: 3 * day + 9 * hour)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .grok,
                planName: "SuperGrok",
                windows: [
                    window(.weekly, used: 28, in: 6 * day + 3 * hour)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .kiro,
                planName: "Pro+",
                windows: [
                    window(.credits, used: 42, in: 23 * day)
                ],
                fetchedAt: now
            ),
            ProviderSnapshot(
                provider: .zai,
                planName: "Pro",
                windows: [
                    window(.session, used: 15, in: 4 * hour + 20 * 60),
                    window(.weekly, used: 33, in: 5 * day + 11 * hour),
                    window(.webSearches, used: 10, in: 21 * day)
                ],
                fetchedAt: now
            )
        ]
    }
}

private actor ShowcaseProvider: UsageProvider {
    nonisolated let id: ProviderID
    private let snapshot: ProviderSnapshot

    init(_ snapshot: ProviderSnapshot) {
        id = snapshot.provider
        self.snapshot = snapshot
    }

    func fetch() async throws -> ProviderSnapshot {
        snapshot
    }
}

@MainActor
private struct ShowcaseLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .enabled }
    func register() throws {}
    func unregister() throws {}
}
