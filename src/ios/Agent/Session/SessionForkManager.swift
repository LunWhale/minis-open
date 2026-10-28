import Foundation
import os.log

private let logger = AppLogger(category: "SessionFork")

/// Handles forking remote sessions (deep copy) and copying remote skills/memories to local device.
@MainActor
final class SessionForkManager {
    static let shared = SessionForkManager()
    private init() {}

    /// [ISS-038] Duplicate titles chosen but not yet written as a session. Two
    /// quick "Duplicate" taps run as two tasks on the main actor; each one
    /// picks its title and reserves it with no suspension point in between,
    /// so the second one sees the first one's title as taken.
    private var reservedDuplicateTitles: Set<String> = []

    // MARK: - Fork Remote Session

    /// Fork a remote session into a new local session with deep-copied messages.
    func forkSession(remoteSessionId: String, remoteDeviceId: String) async -> ChatSession? {
        let store = ChatStore.shared

        // Load remote session
        let remoteSessions = await store.listRemoteSessions(deviceId: remoteDeviceId)
        guard let remoteSession = remoteSessions.first(where: { $0.id == remoteSessionId }) else {
            logger.error("[Fork] Remote session not found: \(remoteSessionId)")
            return nil
        }

        // Create new local session
        let forkTitle = (remoteSession.title ?? "Untitled") + " (Fork)"
        let newSession = await store.createSession(modelId: remoteSession.modelId, title: forkTitle)

        // Update category if present
        if let category = remoteSession.category {
            await store.updateSessionTitle(newSession.id, title: forkTitle, category: category)
        }

        // Load and deep-copy messages
        let remoteMessages = await store.loadRemoteMessages(sessionId: remoteSessionId, deviceId: remoteDeviceId)
        for msg in remoteMessages {
            let newMsg = RawMessage(
                id: UUID().uuidString,
                sessionId: newSession.id,
                role: msg.role,
                parts: msg.parts,
                createdAt: msg.createdAt,
                tokenUsage: msg.tokenUsage,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount
            )
            await store.appendMessage(newMsg)
        }

        logger.info("[Fork] Forked remote session \(remoteSessionId) → \(newSession.id) (\(remoteMessages.count) messages)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: newSession.id)

        return newSession
    }

    // MARK: - Duplicate Local Session

    /// Duplicate a local session (same as fork but reads from main tables).
    func duplicateSession(sessionId: String) async -> ChatSession? {
        let store = ChatStore.shared

        guard let session = await store.getSession(sessionId) else {
            logger.error("[Fork] Local session not found: \(sessionId)")
            return nil
        }

        // [ISS-038] "Foo (Copy)", then "Foo (Copy 2)", "Foo (Copy 3)"…, never
        // "Foo (Copy) (Copy)"; the word is localized ("副本"), and copies made
        // under another language are recognized. Only titles are read (the
        // cached session list), never messages. See SessionDuplicateTitle.
        let existingTitles = await store.listSessions().compactMap(\.title)
        let dupTitle = SessionDuplicateTitle.make(
            sourceTitle: session.title,
            existingTitles: existingTitles + reservedDuplicateTitles,
            suffixWord: Self.copySuffixWord(),
            knownSuffixWords: Self.allCopySuffixWords,
            untitledTitle: AppLocalized("Untitled"))
        reservedDuplicateTitles.insert(dupTitle)
        let newSession = await store.createSession(modelId: session.modelId, title: dupTitle)
        // createSession invalidates the session-list cache, so the title is
        // visible to the next duplicate from here on.
        reservedDuplicateTitles.remove(dupTitle)

        if let category = session.category {
            await store.updateSessionTitle(newSession.id, title: dupTitle, category: category)
        }

        let messages = await store.loadMessages(sessionId: sessionId)
        // [T-session-duplicate-compact-marker-ios] Track old→new message id so
        // copied compact markers (which reference DB message ids) can be
        // remapped onto the freshly-minted duplicate messages. Without this the
        // markers dangle and the compact divider/shadow is lost on the copy.
        var oldToNewMessageId: [String: String] = [:]
        for msg in messages {
            let newId = UUID().uuidString
            oldToNewMessageId[msg.id] = newId
            let newMsg = RawMessage(
                id: newId,
                sessionId: newSession.id,
                role: msg.role,
                parts: msg.parts,
                createdAt: msg.createdAt,
                tokenUsage: msg.tokenUsage,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount
            )
            await store.appendMessage(newMsg)
        }

        // [T-session-duplicate-compact-marker-ios] Copy compact markers AFTER
        // all messages are appended (so the new messages' sort_orders exist).
        // Zero-marker sessions make this a no-op — the normal duplicate path is
        // untouched. Each marker is remapped independently so multi-compact
        // sessions copy all dividers, in createdAt order (compactMarkers ORDERs
        // by created_at ASC; insertCompactMarker preserves each createdAt).
        let markers = await store.compactMarkers(sessionId: sessionId)
        if !markers.isEmpty {
            // Authoritative new sort_orders, keyed by the new message id.
            let newMessages = await store.loadMessages(sessionId: newSession.id)
            let newSortOrderById = Dictionary(
                uniqueKeysWithValues: newMessages.map { ($0.id, $0.sortOrder) }
            )
            // Remap a referenced message id through the copy map. nil → nil.
            func remapId(_ id: String?) -> String? {
                guard let id else { return nil }
                return oldToNewMessageId[id]
            }
            // Resolve a legacy sort_order fallback to the NEW message's
            // sort_order via the remapped id; keep the original if the id
            // can't be resolved (legacy markers whose id field is nil).
            func remapSortOrder(messageId: String?, original: Int) -> Int {
                guard let newId = remapId(messageId),
                      let so = newSortOrderById[newId] else { return original }
                return so
            }
            var copied = 0
            for marker in markers {
                // All source messages are copied, so every non-nil id field
                // MUST resolve. If one doesn't, the marker is corrupt/dangling
                // already — skip it rather than write a dangling copy.
                let firstKeptNew = remapId(marker.firstKeptMessageId)
                let lastCompactedNew = remapId(marker.lastCompactedMessageId)
                let boundaryNew = remapId(marker.boundaryMessageId)
                if (marker.firstKeptMessageId != nil && firstKeptNew == nil)
                    || (marker.lastCompactedMessageId != nil && lastCompactedNew == nil)
                    || (marker.boundaryMessageId != nil && boundaryNew == nil) {
                    logger.error("[Fork] Skipping compact marker \(marker.id): a referenced message id is not in the copy map (dangling source marker)")
                    continue
                }
                let copy = CompactMarker(
                    id: UUID().uuidString,
                    sessionId: newSession.id,
                    summary: marker.summary,
                    firstKeptSortOrder: remapSortOrder(
                        messageId: marker.firstKeptMessageId,
                        original: marker.firstKeptSortOrder
                    ),
                    compactedCount: marker.compactedCount,
                    createdAt: marker.createdAt,
                    uiBoundarySortOrder: marker.uiBoundarySortOrder.map { _ in
                        remapSortOrder(
                            messageId: marker.boundaryMessageId,
                            original: marker.uiBoundarySortOrder ?? 0
                        )
                    },
                    boundaryMessageId: boundaryNew,
                    firstKeptMessageId: firstKeptNew,
                    lastCompactedMessageId: lastCompactedNew,
                    version: marker.version
                )
                await store.insertCompactMarker(copy)
                copied += 1
            }
            logger.info("[Fork] Copied \(copied)/\(markers.count) compact marker(s) to \(newSession.id)")
        }

        logger.info("[Fork] Duplicated session \(sessionId) → \(newSession.id) (\(messages.count) messages)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: newSession.id)

        return newSession
    }

    // MARK: - Copy Remote Skill

    /// Copy a remote skill to the local device.
    func copyRemoteSkill(skillId: String, deviceId: String) async -> Bool {
        let remoteSkills = await ChatStore.shared.listRemoteSkills(deviceId: deviceId)
        guard let skill = remoteSkills.first(where: { $0.id == skillId }) else {
            logger.error("[Fork] Remote skill not found: \(skillId)")
            return false
        }

        // Build SKILL.md content from body
        let content = skill.body.isEmpty ? "---\nname: \(skill.name)\ndescription: \(skill.description)\nversion: \(skill.version)\n---\n" : skill.body

        do {
            try SkillStore.shared.importSkill(content: content, source: .file)
            logger.info("[Fork] Copied remote skill: \(skill.name)")
            return true
        } catch {
            logger.error("[Fork] Failed to copy skill: \(error)")
            return false
        }
    }

    // MARK: - Copy Remote Memory

    /// Copy a remote memory file to the local memory directory.
    func copyRemoteMemory(memoryId: String, deviceId: String) async -> Bool {
        let remoteMemories = await ChatStore.shared.listRemoteMemories(deviceId: deviceId)
        guard let memory = remoteMemories.first(where: { $0.id == memoryId }) else {
            logger.error("[Fork] Remote memory not found: \(memoryId)")
            return false
        }

        let memoryDir = AIChatViewModel.minisMemoryPersistentDir
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        let destURL = memoryDir.appendingPathComponent(memory.fileName)
        do {
            try memory.content.write(to: destURL, atomically: true, encoding: String.Encoding.utf8)
            logger.info("[Fork] Copied remote memory: \(memory.fileName)")
            return true
        } catch {
            logger.error("[Fork] Failed to copy memory: \(error)")
            return false
        }
    }
}

// MARK: - Duplicate title (ISS-038)

extension SessionForkManager {
    /// The copy word in the current (in-app) language: "Copy", "副本".
    /// Its own key: the plain "Copy" key is the verb (复制) used elsewhere.
    static func copySuffixWord() -> String {
        AppLocalized("Copy (session duplicate suffix)",
                     comment: "Suffix word of a duplicated session's title: \"Foo (Copy)\", \"Foo (Copy 2)\". The word only.")
    }

    /// The copy word in EVERY language the app ships, so a copy made under one
    /// language is still recognized after the user switches language
    /// ("Foo (Copy)" copied in Chinese gives "Foo (副本 2)", not
    /// "Foo (Copy) (副本)"). Read once from each .lproj.
    static let allCopySuffixWords: [String] = {
        var words: [String] = ["Copy"]
        for code in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let word = String(localized: "Copy (session duplicate suffix)", bundle: bundle)
            if word != "Copy (session duplicate suffix)" { words.append(word) }
        }
        return words
    }()
}

// BEGIN SessionDuplicateTitle
/// [ISS-038] Title of a duplicated session. Pure (Foundation only) so the
/// standalone tests compile it as shipped.
///
/// - Format: "<base> (<word>)" for the first copy, "<base> (<word> N)" for
///   N >= 2, with ASCII parentheses and a space before them.
/// - Base: the source title minus ONE trailing copy suffix, so copying
///   "Foo (Copy 2)" never gives "Foo (Copy 2) (Copy)". A trailing suffix is
///   "(" or "（", a known word in any shipped language (case-insensitive), an
///   optional integer >= 2 without a leading zero, then ")" or "）", at the
///   very end after trimming. Anything else is part of the title:
///   "Foo (draft)", "Foo (Copy) notes", "Foo (Copy 2x)", "Foo (Copy 0)",
///   "Foo (Copy 1)" (never produced, so read as the user's own text). A title
///   that is nothing but a suffix ("(Copy)") keeps itself as the base.
/// - Number: the SMALLEST free number among existing titles with the same
///   base, in any language: deleting "Foo (Copy 2)" and copying again refills
///   2, so numbers stay small and the list keeps no unexplained gap.
/// - nil / blank source title: `untitledTitle` is the base.
/// Linear in the number of existing titles (a set lookup per number).
enum SessionDuplicateTitle {
    static func make(sourceTitle: String?, existingTitles: [String], suffixWord: String,
                     knownSuffixWords: [String], untitledTitle: String) -> String {
        let words = recognizedWords(suffixWord: suffixWord, known: knownSuffixWords)
        let trimmed = (sourceTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? untitledTitle : (parse(trimmed, words: words)?.base ?? trimmed)
        var taken = Set<Int>()
        for title in existingTitles {
            guard let p = parse(title, words: words), p.base == base else { continue }
            taken.insert(p.number)
        }
        var number = 1
        while taken.contains(number) { number += 1 }
        return format(base: base, word: suffixWord, number: number)
    }

    static func format(base: String, word: String, number: Int) -> String {
        number <= 1 ? "\(base) (\(word))" : "\(base) (\(word) \(number))"
    }

    static func recognizedWords(suffixWord: String, known: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in [suffixWord, "Copy"] + known {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// (base, number) when `title` ends with a copy suffix; number 1 for a
    /// suffix without a number. nil otherwise.
    static func parse(_ title: String, words: [String]) -> (base: String, number: Int)? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, last == ")" || last == "）" else { return nil }
        guard let open = t.lastIndex(where: { $0 == "(" || $0 == "（" }) else { return nil }
        let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let base = t[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        for word in words {
            if inner.compare(word, options: [.caseInsensitive]) == .orderedSame {
                return (base, 1)
            }
            guard inner.count > word.count,
                  inner.prefix(word.count).compare(word, options: [.caseInsensitive]) == .orderedSame else { continue }
            let rest = inner.dropFirst(word.count)
            guard let space = rest.first, space == " " || space == "\u{3000}" else { continue }
            let digits = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.count <= 9, !digits.hasPrefix("0"),
                  digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let n = Int(digits), n >= 2 else { continue }
            return (base, n)
        }
        return nil
    }
}
// END SessionDuplicateTitle
