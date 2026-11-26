import AppKit
import Combine
import SwiftUI

/// The menu-bar icon and the popover under it.
///
/// An NSPopover, not SwiftUI's MenuBarExtra: when Settings opens or closes, MenuBarExtra resizes
/// its window around the window's own centre, so the menu jumps away from the menu bar. A popover
/// stays attached to the icon and grows downwards.
@MainActor
final class MenuBarItem: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private var watching: Set<AnyCancellable> = []
    private var outsideClicks: Any?

    init(model: AppModel) {
        super.init()
        let content = NSHostingController(rootView: MenuView(model: model))
        content.sizingOptions = .preferredContentSize   // the popover follows the content's height
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = false   // the content changes at once; an animated frame would trail it
        popover.delegate = self

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "figure.strengthtraining.functional",
                                   accessibilityDescription: "Squats")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
        }
        model.$ledger.map(\.owed).removeDuplicates()
            .sink { [weak self] owed in self?.item.button?.title = owed > 0 ? "\(owed)" : "" }
            .store(in: &watching)
        model.$sessionOpen.filter { $0 }   // starting a set closes the menu
            .sink { [weak self] _ in self?.popover.performClose(nil) }
            .store(in: &watching)
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { return popover.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)   // so the switches look live and ⌘Q reaches the menu
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // A click in another app does not reliably dismiss a popover owned by a menu-bar-only app.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClicks.map(NSEvent.removeMonitor)
        outsideClicks = nil
    }
}
