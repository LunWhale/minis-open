// [T-prompt-modules-wired-to-1.15]
//
// The fork's headline feature is a pluginizable system prompt: the prompt split
// into switchable pieces so guidance the user does not need costs no tokens.
// Upstream 1.15 rewrote the prompt as one ~27 KB concatenation, and the merge
// left the ten module switches reading nothing — toggling "Prompt: Shell" did
// nothing at all.
//
// The fix gates the sections upstream writes INLINE instead of appending a
// second copy, which gives one property worth enforcing forever:
//
//   with every module enabled and no user override, the assembled prompt is
//   upstream 1.15's prompt byte-for-byte.
//
// That is what this suite pins. If someone re-wraps a section and drops or
// duplicates a sentence, the ordered literal comparison fails and says which
// one.
//
// Standalone (`swift PromptModuleGatingTests.swift`) like its neighbours:
// deps/libs/libish_emu.a is device-only arm64, so the app cannot link for a
// simulator and an XCTest bundle has nowhere to run.
import Foundation

var failures = 0
var warnings = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")"); failures += 1 }
}
func warn(_ label: String) { print("  ⚠️  \(label)"); warnings += 1 }

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repo = root.deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let promptFile = "Agent/Chat/AIChatViewModel+SystemPrompt.swift"
let current = src(promptFile)
check("the system-prompt file is readable", !current.isEmpty)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 1. Every module is actually wired
// ─────────────────────────────────────────────────────────────────────────────

print("▶️  1. all nine inline modules are gated, and the tenth is injected")

// promptExtensions has no inline section: its text is contributed by
// promptGuidanceTail, so it is asserted separately below.
let inlineModules = [
    "promptShellID", "promptWorkspaceID", "promptMemoryID", "promptCodingID",
    "promptAppleID", "promptMinisCLIID", "promptEnvSecretsID", "promptStyleID",
    "promptScheduledID",
]
for m in inlineModules {
    let n = current.components(separatedBy: "Self.promptModule(BuiltinExtension.\(m),").count - 1
    check("\(m) gates at least one section (\(n))", n >= 1, "found \(n)")
}
check("promptExtensions is wired through the guidance tail",
      current.contains("promptGuidanceTail")
        && current.contains("builtinGuidanceText(BuiltinExtension.promptExtensionsID)"))

// The whole point: the resolver must consult the switch.
let resolver = current.components(separatedBy: "nonisolated static func promptModule(").count - 1
check("promptModule() exists once", resolver == 1, "found \(resolver)")
check("promptModule() consults the plugin switch",
      current.contains("guard ExtensionRegistry.builtinEnabled(id) else { return \"\" }"))
check("promptModule() honours a user override (module stays editable)",
      current.contains("stringValue(extensionID: id, key: \"promptText\")"))
check("promptModule() suppresses a module whose subject feature is off",
      current.contains("BuiltinExtension.describedFeature(ofModule: id)"))
check("promptModule() falls back to the inline upstream text",
      current.contains("return inline()"))

// No stale second copy of the guidance: if the fork's old module bodies were
// appended as well, the prompt would say everything twice.
let oldModuleTexts = [
    "Shell discipline guidance",
    "Workspace and /var/minis layout",
    "Daily-log and GLOBAL.md rules",
]
for t in oldModuleTexts {
    check("no duplicate copy of the old module body: \(t)",
          !current.contains(t))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 2. Byte-identity with upstream 1.15
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  2. all-on output is upstream 1.15's prompt, byte for byte")

/// Source lines of `var baseSystemPrompt: String { ... }`, brace-matched.
func promptBody(_ text: String, anchor: String) -> [String] {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains(anchor) })
    else { return [] }
    var out: [String] = []
    var depth = 0
    var started = false
    for l in lines[start...] {
        out.append(l)
        depth += l.components(separatedBy: "{").count - 1
        depth -= l.components(separatedBy: "}").count - 1
        if l.contains("{") { started = true }
        if started && depth == 0 { break }
    }
    return out
}

