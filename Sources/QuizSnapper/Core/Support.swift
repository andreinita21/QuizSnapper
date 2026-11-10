import AppKit
import Foundation
import os
import Security

// MARK: - Logging

enum Log {
    private static let logger = Logger(subsystem: "com.andrei.quizsnapper", category: "app")
    private static let queue = DispatchQueue(label: "quizsnapper.log")

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QuizSnapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("QuizSnapper.log")
    }()

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        // Only the real app bundle writes the log file (not the self-test binary).
        guard Bundle.main.bundleIdentifier == "com.andrei.quizsnapper" else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

// MARK: - Paths

enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("QuizSnapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let settingsFile = supportDir.appendingPathComponent("settings.json")
    static let historyFile = supportDir.appendingPathComponent("history.json")
    static let iconsDir: URL = {
        let dir = supportDir.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

// MARK: - Keychain

/// API keys live in the login Keychain, never in the settings file.
enum Keychain {
    private static let service = "com.andrei.quizsnapper.provider-key"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "QuizSnapper API key"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func apiKey(for provider: ProviderConfig) -> String? { get(provider.id.uuidString) }
    static func setAPIKey(_ key: String?, for provider: ProviderConfig) { set(key, for: provider.id.uuidString) }
}

// MARK: - Focus

/// Menu bar apps have to activate themselves to show a key window (region selector, popover).
/// This hands focus back to the app you were in (the quiz page), so typing/scrolling keeps working.
@MainActor
enum FocusKeeper {
    private static var previous: NSRunningApplication?

    static func remember() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previous = app
    }

    /// Re-activates the remembered app, but only if we're still frontmost (the user didn't click elsewhere)
    /// and none of our own regular windows (Settings, setup) is in use.
    static func restore() {
        guard let app = previous else { return }
        previous = nil
        guard NSApp.isActive, !app.isTerminated else { return }
        let ourWindowInUse = NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && $0.styleMask.contains(.titled) }
        guard !ourWindowInUse else { return }
        app.activate()
    }
}
