#!/usr/bin/env swift
// [T-sched-pill-align] Renders the chat's scheduled-task pill without a device.
//
// Compiles the real `ScheduledPillFace` (between its markers in
// ScheduledTaskDetailView.swift) on macOS with a stub `ScheduledAccent`, and
// writes PNGs of the variants that matter for layout: no "+N", "+1", "+12",
// the coarse clock, the running word, the Dynamic Type ring cap, dark.
// For a full ring it also measures, from the pixels, how far the ring's stroke
// starts from the pill's left edge (glyphInset 4 - half the 2.5 pt stroke =
// 2.75 pt, the gap it leaves above and below) and the gap from the ring's
// stroke to the clock's first glyph, so the hugging layout is checked rather
// than eyeballed. It also checks the clock's width floor: the pill is as wide
// at "00:48" as at "59:59".
// [T-sched-pill-clock-big] With a run counter it measures, from the ink, the
// gap from the clock's last glyph to the counter's first ("clock→count") and
// from the counter's last glyph to the pill's right edge ("count→edge"; the
// counter is trailing-aligned, so this is the trailing inset); without one,
// "clock→edge".
// [T-sched-pill-vcenter] For every text element ("+N", clock or status word,
// counter) it measures the ink box's vertical centre against the pill's
// middle line ("vΔ", pt, + = below; descender tails and accents excluded,
// see below) and fails a variant off by more than
// 0.5 pt; it also prints the height so Running <-> 00:14 can be compared.
//
// macOS renders the material flat and the fonts at macOS sizes, so this checks
// geometry (alignment, segment width, overflow), not exact device rendering.
//
// Run: swift ScheduledPillSnapshot.swift [outDir]
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let page = (try? String(contentsOf: root.appendingPathComponent("Views/Chat/ScheduledTaskDetailView.swift"), encoding: .utf8)) ?? ""
guard let a = page.range(of: "// [T-sched-pill-align] BEGIN scheduled-pill-face\n"),
      let b = page.range(of: "// [T-sched-pill-align] END scheduled-pill-face", range: a.upperBound..<page.endIndex) else {
    print("❌ pill-face markers not found"); exit(1)
}
let face = String(page[a.upperBound..<b.lowerBound])
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : FileManager.default.temporaryDirectory.appendingPathComponent("pill-snapshots").path
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let harness = "import SwiftUI\nimport AppKit\nenum ScheduledAccent { static let color = Color.orange; static let icon = \"calendar.badge.clock\" }\n"
    + face + #"""
