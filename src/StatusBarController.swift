import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let browserManager = BrowserManager()
    private var browsers: [Browser] = []
    private var currentDefaultBundleID: String?
    private var directoryMonitorSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var launchAtLoginItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.toolTip = "Quick Switch"
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshBrowsers()
        updateStatusBarIcon()
        startDirectoryMonitoring()
    }

    deinit {
        directoryMonitorSource?.cancel()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Rebuild the menu each time it opens to reflect current state
        buildMenu()
    }

    // MARK: - Browser list

    func refreshBrowsers() {
        browsers = browserManager.detectBrowsers()
        currentDefaultBundleID = browserManager.getDefaultBrowserBundleID()
        buildMenu()
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }

        if let defaultID = currentDefaultBundleID,
           let browser = browsers.first(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(defaultID) == .orderedSame
           }) {
            let icon = NSWorkspace.shared.icon(forFile: browser.url.path)
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        } else {
            // Fallback to globe if we can't determine the default
            let fallback = NSImage(
                systemSymbolName: "globe",
                accessibilityDescription: "Quick Switch"
            )
            fallback?.isTemplate = true
            button.image = fallback
        }
    }

    private func buildMenu() {
        menu.removeAllItems()

        let currentDefault = currentDefaultBundleID

        if browsers.isEmpty {
            let noItem = NSMenuItem(title: "No browsers found", action: nil, keyEquivalent: "")
            noItem.isEnabled = false
            menu.addItem(noItem)
        } else {
            for browser in browsers {
                let item = NSMenuItem(
                    title: browser.name,
                    action: #selector(browserSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.image = browser.icon
                item.representedObject = browser

                if let currentDefault,
                   browser.bundleIdentifier.caseInsensitiveCompare(currentDefault) == .orderedSame {
                    item.state = .on
                }

                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Browsers",
            action: #selector(refreshTriggered),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func browserSelected(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? Browser else { return }

        let success = browserManager.setDefaultBrowser(browser.bundleIdentifier)

        if success {
            // Update our tracked default immediately — don't wait for NSWorkspace
            // cache to refresh after the lsd restart.
            currentDefaultBundleID = browser.bundleIdentifier
            buildMenu()
            updateStatusBarIcon()
        } else {
            let alert = NSAlert()
            alert.messageText = "Failed to set default browser"
            alert.informativeText = "Could not write to the LaunchServices preferences. Check file permissions."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func refreshTriggered() {
        refreshBrowsers()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if isLaunchAtLoginEnabled() {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Login Item Error"
            alert.informativeText = "Could not update login item setting: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Directory Monitoring

    private func startDirectoryMonitoring() {
        watchDirectory("/Applications")
    }

    private func watchDirectory(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            // Debounce: cancel any pending refresh and schedule a new one
            // so bulk installs coalesce into a single refresh.
            self?.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshBrowsers()
            }
            self?.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directoryMonitorSource = source
    }
}
