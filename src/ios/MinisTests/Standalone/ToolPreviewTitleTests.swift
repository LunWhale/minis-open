// Tests for [T-preview-tool-title] — the session list preview names a tool
// the way the chat does. A session waiting on a user_ask question showed
// "🔧 user_ask" in the list while the chat's status bar said "Question for
// you": the list kept its own tool-name switch with no user_ask entry and
// fell back to the raw name. Both now read ToolDisplayTitle.
//
// Compiles the REAL ToolDisplayTitle out of Agent/Chat/ChatModels.swift (with
// stubs for the two name constants and AppLocalized), then checks both call
// sites in source.
//
// Standalone: `swift ToolPreviewTitleTests.swift` from this directory.
import Foundation

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func read(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let models = read("Agent/Chat/ChatModels.swift")
let store = chatStoreSource()
let userAsk = read("Agent/Chat/AIChatViewModel+UserAsk.swift")
let subAgent = read("Providers/SubAgentDefinition.swift")
check("sources readable", !models.isEmpty && !store.isEmpty)
guard let s = models.range(of: "enum ToolDisplayTitle {"),
      let e = models.range(of: "// END ToolDisplayTitle", range: s.upperBound..<models.endIndex) else {
    print("❌ ToolDisplayTitle not found"); exit(1)
}
// Stubs carry the REAL constant values, read from source.
func constant(_ src: String, _ decl: String) -> String {
    guard let r = src.range(of: decl + " = \""),
          let end = src.range(of: "\"", range: r.upperBound..<src.endIndex) else { return "?" }
    return String(src[r.upperBound..<end.lowerBound])
}
let userAskName = constant(userAsk, "static let name")
let subAgentName = constant(subAgent, "static let toolName")
check("tool names read from source (user_ask / subagent_task)", userAskName == "user_ask" && subAgentName == "subagent_task")
let harness = """
import Foundation
enum UserAskTool { static let name = "\(userAskName)" }
enum SubAgentDefinition { static let toolName = "\(subAgentName)" }
func AppLocalized(_ key: StaticString) -> String { "L(\\(key))" }

""" + String(models[s.lowerBound..<e.lowerBound]) + #"""
for n in ["user_ask", "subagent_task", "shell_execute", "mcp__x__y", ""] {
    print("\(n)=\(ToolDisplayTitle.fixed(forToolName: n) ?? "nil")")
}
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tpt-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("ToolDisplayTitle compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
let lines = Set(o.split(separator: "\n").map(String.init))
func has(_ l: String) -> Bool { lines.contains(l) }

print("▶️  shared titles")
check("user_ask → the localized \"Question for you\" (zh: 向你提问)", has("user_ask=L(Question for you)"))
check("subagent_task without a title → \"Agent\", as on its card", has("subagent_task=L(Agent)"))
check("tools titled from their arguments are not covered (nil → their own preview)",
      has("shell_execute=nil") && has("mcp__x__y=nil") && has("=nil"))

print("▶️  both call sites use it")
func body(_ src: String, of fn: String) -> String {
    guard let r = src.range(of: fn),
          let end = src.range(of: "\n    }\n", range: r.upperBound..<src.endIndex) else { return "" }
    return String(src[r.lowerBound..<end.lowerBound])
}
let summarize = body(store, of: "private func summarizeToolUse(_ tu: ToolUse) -> String {")
func ordered(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for p in parts {
        guard let r = text.range(of: p, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
check("list preview: tool_title first, then the shared title, before the per-tool switch and the fallback",
      ordered(summarize, ["if let title = str(\"tool_title\")",
                          "if let fixed = ToolDisplayTitle.fixed(forToolName: tu.name) {",
                          "switch tu.name {", "return cap(Self.toolPreviewFallbackPrefix + tu.name)"]))

print("▶️  fallback glyph [T-preview-tool-glyph]")
check("the fallback prefix is U+2692 + U+FE0E (monochrome ⚒︎), written as escapes",
      store.contains("static let toolPreviewFallbackPrefix = \"\\u{2692}\\u{FE0E} \""))
check("only the fallback changed: no 🔧 left in summarizeToolUse, titled previews untouched",
      !summarize.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
          .contains { $0.contains("🔧") }
      && summarize.contains("return cap(title)") && summarize.contains("return cap(fixed)")
      && summarize.contains("return cap(\"$ \" + cmd)"))
check("search hit lines keep 🔧 (a different function, out of scope)",
      store.contains("return \"🔧 \\(tu.name): \\(line)\"") && store.contains("return \"🔧 \\(line)\""))
let desc = body(models, of: "var toolDescription: String {")
check("chat card / status bar: user_ask and the untitled sub agent read the same helper",
      desc.contains("return ToolDisplayTitle.fixed(forToolName: UserAskTool.name) ?? \"\"")
      && desc.contains("title.isEmpty ? (ToolDisplayTitle.fixed(forToolName: SubAgentDefinition.toolName) ?? \"\") : title"))
check("no second copy of the label left in toolDescription",
      !desc.contains("AppLocalized(\"Question for you\")") && !desc.contains("AppLocalized(\"Agent\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
