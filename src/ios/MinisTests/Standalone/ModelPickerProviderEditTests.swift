// Tests for [T-picker-provider-edit]: an edit button in each provider section
// header of the model picker (UnifiedModelPicker), left of the fold chevron,
// that opens THAT provider's detail page.
//
//   [1] which sections get the button (port of providerEditTarget)
//   [2] header layout and tap separation (source guards)
//   [3] the button opens the provider's own detail page (source guards)
//   [4] accessibility label is localized
//
// Standalone: `swift ModelPickerProviderEditTests.swift`.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - Port: UnifiedModelPicker.providerEditTarget

let systemId = "__system__"   // stands in for SystemVoiceProvider.builtinProviderId
func providerEditTarget(forSectionInstanceId id: String, storedInstanceIds: [String]) -> String? {
    guard !id.isEmpty,
          id != systemId,
          !id.hasPrefix(systemId + "/"),
          storedInstanceIds.contains(id) else { return nil }
    return id
}

let stored = ["A-openai", "B-deepseek", "C-xai"]

print("▶️  1. which sections get an edit button")
check("a saved provider opens its own detail page",
      providerEditTarget(forSectionInstanceId: "B-deepseek", storedInstanceIds: stored) == "B-deepseek")
check("every saved provider maps to itself, never to another one",
      stored.allSatisfy { providerEditTarget(forSectionInstanceId: $0, storedInstanceIds: stored) == $0 })
check("the built-in System voice section has none",
      providerEditTarget(forSectionInstanceId: systemId, storedInstanceIds: stored + [systemId]) == nil)
check("…nor a System composite id",
      providerEditTarget(forSectionInstanceId: systemId + "/voice", storedInstanceIds: stored) == nil)
check("an instance that is not (or no longer) stored has none (e.g. deleted while the sheet was open)",
      providerEditTarget(forSectionInstanceId: "Z-gone", storedInstanceIds: stored) == nil)
check("an empty id has none", providerEditTarget(forSectionInstanceId: "", storedInstanceIds: stored + [""]) == nil)

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
let picker = read("Views/Providers/UnifiedModelPicker.swift")
let xc = read("Localizable.xcstrings")
check("picker source read", !picker.isEmpty)

let targetFn: String = {
    guard let a = picker.range(of: "static func providerEditTarget("),
          let b = picker.range(of: "\n    }\n", range: a.upperBound..<picker.endIndex) else { return "" }
    return String(picker[a.lowerBound..<b.upperBound])
}()
let header: String = {
    guard let a = picker.range(of: "private func instanceSection("),
          let h = picker.range(of: "} header: {", range: a.upperBound..<picker.endIndex),
          let e = picker.range(of: "// MARK: - Entry Row", range: h.upperBound..<picker.endIndex) else { return "" }
    return String(picker[h.lowerBound..<e.lowerBound])
}()

print("\n▶️  1b. the port matches the picker")
check("rule excludes the System sentinel and its composite ids",
      targetFn.contains("id != SystemVoiceProvider.builtinProviderId")
      && targetFn.contains("!id.hasPrefix(SystemVoiceProvider.builtinProviderId + \"/\")"))
check("rule requires a stored instance", targetFn.contains("storedInstanceIds.contains(id)"))
check("the header feeds it the stored instances (not instance(for:), which also resolves System)",
      header.contains("storedInstanceIds: store.instances.map(\\.id)"))

print("\n▶️  2. layout and tap separation")
let editAt = header.range(of: "editingProvider = target")?.lowerBound
let chevronAt = header.range(of: "collapsedInstanceIds.insert(item.instance.id)")?.lowerBound
check("the edit button comes before (left of) the chevron",
      editAt != nil && chevronAt != nil && editAt! < chevronAt!)
check("the edit button is its own plain Button (a tap on it cannot fold the section)",
      header.contains("Button {\n                        editingProvider = target\n                    } label: {")
      && !header.contains("editingProvider = target\n                        withAnimation"))
check("the edit action does not touch collapse state", {
    guard let a = header.range(of: "editingProvider = target"),
          let b = header.range(of: "} label: {", range: a.upperBound..<header.endIndex) else { return false }
    return !header[a.lowerBound..<b.lowerBound].contains("collapsedInstanceIds")
}())
check("the chevron's own fold toggle is unchanged",
      header.contains("if collapsed {\n                                _ = collapsedInstanceIds.remove(item.instance.id)\n                            } else {\n                                collapsedInstanceIds.insert(item.instance.id)"))
check("long provider names truncate to one line instead of squeezing the buttons",
      header.contains("Text(item.instance.label)\n                    .lineLimit(1)\n                    .truncationMode(.tail)")
      && header.contains(".fixedSize()"))
// [T-picker-provider-edit-text] A text "Edit" link styled like the Model
// Groups header's, not an icon.
let groupsEdit: String = {
    guard let a = picker.range(of: "Text(\"Model Groups\")"),
          let b = picker.range(of: "} footer: {", range: a.upperBound..<picker.endIndex) else { return "" }
    return String(picker[a.lowerBound..<b.lowerBound])
}()
let providerEdit: String = {
    guard let a = header.range(of: "editingProvider = target"),
          let b = header.range(of: ".accessibilityLabel(", range: a.upperBound..<header.endIndex) else { return "" }
    return String(header[a.lowerBound..<b.lowerBound])
}()
check("the Model Groups edit link is still caption text, tint, plain",
      groupsEdit.contains("Text(\"Edit\")\n                                .font(.caption)\n                                .textCase(nil)")
      && groupsEdit.contains(".buttonStyle(.plain)\n                        .foregroundStyle(.tint)"))
check("the provider edit entry uses the same text, font, case, style and tint",
      providerEdit.contains("Text(\"Edit\")\n                            .font(.caption)\n                            .textCase(nil)")
      && providerEdit.contains(".buttonStyle(.plain)\n                    .foregroundStyle(.tint)"))
check("it is text, not an icon", !providerEdit.contains("Image(systemName:") && !header.contains("slider.horizontal.3"))
check("the visible text stays one line and is not squeezed",
      providerEdit.contains(".lineLimit(1)") && providerEdit.contains(".fixedSize()"))

print("\n▶️  3. destination")
check("the sheet opens ProviderInstanceDetailView for exactly that instance",
      picker.contains(".sheet(item: $editingProvider) { target in")
      && picker.contains("ProviderInstanceDetailView(instanceId: target.id)"))
check("…inside its own NavigationStack with a Done button",
      picker.contains("Button(\"Done\") { editingProvider = nil }"))

print("\n▶️  4. accessibility")
check("the icon button has a spoken label naming the provider",
      header.contains(".accessibilityLabel(Text(\"Edit \\(item.instance.label)\"))"))
check("\"Edit %@\" is in the string catalog", xc.contains("\"Edit %@\" : {"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
