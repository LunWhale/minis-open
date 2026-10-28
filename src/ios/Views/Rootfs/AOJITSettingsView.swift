//
//  AOJITSettingsView.swift
//  MinisApp
//
//  [T-ios-aojit] AOJIT: ahead-of-time compiled JIT translations for the Shell
//  Container. The ARM64 JIT's translations of a few guest programs were
//  recorded and assembled into the app (deps/aot, libish_aot.a); with the
//  switch on, the kernel runs that native code instead of emulating those
//  programs instruction by instruction. On by default.
//

import SwiftUI

/// The recorded build of a guest module: the AOT image linked into the app.
struct AOJITBuild: Equatable {
    /// Image file in deps/aot.
    let file: String
    /// NT_GNU_BUILD_ID of the recorded file. A file with this build-id runs
    /// fully from the image.
    let buildId: String
    /// Package the recorded file comes from.
    let package: String
    /// [T-aojit-pillow] The real file the build was recorded from, when it is
    /// not the image's `module` path: shared libraries are reached through a
    /// soname link (libz.so.1 -> libz.so.1.3.1) whose target changes with the
    /// version, and the runtime reports hits under the real path.
    var path: String? = nil
}

/// A guest module with an AOT image linked into the app. Keep in sync with
/// deps/aot/README.md.
///
/// [T-aojit-family] One image per module. The runtime (deps/ish
/// feat/aot-family-match) also lets an image serve OTHER versions of its
/// module: blocks whose code did not change are found by content and run from
/// the image, the rest is emulated. So the recorded build runs at full speed
/// and any version whose file name matches `family` gets part of the gain,
/// instead of carrying one image per version.
struct AOJITImage: Identifiable, Equatable {
    /// Short name shown as the row title.
    let name: String
    /// Guest module the image is matched against (the stable name for a
    /// shared library, e.g. its soname link).
    let module: String
    /// Programs in the Shell Container that run through that module.
    let binaries: String
    /// The build the image was recorded from.
    let build: AOJITBuild
    /// fnmatch() pattern over file names this image also serves (the image's
    /// own family pattern, written by gen.py: libz.so.1.3.1 -> "libz.so.1*").
    let family: String
    /// `apk add` spec that installs `build`, for modules the user installs
    /// themselves. nil for core packages bundled with the rootfs (musl,
    /// busybox, zlib, OpenSSL): their bundled builds are no longer in the
    /// repository, and other versions are served by family matching.
    let apkSpec: String?
    /// [T-aojit-restore] Plan B for core packages, only offered when the
    /// installed file is not in the image's family at all: put these packages
    /// back to the build bundled with the app, from the original signed Alpine
    /// packages in the app bundle (AOJITRestore/, run by restore.sh with a
    /// rollback download, a dry run and a rollback on failure).
    let restorePackages: [String]
    /// What the core package does, for the restore warning.
    let coreRole: LocalizedStringKey?
    /// Which commands get faster.
    let affects: LocalizedStringKey

    var id: String { module }
    /// Where the runtime reports the recorded build.
    var recordedPath: String { build.path ?? module }

    /// Whether a module file name belongs to this image's family.
    func servesFamily(_ fileName: String) -> Bool {
        fnmatch(family, fileName, 0) == 0
    }

