// [OpenMinis#277] Hardware-keyboard Ctrl+key in the terminal.
//
// Report: on an iPad with a physical keyboard, typing into the Minis terminal
// works but every Control combination (Ctrl+C, Ctrl+D, Ctrl+Z, ...) does
// nothing.
//
// Root cause, in TerminalKeyInputView (src/ios/iSH/Terminal/TerminalInputView.swift):
//   * pressesBegan handled arrows/Tab/Esc/F-keys and sent every other press to
//     super, i.e. into the text-input system, which inserts nothing for a Ctrl
//     combination and drops it;
//   * the keyCommands fallback computed `ascii - 'a' + 1`, a UInt8 subtraction
//     that traps for upper-case input (Caps Lock);
//   * no mapping at all for the non-letter control keys ([ \ ] ^ _ @ ?).
//
//   A. The shipping mapper (TerminalControlKeyMapper), compiled out of the
//      source file and exercised: letters in both cases, symbols, digits, and
//      keys that must NOT be mapped.
//   B. Source invariants: pressesBegan intercepts Ctrl before super and skips
//      Cmd; both paths go through the deduping emitControlCode; the old
//      underflowing subtraction is gone from handleCtrlKey; ended/cancelled are
//      symmetric.
//
// Standalone: `swift PhysicalKeyboardControlKeyTests.swift` (needs swiftc).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

let file = source("iSH/Terminal/TerminalInputView.swift")

// MARK: - A. Shipping mapper

print("A. TerminalControlKeyMapper (compiled from the shipping source)")
let mapperSrc = between(file, "// [OpenMinis#277] BEGIN control-key-mapper",
                        "// [OpenMinis#277] END control-key-mapper")
check("mapper found between markers", mapperSrc != nil)

if let mapperSrc {
    // Each probe prints `<key>=<code or nil>`; keys are written as unicode
    // scalars so spaces and backslashes survive the round trip.
    let probes: [String] = ["a", "c", "d", "z", "A", "C", "D", "Z", "l", "e",
                            "@", "2", "[", "3", "\\", "4", "]", "5", "^", "6",
                            "_", "-", "/", "7", "?", "8",
                            " ", "1", "9", "0", "=", ";", "é", "", "ab", "\t"]
    let probeList = probes.map { p in
        "\"" + p.unicodeScalars.map { String(format: "\\u{%X}", $0.value) }.joined() + "\""
    }.joined(separator: ", ")
    let harness = """
    import Foundation
    \(mapperSrc)
    for p in [\(probeList)] {
        let key = p.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+")
        let v = TerminalControlKeyMapper.controlCode(for: p).map { String($0) } ?? "nil"
        print("\\(key.isEmpty ? "EMPTY" : key)=\\(v)")
    }
    """
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlkey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", main.path, "-o", bin.path])
    check("mapper compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    check("ran", rc == 0)
    var got: [String: String] = [:]
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { got[parts[0]] = parts[1] }
    }
    func key(_ p: String) -> String {
        let k = p.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+")
        return k.isEmpty ? "EMPTY" : k
    }
    func expect(_ p: String, _ code: UInt8?, _ why: String) {
        let want = code.map { String($0) } ?? "nil"
        check("\(why): '\(p == " " ? "space" : p)' -> \(code.map { String(format: "0x%02X", $0) } ?? "nil") (got \(got[key(p)] ?? "?"))",
              got[key(p)] == want)
    }
    // Letters, both cases — the upper-case rows are the ones the old code trapped on.
    expect("a", 0x01, "Ctrl+A line start"); expect("c", 0x03, "Ctrl+C SIGINT")
    expect("d", 0x04, "Ctrl+D EOF");        expect("z", 0x1A, "Ctrl+Z SIGTSTP")
    expect("e", 0x05, "Ctrl+E line end");   expect("l", 0x0C, "Ctrl+L clear")
    expect("A", 0x01, "upper-case A");      expect("C", 0x03, "upper-case C (Caps Lock)")
    expect("D", 0x04, "upper-case D");      expect("Z", 0x1A, "upper-case Z")
    // Symbols and their xterm digit aliases.
    expect("@", 0x00, "NUL");  expect("2", 0x00, "NUL via 2")
    expect("[", 0x1B, "ESC");  expect("3", 0x1B, "ESC via 3")
    expect("\\", 0x1C, "FS");  expect("4", 0x1C, "FS via 4")
    expect("]", 0x1D, "GS");   expect("5", 0x1D, "GS via 5")
    expect("^", 0x1E, "RS");   expect("6", 0x1E, "RS via 6")
    expect("_", 0x1F, "US");   expect("-", 0x1F, "US via -")
    expect("/", 0x1F, "US via /"); expect("7", 0x1F, "US via 7")
    expect("?", 0x7F, "DEL");  expect("8", 0x7F, "DEL via 8")
    // Must pass through to UIKit.
    expect(" ", nil, "Ctrl+Space left to iPadOS input-source switching")
    expect("1", nil, "unmapped digit"); expect("9", nil, "unmapped digit")
    expect("0", nil, "unmapped digit"); expect("=", nil, "unmapped symbol")
    expect(";", nil, "unmapped symbol"); expect("é", nil, "non-ASCII")
    expect("", nil, "empty"); expect("ab", nil, "multi-character")
    expect("\t", nil, "Tab (handled by its own keyCode case)")
}

// MARK: - B. Source invariants

print("B. TerminalKeyInputView wiring")
let began = between(file, "override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {",
                    "override func pressesEnded(") ?? ""
check("pressesBegan located", !began.isEmpty)
check("pressesBegan checks .control on the hardware key",
      began.contains("flags.contains(.control)") && began.contains("key.charactersIgnoringModifiers"))
check("Cmd combinations are left to the system",
      began.contains("!flags.contains(.command)"))
check("Ctrl+key goes through the deduping emitter",
      began.contains("emitControlCode(code, fromPress: true)"))
if let ctrlRange = began.range(of: "flags.contains(.control)"),
   let superRange = began.range(of: "super.pressesBegan(presses, with: event)") {
    check("Ctrl interception runs before the super fallback", ctrlRange.lowerBound < superRange.lowerBound)
} else {
    check("Ctrl interception runs before the super fallback", false)
}
check("handled presses are recorded for the ended/cancelled phases",
      began.contains("consumedPresses.insert(ObjectIdentifier(press))"))

let ctrlKey = between(file, "@objc private func handleCtrlKey(_ command: UIKeyCommand) {", "\n    }") ?? ""
check("handleCtrlKey lower-cases its input", ctrlKey.contains("command.input?.lowercased()"))
check("handleCtrlKey uses the shared mapper + emitter",
      ctrlKey.contains("TerminalControlKeyMapper.controlCode") && ctrlKey.contains("emitControlCode(code, fromPress: false)"))
check("the underflowing `- Character(\"a\").asciiValue! + 1` is gone from handleCtrlKey",
      !ctrlKey.contains("Character(\"a\").asciiValue! + 1"))

check("pressesEnded passes through only unconsumed presses",
      file.contains("override func pressesEnded(") &&
      file.contains("super.pressesEnded(passthrough, with: event)"))
check("pressesCancelled passes through only unconsumed presses",
      file.contains("override func pressesCancelled(") &&
      file.contains("super.pressesCancelled(passthrough, with: event)"))
let emitter = between(file, "private func emitControlCode(_ code: UInt8, fromPress: Bool) {", "\n    }") ?? ""
check("emitter drops the other path's duplicate within 50 ms",
      emitter.contains("last.fromPress != fromPress") && emitter.contains("< 0.05"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
