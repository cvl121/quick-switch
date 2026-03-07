import AppKit
import CoreServices

struct Browser: Hashable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let url: URL

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier.lowercased())
    }

    static func == (lhs: Browser, rhs: Browser) -> Bool {
        lhs.bundleIdentifier.caseInsensitiveCompare(rhs.bundleIdentifier) == .orderedSame
    }
}

final class BrowserManager {

    func detectBrowsers() -> [Browser] {
        guard let httpsURL = URL(string: "https://example.com") else { return [] }
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: httpsURL)

        var browsers: [Browser] = []
        var seen = Set<String>()

        for appURL in appURLs {
            guard let bundle = Bundle(url: appURL),
                  let bundleID = bundle.bundleIdentifier else { continue }

            let key = bundleID.lowercased()
            guard !seen.contains(key) else { continue }
            guard key != "org.chromium.chromium" else { continue }
            seen.insert(key)

            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? appURL.deletingPathExtension().lastPathComponent

            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 18, height: 18)

            browsers.append(Browser(bundleIdentifier: bundleID, name: name, icon: icon, url: appURL))
        }

        return browsers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func getDefaultBrowserBundleID() -> String? {
        guard let url = URL(string: "https:") else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Changes the default browser by writing directly to the LaunchServices
    /// preferences plist and reloading the daemon. This bypasses
    /// `LSSetDefaultHandlerForURLScheme` which triggers a system confirmation
    /// dialog on modern macOS.
    func setDefaultBrowser(_ bundleIdentifier: String) -> Bool {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices")
        let prefsFile = prefsDir.appendingPathComponent("com.apple.launchservices.secure.plist")

        // Read existing plist (or start fresh)
        var plist: [String: Any]
        var handlers: [[String: Any]]

        if let data = try? Data(contentsOf: prefsFile),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = root
            handlers = (root["LSHandlers"] as? [[String: Any]]) ?? []
        } else {
            plist = [:]
            handlers = []
        }

        let now = Int(Date().timeIntervalSinceReferenceDate)

        // Schemes and content types we need to update
        let urlSchemes = ["http", "https"]
        let contentTypes = ["public.html", "com.apple.default-app.web-browser"]

        // Update existing URL scheme entries
        var updatedSchemes = Set<String>()
        var updatedTypes = Set<String>()

        for i in handlers.indices {
            if let scheme = handlers[i]["LSHandlerURLScheme"] as? String,
               urlSchemes.contains(scheme.lowercased()) {
                handlers[i]["LSHandlerRoleAll"] = bundleIdentifier
                handlers[i]["LSHandlerModificationDate"] = now
                updatedSchemes.insert(scheme.lowercased())
            }
            if let ct = handlers[i]["LSHandlerContentType"] as? String,
               contentTypes.contains(ct.lowercased()) {
                handlers[i]["LSHandlerRoleAll"] = bundleIdentifier
                handlers[i]["LSHandlerModificationDate"] = now
                updatedTypes.insert(ct.lowercased())
            }
        }

        // Add missing entries
        for scheme in urlSchemes where !updatedSchemes.contains(scheme) {
            handlers.append([
                "LSHandlerURLScheme": scheme,
                "LSHandlerRoleAll": bundleIdentifier,
                "LSHandlerModificationDate": now,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"]
            ])
        }
        for ct in contentTypes where !updatedTypes.contains(ct) {
            handlers.append([
                "LSHandlerContentType": ct,
                "LSHandlerRoleAll": bundleIdentifier,
                "LSHandlerModificationDate": now,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"]
            ])
        }

        plist["LSHandlers"] = handlers

        // Write back as binary plist
        guard let newData = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        ) else { return false }

        do {
            try FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
            try newData.write(to: prefsFile, options: .atomic)
        } catch {
            return false
        }

        // Reload LaunchServices so the change takes effect immediately
        reloadLaunchServices()
        return true
    }

    private func reloadLaunchServices() {
        // Restart the LaunchServices daemon so it re-reads the plist.
        // `killall lsd` is much faster than `lsregister -kill -r` and
        // immediately makes NSWorkspace reflect the new default.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["lsd"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