    static let catalog: [AOJITImage] = [
        AOJITImage(
            name: "musl",
            module: "/lib/ld-musl-aarch64.so.1",
            binaries: "/lib/ld-musl-aarch64.so.1 (musl libc)",
            build: AOJITBuild(file: "aot_musl_1.2.5-r8.S", buildId: "384940f9110e809da953d6fbabcb31d297c217b5", package: "musl 1.2.5-r8"),
            family: "ld-musl-aarch64.so.1*",
            apkSpec: nil,
            restorePackages: ["musl", "musl-utils"],
            coreRole: "musl is the C library that almost every installed program is linked against.",
            affects: "Every dynamically linked program: the C library under git, curl, apk, python3, node and most other commands."
        ),
        AOJITImage(
            name: "BusyBox",
            module: "/bin/busybox",
            binaries: "/bin/busybox, /bin/sh",
            build: AOJITBuild(file: "aot_busybox_1.37.0-r8.S", buildId: "2f8b429ec88eacccb94c8bb23ec060ab4a028ee8", package: "busybox 1.37.0-r8"),
            family: "busybox",
            apkSpec: nil,
            restorePackages: ["busybox", "busybox-binsh", "ssl_client"],
            coreRole: "BusyBox provides /bin/sh and the basic commands (ls, cp, grep, sed and more).",
            affects: "The shell and core tools: sh scripts and loops, ls, cat, grep, sed, awk, find, sort, xargs, tar, gzip and other BusyBox commands."
        ),
        AOJITImage(
            name: "Python",
            module: "/usr/lib/libpython3.12.so.1.0",
            binaries: "/usr/bin/python3, /usr/bin/pip",
            build: AOJITBuild(file: "aot_python3_3.12.15-r0.S", buildId: "d644d658076939b92edde6d007ef8bf491fec5a3", package: "python3 3.12.15-r0"),
            family: "libpython3.12.so.1*",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "python3 and pip: Python scripts, python3 -c one-liners and pip commands."
        ),
        AOJITImage(
            name: "Node.js",
            module: "/usr/bin/node",
            binaries: "/usr/bin/node, /usr/bin/npm, /usr/bin/npx",
            build: AOJITBuild(file: "aot_nodejs_22.23.2-r0.S", buildId: "c324f04a6d01b07f6858cc8ef1da4d6d3656daa3", package: "nodejs 22.23.2-r0"),
            family: "node",
            apkSpec: "nodejs=22.23.2-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "node, npm and npx: JavaScript scripts and Node-based CLI tools."
        ),
        // [T-aojit-pillow] The Pillow image stack (apk add py3-pillow).
        AOJITImage(
            name: "Pillow",
            module: "/usr/lib/python3.12/site-packages/PIL/_imaging.cpython-312-aarch64-linux-musl.so",
            binaries: "PIL._imaging (python3 -c \"from PIL import Image\")",
            build: AOJITBuild(file: "aot_pillow_11.0.0-r0.S", buildId: "4c527f1dd53c539fadb6e761f32fe1c97453f94e", package: "py3-pillow 11.0.0-r0"),
            family: "_imaging.cpython-312-aarch64-linux-musl.so",
            apkSpec: "py3-pillow=11.0.0-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Image processing with Pillow: opening and decoding images, resizing, filters such as blur and sharpen, and colour conversion."
        ),
        AOJITImage(
            name: "libwebp",
            module: "/usr/lib/libwebp.so.7",
            binaries: "/usr/lib/libwebp.so.7 (Pillow's WebP support)",
            build: AOJITBuild(file: "aot_libwebp_1.4.0-r0.S", buildId: "8ef75205b20db80a13c5a7cc73c4010bf5ee4d6f", package: "libwebp 1.4.0-r0", path: "/usr/lib/libwebp.so.7.1.9"),
            family: "libwebp.so.7*",
            apkSpec: "libwebp=1.4.0-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Saving and opening WebP images with Pillow. Much of libwebp is vector code that still runs emulated, so the gain is smaller."
        ),
        AOJITImage(
            name: "libjpeg-turbo",
            module: "/usr/lib/libjpeg.so.8",
            binaries: "/usr/lib/libjpeg.so.8 (Pillow's JPEG support)",
            build: AOJITBuild(file: "aot_libjpeg_3.0.4-r0.S", buildId: "18c1b17b04d907c6774bf76263b9fa42e9408db8", package: "libjpeg-turbo 3.0.4-r0", path: "/usr/lib/libjpeg.so.8.3.2"),
            family: "libjpeg.so.8*",
            apkSpec: "libjpeg-turbo=3.0.4-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Saving and opening JPEG images with Pillow. Much of libjpeg-turbo is vector code that still runs emulated, so the gain is smaller."
        ),
        // [T-aojit-family] numpy, from the ish-arm64 AOJIT set.
        AOJITImage(
            name: "NumPy",
            module: "/usr/lib/python3.12/site-packages/numpy/_core/_multiarray_umath.cpython-312-aarch64-linux-musl.so",
            binaries: "numpy._core._multiarray_umath (python3 -c \"import numpy\")",
            build: AOJITBuild(file: "aot_numpy_2.1.3-r0.S", buildId: "04b4971c8e52a43f5c0608f64d7b13207b8c1c3e", package: "py3-numpy 2.1.3-r0"),
            family: "_multiarray_umath.cpython-312-aarch64-linux-musl.so",
            apkSpec: "py3-numpy=2.1.3-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "NumPy array operations in Python: arithmetic on arrays, reductions such as sum and mean, sorting and indexing (also under pandas and matplotlib). Linear algebra runs in OpenBLAS, which has no image."
        ),
        AOJITImage(
            name: "zlib",
            module: "/usr/lib/libz.so.1",
            binaries: "/usr/lib/libz.so.1",
            // The bundled rootfs build: every fresh install has it exactly.
            build: AOJITBuild(file: "aot_zlib_1.3.1-r2.S", buildId: "0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9", package: "zlib 1.3.1-r2", path: "/usr/lib/libz.so.1.3.1"),
            family: "libz.so.1*",
            apkSpec: nil,
            restorePackages: [],
            coreRole: nil,
            affects: "Compression: PNG images, Python's zlib and gzip modules, pip unpacking packages, and other programs that use zlib."
        ),
        // [T-aojit-net] Database, TLS and PCRE2 libraries.
        AOJITImage(
            name: "SQLite",
            module: "/usr/lib/libsqlite3.so.0",
            binaries: "/usr/lib/libsqlite3.so.0 (python3 sqlite3, node:sqlite)",
            build: AOJITBuild(file: "aot_sqlite_3.48.0-r4.S", buildId: "0cd2f33152f67d2b77c8468184bbe0cef1d7e7f2", package: "sqlite-libs 3.48.0-r4", path: "/usr/lib/libsqlite3.so.0.8.6"),
            family: "libsqlite3.so.0*",
            apkSpec: "sqlite-libs=3.48.0-r4",
            restorePackages: [],
            coreRole: nil,
            affects: "SQLite databases in Python (sqlite3), Node (node:sqlite) and other programs: inserts, indexed and range queries, full-text search and JSON functions."
        ),
        AOJITImage(
            name: "OpenSSL libcrypto",
            module: "/usr/lib/libcrypto.so.3",
            binaries: "/usr/lib/libcrypto.so.3 (python3 ssl/hashlib, curl, git, node)",
            // The bundled rootfs build (apk itself links it); upgraded
            // OpenSSL builds are served by family matching.
            build: AOJITBuild(file: "aot_libcrypto_3.3.2-r4.S", buildId: "1dcac613c1f6b724c56844356ad82a8c97ff401a", package: "libcrypto3 3.3.2-r4"),
            family: "libcrypto.so.3*",
            apkSpec: nil,
            restorePackages: [],
            coreRole: nil,
            affects: "HTTPS and cryptography: TLS handshakes, certificate checks and hashing (Python hashlib and ssl, curl, git, pip, node https). Bulk AES-GCM encryption gains little."
        ),
        AOJITImage(
            name: "OpenSSL libssl",
            module: "/usr/lib/libssl.so.3",
            binaries: "/usr/lib/libssl.so.3",
            build: AOJITBuild(file: "aot_libssl_3.3.2-r4.S", buildId: "d0b98a4924a7a7dcc3f3f31dc5645db6ffd4fd9c", package: "libssl3 3.3.2-r4"),
            family: "libssl.so.3*",
            apkSpec: nil,
            restorePackages: [],
            coreRole: nil,
            affects: "The TLS protocol layer of HTTPS connections, used together with libcrypto; most of the HTTPS gain comes from libcrypto."
        ),
        AOJITImage(
            name: "PCRE2",
            module: "/usr/lib/libpcre2-8.so.0",
            binaries: "/usr/lib/libpcre2-8.so.0 (git grep -P, grep -P, rg -P)",
            build: AOJITBuild(file: "aot_pcre2_10.43-r0.S", buildId: "2a7cfd13f571d133069bf15c8e869ba13d2a4c5f", package: "pcre2 10.43-r0", path: "/usr/lib/libpcre2-8.so.0.12.0"),
            family: "libpcre2-8.so.0*",
            apkSpec: "pcre2=10.43-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Only searches that ask for PCRE regular expressions explicitly: git grep -P, GNU grep -P and rg -P / --pcre2. ripgrep's default search does not use PCRE2 and does not benefit, and neither does jq (it uses another regex library)."
        ),
        // [T-aojit-batch2] SSH and Python's lib-dynload modules, picked from
        // the shell usage reports (ssh/scp and python3 -c are the most
        // frequent commands) and recorded by ish-arm64. ripgrep and _ssl were
        // recorded too but dropped after measuring on an iPhone 11: rg gained
        // ~5% for 22 MB, _ssl 1% (the handshake runs in libcrypto).
        AOJITImage(
            name: "OpenSSH ssh",
            module: "/usr/bin/ssh",
            binaries: "/usr/bin/ssh (also under scp, sftp, rsync and git over SSH)",
            build: AOJITBuild(file: "aot_ssh_9.9_p2-r0.S", buildId: "df1649582b7a74dc596ffcb440391796995dd202", package: "openssh-client-default 9.9_p2-r0"),
            family: "ssh",
            apkSpec: "openssh-client-default=9.9_p2-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "ssh logins and remote commands, and every tool that connects through ssh: scp, sftp, rsync and git over SSH. Each new connection's handshake gets faster; the encryption of the data itself runs in libcrypto."
        ),
        AOJITImage(
            name: "OpenSSH scp",
            module: "/usr/bin/scp",
            binaries: "/usr/bin/scp",
            build: AOJITBuild(file: "aot_scp_9.9_p2-r0.S", buildId: "cbc5234e3d96db92e8acd726e6743ec76b66e03d", package: "openssh-client-common 9.9_p2-r0"),
            family: "scp",
            apkSpec: "openssh-client-common=9.9_p2-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Copying files with scp. Most of the gain comes from the ssh connection scp opens, which has its own image."
        ),
        AOJITImage(
            name: "Python json",
            module: "/usr/lib/python3.12/lib-dynload/_json.cpython-312-aarch64-linux-musl.so",
            binaries: "_json (import json)",
            build: AOJITBuild(file: "aot_py_json_3.12.15-r0.S", buildId: "a1d82af66c4470aa6cac49ca772927a2995ed297", package: "python3 3.12.15-r0"),
            family: "_json.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "json.loads and json.dumps in Python scripts and python3 -c one-liners."
        ),
        AOJITImage(
            name: "Python hashlib",
            module: "/usr/lib/python3.12/lib-dynload/_hashlib.cpython-312-aarch64-linux-musl.so",
            binaries: "_hashlib (import hashlib)",
            build: AOJITBuild(file: "aot_py_hashlib_3.12.15-r0.S", buildId: "97a005a1b066e6bd4158eb271132e1b38c1be8cb", package: "python3 3.12.15-r0"),
            family: "_hashlib.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "hashlib digests such as sha256 and md5 in Python; the hashing itself runs in libcrypto."
        ),
        AOJITImage(
            name: "Python blake2",
            module: "/usr/lib/python3.12/lib-dynload/_blake2.cpython-312-aarch64-linux-musl.so",
            binaries: "_blake2 (hashlib.blake2b / blake2s)",
            build: AOJITBuild(file: "aot_py_blake2_3.12.15-r0.S", buildId: "f4f542cf566ffe62953373b6e54602f614df6951", package: "python3 3.12.15-r0"),
            family: "_blake2.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "hashlib.blake2b and hashlib.blake2s in Python."
        ),
        AOJITImage(
            name: "Python struct",
            module: "/usr/lib/python3.12/lib-dynload/_struct.cpython-312-aarch64-linux-musl.so",
            binaries: "_struct (import struct)",
            build: AOJITBuild(file: "aot_py_struct_3.12.15-r0.S", buildId: "6cfef1a2458b6dcc2f396ec8f2b9d9ebb771bba1", package: "python3 3.12.15-r0"),
            family: "_struct.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "struct.pack and struct.unpack: reading and writing binary data in Python."
        ),
        AOJITImage(
            name: "Python datetime",
            module: "/usr/lib/python3.12/lib-dynload/_datetime.cpython-312-aarch64-linux-musl.so",
            binaries: "_datetime (import datetime)",
            build: AOJITBuild(file: "aot_py_datetime_3.12.15-r0.S", buildId: "e361da74dd7d72b332863d47c2dfe3f52026d916", package: "python3 3.12.15-r0"),
            family: "_datetime.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Date and time parsing, formatting and arithmetic with Python's datetime."
        ),
        AOJITImage(
            name: "Python binascii",
            module: "/usr/lib/python3.12/lib-dynload/binascii.cpython-312-aarch64-linux-musl.so",
            binaries: "binascii (import base64, binascii)",
            build: AOJITBuild(file: "aot_py_binascii_3.12.15-r0.S", buildId: "dd90d3e7366c8149d54e58c13669f05e76e48e60", package: "python3 3.12.15-r0"),
            family: "binascii.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Base64, hex and CRC conversions in Python (base64 and binascii)."
        ),
        AOJITImage(
            name: "Python math",
            module: "/usr/lib/python3.12/lib-dynload/math.cpython-312-aarch64-linux-musl.so",
            binaries: "math (import math)",
            build: AOJITBuild(file: "aot_py_math_3.12.15-r0.S", buildId: "67f6d6a06bb8f7453d482c52f6ef4bc6fb720937", package: "python3 3.12.15-r0"),
            family: "math.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Python's math module."
        ),
        AOJITImage(
            name: "Python zlib",
            module: "/usr/lib/python3.12/lib-dynload/zlib.cpython-312-aarch64-linux-musl.so",
            binaries: "zlib (import zlib, gzip, zipfile)",
            build: AOJITBuild(file: "aot_py_zlib_3.12.15-r0.S", buildId: "fad09a48ab85c708fbd9bc458f4b1ac1ed129055", package: "python3 3.12.15-r0"),
            family: "zlib.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Compression in Python (zlib, gzip, zipfile); the compression itself runs in libz."
        ),
        AOJITImage(
            name: "Python socket",
            module: "/usr/lib/python3.12/lib-dynload/_socket.cpython-312-aarch64-linux-musl.so",
            binaries: "_socket (import socket)",
            build: AOJITBuild(file: "aot_py_socket_3.12.15-r0.S", buildId: "d3f34d4d8f288f9f9324bf303dc3b25c8969b533", package: "python3 3.12.15-r0"),
            family: "_socket.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Network connections in Python: sockets, urllib, http.client and requests."
        ),
        AOJITImage(
            name: "Python select",
            module: "/usr/lib/python3.12/lib-dynload/select.cpython-312-aarch64-linux-musl.so",
            binaries: "select (import select)",
            build: AOJITBuild(file: "aot_py_select_3.12.15-r0.S", buildId: "109bd4dae0f995d654c1e0b4346eba111c6aa8c1", package: "python3 3.12.15-r0"),
            family: "select.cpython-312-aarch64-linux-musl.so",
            apkSpec: "python3=3.12.15-r0",
            restorePackages: [],
            coreRole: nil,
            affects: "Waiting on sockets and pipes in Python: subprocess, selectors and asyncio."
        ),
    ]
}

