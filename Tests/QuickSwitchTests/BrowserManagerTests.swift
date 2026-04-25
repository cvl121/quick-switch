import XCTest
@testable import QuickSwitch

final class BrowserManagerTests: XCTestCase {

    private var tempDir: URL!
    private var prefsURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        prefsURL = tempDir.appendingPathComponent("com.apple.launchservices.secure.plist")
    }

    override func tearDownWithError() throws {
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Builds a manager that writes to the temp plist and never touches the
    /// real `lsd` daemon.
    private func makeManager() -> BrowserManager {
        BrowserManager(prefsFileURL: prefsURL, reloadDaemon: {})
    }

    private func readHandlers() throws -> [[String: Any]] {
        let data = try Data(contentsOf: prefsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (plist?["LSHandlers"] as? [[String: Any]]) ?? []
    }

    private func writeInitialPlist(_ handlers: [[String: Any]]) throws {
        let plist: [String: Any] = ["LSHandlers": handlers]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: prefsURL)
    }

    // MARK: - Correctness

    func testWritesHttpsHandler() throws {
        let manager = makeManager()
        XCTAssertTrue(manager.writeDefaultBrowserPreference("com.apple.Safari"))

        let handlers = try readHandlers()
        let https = handlers.first { ($0["LSHandlerURLScheme"] as? String) == "https" }
        XCTAssertEqual(https?["LSHandlerRoleAll"] as? String, "com.apple.Safari")
    }

    func testWritesHttpHandler() throws {
        let manager = makeManager()
        manager.writeDefaultBrowserPreference("com.apple.Safari")

        let handlers = try readHandlers()
        let http = handlers.first { ($0["LSHandlerURLScheme"] as? String) == "http" }
        XCTAssertEqual(http?["LSHandlerRoleAll"] as? String, "com.apple.Safari")
    }

    func testWritesContentTypeHandlers() throws {
        let manager = makeManager()
        manager.writeDefaultBrowserPreference("com.apple.Safari")

        let handlers = try readHandlers()
        let html = handlers.first { ($0["LSHandlerContentType"] as? String) == "public.html" }
        let webBrowser = handlers.first { ($0["LSHandlerContentType"] as? String) == "com.apple.default-app.web-browser" }
        XCTAssertEqual(html?["LSHandlerRoleAll"] as? String, "com.apple.Safari")
        XCTAssertEqual(webBrowser?["LSHandlerRoleAll"] as? String, "com.apple.Safari")
    }

    func testPreservesUnrelatedHandlers() throws {
        try writeInitialPlist([
            ["LSHandlerURLScheme": "mailto", "LSHandlerRoleAll": "com.apple.mail"],
            ["LSHandlerURLScheme": "ftp", "LSHandlerRoleAll": "com.example.ftp"],
        ])

        let manager = makeManager()
        manager.writeDefaultBrowserPreference("com.google.Chrome")

        let handlers = try readHandlers()
        let mailto = handlers.first { ($0["LSHandlerURLScheme"] as? String) == "mailto" }
        let ftp = handlers.first { ($0["LSHandlerURLScheme"] as? String) == "ftp" }
        XCTAssertEqual(mailto?["LSHandlerRoleAll"] as? String, "com.apple.mail")
        XCTAssertEqual(ftp?["LSHandlerRoleAll"] as? String, "com.example.ftp")
    }

    func testDoesNotDuplicateExistingHandlers() throws {
        try writeInitialPlist([
            ["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "com.apple.Safari"],
            ["LSHandlerURLScheme": "http", "LSHandlerRoleAll": "com.apple.Safari"],
            ["LSHandlerContentType": "public.html", "LSHandlerRoleAll": "com.apple.Safari"],
            ["LSHandlerContentType": "com.apple.default-app.web-browser", "LSHandlerRoleAll": "com.apple.Safari"],
        ])

        let manager = makeManager()
        manager.writeDefaultBrowserPreference("com.google.Chrome")

        let handlers = try readHandlers()
        let httpsCount = handlers.filter { ($0["LSHandlerURLScheme"] as? String) == "https" }.count
        let httpCount = handlers.filter { ($0["LSHandlerURLScheme"] as? String) == "http" }.count
        let htmlCount = handlers.filter { ($0["LSHandlerContentType"] as? String) == "public.html" }.count
        XCTAssertEqual(httpsCount, 1)
        XCTAssertEqual(httpCount, 1)
        XCTAssertEqual(htmlCount, 1)

        let https = handlers.first { ($0["LSHandlerURLScheme"] as? String) == "https" }
        XCTAssertEqual(https?["LSHandlerRoleAll"] as? String, "com.google.Chrome")
    }

    func testGetDefaultRoundTripsWrittenValue() {
        let manager = makeManager()
        manager.writeDefaultBrowserPreference("com.brave.Browser")
        XCTAssertEqual(manager.getDefaultBrowserBundleID(), "com.brave.Browser")
    }

    func testWriteSucceedsWhenPlistMissing() throws {
        // No initial plist — fresh install scenario.
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefsURL.path))

        let manager = makeManager()
        XCTAssertTrue(manager.writeDefaultBrowserPreference("com.apple.Safari"))

        let handlers = try readHandlers()
        XCTAssertFalse(handlers.isEmpty)
    }

    // MARK: - Performance regression

    /// The user-perceived lag when switching browsers is the synchronous time
    /// between the menu click and our UI update. The plist write is fast
    /// (~ms); the slow part is the `launchctl kickstart` of `lsd`, which is
    /// dispatched asynchronously. If anyone moves the kickstart back to the
    /// synchronous path, this test will fail because real kickstart takes
    /// 100–300 ms.
    func testSetDefaultBrowserReturnsWithoutBlockingOnDaemonReload() {
        // Simulate a daemon reload that takes a realistic amount of time.
        // If setDefaultBrowser ever waits on it, this assertion will fail.
        let slowReload: () -> Void = {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let manager = BrowserManager(prefsFileURL: prefsURL, reloadDaemon: slowReload)

        let start = Date()
        XCTAssertTrue(manager.setDefaultBrowser("com.google.Chrome"))
        let elapsed = Date().timeIntervalSince(start)

        // 50ms is generous: plist read+write on a temp file is sub-ms
        // territory. If we ever exceed this, something is blocking.
        XCTAssertLessThan(
            elapsed, 0.05,
            "setDefaultBrowser must not block on the daemon reload (took \(elapsed)s)"
        )
    }

    /// Microbenchmark for the synchronous portion of the switch. Establishes
    /// a baseline so future regressions are visible in CI.
    func testSetDefaultBrowserSynchronousPerformance() throws {
        // Pre-populate with a realistic number of unrelated handlers so the
        // measurement reflects production-shaped data rather than an empty
        // plist.
        var handlers: [[String: Any]] = []
        for i in 0..<60 {
            handlers.append([
                "LSHandlerURLScheme": "scheme\(i)",
                "LSHandlerRoleAll": "com.example.app\(i)"
            ])
        }
        try writeInitialPlist(handlers)

        let manager = BrowserManager(prefsFileURL: prefsURL, reloadDaemon: {})
        measure {
            _ = manager.setDefaultBrowser("com.google.Chrome")
        }
    }
}
