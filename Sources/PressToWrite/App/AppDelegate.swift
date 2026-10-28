import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    public var statusItem: NSStatusItem?
    public var pillPanel: FloatingPillPanel?

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private var watchdogTimer: Timer?
    private var correctionPanel: CorrectionSuggestionPanel?
    private var correctionSubscription: AnyCancellable?
    private var correctionFocusObserver: NSObjectProtocol?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as standard macOS application with Dock presence
        NSApp.setActivationPolicy(.regular)

        setupMainMenu()
        setupStatusItem()
        setupFloatingPill()
        setupCorrectionSuggestions()

        // Start global keyboard and modifier listener
        HotkeyManager.shared.startListening()

        // All transcription runs through the local MLX daemon.
        Task { await AppState.shared.refreshEngineStatus() }

        // Keep-alive watchdog timer
        startWatchdog()

        // Show permissions window on first launch if permissions not granted
        if !HotkeyManager.isAccessibilityGranted() || !AudioRecorder.shared.hasPermission {
            openPermissions()
        }
    }

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                HotkeyManager.shared.rearmIfAccessibilityBecameTrusted()
                self.ensureStatusItemVisible()
                await AppState.shared.refreshEngineStatus()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let correctionFocusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(correctionFocusObserver)
        }
        correctionSubscription?.cancel()
        correctionPanel?.orderOut(nil)
        MicrophoneController.shared.endMonitoring()
        AppState.shared.cancelDictation(showFeedback: false)
        HotkeyManager.shared.stopListening()
        pillPanel?.saveCurrentPosition()
        LocalDaemonClient.shared.terminateLaunchedDaemon()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureStatusItemVisible()
        pillPanel?.orderFront(nil)
        return true
    }

    private func setupFloatingPill() {
        let panel = FloatingPillPanel()
        panel.orderFront(nil)
        self.pillPanel = panel
    }

    private func setupCorrectionSuggestions() {
        correctionSubscription = AppState.shared.$correctionSuggestions
            .receive(on: RunLoop.main)
            .sink { [weak self] suggestions in
                guard let self else { return }
                guard let suggestion = suggestions.first, let frame = self.pillPanel?.frame else {
                    self.correctionPanel?.orderOut(nil)
                    return
                }
                if let panel = self.correctionPanel { panel.update(suggestion) }
                else { self.correctionPanel = CorrectionSuggestionPanel(suggestion: suggestion) }
                self.correctionPanel?.show(near: frame)
            }
        correctionFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.stopCorrectionLearning() }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. Application Menu (Press To Write)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let aboutItem = NSMenuItem(title: "About Press To Write", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: "Permissions & Setup...", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        appMenu.addItem(permissionsItem)

        let historyItem = NSMenuItem(title: "Dictation History...", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        appMenu.addItem(historyItem)

        appMenu.addItem(NSMenuItem.separator())

        let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesMenuItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesMenuItem)

        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide Press To Write", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Press To Write", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Edit Menu (crucial for copy/paste/select in input fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func setupStatusItem() {
        let autosaveName = "PressToWriteMenuBar"
        // Remove the earlier forced placement once, then let macOS and the user
        // choose and retain the icon's position normally.
        let previousPlacementOverride = "presstowrite_menu_position_seeded_v1"
        if UserDefaults.standard.bool(forKey: previousPlacementOverride) {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(autosaveName)")
            UserDefaults.standard.removeObject(forKey: previousPlacementOverride)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Press To Write")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
            if icon == nil { button.title = "P" }
            button.imagePosition = icon == nil ? .noImage : .imageOnly
            button.toolTip = "Press To Write — Local Dictation"
            button.setAccessibilityLabel("Press To Write")
        }

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Press To Write", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let dictateItem = NSMenuItem(title: "Dictate (Hold Fn)", action: #selector(toggleDictation), keyEquivalent: "")
        dictateItem.target = self
        menu.addItem(dictateItem)

        let copyLastItem = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLastDictationAction), keyEquivalent: "c")
        copyLastItem.target = self
        menu.addItem(copyLastItem)

        let recoverItem = NSMenuItem(title: "Transcribe Last Recording", action: #selector(transcribeLastRecordingAction), keyEquivalent: "r")
        recoverItem.target = self
        menu.addItem(recoverItem)

        // Transcription Style Submenu
        let styleMenuItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleSubmenu = NSMenu()
        for style in TranscriptionStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            styleSubmenu.addItem(item)
        }
        styleMenuItem.submenu = styleSubmenu
        menu.addItem(styleMenuItem)

        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "Dictation History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings & Vocabulary...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: "Permissions & Setup...", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        // Snap Floating Pill Submenu
        let snapMenuItem = NSMenuItem(title: "Snap Floating Pill", action: nil, keyEquivalent: "")
        let snapSubmenu = NSMenu()
        let snapTargets: [(String, PillSnapTarget)] = [
            ("Bottom Center", .bottomCenter),
            ("Bottom Left", .bottomLeft),
            ("Bottom Right", .bottomRight),
            ("Left Edge (Vertical)", .leftCenter),
            ("Right Edge (Vertical)", .rightCenter),
            ("Top Center", .topCenter),
            ("Top Left", .topLeft),
            ("Top Right", .topRight)
        ]
        for (title, target) in snapTargets {
            let item = NSMenuItem(title: title, action: #selector(snapPillToTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            snapSubmenu.addItem(item)
        }
        snapMenuItem.submenu = snapSubmenu
        menu.addItem(snapMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Press To Write", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        item.menu = menu
        self.statusItem = item

    }

    private func ensureStatusItemVisible() {
        guard let statusItem else {
            setupStatusItem()
            return
        }
        if !statusItem.isVisible { statusItem.isVisible = true }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        if let copyItem = menu.items.first(where: { $0.action == #selector(copyLastDictationAction) }) {
            let lastText = AppState.shared.lastTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if lastText.isEmpty {
                copyItem.title = "Copy Last Dictation (None)"
                copyItem.isEnabled = false
            } else {
                let preview = lastText.count > 25 ? String(lastText.prefix(22)) + "..." : lastText
                copyItem.title = "Copy: \"\(preview)\""
                copyItem.isEnabled = true
            }
        }
        if let recoverItem = menu.items.first(where: { $0.action == #selector(transcribeLastRecordingAction) }) {
            if RescueAudioController.shared.hasRescueAudio {
                let duration = RescueAudioController.shared.pendingMetadata?.duration ?? 0.0
                recoverItem.title = String(format: "Transcribe Last Recording (%.1fs)", duration)
                recoverItem.isEnabled = !AppState.shared.isRecording && !AppState.shared.isProcessing
            } else {
                recoverItem.title = "Transcribe Last Recording (None)"
                recoverItem.isEnabled = false
            }
        }
    }

    @objc private func toggleDictation() {
        AppState.shared.toggleRecording()
    }

    @objc private func copyLastDictationAction() {
        AppState.shared.copyLastDictation()
    }

    @objc private func transcribeLastRecordingAction() {
        AppState.shared.transcribeRescueAudio()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? TranscriptionStyle {
            AppState.shared.transcriptionStyle = style
        }
    }

    @objc public func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Press To Write Settings"
            window.delegate = self
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        MicrophoneController.shared.beginMonitoring()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            MicrophoneController.shared.endMonitoring()
        }
    }

    @objc public func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Press To Write History"
            window.center()
            window.contentView = NSHostingView(rootView: HistoryView())
            window.isReleasedWhenClosed = false
            self.historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func openPermissions() {
        if permissionsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Press To Write Permissions & Setup"
            window.center()
            window.contentView = NSHostingView(rootView: PermissionsView())
            window.isReleasedWhenClosed = false
            self.permissionsWindow = window
        }
        permissionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func centerPill() {
        pillPanel?.resetPositionToCenter()
    }

    @objc private func snapPillToTarget(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? PillSnapTarget {
            pillPanel?.snap(to: target)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
