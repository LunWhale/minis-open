//
//  ChatStore+SyncRemoteRecords.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, the other synced records: sync devices, remote media, skills,
//  memories, provider configs and env vars, clearing remote tables, single
//  message lookup for sync, and size estimates per sync category.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {
    // MARK: - Sync Device CRUD

    func upsertSyncDevice(_ device: SyncDevice) {
        iCloudLogger.info("[iCloud] upsertSyncDevice: id=\(device.id) name=\(device.deviceName) zone=\(device.zoneName) upload=\(device.uploadTypes)")
        let sql = """
            INSERT OR REPLACE INTO sync_devices (device_id, device_name, zone_name, last_seen, os_version, upload_types)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (device.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (device.deviceName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (device.zoneName as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, device.lastSeen.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 5, (device.osVersion as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (device.uploadTypes.joined(separator: ",") as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func listSyncDevices() -> [SyncDevice] {
        let sql = "SELECT device_id, device_name, zone_name, last_seen, os_version, upload_types FROM sync_devices"
        var stmt: OpaquePointer?
        var devices: [SyncDevice] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let uploadTypesStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let uploadTypes = uploadTypesStr.isEmpty ? [] : uploadTypesStr.components(separatedBy: ",")
                devices.append(SyncDevice(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    deviceName: String(cString: sqlite3_column_text(stmt, 1)),
                    zoneName: String(cString: sqlite3_column_text(stmt, 2)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    osVersion: String(cString: sqlite3_column_text(stmt, 4)),
                    uploadTypes: uploadTypes
                ))
            }
        }
        sqlite3_finalize(stmt)
        iCloudLogger.info("[iCloud] listSyncDevices: returning \(devices.count) devices")
        for d in devices {
            iCloudLogger.info("[iCloud]   device: id=\(d.id) name=\(d.deviceName) zone=\(d.zoneName)")
        }
        // DIAG: when zero devices, dump enough surrounding state to tell at
        // a glance WHY peer discovery isn't surfacing the other side. Three
        // common causes — sync not initialized (zoneEmpty), user disabled
        // upload categories in Settings, no dirty rows queued — each
        // produces a distinctly identifiable footprint here.
        if devices.isEmpty {
            let zoneState = syncZoneName.isEmpty ? "EMPTY(syncNotInitialized)" : syncZoneName
            let categoryStates = UploadPolicy.Category.allCases.map { cat in
                "\(cat.rawValue)=\(UploadPolicy.isEnabled(cat))"
            }.joined(separator: " ")
            // Count any pending dirty rows so we can tell if writes are
            // backing up (sync running but push failing) vs no writes
            // happening at all (markDirty skipped at the source).
            var dirtyCount = 0
            var dirtyByType: [String: Int] = [:]
            var dStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT record_type, COUNT(*) FROM sync_dirty_records GROUP BY record_type", -1, &dStmt, nil) == SQLITE_OK {
                while sqlite3_step(dStmt) == SQLITE_ROW {
                    let t = String(cString: sqlite3_column_text(dStmt, 0))
                    let c = Int(sqlite3_column_int(dStmt, 1))
                    dirtyByType[t] = c
                    dirtyCount += c
                }
            }
            sqlite3_finalize(dStmt)
            let dirtySummary = dirtyByType.isEmpty ? "empty" : dirtyByType.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
            iCloudLogger.info("[iCloud] listSyncDevices=0 diag: zone=\(zoneState) uploadPolicy=[\(categoryStates)] dirtyQueue=\(dirtyCount){\(dirtySummary)}")
        }
        return devices
    }

    // MARK: - Remote Media CRUD

    func upsertRemoteMedia(
        id: String, deviceId: String, sessionId: String,
        relativePath: String, mimeType: String?,
        originalFileName: String?, localCachePath: String?
    ) {
        let sql = """
            INSERT OR REPLACE INTO remote_media
            (id, device_id, session_id, relative_path, mime_type, original_file_name, local_cache_path)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (relativePath as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 5, value: mimeType)
            bindOptionalText(stmt, index: 6, value: originalFileName)
            bindOptionalText(stmt, index: 7, value: localCachePath)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Remote Skill CRUD

    func upsertRemoteSkill(
        id: String, deviceId: String, name: String, description: String,
        version: String, importSource: String, isEnabled: Bool,
        installedAt: Date, updatedAt: Date, bodyText: String
    ) {
        let sql = """
            INSERT OR REPLACE INTO remote_skills
            (id, device_id, name, description, version, import_source, is_enabled, installed_at, updated_at, body_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (description as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (version as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (importSource as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 7, isEnabled ? 1 : 0)
            sqlite3_bind_double(stmt, 8, installedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 10, (bodyText as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteRemoteSkill(id: String, deviceId: String) {
        let sql = "DELETE FROM remote_skills WHERE id = ? AND device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func listRemoteSkills(deviceId: String) -> [Skill] {
        let sql = """
            SELECT id, name, description, version, import_source, is_enabled, installed_at, updated_at, body_text
            FROM remote_skills WHERE device_id = ?
        """
        var stmt: OpaquePointer?
        var skills: [Skill] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                skills.append(Skill(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    description: String(cString: sqlite3_column_text(stmt, 2)),
                    version: String(cString: sqlite3_column_text(stmt, 3)),
                    importSource: SkillImportSource.fromDB(String(cString: sqlite3_column_text(stmt, 4))),
                    isEnabled: sqlite3_column_int(stmt, 5) == 1,
                    installedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                    body: String(cString: sqlite3_column_text(stmt, 8))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return skills
    }

    // MARK: - Remote Memory CRUD

    func upsertRemoteMemory(
        id: String, deviceId: String, fileName: String,
        content: String, updatedAt: Date
    ) {
        let sql = """
            INSERT OR REPLACE INTO remote_memories (id, device_id, file_name, content, updated_at)
            VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (fileName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (content as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteRemoteMemory(id: String, deviceId: String) {
        let sql = "DELETE FROM remote_memories WHERE id = ? AND device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func listRemoteMemories(deviceId: String) -> [RemoteMemory] {
        let sql = "SELECT id, device_id, file_name, content, updated_at FROM remote_memories WHERE device_id = ?"
        var stmt: OpaquePointer?
        var memories: [RemoteMemory] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                memories.append(RemoteMemory(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    deviceId: String(cString: sqlite3_column_text(stmt, 1)),
                    fileName: String(cString: sqlite3_column_text(stmt, 2)),
                    content: String(cString: sqlite3_column_text(stmt, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return memories
    }

    // MARK: - Remote Provider Configs

    func upsertRemoteProviderConfig(deviceId: String, configJson: String, updatedAt: Date) {
        let sql = """
            INSERT OR REPLACE INTO remote_provider_configs (device_id, config_json, updated_at)
            VALUES (?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (configJson as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteRemoteProviderConfig(deviceId: String) {
        let sql = "DELETE FROM remote_provider_configs WHERE device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func loadRemoteProviderConfig(deviceId: String) -> (configJson: String, updatedAt: Date)? {
        let sql = "SELECT config_json, updated_at FROM remote_provider_configs WHERE device_id = ?"
        var stmt: OpaquePointer?
        var result: (String, Date)?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(stmt, 0))
                let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                result = (json, date)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Remote Env Vars

    func upsertRemoteEnvVars(deviceId: String, envVarsJson: String, updatedAt: Date) {
        let sql = """
            INSERT OR REPLACE INTO remote_env_vars (device_id, env_vars_json, updated_at)
            VALUES (?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (envVarsJson as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteRemoteEnvVars(deviceId: String) {
        let sql = "DELETE FROM remote_env_vars WHERE device_id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func loadRemoteEnvVars(deviceId: String) -> (envVarsJson: String, updatedAt: Date)? {
        let sql = "SELECT env_vars_json, updated_at FROM remote_env_vars WHERE device_id = ?"
        var stmt: OpaquePointer?
        var result: (String, Date)?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (deviceId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(stmt, 0))
                let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                result = (json, date)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Clear Remote Tables

    /// Clear all remote reference tables AND pending dirty records.
    /// Used only by full state reset flows.
    func clearAllRemoteTables() {
        clearRemoteReferenceTables()
        exec("DELETE FROM sync_dirty_records")
    }

    /// Clear remote reference/mirror tables only.
    /// Preserves sync_dirty_records so pending local changes still get pushed.
    func clearRemoteReferenceTables() {
        exec("DELETE FROM remote_sessions")
        exec("DELETE FROM remote_messages")
        exec("DELETE FROM remote_media")
        exec("DELETE FROM remote_skills")
        exec("DELETE FROM remote_memories")
        exec("DELETE FROM remote_provider_configs")
        exec("DELETE FROM remote_env_vars")
        exec("DELETE FROM sync_devices")
    }

    // MARK: - Single Message Lookup (for sync)

    func messageSortOrder(id: String) -> Int {
        let sql = "SELECT sort_order FROM messages WHERE id = ?"
        var stmt: OpaquePointer?
        var order = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                order = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return order
    }

    /// Return updated_at for a message, falling back to created_at if NULL (pre-migration data).
    func messageUpdatedAt(id: String) -> Date {
        let sql = "SELECT COALESCE(updated_at, created_at) FROM messages WHERE id = ?"
        var stmt: OpaquePointer?
        var ts: Double = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                ts = sqlite3_column_double(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return Date(timeIntervalSince1970: ts)
    }

    func loadSingleMessage(id: String) -> RawMessage? {
        let sql = """
            SELECT id, session_id, role, parts_json, created_at, token_usage, reasoning_content, stream_interrupt_count, sort_order
            FROM messages WHERE id = ?
        """
        var stmt: OpaquePointer?
        var message: RawMessage?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(stmt, 0))
                let sessionId = String(cString: sqlite3_column_text(stmt, 1))
                let roleStr = String(cString: sqlite3_column_text(stmt, 2))
                let partsJson = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let tokenUsageStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let reasoningContent = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let streamInterruptCount = Int(sqlite3_column_int(stmt, 7))
                let sortOrder = Int(sqlite3_column_int64(stmt, 8))

                let role = MessageRole(rawValue: roleStr) ?? .user
                let parts = (try? JSONDecoder().decode([ContentPart].self, from: Data(partsJson.utf8))) ?? []
                let tokenUsage = tokenUsageStr.flatMap { str in
                    try? JSONDecoder().decode(StoredTokenUsage.self, from: Data(str.utf8))
                }

                var raw = RawMessage(
                    id: msgId, sessionId: sessionId, role: role, parts: parts,
                    createdAt: createdAt, tokenUsage: tokenUsage,
                    reasoningContent: reasoningContent,
                    streamInterruptCount: streamInterruptCount
                )
                raw.sortOrder = sortOrder
                message = raw
            }
        }
        sqlite3_finalize(stmt)
        return message
    }

    // MARK: - Size Estimation for Sync Categories

    /// Estimated size of all sessions + messages in the database.
    func estimateSessionsSize() -> Int64 {
        var total: Int64 = 0
        // Sessions table size (rough: count * avg row ~200 bytes)
        let sessionCount = queryInt64("SELECT COUNT(*) FROM sessions")
        total += sessionCount * 200

        // Messages: sum of parts_json lengths + overhead
        let partsSize = queryInt64("SELECT COALESCE(SUM(LENGTH(parts_json)), 0) FROM messages")
        let msgCount = queryInt64("SELECT COUNT(*) FROM messages")
        total += partsSize + msgCount * 100 // overhead per row
        return total
    }

    /// Estimated size of all session files (attachments, offloads, workspace, browser).
    func estimateFilesSize() -> Int64 {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let minisBase = library.appendingPathComponent("MinisChat/minis")
        return directorySize(minisBase)
    }

    /// Estimated size of memory files.
    func estimateMemoriesSize() -> Int64 {
        return directorySize(AIChatViewModel.minisMemoryPersistentDir)
    }

    /// Estimated size of skills (db entries + skill files).
    func estimateSkillsSize() -> Int64 {
        return directorySize(AIChatViewModel.minisSkillsPersistentDir)
    }

    /// Estimated size of provider config JSON.
    func estimateProvidersSize() -> Int64 {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let configURL = library.appendingPathComponent("MinisChat/provider-config.json")
        return (try? configURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    /// Estimated size of env vars JSON.
    func estimateEnvVarsSize() -> Int64 {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let envURL = library.appendingPathComponent("MinisChat/env-vars.json")
        return (try? envURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    func queryInt64(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        var result: Int64 = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
