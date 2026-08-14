import Foundation
import SwiftUI

// MARK: - Extension Log Store
//
// In-memory ring buffer of extension-related log lines (install/uninstall/
// load errors, tool/command invocations, permission decisions, JS/Lua
// runtime messages). Surfaced in the Extension Manager's debug panel
// (minis://extensions/debug). Capped at 500 entries.

final class ExtensionLogStore: ObservableObject {
    static let shared = ExtensionLogStore()

    struct Entry: Identifiable, Equatable {
        enum Level: String { case info, warn, error }
        let id: UUID
        let date: Date
        let level: Level
        let category: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let cap = 500
    private let lock = NSLock()

    private init() {}

    func log(_ message: String, level: Entry.Level = .info, category: String = "Extension") {
        lock.lock()
        entries.insert(Entry(id: UUID(), date: Date(), level: level, category: category, message: message), at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        lock.unlock()
        // Published var must be mutated on main.
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}

// MARK: - Debug Panel View

struct ExtensionDebugView: View {
    @ObservedObject private var store = ExtensionLogStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Section {
                        Text("No extension log entries yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(store.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(levelColor(entry.level))
                                Text(entry.category)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Extension Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { store.clear() }
                }
            }
        }
    }

    private func levelColor(_ level: ExtensionLogStore.Entry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
