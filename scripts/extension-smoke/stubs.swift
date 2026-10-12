import Foundation

// ---- Stubs for symbols ExtensionJSRuntime.swift references from the app ----

final class AppLogger {
    init(category: String) {}
    func info(_ message: String) { LogSink.shared.info(message) }
    func error(_ message: String) { LogSink.shared.error(message) }
    func warning(_ message: String) { LogSink.shared.warning(message) }
    func debug(_ message: String) {}
    func fault(_ message: String) {}
}

final class LogSink {
    static let shared = LogSink()
    private(set) var lines: [String] = []
    func info(_ m: String) { lines.append("INFO \(m)") }
    func error(_ m: String) { lines.append("ERROR \(m)") }
    func warning(_ m: String) { lines.append("WARN \(m)") }
    func reset() { lines.removeAll() }
}

enum ExtensionError: LocalizedError {
    case missingManifest
    case invalidManifest(String)
    case runtime(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest: return "missing manifest"
        case .invalidManifest(let s): return "invalid manifest: \(s)"
        case .runtime(let s): return "runtime: \(s)"
        case .io(let s): return "io: \(s)"
        }
    }
}

final class ExtensionRegistry {
    static let shared = ExtensionRegistry()
    private(set) var refreshCount = 0
    func refreshInterceptorFlag() { refreshCount += 1 }
}

// Stub for the in-app extension debug log store (referenced by the real
// ExtensionLuaRuntime / ExtensionJSRuntime for the debug panel).
final class ExtensionLogStore {
    static let shared = ExtensionLogStore()
    enum Level { case info, warn, error }
    private(set) var entries: [(String, String)] = []
    func log(_ message: String, level: Level = .info, category: String = "Extension") {
        entries.append((category, message))
    }
}
