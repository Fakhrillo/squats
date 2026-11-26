import AppKit

/// A plain AppKit entry point: the whole app is one menu-bar item, so there is no SwiftUI scene.
@main
@MainActor
final class SquatsApp: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menu: MenuBarItem?

    static func main() {
        let app = SquatsApp()
        NSApplication.shared.delegate = app   // a weak reference: an optimised build frees `app` here
        withExtendedLifetime(app) { NSApplication.shared.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        menu = MenuBarItem(model: model)
    }
}
