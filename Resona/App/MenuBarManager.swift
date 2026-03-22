import AppKit
import SwiftUI

/// Owns the NSStatusItem (menu bar icon) and the popover it presents.
final class MenuBarManager: NSObject {

    // MARK: - Private Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let detectionService: MusicDetectionService
    private var eventMonitor: Any?

    // MARK: - Init

    init(detectionService: MusicDetectionService) {
        self.detectionService = detectionService
        super.init()
        setupStatusItem()
        setupPopover()
        setupObservers()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Resona")
        button.image?.isTemplate = true   // adapts to light/dark menu bar
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(detectionService: detectionService)
        )
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trackDidChange(_:)),
            name: .trackDidChange,
            object: nil
        )
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Close popover when user clicks outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Icon Updates

    @objc private func trackDidChange(_ notification: Notification) {
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let isPlaying = detectionService.playbackState == .playing

        DispatchQueue.main.async {
            if isPlaying {
                button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Resona – Playing")
            } else {
                button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Resona – Idle")
            }
            button.image?.isTemplate = true
        }
    }
}