/// Ordered string literals in a body, comments stripped. Interpolations are
/// kept verbatim — they are part of the text and must match too.
func literals(_ lines: [String]) -> [String] {
    var res: [String] = []
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
        var i = line.startIndex
        var inString = false
        var buf = ""
        while i < line.endIndex {
            let c = line[i]
            if !inString {
                if c == "/", line.index(after: i) < line.endIndex,
                   line[line.index(after: i)] == "/" { break }
                if c == "\"" { inString = true; buf = "" }
            } else {
                if c == "\\" {
                    buf.append(c)
                    let n = line.index(after: i)
                    if n < line.endIndex { buf.append(line[n]) }
                    i = line.index(after: n)
                    continue
                }
                if c == "\"" { res.append(buf); inString = false }
                else { buf.append(c) }
            }
            i = line.index(after: i)
        }
    }
    return res
}

// [T-minimal-mode] Our body lives in `fullSystemPrompt`; upstream 1.15's lived
// in `baseSystemPrompt` (a minimal session now substitutes its own compact prompt,
// so the full one moved behind a wrapper). Same text, different home.
let mine = literals(promptBody(current, anchor: "var fullSystemPrompt: String {"))
// The wrapper must still hand a normal session this exact prompt.
check("a normal session gets the full prompt",
      current.contains("if isMinimalMode { return MinimalModePolicy.prompt }")
        && current.contains("return fullSystemPrompt"))
check("the assembled prompt has the expected literal count (174)", mine.count == 174,
      "found \(mine.count)")
let totalChars = mine.reduce(0) { $0 + $1.count }
check("…and the expected total length (27101 chars)", totalChars == 27101,
      "found \(totalChars)")

// Full ordered comparison against upstream's file when the 1.15 tag is present.
// A clean clone of the fork has it; if it is missing, say so rather than pass
// silently on a weaker check.
let upstreamPath = repo.appendingPathComponent("deps/ish").path  // any existing dir proves we can run git
let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
git.arguments = ["-C", repo.path, "show", "1.15:src/ios/\(promptFile)"]
let pipe = Pipe()
git.standardOutput = pipe
git.standardError = Pipe()
try? git.run()
let upstreamData = pipe.fileHandleForReading.readDataToEndOfFile()
git.waitUntilExit()

if git.terminationStatus == 0, !upstreamData.isEmpty,
   let upstream = String(data: upstreamData, encoding: .utf8) {
    let theirs = literals(promptBody(upstream, anchor: "var baseSystemPrompt: String {"))
    check("upstream 1.15 has the same literal count", theirs.count == mine.count,
          "upstream \(theirs.count) vs ours \(mine.count)")
    if theirs.count == mine.count {
        var firstDiff: Int? = nil
        for (i, pair) in zip(theirs, mine).enumerated() where pair.0 != pair.1 {
            firstDiff = i; break
        }
        if let i = firstDiff {
            let a = i < theirs.count ? theirs[i] : ""
            let b = i < mine.count ? mine[i] : ""
            check("literal order and text identical", false,
                  "[\(i)] upstream=\(a.prefix(80)) ours=\(b.prefix(80))")
        } else {
            check("literal order and text identical (all \(theirs.count))", true)
        }
    }
    _ = upstreamPath
} else {
    warn("git tag 1.15 not available — skipped the full ordered comparison (counts/lengths above still hold)")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 3. The tail stays blank in a stock configuration
// ─────────────────────────────────────────────────────────────────────────────

print("\n▶️  3. the guidance tail cannot leak text into a default install")

check("tail is built from the gated accessors, not raw strings",
      current.contains("out += ExtensionRegistry.featureExtraGuidance()"))
let registry = src("Agent/Extension/ExtensionRegistry.swift")
check("the extensions module contributes nothing until an extension registers a surface",
      registry.contains("!ExtensionRegistry.shared.hasRegisteredExtensionSurface"))
check("feature-plugin guidance emits only user-typed text",
      registry.contains("let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)\n            guard !trimmed.isEmpty else { continue }"))

// ─────────────────────────────────────────────────────────────────────────────

print("")
if warnings > 0 { print("⚠️  \(warnings) warning(s)") }
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