/// How the file in the container relates to the image.
enum AOJITModuleState: Equatable {
    case checking
    /// The recorded build: runs fully from the image.
    case matched(AOJITBuild)
    /// [T-aojit-family] Another version of the module (its file name is in
    /// the image's family): unchanged code runs from the image, the rest is
    /// emulated. `file` is the real file found, e.g. libz.so.1.3.2.
    case family(file: String)
    case notInstalled
    /// Not in the family at all: runs without AOJIT.
    case mismatch(found: String?)
}

/// Reads ELF build-ids straight from the rootfs data directory (host side,
/// no guest process), so the check works with the kernel idle.
enum AOJITModuleProbe {
    static func state(for image: AOJITImage) -> AOJITModuleState {
        let root = RootfsManager.shared.dataPath
        var path = image.module
        // [T-aojit-pillow] fakefs keeps a symlink as a small file holding its
        // target, so a soname link (libz.so.1 -> libz.so.1.3.1) is followed
        // here by hand.
        for _ in 0..<4 {
            let url = root.appendingPathComponent(String(path.dropFirst()))
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .notInstalled }
            // Program headers and the note segment sit near the start of the file.
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            guard !head.isEmpty else { return .notInstalled }
            if let next = linkTarget(head, from: path) { path = next; continue }
            return match(buildId(inELF: head), file: (path as NSString).lastPathComponent, in: image)
        }
        return .mismatch(found: nil)
    }

    /// The target of a fakefs symlink stored as file content, resolved against
    /// the link's directory; nil for anything that is not such a link.
    static func linkTarget(_ d: Data, from path: String) -> String? {
        guard d.count < 1024, !d.starts(with: [0x7f, 0x45, 0x4c, 0x46]),
              let text = String(data: d, encoding: .utf8),
              !text.isEmpty, !text.contains("\0"), !text.contains("\n") else { return nil }
        if text.hasPrefix("/") { return text }
        let dir = (path as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(text)
    }

    /// The runtime's rule (deps/ish jit.c): the recorded build-id first, else
    /// the family pattern over the module's file name.
    static func match(_ found: String?, file: String, in image: AOJITImage) -> AOJITModuleState {
        if let found, found == image.build.buildId { return .matched(image.build) }
        if image.servesFamily(file) { return .family(file: file) }
        return .mismatch(found: found)
    }

    /// NT_GNU_BUILD_ID from the PT_NOTE segments of a 64-bit little-endian ELF.
    static func buildId(inELF d: Data) -> String? {
        let b = [UInt8](d)
        guard b.count >= 64, b[0] == 0x7f, b[1] == 0x45, b[2] == 0x4c, b[3] == 0x46, b[4] == 2 else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? (0..<4).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } : 0 }
        func u64(_ o: Int) -> Int { o + 8 <= b.count ? (0..<8).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } : 0 }
        let phoff = u64(0x20), phentsize = u16(0x36), phnum = u16(0x38)
        for i in 0..<phnum {
            let ph = phoff + i * phentsize
            guard u32(ph) == 4 else { continue }  // PT_NOTE
            var off = u64(ph + 8)
            let end = off + u64(ph + 32)
            while off + 12 <= min(end, b.count) {
                let namesz = u32(off), descsz = u32(off + 4), type = u32(off + 8)
                let desc = off + 12 + ((namesz + 3) & ~3)
                if type == 3, namesz == 4, desc + descsz <= b.count,
                   b[off + 12] == 0x47, b[off + 13] == 0x4e, b[off + 14] == 0x55 {  // "GNU"
                    return b[desc..<(desc + descsz)].map { String(format: "%02x", $0) }.joined()
                }
                off = desc + ((descsz + 3) & ~3)
            }
        }
        return nil
    }
}

