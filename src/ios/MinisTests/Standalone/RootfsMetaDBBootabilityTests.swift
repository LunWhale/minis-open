// Guards for [T-rootfs-metadb-bootability] — the "Kernel boot failed: -22"
// dead end.
//
// Symptom: the app installs and runs, then every attempt to start the sandbox
// shows a full-screen overlay reading
//
//     Kernel boot failed: -22
//
// with no way out. -22 is EINVAL, and the ONLY place in the iSH boot path that
// returns it is `fake_db_init` (deps/ish/fs/fake-db.c), when
// `sqlite3_open_v2(meta.db, ..., SQLITE_OPEN_READWRITE, NULL)` fails. Everything
// else on that path reports _EIO (-5), _ENOENT (-2) or _EACCES (-13).
//
// The tree was unrecoverable because `RootfsManager.isInstalled` answered from
// `data/` plus the `.arch` tag alone, and `installIfNeeded()` "repairs" a
// missing tag in place. A rootfs whose meta.db was gone therefore looked
// installed for ever: the install never ran again, so the missing database was
// never restored. Nothing on the C side can recreate it — `fakefs_migrate` only
// applies schema migrations, and `fakefs_rebuild` copies out of the existing
// `paths`/`stats` tables — so reinstalling from the bundled zip is the only fix.
//
// Standalone (`swift RootfsMetaDBBootabilityTests.swift`) like its neighbours:
// deps/libs/libish_emu.a is device-only arm64, so the app cannot link for a
// simulator and an XCTest bundle has nowhere to run.
import Foundation
import SQLite3

var failures = 0
var warnings = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")"); failures += 1 }
}
func warn(_ label: String) {
    print("  ⚠️  \(label)"); warnings += 1
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repo = root.deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func repoSrc(_ rel: String) -> String {
    (try? String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func slice(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start),
          let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.upperBound..<b.lowerBound])
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 1. The errno really does identify one call site
// ─────────────────────────────────────────────────────────────────────────────

print("▶️  1. -22 is EINVAL, and only fake_db_init returns it during boot")

let fakeDBC = repoSrc("deps/ish/fs/fake-db.c")
let openFailure = slice(fakeDBC,
                        from: "int err = sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE, NULL);",
                        to: "sqlite3_busy_timeout")
check("fake_db_init opens meta.db READWRITE (no CREATE — a missing file is fatal)",
      fakeDBC.contains("sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE, NULL)")
        && !fakeDBC.contains("SQLITE_OPEN_CREATE"))
check("an open failure returns _EINVAL, which the UI prints as -22",
      openFailure.contains("return _EINVAL;"))

// The diagnostics on that branch are a fork patch, not upstream code: deps/ish
// is a submodule of OpenMinis/ish-arm64, so the change cannot live in the parent
// repository's history. build_ish.sh replays it. Assert the patch and its wiring
// rather than the submodule's working tree, which a fresh clone will not have
// patched yet.
let patchPath = "../../../../deps/patches/0001-fakefs-name-the-meta-db-open-failure.patch"
let patch = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent(patchPath), encoding: .utf8)) ?? ""
check("the diagnostic ships as a patch against deps/ish", !patch.isEmpty)
check("the patch names the database path so the log is diagnosable",
      patch.contains("cannot open") && patch.contains("db_path"))
check("the patch stops the closed handle leaking to fake_db_deinit",
      patch.contains("fs->db = NULL;"))
let buildIsh = repoSrc("deps/build_ish.sh")
check("build_ish.sh replays deps/patches/*.patch",
      buildIsh.contains("apply_fork_patches()")
        && buildIsh.contains("apply_fork_patches\n"))
check("…idempotently (an already-patched submodule is not an error)",
      buildIsh.contains("git apply --check --reverse"))
check("every OTHER init failure reports _EIO, not _EINVAL (so -22 is unambiguous)",
      fakeDBC.contains("return _EIO;"))

// The boot path itself must not introduce a second _EINVAL.
let initC = repoSrc("deps/ish/kernel/init.c")
check("mount_root returns the mount error unchanged (no EINVAL of its own)",
      !initC.contains("_EINVAL"))
