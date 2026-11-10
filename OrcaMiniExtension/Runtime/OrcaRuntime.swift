//
//  OrcaRuntime.swift
//  OrcaMiniExtension
//
//  Owns the Orca engine + editor. A background thread keeps the real-time kernel's ring buffer a few frames ahead
//  (it only steps the engine while the HOST is playing). The UI talks to it through lock-protected edit() calls.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct GridSnapshot: Equatable {
    var w = 1, h = 1
    var cells: [Character] = ["."]
    var cx = 0, cy = 0, cw = 0, ch = 0       // cursor + selection extent (cw/ch may be negative, as in Orca)
    var ins = false
    var playing = false
    var frame = 0
    var speed = 3
}

final class OrcaRuntime: ObservableObject, @unchecked Sendable {
    static let gridW = 36, gridH = 16                       // the mini grid (one constant: easy to change)
    static let defaultPatch = ""                            // a fresh instance opens blank (the host restores a saved session's patch through fullState)

    let engine = OrcaEngine(seed: UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000)))
    let editor: OrcaEditor
    private let lock = NSLock()
    private let kernel: OrcaKernelRef
    private var running = false
    private var lastGen: UInt32 = 0
    private var uiTimer: Timer?
    private let lookahead = 4

    @Published private(set) var snapshot = GridSnapshot()
    // octave limits, in Orca's own octave numbers (0...8): any note outside is moved by whole octaves into range (folded), so the pitch name stays the same
    @Published private(set) var octLo = 0
    @Published private(set) var octHi = 8
    private var foldMap = [Int16](repeating: -1, count: 16 * 128)      // channel/note as Orca sent it -> the note actually sent, so a note-off always matches its note-on even if the range changes while it sounds
    func setOctaveRange(lo: Int, hi: Int) {
        let l = max(0, min(8, lo)), h = max(l, min(8, hi))
        lock.lock(); octLo = l; octHi = h; editRevision += 1; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
    /// call with the lock held
    private func limitOctaves(_ msgs: [MidiMessage], track: Bool) -> [MidiMessage] {
        let lo = octLo == 0 ? 0 : 24 + 12 * octLo, hi = octHi == 8 ? 127 : 24 + 12 * octHi + 11      // (the full range leaves every note alone)
        return msgs.map { m in
            guard m.bytes.count >= 2 else { return m }
            let kind = m.bytes[0] & 0xF0, ch = Int(m.bytes[0] & 0x0F), note = Int(m.bytes[1])
            let isOn = kind == 0x90 && (m.bytes.count < 3 || m.bytes[2] > 0), isOff = kind == 0x80 || (kind == 0x90 && !isOn)
            guard isOn || isOff, note < 128 else { return m }
            var x = note; while x < lo { x += 12 }; while x > hi { x -= 12 }; x = max(0, min(127, x))
            let slot = ch * 128 + note; var out = x
            if track {
                if isOn { foldMap[slot] = Int16(x) } else if foldMap[slot] >= 0 { out = Int(foldMap[slot]); foldMap[slot] = -1 }
            }
            var b = m.bytes; b[1] = UInt8(out); return MidiMessage(b)
        }
    }

    init(kernel: OrcaKernelRef) {
        self.kernel = kernel
        editor = OrcaEditor(engine)
        loadPatch(OrcaRuntime.defaultPatch)
    }

    // MARK: engine thread
    func start() {
        lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "OrcaMini.engine"; t.qualityOfService = .userInteractive; t.start()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.uiTimer?.invalidate()
            self.uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }
    func stop() {
        lock.lock(); running = false; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.uiTimer?.invalidate(); self?.uiTimer = nil }
    }
    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private var spec: OrcaEngine?          // copy of the engine already stepped through the opening frames (prepared while the host is stopped)
    private var editRevision = 0, specRevision = -1

    private func pack(_ msgs: [MidiMessage], into out: inout [UInt8]) -> Int32 {
        var n: Int32 = 0
        for m in msgs where out.count + 3 <= Int(OrcaKernelSlotBytes()) * 8 {
            out.append(m.bytes[0]); out.append(m.bytes.count > 1 ? m.bytes[1] : 0); out.append(m.bytes.count > 2 ? m.bytes[2] : 0); n += 3
        }
        return n
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: Int(OrcaKernelSlotBytes()))
        while isRunning() {
            let gen = OrcaKernelGeneration(kernel)
            let playing = OrcaKernelHostPlaying(kernel)
            if gen != lastGen {
                lastGen = gen
                lock.lock()
                if playing {
                    // the kernel already injected the prepared opening frames (if it could): continue exactly where that copy of the engine stands
                    if OrcaKernelStartUsedGen(kernel) == gen, let s = spec { engine.adoptState(from: s) } else { engine.restartFrames() }
                }
                spec = nil
                lock.unlock()
            }
            if playing {
                var guardN = 0
                while OrcaKernelDepth(kernel) < Int32(lookahead) && guardN < 16 {
                    lock.lock(); let msgs = limitOctaves(engine.step(), track: true); lock.unlock()
                    var n = 0
                    for m in msgs where n + 3 <= buf.count {
                        buf[n] = m.bytes[0]; buf[n + 1] = m.bytes.count > 1 ? m.bytes[1] : 0; buf[n + 2] = m.bytes.count > 2 ? m.bytes[2] : 0; n += 3
                    }
                    let g = gen
                    buf.withUnsafeBufferPointer { _ = OrcaKernelPush(kernel, g, $0.baseAddress, Int32(n)) }
                    guardN += 1
                }
            } else {
                // stopped: keep the first frames of the CURRENT patch ready, so the first beat of the next start is never late
                lock.lock()
                if spec == nil || specRevision != editRevision {
                    let c = engine.cloneForPreview()
                    var bytes: [UInt8] = [], lens: [Int32] = []
                    for _ in 0..<4 { lens.append(pack(limitOctaves(c.step(), track: false), into: &bytes)) }
                    spec = c; specRevision = editRevision
                    lock.unlock()
                    bytes.withUnsafeBufferPointer { b in lens.withUnsafeBufferPointer { l in OrcaKernelSetStartFrames(kernel, b.baseAddress, l.baseAddress, 4) } }
                } else { lock.unlock() }
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    // MARK: UI-facing
    func refresh() {
        lock.lock()
        let snap = GridSnapshot(w: engine.w, h: engine.h, cells: engine.cells, cx: editor.x, cy: editor.y, cw: editor.w, ch: editor.h,
                                ins: editor.ins, playing: OrcaKernelHostPlaying(kernel) != false, frame: engine.f, speed: Int(OrcaKernelSpeed(kernel)))
        lock.unlock()
        if Thread.isMainThread { if snap != snapshot { snapshot = snap } }
        else { DispatchQueue.main.async { [weak self] in if let self = self, snap != self.snapshot { self.snapshot = snap } } }
    }

    func edit(_ block: (OrcaEditor) -> Void) { lock.lock(); block(editor); editRevision += 1; lock.unlock(); refresh() }

    func setSpeed(_ i: Int) { OrcaKernelSetParameter(kernel, 0, AUValue(max(0, min(7, i)))); refresh() }
    func speedUp() { setSpeed(Int(OrcaKernelSpeed(kernel)) + 1) }
    func speedDown() { setSpeed(Int(OrcaKernelSpeed(kernel)) - 1) }

    func patchText() -> String {
        lock.lock(); defer { lock.unlock() }
        let w = engine.w, cs = engine.cells
        return stride(from: 0, to: cs.count, by: w).map { String(cs[$0..<min($0 + w, cs.count)]) }.joined(separator: "\n") + "\n"
    }

    static let maxW = 128, maxH = 96

    /// load a patch: the grid is at least the mini size and grows to the patch's own size (capped)
    func loadPatch(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        let w = min(OrcaRuntime.maxW, max(OrcaRuntime.gridW, lines.map { $0.count }.max() ?? 0))
        let h = min(OrcaRuntime.maxH, max(OrcaRuntime.gridH, lines.count - (lines.last == "" ? 1 : 0)))
        var rows: [String] = []
        for y in 0..<h {
            let line = y < lines.count ? Array(lines[y]) : []
            var r = String(line.prefix(w))
            r += String(repeating: ".", count: w - r.count)
            rows.append(r)
        }
        lock.lock()
        engine.load(w: w, h: h, text: rows.joined())
        editor.history.reset(); editor.history.record(engine.text()); editor.reset(pos: true)
        editRevision += 1
        lock.unlock()
        refresh()
    }

    /// zooming out opens up room: grow the grid so it fills the visible area (never shrinks by itself; existing cells are kept)
    func ensureGrid(cols: Int, rows: Int) {
        lock.lock()
        let nw = min(OrcaRuntime.maxW, max(engine.w, cols)), nh = min(OrcaRuntime.maxH, max(engine.h, rows))
        let changed = nw != engine.w || nh != engine.h
        if changed { editor.resizeGrid(w: nw, h: nh); editRevision += 1 }
        lock.unlock()
        if changed { refresh() }
    }

    // MARK: patch library (inside the plugin's own container) + export
    static var libraryDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func cleanName(_ n: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let s = n.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "patch" : String(s.prefix(60))
    }
    /// newest first
    func libraryNames() -> [String] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: OrcaRuntime.libraryDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "orca" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    @discardableResult func savePatch(named name: String) -> Bool {
        let url = OrcaRuntime.libraryDir.appendingPathComponent(cleanName(name) + ".orca")
        return (try? patchText().write(to: url, atomically: true, encoding: .utf8)) != nil
    }
    func loadSaved(_ name: String) {
        let url = OrcaRuntime.libraryDir.appendingPathComponent(name + ".orca")
        if let t = try? String(contentsOf: url, encoding: .utf8) { loadPatch(t) }
    }
    func deleteSaved(_ name: String) { try? FileManager.default.removeItem(at: OrcaRuntime.libraryDir.appendingPathComponent(name + ".orca")) }
    func newPatch() { loadPatch("") }
    /// a temp .orca file of the current patch, ready for the share sheet (Files, AirDrop, Messages...)
    func exportFile(named name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OrcaExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(cleanName(name) + ".orca")
        return (try? patchText().write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let d = try? Data(contentsOf: url), d.count < 2_000_000, let t = String(data: d, encoding: .utf8) { loadPatch(t) }
    }

    func copyToPasteboard() {
        lock.lock(); let s = editor.copyText(); lock.unlock()
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #endif
    }
    func pasteFromPasteboard() {
        #if canImport(UIKit)
        if let s = UIPasteboard.general.string { edit { $0.paste(s) } }
        #endif
    }
}