/// Per-module line of the runtime's report: images accepted / rejected and
/// blocks / AOT hits / of which moved (see jit_describe in deps/ish).
struct AOJITRuntimeStatus {
    struct Coverage: Equatable {
        var blocks = 0
        /// Blocks installed from an image.
        var hits = 0
        /// Of those, found by content in another version (family matching).
        var moved = 0
    }
    var rejected: Set<String> = []
    var accepted: Set<String> = []
    var hits: [String: Coverage] = [:]
    var abi: String?

    /// Totals over every module file the image serves: the recorded file and
    /// any other version in its family (reported under its own real path).
    func coverage(for image: AOJITImage) -> Coverage? {
        let rows = hits.filter { $0.key == image.recordedPath || image.servesFamily(($0.key as NSString).lastPathComponent) }
        guard !rows.isEmpty else { return nil }
        return rows.values.reduce(into: Coverage()) { $0.blocks += $1.blocks; $0.hits += $1.hits; $0.moved += $1.moved }
    }

    init(report: String) {
        for raw in report.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "(abi ") {
                abi = String(line[r.upperBound...].prefix { $0 != ")" })
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, parts[0] == "ok" { accepted.insert(parts[1]) }
            if parts.count >= 2, parts[0].hasPrefix("rejected") { rejected.insert(parts[1]) }
            // "/path   blocks / hits / moved" (moved: family runtimes; absent before)
            if parts.count >= 4, parts[0].hasPrefix("/"), parts[2] == "/",
               let blocks = Int(parts[1]), let hit = Int(parts[3]) {
                let moved = parts.count >= 6 && parts[4] == "/" ? Int(parts[5]) ?? 0 : 0
                hits[parts[0]] = Coverage(blocks: blocks, hits: hit, moved: moved)
            }
        }
    }
}