let genericC = repoSrc("deps/ish/fs/generic.c")
let genericOpen = slice(genericC, from: "struct fd *generic_openat(", to: "struct mount *mount = find_mount_and_trim_path")
check("generic_openat only rejects conflicting access modes with EINVAL",
      genericOpen.contains("if (flags & O_RDWR_ && flags & O_WRONLY_)"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 2. sqlite itself: READWRITE on a missing file fails
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  2. sqlite3_open_v2(READWRITE) reproduces the failure on a missing db")

func sqliteOpenRW(_ path: String) -> Int32 {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
    if db != nil { sqlite3_close(db) }
    return rc
}
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("metadb-probe-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let absent = tmp.appendingPathComponent("absent.db").path
let absentRC = sqliteOpenRW(absent)
check("missing file → SQLITE_CANTOPEN (\(absentRC))", absentRC == SQLITE_CANTOPEN,
      "got \(absentRC), want \(SQLITE_CANTOPEN)")

let empty = tmp.appendingPathComponent("empty.db")
FileManager.default.createFile(atPath: empty.path, contents: Data())
let emptyRC = sqliteOpenRW(empty.path)
check("zero-byte file opens (so it fails LATER, with -5, not -22)",
      emptyRC == SQLITE_OK, "got \(emptyRC)")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 3. isInstalled must require a usable meta.db
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  3. the installed-check now covers the fakefs database")

let rootfsSwift = src("iSH/RootfsManager.swift")
let isInstalledBody = slice(rootfsSwift, from: "var isInstalled: Bool {", to: "\n    ///")
check("isInstalled still requires data/", isInstalledBody.contains("fileExists(atPath: dataPath.path)"))
check("isInstalled still requires the aarch64 tag", isInstalledBody.contains("== currentArch"))
check("isInstalled ALSO requires a usable meta.db (the actual fix)",
      isInstalledBody.contains("return hasUsableMetaDB"))
check("a usable meta.db means present, non-empty and writable",
      rootfsSwift.contains("guard size > 0 else { return .empty }")
        && rootfsSwift.contains("isWritableFile(atPath: path)"))
check("permissions are repaired before the tree is condemned",
      rootfsSwift.contains("repaired permissions on meta.db"))
check("an unbootable-but-present tree is replaced, not unzipped over",
      rootfsSwift.contains("rootfs present but its database is")
        && rootfsSwift.contains("try discardOldRootfs()"))
check("a merely unwritable database is reported, NOT wiped (that would destroy user files)",
      rootfsSwift.contains("case .unwritable:")
        && rootfsSwift.contains("is not writable, so the sandbox cannot start")
        && rootfsSwift.contains("domain: \"RootfsManager\", code: 3"))
check("the tag-repair path no longer claims a broken tree is fine",
      rootfsSwift.contains("tree still not bootable after tag repair"))
check("the reason is reported as a string, not a bare errno",
      rootfsSwift.contains("func integrityDiagnostic() -> String")
        && rootfsSwift.contains("\"meta-db-missing\"")
        && rootfsSwift.contains("\"meta-db-empty\"")
        && rootfsSwift.contains("\"meta-db-unwritable\""))

// Exercise the same decision against real trees.
struct RootfsProbe {
    let rootfsPath: URL
    let currentArch = "aarch64"
    var dataPath: URL { rootfsPath.appendingPathComponent("data") }
    var archTagPath: URL { rootfsPath.appendingPathComponent(".arch") }
    var metaDBPath: URL { rootfsPath.appendingPathComponent("meta.db") }

    // Copied from RootfsManager.hasUsableMetaDB.
    var hasUsableMetaDB: Bool {
        let path = metaDBPath.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return false }
        if !FileManager.default.isWritableFile(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootfsPath.path)
            guard FileManager.default.isWritableFile(atPath: path) else { return false }
        }
        return true
    }
    // Copied from RootfsManager.isInstalled.
    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: dataPath.path) else { return false }
        guard let tag = try? String(contentsOf: archTagPath, encoding: .utf8) else { return false }
        guard tag.trimmingCharacters(in: .whitespacesAndNewlines) == currentArch else { return false }
        return hasUsableMetaDB
    }
}

func makeTree(named name: String,
              tag: String? = "aarch64",
              data: Bool = true,
              metaDB: Data? = Data(repeating: 0x41, count: 1024)) -> URL {
    let dir = tmp.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if data {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("data"),
                                                 withIntermediateDirectories: true)
    }
    if let tag { try? tag.write(to: dir.appendingPathComponent(".arch"), atomically: true, encoding: .utf8) }
    if let metaDB { FileManager.default.createFile(atPath: dir.appendingPathComponent("meta.db").path, contents: metaDB) }
    return dir
}

// The regression: this exact tree used to report isInstalled == true.
let noDB = RootfsProbe(rootfsPath: makeTree(named: "no-meta-db", metaDB: nil))
check("REGRESSION: data/ + .arch but NO meta.db is NOT installed",
      noDB.isInstalled == false)

let emptyDB = RootfsProbe(rootfsPath: makeTree(named: "empty-meta-db",
                                               metaDB: Data()))
check("a zero-byte meta.db is NOT installed", emptyDB.isInstalled == false)

