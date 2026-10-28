// Tests for three scroll-stability fixes around in-place cards
// (review 2026-10-01):
//  - [T-user-ask-history-seed] tapping an answered user_ask card open in a
//    FINISHED message must re-measure it: the anchored toggle drops the row's
//    memoized height before configureCell, which would otherwise seed the old
//    state's height and skip the measure (device: ANCHORED h=64.0→64.0).
//  - [T-user-ask-estimate] user_ask / sub agent cards are estimated as cards
//    in the snapshot seed loop, not as 36pt capsules.
//  - [T-user-ask-pending-reuse] a pending card's body height and "Show more"
//    state survive cell reuse (compiled from the real source).
//
// Standalone: `swift ScrollJitterFixesTests.swift` from this directory.
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func read(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let v3 = messageListV3Source()
let card = read("Views/Chat/UserAskCardView.swift")
check("sources readable", !v3.isEmpty && !card.isEmpty)
func ordered(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for p in parts {
        guard let r = text.range(of: p, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
func body(_ src: String, of fn: String) -> String {
    guard let r = src.range(of: fn),
          let end = src.range(of: "\n        }\n", range: r.upperBound..<src.endIndex) else { return "" }
    return String(src[r.lowerBound..<end.lowerBound])
}

print("▶️  anchored toggle re-measures in finished messages [T-user-ask-history-seed]")
let anchored = body(v3, of: "func remeasureKeepingTop(")
check("flip → drop the row's cached + memoized height → fresh configuration → measure",
      ordered(anchored, ["_ = request?.run()",
                         "layout.invalidateHeight(at: i)",
                         "self.configureCell(cell, item: item, indexPath: ip)",
                         "cell.clearCachedHeight()",
                         "let fitted = cell.preferredLayoutAttributesFitting(attrs)",
                         "layout.setMeasuredHeight(fitted.size.height, at: i)"]))
let layout = read("Agent/MessageList/MessageListLayout.swift")
check("invalidateHeight drops the memo under the row's content key (what configureCell would seed)",
      ordered(layout, ["func invalidateHeight(at index: Int) {", "heightCache.removeValue(forKey: index)",
                       "if let key = contentKeyByIndex[index] {", "measuredHeightByContentKey.removeValue(forKey: key)"]))
check("the work stays on the tap path (only remeasureKeepingTop gained it, not configureCell)",
      !body(v3, of: "func configureCell(").contains("invalidateHeight"))

print("▶️  card estimates [T-user-ask-estimate]")
check("the snapshot seed loop estimates user_ask and sub agent cards through estimateItemHeight",
      v3.contains("case .userAskTool, .delegateTool:\n")
      && ordered(v3, ["case .userAskTool, .delegateTool:", "layout.setEstimatedHeight(",
                      "Self.estimateItemHeight(item, messages: messages, width: cvWidth), at: i)"]))
check("an answered (collapsed) user_ask card is estimated at its measured 64pt, a pending one at 260",
      v3.contains("return block.content.isEmpty ? 260 : 64"))
check("the sub agent card estimate is unchanged (58, control call 36)",
      v3.contains("return HelperBlockInfo.isControlOnly(block) ? 36 : 58"))

print("▶️  pending card state survives cell reuse [T-user-ask-pending-reuse]")
guard let s = card.range(of: "enum UserAskPendingLayoutCache {"),
      let e = card.range(of: "// END UserAskPendingLayoutCache", range: s.upperBound..<card.endIndex) else {
    print("❌ UserAskPendingLayoutCache not found"); exit(1)
}
let harness = "import Foundation\nimport CoreGraphics\n" + String(card[s.lowerBound..<e.lowerBound]) + #"""
let k = UserAskPendingLayoutCache.key("req-1", 2)
print("key=\(k)")
print("fresh=\(UserAskPendingLayoutCache.bodyHeight(k))|\(UserAskPendingLayoutCache.isExpanded(k))")
UserAskPendingLayoutCache.setBodyHeight(212.5, k)
UserAskPendingLayoutCache.setExpanded(true, k)
print("stored=\(UserAskPendingLayoutCache.bodyHeight(k))|\(UserAskPendingLayoutCache.isExpanded(k))")
print("otherQuestion=\(UserAskPendingLayoutCache.bodyHeight(UserAskPendingLayoutCache.key("req-1", 3)))")
UserAskPendingLayoutCache.setExpanded(false, k)
print("collapsed=\(UserAskPendingLayoutCache.isExpanded(k))")
for i in 0..<300 { UserAskPendingLayoutCache.setBodyHeight(CGFloat(i + 1), UserAskPendingLayoutCache.key("bulk", i)) }
print("bounded=\(UserAskPendingLayoutCache.bodyHeight(UserAskPendingLayoutCache.key("bulk", 299)))|\(UserAskPendingLayoutCache.bodyHeight(UserAskPendingLayoutCache.key("bulk", 0)))")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sjf-\(UUID().uuidString)")
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
check("UserAskPendingLayoutCache compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
let lines = Set(o.split(separator: "\n").map(String.init))
func has(_ l: String) -> Bool { lines.contains(l) }
check("one entry per ask and question", has("key=req-1#2") && has("otherQuestion=0.0"))
check("nothing stored → 0pt body, collapsed (first appearance behaves as before)", has("fresh=0.0|false"))
check("a stored height / Show more state comes back", has("stored=212.5|true") && has("collapsed=false"))
check("bounded: a long session's leftovers are dropped, the newest entry is kept",
      has("bounded=300.0|0.0"))

let pending = body(card, of: "private struct UserAskPendingCard: View {")
check("the card seeds its @State from the cache for the question it shows",
      card.contains("_bodyHeight = State(initialValue: UserAskPendingLayoutCache.bodyHeight(key))")
      && card.contains("_questionExpanded = State(initialValue: UserAskPendingLayoutCache.isExpanded(key))")
      && card.contains("let key = UserAskPendingLayoutCache.key(ask.requestId, min(ask.currentIndex, ask.questions.count - 1))"))
check("a changed body height is cached BEFORE the re-measure post; an unchanged one posts nothing",
      ordered(card, ["guard abs(h - bodyHeight) > 0.5 else { return }", "bodyHeight = h",
                     "UserAskPendingLayoutCache.setBodyHeight(h, layoutKey)",
                     "NotificationCenter.default.post(name: .thinkingBlockToggled, object: blockId)"]))
check("Show more/less is remembered per question",
      ordered(card, ["questionExpanded.toggle()", "UserAskPendingLayoutCache.setExpanded(questionExpanded, layoutKey)"])
      && card.contains("questionExpanded = UserAskPendingLayoutCache.isExpanded(layoutKey)"))
check("the cache is plain storage, not observable (reading it never re-renders)",
      !card.contains("class UserAskPendingLayoutCache") && !pending.contains("@ObservedObject private var layoutCache"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