@MainActor
final class AOJITSettingsModel: ObservableObject {
    @Published var enabled: Bool = ISHKernel.isAOJITEnabled()
    @Published var states: [String: AOJITModuleState] = [:]
    @Published var runtime = AOJITRuntimeStatus(report: "")
    @Published var fixing: String?
    @Published var fixError: String?
    @Published var fixNotice: String?

    func setEnabled(_ on: Bool) {
        ISHKernel.setAOJITEnabled(on)
        enabled = on
        if on { refresh() }
    }

    func refresh() {
        for image in AOJITImage.catalog { states[image.id] = .checking }
        Task.detached(priority: .userInitiated) {
            let result = Dictionary(uniqueKeysWithValues: AOJITImage.catalog.map { ($0.id, AOJITModuleProbe.state(for: $0)) })
            let report = ISHKernel.aojitStatusReport()
            await MainActor.run {
                self.states = result
                self.runtime = AOJITRuntimeStatus(report: report)
            }
        }
    }

    /// Install the build the image was recorded from with apk, then re-check.
    /// Only called from the confirmation dialog (AOJITSettingsSection).
    func fix(_ image: AOJITImage) {
        guard let spec = image.apkSpec, fixing == nil else { return }
        guard ISHKernel.shared.isBooted else {
            fixError = AppLocalized("The Shell Container is not running yet. Open the terminal once, then try again.")
            return
        }
        fixing = image.id
        fixError = nil
        Task.detached(priority: .userInitiated) {
            let result = ISHShellExecutor.executeCommandSync("apk add \(spec) 2>&1", timeout: 600, lineCallback: nil)
            await MainActor.run {
                self.fixing = nil
                if result.exitCode != 0 {
                    let tail = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
                    self.fixError = AppLocalized("apk add \(spec) failed: \(tail)")
                }
                self.refresh()
            }
        }
    }