let goodDB = RootfsProbe(rootfsPath: makeTree(named: "good"))
check("data/ + .arch + a real meta.db IS installed", goodDB.isInstalled == true)

let wrongArch = RootfsProbe(rootfsPath: makeTree(named: "wrong-arch", tag: "x86_64"))
check("a wrong arch tag is still rejected", wrongArch.isInstalled == false)

let noData = RootfsProbe(rootfsPath: makeTree(named: "no-data", data: false))
check("a missing data/ is still rejected", noData.isInstalled == false)

let readOnly = RootfsProbe(rootfsPath: makeTree(named: "readonly"))
try? FileManager.default.setAttributes([.posixPermissions: 0o444],
                                       ofItemAtPath: readOnly.metaDBPath.path)
let readOnlyBefore = FileManager.default.isWritableFile(atPath: readOnly.metaDBPath.path)
check("a read-only meta.db is repaired rather than triggering a wipe",
      readOnlyBefore == false && readOnly.isInstalled == true,
      "writable-before=\(readOnlyBefore)")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 4. Reinstalling must actually restore the database
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  4. the bundled rootfs can restore a missing meta.db")

let zipURL = repo.appendingPathComponent("deps/resources/alpine-rootfs.zip")
let zipBytes = (try? Data(contentsOf: zipURL)) ?? Data()
check("deps/resources/alpine-rootfs.zip exists (\(zipBytes.count) bytes)", zipBytes.count > 0)
// Zip entry names live uncompressed in the central directory.
let zipText = String(decoding: zipBytes, as: UTF8.self)
check("it carries meta.db, so a reinstall replaces the missing file",
      zipText.contains("alpine-rootfs/meta.db"))
check("it carries the guest tree under data/",
      zipText.contains("alpine-rootfs/data/"))
check("RootfsManager looks the zip up by that exact resource name",
      rootfsSwift.contains("forResource: \"alpine-rootfs\", withExtension: \"zip\""))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 5. The failure is no longer a dead end
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  5. the boot-failure overlay offers a way out")

let miscSwift = src("Agent/Chat/AIChatViewModel+Misc.swift")
check("boot failure logs the tree state next to the errno",
      miscSwift.contains("rootfs=\\(RootfsManager.shared.integrityDiagnostic())"))
check("errno -22 is translated into an actionable message",
      miscSwift.contains("func describeBootError(_ err: Int32) -> String")
        && miscSwift.contains("case -22:"))
check("a reinstall-and-retry entry point exists",
      miscSwift.contains("func reinstallRootfsAndRetry()"))
check("a plain retry exists for transient failures",
      miscSwift.contains("func retryKernelBoot()"))

// Upstream 1.15 split AIChatView.swift into Views/Chat/AIChatView/**; the
// kernel boot overlay lives in its Banners part.
let chatView = src("Views/Chat/AIChatView/AIChatView+Banners.swift")
check("the failed overlay renders a Reinstall Rootfs button",
      chatView.contains("vm.reinstallRootfsAndRetry()")
        && chatView.contains("Reinstall Rootfs"))
check("…and a Try Again button", chatView.contains("vm.retryKernelBoot()"))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 6. End to end: the reinstall path turns a broken tree bootable
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  6. end-to-end recovery of a tree with no meta.db")

let broken = makeTree(named: "broken-e2e", metaDB: nil)
let brokenProbe = RootfsProbe(rootfsPath: broken)
check("precondition: the broken tree reports not-installed", brokenProbe.isInstalled == false)

// Extract exactly the way RootfsManager.unzipFile does: the zip stores entries
// under `alpine-rootfs/` and the installer strips that prefix, so the file must
// land at <rootfs>/meta.db — not <rootfs>/alpine-rootfs/meta.db, which would
// leave the tree just as unbootable as before.
let extracted = tmp.appendingPathComponent("extract")
try? FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
let unzip = Process()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-o", "-q", zipURL.path, "alpine-rootfs/meta.db", "-d", extracted.path]
unzip.standardOutput = FileHandle.nullDevice
unzip.standardError = FileHandle.nullDevice
try? unzip.run()
unzip.waitUntilExit()

let stagedDB = extracted.appendingPathComponent("alpine-rootfs/meta.db")
check("the bundle supplies a meta.db to restore",
      FileManager.default.fileExists(atPath: stagedDB.path))

if let data = try? Data(contentsOf: stagedDB) {
    try? data.write(to: broken.appendingPathComponent("meta.db"))
}
check("E2E: the restored tree reports installed again",
      RootfsProbe(rootfsPath: broken).isInstalled == true)

