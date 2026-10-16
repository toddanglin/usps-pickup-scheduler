import Foundation

/// Throwaway `UserDefaults` suites for tests.
enum TestDefaults {
    /// Removes the suite's contents and its plist file.
    ///
    /// `removePersistentDomain(forName:)` alone empties the domain but leaves a
    /// 42-byte empty plist in the test host's container, one per test, so
    /// the file is deleted too (the host is sandboxed, so `NSHomeDirectory()`
    /// is that container).
    static func remove(suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
