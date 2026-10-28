#!/usr/bin/env swift
// [T-voice-ring-inside] [T-voice-ring-soft] The blue "transcribing" arc on the
// voice mic button lies on the INSIDE of the white disc, flush with its rim
// (no blue pixel outside, the outermost at the rim). [T-voice-ring-ends] It is
// solid colour, with a short, light fade at each end only.
//
//   [1] TranscribingRingGeometry, compiled from the shipping file
//   [2] the shipping TranscribingRingArc rendered over a white disc at @3x,
//       both button sizes, several angles, measured pixel by pixel:
//       inside the disc, flush, solid middle, both tips faded, smooth fades
//   [3] source guards: the button draws the shipping arc, animation unchanged
//
// Run: swift VoiceTranscribingRingTests.swift   (needs swiftc, macOS 13+)
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

let view = source("Views/Chat/Voice/InlineVoiceInputView.swift")
guard let geo = between(view, "// BEGIN TranscribingRingGeometry", "// END TranscribingRingGeometry") else {
    print("❌ TranscribingRingGeometry not found"); exit(1)
}

let harness = #"""
import SwiftUI
import AppKit
func out(_ k: String, _ v: Any) { print("R \(k)=\(v)") }
for d: CGFloat in [60, 72] {
    out("path\(Int(d))", TranscribingRingGeometry.pathDiameter(disc: d))
    out("clear\(Int(d))", TranscribingRingGeometry.clearance(disc: d))
}
out("line", TranscribingRingGeometry.line)
out("gap", TranscribingRingGeometry.gap)
out("sweep", TranscribingRingGeometry.sweepDegrees)
out("fade", TranscribingRingGeometry.endFadeFraction)
out("tip", TranscribingRingGeometry.endOpacity)
out("curve", [0, 0.05, 0.1, 0.5, 0.9, 0.95, 1].map { String(format: "%.3f", TranscribingRingGeometry.opacity(atFraction: $0)) }.joined(separator: "/"))
out("stops", TranscribingRingGeometry.stopFractions.map { String(format: "%.4f", $0) }.joined(separator: "/"))