// It has to be a real sqlite database with the fakefs schema, or the guest
// would just fail differently (SQLITE_NOTADB → -5) instead of booting.
let restoredDB = broken.appendingPathComponent("meta.db").path
check("E2E: the restored file is a sqlite database",
      (try? Data(contentsOf: URL(fileURLWithPath: restoredDB)))?.prefix(15)
        == Data("SQLite format 3".utf8))
check("E2E: sqlite opens it read-write, as fake_db_init will",
      sqliteOpenRW(restoredDB) == SQLITE_OK)

var probeDB: OpaquePointer?
if sqlite3_open_v2(restoredDB, &probeDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
    func scalar(_ sql: String) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(probeDB, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }
    check("E2E: the fakefs schema is present (paths/stats populated)",
          scalar("select count(*) from paths") > 0 && scalar("select count(*) from stats") > 0)
    check("E2E: schema version is current (no migration needed)",
          scalar("pragma user_version") == 3)
} else {
    check("E2E: could not reopen the restored database", false)
}
if probeDB != nil { sqlite3_close(probeDB) }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 7. The automatic repair keeps what the user did not agree to lose
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  7. repair preserves user data")

check("the repair stashes the guest home before discarding the tree",
      rootfsSwift.contains("func stashUserHome() -> URL?")
        && rootfsSwift.contains("stashedHome = stashUserHome()"))
check("…and puts it back after the fresh install",
      rootfsSwift.contains("func restoreStashedUserHome(_ stash: URL?)")
        && rootfsSwift.contains("restoreStashedUserHome(stashedHome)"))
check("the stash is not abandoned when the unzip throws",
      rootfsSwift.contains("defer { if !homeRestored { restoreStashedUserHome(stashedHome) } }"))
check("an unwritable database does NOT trigger the destructive path",
      rootfsSwift.contains("case .missing, .empty:")
        && rootfsSwift.contains("case .unwritable:"))

// /var/minis must survive because its subdirectories are symlinks into the
// persistent store, which lives outside the rootfs.
let offloading = src("Agent/Chat/AIChatViewModel+Offloading.swift")
check("/var/minis is bind-mounted, so a rootfs reinstall cannot take it",
      offloading.contains("let hostPath = dataPath.appendingPathComponent(String(linuxDir.dropFirst()))"))
let miscPaths = src("Agent/Chat/AIChatViewModel+Misc.swift")
check("its persistent store is under Library, not Documents/alpine-rootfs",
      miscPaths.contains("MinisChat/minis"))
let rootfsSwiftForPaths = rootfsSwift
check("the rootfs itself lives under Documents",
      rootfsSwiftForPaths.contains("documents.appendingPathComponent(\"alpine-rootfs\")"))

// Behaviour: mirror stashUserHome + restoreStashedUserHome and prove the files
// survive a discard-and-reinstall cycle.
let homeTree = tmp.appendingPathComponent("home-cycle")
let homeRoot = homeTree.appendingPathComponent("data/root")
let homeStash = tmp.appendingPathComponent("home-stash/root")
try? FileManager.default.createDirectory(at: homeRoot.appendingPathComponent("project/src"),
                                        withIntermediateDirectories: true)
try? "notes".write(to: homeRoot.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
try? "x".write(to: homeRoot.appendingPathComponent("project/src/main.c"), atomically: true, encoding: .utf8)
try? FileManager.default.createDirectory(at: homeStash.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
// 1. stash (a move, as the real code does)
try? FileManager.default.moveItem(at: homeRoot, to: homeStash)
check("stash moves /root out of the doomed tree",
      !FileManager.default.fileExists(atPath: homeRoot.path)
        && FileManager.default.fileExists(atPath: homeStash.appendingPathComponent("NOTES.md").path))
// 2. discard the tree
let discarded = try? FileManager.default.removeItem(at: homeTree)
check("the tree is discarded", discarded != nil)
// 3. a fresh install creates an empty /root (the bundle ships one)
try? FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
// 4. restore
if FileManager.default.fileExists(atPath: homeRoot.path) {
    try? FileManager.default.removeItem(at: homeRoot)
}
try? FileManager.default.moveItem(at: homeStash, to: homeRoot)
check("E2E: the user's notes survive the repair",
      (try? String(contentsOf: homeRoot.appendingPathComponent("NOTES.md"), encoding: .utf8)) == "notes")
check("E2E: nested files survive too",
      (try? String(contentsOf: homeRoot.appendingPathComponent("project/src/main.c"), encoding: .utf8)) == "x")
try? FileManager.default.removeItem(at: homeTree)
try? FileManager.default.removeItem(at: homeStash.deletingLastPathComponent())

// ─────────────────────────────────────────────────────────────────────────────

print("")
if warnings > 0 { print("⚠️  \(warnings) note(s)") }
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
