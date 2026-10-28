#!/usr/bin/env swift
// [T-readaloud-volume] One read-aloud volume (0...1, default 1.0) for BOTH
// playback paths: the System voice's live utterances and VoiceOutputPlayer's
// AVAudioPlayer (cloud models + System voices rendered to WAV). Slider above
// the expanded read-aloud capsule.
//
//   [1] ReadAloudVolume (BEGIN/END block in VoiceOutputPlayer.swift), compiled
//       against a scratch UserDefaults suite: default, clamping, NaN/inf,
//       Float/Double/garbage storage, percent.
//   [2] Source guards: both paths read the one value, the WAV render is not
//       double-scaled, live changes reach the playing unit, the two controls
//       stay in sync, the slider's UI contract, audio session untouched.
//
// Run: swift ReadAloudVolumeTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let player = source("Providers/Voice/VoiceOutputPlayer.swift")
let catalog = source("Providers/Voice/SystemVoiceCatalog.swift")
let systemProvider = source("Providers/Voice/VoiceProvider+System.swift")
let speech = source("Agent/Chat/AIChatViewModel+Speech.swift")
let state = source("Providers/Voice/VoiceProviderResolver.swift")
let keepAlive = source("Agent/Background/BackgroundKeepAliveManager.swift")
let capsule = source("Views/Chat/Voice/SpeechPlayerControl.swift")
let session = source("Providers/Voice/AudioSessionCoordinator.swift")
let strings = source("Localizable.xcstrings")
guard let block = between(player, "// BEGIN ReadAloudVolume", "// END ReadAloudVolume") else {
    print("❌ ReadAloudVolume block not found"); exit(1)
}