// The shipping arc over a white disc, as micButton composes them.
@MainActor func measure(disc: CGFloat, degrees: Double) -> String {
    let v = ZStack {
        Color.black
        Circle().fill(Color.white).frame(width: disc, height: disc)
        TranscribingRingArc(color: Color(red: 0, green: 0.48, blue: 1), disc: disc)
            .rotationEffect(.degrees(degrees))
    }
    .frame(width: disc + 20, height: disc + 20)
    let r = ImageRenderer(content: v); r.scale = 3
    guard let cg = r.cgImage else { return "render-failed" }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let cx = Double(w) / 2, cy = Double(h) / 2, rim = Double(disc) * 3 / 2
    var maxD = 0.0, n = 0
    // Saturation (B - R) by position along the arc, 1-degree bins, line core only.
    // Over white, B - R = 255 * opacity for this blue.
    let bins = Int(TranscribingRingGeometry.sweepDegrees)
    var binSum = [Double](repeating: 0, count: bins), binN = [Int](repeating: 0, count: bins)
    let core = Double(TranscribingRingGeometry.pathDiameter(disc: disc)) * 3 / 2
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let R = Int(px[i]), B = Int(px[i + 2])
        guard B > 150, B - R > 25 else { continue }      // any bluish pixel, faint tail included
        let dx = Double(x) + 0.5 - cx, dy = cy - (Double(y) + 0.5)   // CG rows run bottom-up
        let d = (dx * dx + dy * dy).squareRoot()
        maxD = max(maxD, d); n += 1
        guard abs(d - core) < 1.5 else { continue }
        // Screen angle, clockwise from 3 o'clock (y down), relative to the arc start.
        var a = atan2(-dy, dx) * 180 / .pi - degrees
        a = a.truncatingRemainder(dividingBy: 360); if a < 0 { a += 360 }
        let bin = Int(a)
        if bin < bins { binSum[bin] += Double(B - R); binN[bin] += 1 }
    } }
    let sat = (0..<bins).map { binN[$0] > 0 ? binSum[$0] / Double(binN[$0]) : -1 }
    let s = sat.map { String(format: "%.0f", $0) }.joined(separator: "/")
    return "\(maxD <= rim),\(String(format: "%.2f", (rim - maxD) / 3)),\(n),\(s)"
}
let group = DispatchGroup(); group.enter()
Task { @MainActor in
    for d: CGFloat in [60, 72] {
        for deg in [0.0, 137.0, 290.0] { out("render\(Int(d))_\(Int(deg))", measure(disc: d, degrees: deg)) }
    }
    group.leave()
}
while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-ring-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Geo.swift": "import SwiftUI\n" + geo, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("[1] TranscribingRingGeometry from the shipping file")
check("compiles with the harness", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (status, out) = run(bin, [])
check("harness ran", status == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}
check("line width 3pt (rounder caps)", r["line"] == "3.0")
check("gap 0.25pt (flush, antialiasing kept on the disc)", r["gap"] == "0.25")
check("sweep stays 75°", r["sweep"] == "75.0")
check("end fade 10% of the arc at each end, tips at 0.35 opacity", r["fade"] == "0.1" && r["tip"] == "0.35")
check("opacity curve: tips 0.35, eased, solid from 10% to 90%, symmetric",
      r["curve"] == "0.350/0.675/1.000/1.000/1.000/0.675/0.350")
check("gradient stops: 7 across each 7.5° fade, solid between",
      r["stops"] == "0.0000/0.0167/0.0333/0.0500/0.0667/0.0833/0.1000/0.9000/0.9167/0.9333/0.9500/0.9667/0.9833/1.0000")
check("path diameter = disc - 2*gap - line (60 → 56.5, 72 → 68.5)", r["path60"] == "56.5" && r["path72"] == "68.5")
check("line's outer edge 0.25pt inside the rim, both sizes", r["clear60"] == "0.25" && r["clear72"] == "0.25")

print("[2] Shipping arc rendered @3x and measured")
for d in [60, 72] { for deg in [0, 137, 290] {
    let parts = (r["render\(d)_\(deg)"] ?? "").split(separator: ",")
    guard parts.count == 4 else { check("disc \(d)pt at \(deg)°: rendered", false); continue }
    let inside = parts[0] == "true", gap = Double(parts[1]) ?? -1, blue = Int(parts[2]) ?? 0
    check("disc \(d)pt, arc at \(deg)°: \(blue) bluish px (faint tail included) all inside the disc, outermost \(String(format: "%.2f", gap))pt from the rim (≤0.5)",
          inside && blue > 100 && gap >= 0 && gap <= 0.5)
    // 1° bins over the 75° arc, as opacity (B - R over white / 255).
    let op = parts[3].split(separator: "/").map { (Double($0) ?? -255) / 255 }
    guard op.count == 75, op.allSatisfy({ $0 > 0 }) else { check("  every degree of the arc measured", false); continue }
    let middle = op[15..<60]                         // 20%...80% of the arc
    let tail = op[0..<8], head = op[67..<75]         // the two 7.5° fades
    let f = { (x: Double) in String(format: "%.2f", x) }
    check("  middle 20-80% solid: min opacity \(f(middle.min()!)) (≥0.95)", middle.min()! >= 0.95)
    check("  tips faded to ~0.35: tail \(f(op[0])), head \(f(op[74])) (0.25...0.55, within 0.08 of each other)",
          (0.25...0.55).contains(op[0]) && (0.25...0.55).contains(op[74]) && abs(op[0] - op[74]) < 0.08)
    let up = zip(tail, tail.dropFirst()).map { $1 - $0 }, down = zip(head, head.dropFirst()).map { $0 - $1 }
    check("  fades smooth and monotonic: each 1° step 0...0.2 (tail up, head down), solid by 10°",
          (up + down).allSatisfy { $0 >= -0.02 && $0 <= 0.2 } && op[10] >= 0.95 && op[64] >= 0.95)
} }

print("[3] Source guards")
check("the button draws the shipping arc and spins it",
      view.contains("TranscribingRingArc(color: .accentColor, disc: micDiameter)\n                            .rotationEffect(angle)"))
check("arc: trimmed to the sweep, stroked with an angular gradient built from the opacity curve, round caps",
      geo.contains(".trim(from: 0, to: TranscribingRingGeometry.sweepDegrees / 360)")
      && geo.contains(".init(color: color.opacity(TranscribingRingGeometry.opacity(atFraction: $0)), location: $0)")
      && geo.contains("startAngle: .degrees(0),\n                    endAngle: .degrees(TranscribingRingGeometry.sweepDegrees))")
      && geo.contains("lineCap: .round"))
check("rotation speed unchanged (one turn per 0.9s)",
      view.contains("let angle = Angle(degrees: (t / 0.9).truncatingRemainder(dividingBy: 1) * 360)"))
check("the white disc is still framed at micDiameter",
      view.contains("Circle()\n                    .fill(Color.white)\n                    .frame(width: micDiameter, height: micDiameter)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