    /// [T-aojit-restore] Plan B: put a core package (musl, busybox) back to
    /// the build bundled with the app. Only offered when the installed build
    /// matches none of the recorded images, and only called from the warning
    /// alert (AOJITSettingsSection). The work is done in the guest by
    /// AOJITRestore/restore.sh; see its header for the safety steps.
    func restore(_ image: AOJITImage) {
        guard !image.restorePackages.isEmpty, fixing == nil else { return }
        guard ISHKernel.shared.isBooted else {
            fixError = AppLocalized("The Shell Container is not running yet. Open the terminal once, then try again.")
            return
        }
        guard let bundled = Bundle.main.url(forResource: "AOJITRestore", withExtension: nil) else {
            fixError = AppLocalized("The bundled packages are missing from this build of the app.")
            return
        }
        fixing = image.id
        fixError = nil
        fixNotice = nil
        let target = image.build.package
        let packages = image.restorePackages.joined(separator: " ")
        Task.detached(priority: .userInitiated) {
            let stage = "/var/cache/minis-aojit/bundled"
            var code: Int32 = -1
            var output = ""
            do {
                try RootfsManager.shared.stageFiles(from: bundled, toLinuxDir: stage)
                // rm from inside the guest so meta.db drops the staged files too.
                let result = ISHShellExecutor.executeCommandSync(
                    "sh \(stage)/restore.sh \(stage) \(packages) 2>&1; rc=$?; rm -rf \(stage); exit $rc",
                    timeout: 900, lineCallback: nil)
                code = result.exitCode
                output = result.output
            } catch {
                output = error.localizedDescription
            }
            let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
            await MainActor.run {
                self.fixing = nil
                switch code {
                case 0: self.fixNotice = AppLocalized("Restored \(target). Commands started from now on use AOJIT.")
                case 1: self.fixNotice = AppLocalized("\(target) is already installed.")
                case 11: self.fixError = AppLocalized("Nothing was changed: the installed build could not be downloaded as a rollback (offline, or the repository has another build). Try again online.")
                case 12: self.fixError = AppLocalized("Nothing was changed: the dry run would also change other packages.\n\(tail)")
                case 13: self.fixError = AppLocalized("The install failed and was rolled back to the previous build. Nothing else was changed.\n\(tail)")
                case 14: self.fixError = AppLocalized("The install and the rollback both failed. The previous packages are kept: run “apk add /var/cache/minis-aojit/rollback/*.apk” in the terminal.\n\(tail)")
                default: self.fixError = AppLocalized("Restoring \(target) failed: \(tail)")
                }
                self.refresh()
            }
        }
    }
}