let harness = """
import Foundation
\(block)
let suite = "readaloud.volume.test.\\(UUID().uuidString)"
let d = UserDefaults(suiteName: suite)!
defer { d.removePersistentDomain(forName: suite) }
func out(_ k: String, _ v: Any) { print("R \\(k)=\\(v)") }
out("default", ReadAloudVolume.read(d))
out("key", ReadAloudVolume.key)
ReadAloudVolume.write(0.35, to: d); out("roundtrip", ReadAloudVolume.read(d))
ReadAloudVolume.write(-0.5, to: d); out("below", ReadAloudVolume.read(d))
ReadAloudVolume.write(3, to: d); out("above", ReadAloudVolume.read(d))
ReadAloudVolume.write(.nan, to: d); out("nan", ReadAloudVolume.read(d))
ReadAloudVolume.write(.infinity, to: d); out("inf", ReadAloudVolume.read(d))
d.set(Double(0.3), forKey: ReadAloudVolume.key); out("double", ReadAloudVolume.read(d))
d.set(Float(0.3), forKey: ReadAloudVolume.key); out("float", ReadAloudVolume.read(d))
d.set("loud", forKey: ReadAloudVolume.key); out("garbage", ReadAloudVolume.read(d))
d.set(Double(7), forKey: ReadAloudVolume.key); out("storedAbove", ReadAloudVolume.read(d))
out("clampEdges", "\\(ReadAloudVolume.clamp(0))/\\(ReadAloudVolume.clamp(1))")
out("percent", "\\(ReadAloudVolume.percent(0))/\\(ReadAloudVolume.percent(0.05))/\\(ReadAloudVolume.percent(0.333))/\\(ReadAloudVolume.percent(1))/\\(ReadAloudVolume.percent(2))")
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("readaloudvol_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. The value")
check("default is 1.0 (unchanged behaviour after the upgrade)", r["default"] == "1.0")
check("stored under the existing \"speechVolume\" key", r["key"] == "speechVolume")
check("write/read round-trips", r["roundtrip"] == "0.35")
check("below 0 clamps to 0, above 1 clamps to 1", r["below"] == "0.0" && r["above"] == "1.0")
check("NaN / infinity fall back to 1.0", r["nan"] == "1.0" && r["inf"] == "1.0")
check("a Double-stored value is read (as? Float used to fail → 1.0)", r["double"] == "0.3")
check("a Float-stored value is read", r["float"] == "0.3")
check("garbage falls back to 1.0; an out-of-range stored value is clamped",
      r["garbage"] == "1.0" && r["storedAbove"] == "1.0")
check("0 and 1 are kept", r["clampEdges"] == "0.0/1.0")
check("percent: 0 / 5 / 33 / 100 / clamped 100", r["percent"] == "0/5/33/100/100")

print("\n2. Both playback paths read the one value")
check("System voice live utterance: volume from SystemVoicePreferences.volume",
      speech.contains("utterance.volume = SystemVoicePreferences.volume"))
check("SystemVoicePreferences.volume IS the read-aloud volume",
      catalog.contains("get { ReadAloudVolume.read(UserDefaults.standard) }")
      && catalog.contains("set { ReadAloudVolume.write(newValue, to: UserDefaults.standard) }"))
check("cloud / WAV player: every unit starts at the read-aloud volume",
      player.contains("p.volume = VoiceOutputPreferences.readAloudVolume"))
check("player volume changes in real time on the playing unit",
      player.contains("func setVolume(_ volume: Float) {\n        player?.volume = ReadAloudVolume.clamp(volume)"))
check("System voice rendered to WAV is not scaled twice (render at 1.0, player applies)",
      systemProvider.contains("utterance.volume = 1.0") && !systemProvider.contains("utterance.volume = SystemVoicePreferences.volume"))
check("verification logs carry the volume",
      player.contains("volume=%.2f queueAhead") && speech.contains("TTS system utterance volume=%.2f"))

print("\n3. Live state and the two controls")
let didSet = between(state, "@Published var readAloudVolume: Float = VoiceOutputPreferences.readAloudVolume {", "\n    }\n") ?? ""
check("slider state persists, applies live, mirrors the settings slider",
      didSet.contains("VoiceOutputPreferences.readAloudVolume = v")
      && didSet.contains("VoiceOutputPlayer.shared.setVolume(v)")
      && didSet.contains("if settings.speechVolume != v { settings.speechVolume = v }"))
check("slider state clamps and ignores no-op writes",
      didSet.contains("let v = ReadAloudVolume.clamp(readAloudVolume)") && didSet.contains("guard oldValue != v else { return }"))
check("settings slider (Enhanced Background) writes the same value and mirrors back",
      keepAlive.contains("@Published var speechVolume: Float = ReadAloudVolume.read(UserDefaults.standard) {")
      && keepAlive.contains("ReadAloudVolume.write(speechVolume, to: UserDefaults.standard)")
      && keepAlive.contains("if live.readAloudVolume != speechVolume { live.readAloudVolume = speechVolume }"))

print("\n4. The slider")
check("expanded capsule = volume row above the controls",
      capsule.contains("VStack(alignment: .trailing, spacing: 6) {\n            volumeRow\n            controlsCapsule"))
check("0…100%, bound to the shared state, keeps the capsule open while adjusting",
      capsule.contains("), in: 0...1, step: 0.05)")
      && capsule.contains("set: { state.readAloudVolume = Float($0); bumpIdle() }"))
check("accessibility label and percent value",
      capsule.contains(".accessibilityLabel(Text(\"Read-aloud volume\"))")
      && capsule.contains(".accessibilityValue(Text(verbatim: \"\\(ReadAloudVolume.percent(state.readAloudVolume))%\"))"))
let widthLine = capsule.range(of: "static let volumeRowWidth: CGFloat = ")
let width = widthLine.flatMap { Double(capsule[$0.upperBound...].prefix(while: { $0.isNumber })) } ?? 999
check("fixed-width row fits a 320 pt screen with 16 pt margins (\(Int(width)) ≤ 288)", width <= 288)
check("the row is not inside the controls HStack (cannot squeeze its buttons)",
      !(between(capsule, "private var controlsCapsule: some View {", "// MARK: - Idle collapse") ?? "").contains("volumeRow"))
check("label localized (zh-Hans present)",
      strings.contains("\"Read-aloud volume\" : {") && strings.contains("朗读音量"))

print("\n5. Audio session untouched")
check("reply TTS still ducks others; keep-alive still mixes",
      session.contains("case .replyTTS:\n            return (.playback, .spokenAudio, [.duckOthers])")
      && session.contains("case .backgroundKeepAlive:\n            return (.playback, .default, [.mixWithOthers])"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
