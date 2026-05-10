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

        if let logoImage = menuBarImage() {
            button.image = logoImage
        } else {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Resona")
            button.image?.isTemplate = true
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func menuBarImage() -> NSImage? {
        if let img = NSImage(named: "ResonaMenuBarIcon") {
            img.isTemplate = false
            img.size = NSSize(width: 22, height: 22)
            return img
        }
        if let url = Bundle.main.url(forResource: "ResonaMenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = false
            img.size = NSSize(width: 22, height: 22)
            return img
        }
        return nil
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior    = .transient
        popover.animates    = false   // we handle our own open animation

        // ── Fluid glass popover ──────────────────────────────────────────
        // FluidPopoverViewController layers:
        //   Metal fluid shader → frosted glass → grain → SwiftUI content
        let fluidVC = FluidPopoverViewController(detectionService: detectionService)
        popover.contentViewController = fluidVC

        // Make the popover window itself transparent so rounded corners show
        // against the desktop without a white halo.
        // This must be set after contentViewController is assigned.
        DispatchQueue.main.async {
            if let popoverWindow = self.popover.contentViewController?.view.window {
                popoverWindow.backgroundColor = .clear
                popoverWindow.isOpaque        = false
            }
        }
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trackDidChange(_:)),
            name: .trackDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverForAppAction),
            name: .closePopoverRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverForAppAction),
            name: .quitRequested,
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

        // Make the popover's backing window transparent after it appears
        // (NSPopover creates its window lazily on first show).
        DispatchQueue.main.async {
            if let win = self.popover.contentViewController?.view.window {
                win.backgroundColor = .clear
                win.isOpaque        = false
                win.hasShadow       = true
            }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        // Remove the event monitor first to prevent re-entry during animation
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        // Animate out before closing
        guard let vc = popover.contentViewController else {
            popover.performClose(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            vc.view.animator().alphaValue = 0
        }, completionHandler: {
            self.popover.performClose(nil)
            vc.view.alphaValue = 1   // reset for next open
        })
    }

    @objc private func closePopoverForAppAction() {
        if popover.isShown {
            closePopover()
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
            button.alphaValue = isPlaying ? 1.0 : 0.55
            button.toolTip    = isPlaying ? "Resona — Playing" : "Resona — Idle"
        }
    }
}