/// Section shown in Rootfs Management (the Shell Container screen).
struct AOJITSettingsSection: View {
    @StateObject private var model = AOJITSettingsModel()
    /// The module whose Fix is waiting for the user to confirm it.
    @State private var pendingFix: AOJITImage?
    /// The core module whose restore is waiting for the user to confirm it.
    @State private var pendingRestore: AOJITImage?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
                Label("AOJIT Optimization", systemImage: "bolt.horizontal.circle")
            }
            if model.enabled {
                ForEach(AOJITImage.catalog) { image in
                    row(image)
                }
                if let error = model.fixError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let notice = model.fixNotice {
                    Text(notice).font(.caption).foregroundStyle(.green)
                }
            }
        } header: {
            Text("AOJIT")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runs JIT code recorded and compiled ahead of time for the libraries below, instead of emulating them instruction by instruction. Shell pipelines typically run 2–4× faster. Applies to commands started after switching.")
                // [T-aojit-family]
                Text("Each library has one image, recorded from the build listed: that build runs at full speed. Other versions of the same library still run the code that did not change from the image and emulate the rest, so they get part of the gain.")
                if !model.enabled {
                    Text("Covers: \(AOJITImage.catalog.map(\.name).joined(separator: ", "))")
                }
            }
        }
        .onAppear { if model.enabled { model.refresh() } }
        // [T-aojit-fix-confirm] Fix runs `apk add <pkg>=<version>` in the
        // user's container, which can replace (even downgrade) an installed
        // package. Say exactly what will be installed and let the user confirm.
        .confirmationDialog(
            pendingFix.map { AppLocalized("Install \($0.build.package)?") } ?? "",
            isPresented: Binding(get: { pendingFix != nil }, set: { if !$0 { pendingFix = nil } }),
            titleVisibility: .visible,
            presenting: pendingFix
        ) { image in
            Button("Install \(image.build.package)") { model.fix(image) }
            Button("Cancel", role: .cancel) {}
        } message: { image in
            Text("Runs “apk add \(image.apkSpec ?? "")” in the Shell Container. If another version of \(image.name) is installed, it is replaced with this one, which may be older. Other packages are not changed.")
        }
        // [T-aojit-restore] Plan B for a core package: a warning, not a plain
        // confirmation. The destructive button is the only way to start it.
        .alert(
            pendingRestore.map { AppLocalized("Restore \($0.build.package)?") } ?? "",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { image in
            Button("Restore", role: .destructive) { model.restore(image) }
            Button("Cancel", role: .cancel) {}
        } message: { image in
            Text(image.coreRole ?? "") + Text(verbatim: "\n\n")
                + Text("This is a core system package: if it breaks, no program in the Shell Container can start. Minis first downloads the installed build for a rollback and does a dry run, stops without changing anything if other packages would be affected, and rolls back if the install fails. Back up files you cannot lose before continuing. The next apk upgrade may replace the restored build again.")
        }
    }

    @ViewBuilder
    private func row(_ image: AOJITImage) -> some View {
        let state = model.states[image.id] ?? .checking
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: image.name).font(.subheadline.weight(.semibold))
                Spacer()
                stateBadge(image)
            }
            Text(image.binaries).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(image.affects).font(.caption).foregroundStyle(.secondary)
            Text("Image recorded from \(image.build.package)").font(.caption2).foregroundStyle(.tertiary)
            // [T-aojit-family] What the installed file gets from the image.
            switch state {
            case .matched:
                Text("Full speed: this is the recorded build.").font(.caption2).foregroundStyle(.secondary)
            case .family(let file):
                Text("Another version is installed (\(file)): code unchanged since \(image.build.package) runs from the image, the rest is emulated.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .mismatch:
                Text("The installed file is not a version this image can serve, so it runs without AOJIT.")
                    .font(.caption2).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            if let c = model.runtime.coverage(for: image), c.blocks > 0 {
                Text("AOT coverage: \(Self.percent(c.hits, of: c.blocks)) of \(c.blocks) blocks").font(.caption2).foregroundStyle(.tertiary)
                if c.moved > 0 {
                    Text("\(c.moved) of them reused from another version by content").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // Plan B only when the installed file is not in the family at all.
            if !image.restorePackages.isEmpty, case .mismatch = state {
                Text("You can put back the build bundled with Minis.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    pendingRestore = image
                } label: {
                    if model.fixing == image.id {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Restoring…") }
                    } else {
                        Text("Restore bundled \(image.build.package)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.fixing != nil)
            }
            if image.apkSpec != nil, needsFix(image) {
                Button {
                    pendingFix = image
                } label: {
                    if model.fixing == image.id {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
                    } else if case .family = state {
                        Text("Install \(image.build.package) for full speed")
                    } else {
                        Text("Fix: install \(image.build.package)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.fixing != nil)
            }
        }
        .padding(.vertical, 2)
    }

    /// "87%", never "100%" unless every block hit, never "0%" if any did.
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        var p = Int((Double(part) / Double(whole) * 100).rounded())
        if part < whole { p = min(p, 99) }
        if part > 0 { p = max(p, 1) }
        return "\(p)%"
    }

    private func needsFix(_ image: AOJITImage) -> Bool {
        switch model.states[image.id] {
        case .notInstalled, .mismatch, .family: return true
        default: return false
        }
    }

    @ViewBuilder
    private func stateBadge(_ image: AOJITImage) -> some View {
        if model.runtime.rejected.contains(image.recordedPath) {
            badge("Rejected", color: .red)
        } else {
            switch model.states[image.id] ?? .checking {
            case .checking: ProgressView().controlSize(.mini)
            case .matched: badge("Ready", color: .green)
            case .family: badge("Partial", color: .blue)
            case .notInstalled: badge("Not installed", color: .secondary)
            case .mismatch: badge("No image", color: .orange)
            }
        }
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
