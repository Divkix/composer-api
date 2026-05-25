import CursorAPICore
import AppKit
import SwiftUI

@main
struct CursorAPIMacApp: App {
    @NSApplicationDelegateAdaptor(CursorAPIAppDelegate.self) private var appDelegate
    @StateObject private var model: CursorAPIAppModel

    init() {
        let model = CursorAPIAppModel()
        _model = StateObject(wrappedValue: model)
        CursorAPIWindowRestorer.shared.model = model
        DispatchQueue.main.async {
            CursorAPIWindowRestorer.shared.revealMainWindowSoon()
        }
    }

    var body: some Scene {
        Window(CursorAPIBrand.displayName, id: "main") {
            CursorAPIAppRootView(model: model)
        }
        .defaultSize(width: 893, height: 592)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: model)
                .frame(width: 560)
        }
    }
}

private struct CursorAPIAppRootView: View {
    @ObservedObject var model: CursorAPIAppModel

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 760, minHeight: 560)
            .task {
                model.startServer(allowKeychainPrompt: false)
            }
    }
}

final class CursorAPIAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CursorAPIWindowRestorer.shared.revealMainWindowSoon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            CursorAPIWindowRestorer.shared.revealMainWindowSoon()
        }
        return true
    }
}

@MainActor
final class CursorAPIWindowRestorer {
    static let shared = CursorAPIWindowRestorer()

    var model: CursorAPIAppModel?
    private var fallbackWindow: NSWindow?

    func revealMainWindowSoon() {
        for delay in [0.25, 0.75, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.revealMainWindow()
            }
        }
    }

    private func revealMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = visibleMainWindow() {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let model else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 893, height: 592),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = CursorAPIBrand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 560)
        window.contentViewController = NSHostingController(rootView: CursorAPIAppRootView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func visibleMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && window.canBecomeKey
                && (window.title == CursorAPIBrand.displayName || window.contentViewController is NSHostingController<CursorAPIAppRootView>)
        }
    }
}