let out = CommandLine.arguments[1]
struct Variant { let name: String; let face: ScheduledPillFace; let dark: Bool }
let variants: [Variant] = [
    Variant(name: "single", face: ScheduledPillFace(ringFraction: 0.35, glyph: ScheduledAccent.icon, others: 0, clock: "00:48", ringSize: 26), dark: false),
    Variant(name: "count_2of30", face: ScheduledPillFace(ringFraction: 0.35, glyph: ScheduledAccent.icon, others: 0, clock: "00:48", counter: "2/30", ringSize: 26), dark: false),
    Variant(name: "count_unbounded", face: ScheduledPillFace(ringFraction: 0.35, glyph: ScheduledAccent.icon, others: 0, clock: "01:12", counter: "#7", ringSize: 26), dark: false),
    Variant(name: "count_plus1", face: ScheduledPillFace(ringFraction: 0.6, glyph: ScheduledAccent.icon, others: 1, clock: "01:39", counter: "12/30", ringSize: 26), dark: false),
    Variant(name: "count_running", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 1, clock: "En ejecución", counter: "3/30", clockIsStatus: true, ringSize: 26), dark: false),
    Variant(name: "status_running_en", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "Running", counter: "1/8", clockIsStatus: true, ringSize: 26), dark: false),
    Variant(name: "status_running_zh", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "运行中", counter: "1/8", clockIsStatus: true, ringSize: 26), dark: false),
    Variant(name: "count_1of8", face: ScheduledPillFace(ringFraction: 0.4, glyph: ScheduledAccent.icon, others: 0, clock: "00:14", counter: "1/8", ringSize: 26), dark: false),
    Variant(name: "count_large", face: ScheduledPillFace(ringFraction: 0.5, glyph: ScheduledAccent.icon, others: 2, clock: "00:48", counter: "12/30", ringSize: ScheduledPillFace.maxRingSize), dark: false),
    Variant(name: "count_dark", face: ScheduledPillFace(ringFraction: 0.6, glyph: ScheduledAccent.icon, others: 0, clock: "00:49", counter: "2/30", ringSize: 26), dark: true),
    Variant(name: "count_2of20", face: ScheduledPillFace(ringFraction: 0.75, glyph: ScheduledAccent.icon, others: 0, clock: "00:14", counter: "2/20", ringSize: 26), dark: false),
    Variant(name: "count_hours", face: ScheduledPillFace(ringFraction: 0.1, glyph: ScheduledAccent.icon, others: 0, clock: "1h 5m", counter: "#7", ringSize: 26), dark: false),
    Variant(name: "count_9of30", face: ScheduledPillFace(ringFraction: 0.2, glyph: ScheduledAccent.icon, others: 0, clock: "00:48", counter: "9/30", ringSize: 26), dark: false),
    Variant(name: "count_10of30", face: ScheduledPillFace(ringFraction: 0.2, glyph: ScheduledAccent.icon, others: 0, clock: "00:48", counter: "10/30", ringSize: 26), dark: false),
    Variant(name: "plus1", face: ScheduledPillFace(ringFraction: 0.6, glyph: ScheduledAccent.icon, others: 1, clock: "01:39", ringSize: 26), dark: false),
    Variant(name: "plus12_hours", face: ScheduledPillFace(ringFraction: 0.1, glyph: ScheduledAccent.icon, others: 12, clock: "1h 5m", ringSize: 26), dark: false),
    Variant(name: "running", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 1, clock: "En ejecución", clockIsStatus: true, ringSize: 26), dark: false),
    Variant(name: "waiting", face: ScheduledPillFace(ringFraction: 0, glyph: "hourglass", others: 0, clock: "Waiting", clockIsStatus: true, ringSize: 26), dark: false),
    Variant(name: "status_large", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 2, clock: "Running", counter: "12/30", clockIsStatus: true, ringSize: ScheduledPillFace.maxRingSize), dark: false),
    Variant(name: "status_dark", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "运行中", counter: "2/30", clockIsStatus: true, ringSize: 26), dark: true),
    Variant(name: "large_ring_cap", face: ScheduledPillFace(ringFraction: 0.5, glyph: ScheduledAccent.icon, others: 99, clock: "00:48", ringSize: ScheduledPillFace.maxRingSize), dark: false),
    Variant(name: "measure_full_ring", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "00:48", ringSize: 26), dark: false),
    Variant(name: "measure_full_ring_5959", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "59:59", ringSize: 26), dark: false),
    Variant(name: "measure_full_ring_1111", face: ScheduledPillFace(ringFraction: 1, glyph: ScheduledAccent.icon, others: 0, clock: "11:11", ringSize: 26), dark: false),
    Variant(name: "dark_plus1", face: ScheduledPillFace(ringFraction: 0.6, glyph: ScheduledAccent.icon, others: 1, clock: "00:49", ringSize: 26), dark: true),
]
MainActor.assumeIsolated {
    for v in variants {
        // Plain backdrop with room for the shadow; the pill alone is measured too.
        let card = v.face.padding(16).background(v.dark ? Color.black : Color.white)
            .environment(\.colorScheme, v.dark ? .dark : .light)
        let r = ImageRenderer(content: card); r.scale = 3
        guard let cg = r.cgImage else { print("render failed \(v.name)"); continue }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/pill_\(v.name).png"))
        let bare = ImageRenderer(content: v.face.fixedSize()); bare.scale = 1
        let size = bare.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        var line = "\(v.name) size=\(Int(size.width))x\(Int(size.height))"
        if v.face.ringFraction >= 1 {
            // Strongly-orange columns through the pill's centre: with a full
            // ring, the first is its stroke's left edge.
            let midY = cg.height / 2
            func strong(_ x: Int) -> Bool {
                guard let c = rep.colorAt(x: x, y: midY)?.usingColorSpace(.deviceRGB) else { return false }
                return c.redComponent > 0.85 && c.greenComponent < 0.7 && c.blueComponent < 0.35
            }
            let ringX = (0..<cg.width).first(where: strong)
            // The pill's own left edge sits at 16 pt in the padded render.
            let inset = ringX.map { Double($0) / 3 - 16 } ?? -1
            let expected = Double(ScheduledPillFace.glyphInset) - 1.25
            line += " ringStrokeLeft=\(String(format: "%.2f", inset)) \(abs(inset - expected) < 0.5 ? "✅" : "❌ expected \(expected)")"
            // The ring's outer edge, then the clock's first ink after a gap.
            let ringRight = 16 + Double(ScheduledPillFace.glyphInset) + Double(v.face.ringSize) + 1.25
            let from = Int((ringRight + 0.5) * 3)
            if v.face.others == 0, let clockX = (from..<cg.width).first(where: strong) {
                line += " ringToClock=\(String(format: "%.2f", Double(clockX) / 3 - ringRight))"
            }
        }
        // [T-sched-pill-clock-big] Amber ink (clock, counter, ring) along a
        // band through the text, split into runs at gaps of 3.5 pt or more.
        // The tinted fill (6 %), track (18 %) and border (28 %) stay below
        // the threshold; the 70 % counter and the clock pass it.
        let pillLeft = 16 * 3, pillRight = Int((16 + size.width) * 3)
        let band = (cg.height / 2 - 6)...(cg.height / 2 + 6)
        func ink(_ x: Int) -> Bool {
            band.contains { y in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return v.dark ? (c.redComponent - c.blueComponent > 0.45 && c.redComponent > 0.5)
                              : (c.redComponent - c.blueComponent > 0.45)
            }
        }
        let textStart = pillLeft + Int((Double(ScheduledPillFace.glyphInset) + Double(v.face.ringSize) + 2) * 3)
        var runs: [(Int, Int)] = []
        for x in textStart..<pillRight where ink(x) {
            if let last = runs.last, x - last.1 <= 10 { runs[runs.count - 1].1 = x } else { runs.append((x, x)) }
        }
        func pt(_ px: Int) -> String { String(format: "%.1f", Double(px) / 3) }
        // [T-sched-pill-vcenter] Vertical ink centre of each run, inside the
        // pill (2 pt clear of its border), against the pill's middle line.
        func inkAt(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return v.dark ? (c.redComponent - c.blueComponent > 0.45 && c.redComponent > 0.5)
                          : (c.redComponent - c.blueComponent > 0.45)
        }
        let pillTop = 16 * 3, pillBottom = Int((16 + size.height) * 3)
        let mid = Double(pillTop + pillBottom) / 2
        var deltas: [Double] = []
        // Per element, not per word: "+N" first (if any), the counter last
        // (if any), the clock or status word in between ("En ejecución" is
        // two ink runs but one element).
        var elements: [[(Int, Int)]] = []
        var rest = runs
        if v.face.others > 0, !rest.isEmpty { elements.append([rest.removeFirst()]) }
        let counterRun: (Int, Int)? = v.face.counter != nil && rest.count > 1 ? rest.removeLast() : nil
        if !rest.isEmpty { elements.append(rest) }
        if let counterRun { elements.append([counterRun]) }
        for element in elements {
            // The body of the text, not its tails: rows holding at least a
            // quarter of the densest row's ink. A "g" / "j" descender or an
            // accent is a few pixels a row and drops out, so "Running" is
            // centred on its letters as the eye reads them.
            let counts = ((pillTop + 6)..<(pillBottom - 6)).map { y in
                (y, element.reduce(0) { n, run in n + (run.0...run.1).filter { inkAt($0, y) }.count })
            }
            let peak = counts.map(\.1).max() ?? 0
            let rows = counts.filter { $0.1 > 0 && $0.1 * 4 >= peak }.map(\.0)
            guard let lo = rows.first, let hi = rows.last else { continue }
            deltas.append((Double(lo + hi) / 2 - mid) / 3)
        }
        if !deltas.isEmpty {
            // Clock, counter, "+N": within 0.5 pt. A status word gets 1 pt: a
            // mostly lower-case word ("En ejecución") has its body on the
            // x-height band, which sits under the capitals' centre by design
            // (its glyph box is centred like the clock's; "Running" and
            // "运行中" measure 0).
            let statusIndex = v.face.clockIsStatus ? (v.face.others > 0 ? 1 : 0) : -1
            let ok = deltas.enumerated().allSatisfy { i, d in abs(d) <= (i == statusIndex ? 1.0 : 0.5) }
            line += " vΔ=[\(deltas.map { String(format: "%+.1f", $0) }.joined(separator: ","))] \(ok ? "✅" : "❌")"
        }
        if v.face.counter != nil, runs.count >= 2 {
            let clockEnd = runs[runs.count - 2].1, counter = runs[runs.count - 1]
            line += " clock→count=\(pt(counter.0 - clockEnd)) count→edge=\(pt(pillRight - counter.1))"
        } else if v.face.counter == nil, let last = runs.last {
            line += " clock→edge=\(pt(pillRight - last.1))"
        }
        print(line)
    }
}
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pill-snap-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let file = tmp.appendingPathComponent("main.swift")
try? harness.write(to: file, atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swift", file.path, outDir]
let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
try? p.run(); p.waitUntilExit()
let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
try? FileManager.default.removeItem(at: tmp)
print(output)
print(p.terminationStatus == 0 ? "📸 snapshots in \(outDir)" : "❌ render failed")
exit(p.terminationStatus)
