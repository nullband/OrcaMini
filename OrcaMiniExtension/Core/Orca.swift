// OrcaCore - a faithful Swift port of Orca (hundredrabbits/Orca, MIT): grid, locks, variables, all operators, and the MIDI / CC / mono outputs.
// Pure logic: no UI, no clock, no audio. One call to `step()` = one Orca frame; it returns the MIDI messages that frame sends.
import Foundation

public struct MidiMessage: Equatable { public var bytes: [UInt8]; public init(_ b: [UInt8]) { bytes = b } }

/// mulberry32 - the same generator the test harness injects into the JS interpreter, so the R operator can be compared exactly
public struct Mulberry32 {
    var a: UInt32
    public init(seed: UInt32) { a = seed }
    public mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double((t ^ (t >> 14))) / 4294967296.0
    }
}

struct Port {
    var x: Int, y: Int
    var cMin = 0, cMax = 36           // JS: a clamp min/max of 0 or missing behaves as 0 / 36
    var def: Character? = nil
    var bang = false, output = false, sensitive = false
    init(_ x: Int, _ y: Int, min: Int = 0, max: Int = 36, def: Character? = nil, bang: Bool = false, output: Bool = false, sensitive: Bool = false) {
        self.x = x; self.y = y; cMin = min == 0 ? 0 : min; cMax = max == 0 ? 36 : max; self.def = def; self.bang = bang; self.output = output; self.sensitive = sensitive
    }
}

let transposeTable: [Character: String] = [
    "A": "A0", "a": "a0", "B": "B0", "C": "C0", "c": "c0", "D": "D0", "d": "d0", "E": "E0", "F": "F0", "f": "f0", "G": "G0", "g": "g0",
    "H": "A0", "h": "a0", "I": "B0", "J": "C1", "j": "c1", "K": "D1", "k": "d1", "L": "E1", "M": "F1", "m": "f1", "N": "G1", "n": "g1",
    "O": "A1", "o": "a1", "P": "B1", "Q": "C2", "q": "c2", "R": "D2", "r": "d2", "S": "E2", "T": "F2", "t": "f2", "U": "G2", "u": "g2",
    "V": "A2", "v": "a2", "W": "B2", "X": "C3", "x": "c3", "Y": "D3", "y": "d3", "Z": "E3",
    "e": "F0", "l": "F1", "s": "F2", "z": "F3", "b": "C1", "i": "C1", "p": "C2", "w": "C3",
]
let noteNames: [Character] = ["C", "c", "D", "d", "E", "F", "f", "G", "g", "A", "a", "B"]
let keyChars: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
let allowedOps = Set("abcdefghijklmnopqrstuvwxyz0123456789*#$:!?%=;")

final class MidiItem {
    var channel: Int, octave: Int, note: Character, velocity: Int, length: Int, isPlayed: Bool
    init(_ c: Int, _ o: Int, _ n: Character, _ v: Int, _ l: Int) { channel = c; octave = o; note = n; velocity = v; length = l; isPlayed = false }
}

public final class OrcaEngine {
    public private(set) var w = 1, h = 1, f = 0
    public internal(set) var cells: [Character] = ["."]
    var locks: [Bool] = []
    var variables: [Character: Character] = [:]
    var runtime: [Op] = []
    var rng: Mulberry32
    // outputs
    var out: [MidiMessage] = []
    var midiStack: [MidiItem?] = []
    var monoStack: [Int: MidiItem] = [:]
    var ccStack: [(type: Int, channel: Int, a: Int, b: Int)] = []     // type 0 = cc (a=knob,b=value) 1 = pb (a=lsb,b=msb)
    public var ccOffset = 64

    public init(seed: UInt32 = 1) { rng = Mulberry32(seed: seed); reset() }
    public func reseed(_ s: UInt32) { rng = Mulberry32(seed: s) }

    // MARK: grid
    public func reset(w: Int? = nil, h: Int? = nil) { f = 0; self.w = w ?? self.w; self.h = h ?? self.h; cells = Array(repeating: ".", count: self.w * self.h); release() }
    public func load(w: Int, h: Int, text: String, frame: Int = 0) {
        self.w = w; self.h = h; f = 0 + frame
        var cs: [Character] = []
        for ch in text.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines) { if cs.count >= w * h { break }; cs.append(isAllowed(ch) ? ch : ".") }
        while cs.count < w * h { cs.append(".") }       // JS substr leaves a short string; glyphAt of a missing index is "" - treat as empty
        cells = cs; release()
    }
    /// convenience: load a .orca file's text (lines padded with '.') exactly like the lab runner
    public func loadPatch(_ text: String) {
        var lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if let l = lines.last, l.isEmpty { lines.removeLast() }
        let w = max(1, lines.map { $0.count }.max() ?? 1), h = max(1, lines.count)
        load(w: w, h: h, text: lines.map { $0 + String(repeating: ".", count: w - $0.count) }.joined())
    }
    /// grow or shrink the grid, keeping every cell that still fits (new space is empty). The frame counter and held notes are untouched.
    public func resize(w nw: Int, h nh: Int) {
        let nw = max(1, nw), nh = max(1, nh)
        if nw == w && nh == h { return }
        var n = Array(repeating: Character("."), count: nw * nh)
        for y in 0..<min(h, nh) { for x in 0..<min(w, nw) { n[y * nw + x] = cells[y * w + x] } }
        w = nw; h = nh; cells = n; release()
    }
    public func isAllowed(_ g: Character) -> Bool { g == "." || allowedOps.contains(Character(g.lowercased())) }
    public func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h }
    func indexAt(_ x: Int, _ y: Int) -> Int { inBounds(x, y) ? x + w * y : -1 }
    public func glyphAt(_ x: Int, _ y: Int) -> Character { let i = indexAt(x, y); return i >= 0 && i < cells.count ? cells[i] : "\0" }   // "\0" = JS empty string
    func valueOf(_ g: Character) -> Int {
        if g == "\0" || g == "." || g == "*" { return 0 }
        return keyChars.firstIndex(of: Character(g.lowercased())) ?? -1
    }
    func keyOf(_ v: Int, upper: Bool = false) -> Character { let c = keyChars[((v % 36) + 36) % 36]; return upper ? Character(c.uppercased()) : c }
    @discardableResult
    public func write(_ x: Int, _ y: Int, _ g: Character) -> Bool {
        if g == "\0" || !inBounds(x, y) || glyphAt(x, y) == g { return false }
        cells[indexAt(x, y)] = isAllowed(g) ? g : "."
        return true
    }
    public func text() -> String { String(cells) }
    func release() { locks = Array(repeating: false, count: w * h); variables = [:] }
    func lock(_ x: Int, _ y: Int) { let i = indexAt(x, y); if i >= 0 { locks[i] = true } }
    func lockAt(_ x: Int, _ y: Int) -> Bool { let i = indexAt(x, y); return i >= 0 && locks[i] }
    func valueIn(_ key: Character) -> Character { variables[key] ?? "." }

    // MARK: one frame (client order: io.clear, orca.run, io.run)
    @discardableResult
    public func step() -> [MidiMessage] {
        out = []
        midiStack = midiStack.filter { $0 != nil }          // midi.clear
        ccStack = []                                        // cc.clear
        // orca.run
        runtime = []
        for y in 0..<h { for x in 0..<w {
            let g = glyphAt(x, y)
            if g == "." || !isAllowed(g) { continue }
            let lower = Character(g.lowercased())
            runtime.append(Op(self, lower, x, y, g == Character(g.uppercased())))
        } }
        release()
        for op in runtime {
            if lockAt(op.x, op.y) { continue }
            if op.passive || op.hasNeighbor("*") { op.run() }
        }
        f += 1
        // io.run
        midiRun(); ccRun(); monoRun()
        return out
    }

    // MARK: midi
    func transpose(_ n: Character, _ o: Int) -> (id: Int, value: Int)? {
        guard let t = transposeTable[n] else { return nil }
        let chars = Array(t)
        let octave = min(8, max(0, o + (Int(String(chars[1])) ?? 0)))
        let value = noteNames.firstIndex(of: chars[0]) ?? -1
        return (min(127, max(0, octave * 12 + value + 24)), value)
    }
    func trigger(_ item: MidiItem, _ down: Bool) {
        guard let tr = transpose(item.note, item.octave) else { return }
        let c = (down ? 0x90 : 0x80) + item.channel
        let n = tr.id
        let v = Int(Double(item.velocity) / 16.0 * 127)
        if n == 0 || c == 127 { return }
        out.append(MidiMessage([UInt8(c), UInt8(n), UInt8(max(0, min(127, v)))]))
    }
    func midiRelease(_ item: MidiItem, _ id: Int?) { trigger(item, false); if let id = id, id < midiStack.count { midiStack[id] = nil } }
    func midiPush(_ channel: Int, _ octave: Int, _ note: Character, _ velocity: Int, _ length: Int) {
        let item = MidiItem(channel, octave, note, velocity, length)
        for id in 0..<midiStack.count {                      // retrigger duplicates (the JS releases the NEW item and deletes the old slot - ported as is)
            if let dup = midiStack[id], dup.channel == channel, dup.octave == octave, dup.note == note { midiRelease(item, id) }
        }
        midiStack.append(item)
    }
    func midiRun() {
        for id in 0..<midiStack.count {
            guard let item = midiStack[id] else { continue }
            if !item.isPlayed { trigger(item, true); item.isPlayed = true }
            if item.length < 1 { midiRelease(item, id) } else { item.length -= 1 }
        }
    }
    func ccRun() {
        for m in ccStack {
            if m.type == 0 { out.append(MidiMessage([UInt8(0xb0 + m.channel), UInt8(max(0, min(127, ccOffset + m.a))), UInt8(max(0, min(127, m.b)))])) }
            else { out.append(MidiMessage([UInt8(0xe0 + m.channel), UInt8(max(0, min(127, m.a))), UInt8(max(0, min(127, m.b)))])) }
        }
    }
    func monoPush(_ channel: Int, _ octave: Int, _ note: Character, _ velocity: Int, _ length: Int) {
        if let old = monoStack[channel] { trigger(old, false); monoStack[channel] = nil }
        monoStack[channel] = MidiItem(channel, octave, note, velocity, length)
    }
    func monoRun() {
        for id in monoStack.keys.sorted() {
            guard var item = monoStack[id] else { continue }
            if item.length < 1 { trigger(item, false); monoStack[item.channel] = nil }
            guard let cur = monoStack[id] else { continue }
            item = cur
            if !item.isPlayed { trigger(item, true); item.isPlayed = true }
            item.length -= 1
        }
    }
    /// an independent copy of this engine at frame 0 (grid, variables, RNG state) - used to prepare the first frames while the host is stopped
    public func cloneForPreview() -> OrcaEngine {
        let c = OrcaEngine(seed: 1)
        c.adoptState(from: self)
        c.restartFrames()
        return c
    }
    /// take over another engine's complete state (grid, frame, locks, variables, RNG, held notes)
    public func adoptState(from o: OrcaEngine) {
        w = o.w; h = o.h; f = o.f; cells = o.cells; locks = o.locks; variables = o.variables; rng = o.rng
        midiStack = o.midiStack.map { item in item.map { MidiItem($0.channel, $0.octave, $0.note, $0.velocity, $0.length) } }
        for (i, item) in o.midiStack.enumerated() { if let it = item, let mine = midiStack[i] { mine.isPlayed = it.isPlayed } }
        monoStack = o.monoStack.mapValues { MidiItem($0.channel, $0.octave, $0.note, $0.velocity, $0.length) }
        for (k, it) in o.monoStack { monoStack[k]?.isPlayed = it.isPlayed }
        ccStack = o.ccStack; ccOffset = o.ccOffset
    }
    /// host transport started: Orca resets its frame counter (like a MIDI START) and forgets held notes
    public func restartFrames() { f = 0; midiStack = []; monoStack = [:] }
    /// silence everything that is still sounding (transport stop): note-offs for held notes + All Notes Off like Orca's stop
    public func allNotesOff() -> [MidiMessage] {
        var m: [MidiMessage] = []
        for chan in 0..<16 { m.append(MidiMessage([UInt8(0xB0 + chan), 123, 0])) }
        midiStack = []; monoStack = [:]
        return m
    }
}

// MARK: operators
final class Op {
    unowned let o: OrcaEngine
    let kind: Character           // lowercase glyph
    var x: Int, y: Int
    var passive: Bool
    var glyph: Character
    var ports: [(name: String, p: Port)] = []
    init(_ orca: OrcaEngine, _ kind: Character, _ x: Int, _ y: Int, _ passive: Bool) {
        o = orca; self.kind = kind; self.x = x; self.y = y; self.passive = passive
        glyph = passive ? Character(String(kind).uppercased()) : kind
        if kind == "*" || kind == "#" || kind == "$" || kind == ":" || kind == "!" || kind == "?" || kind == "%" || kind == "=" || kind == ";" { self.passive = true; glyph = kind }
        setupPorts()
    }
    func port(_ n: String) -> Port? { ports.first { $0.name == n }?.p }
    func setPort(_ n: String, _ p: Port) { if let i = ports.firstIndex(where: { $0.name == n }) { ports[i].p = p } else { ports.append((n, p)) } }
    func setupPorts() {
        switch kind {
        case "a", "b", "l", "m": setPort("a", Port(-1, 0)); setPort("b", Port(1, 0)); setPort("output", Port(0, 1, output: true, sensitive: true))
        case "c": setPort("rate", Port(-1, 0, min: 1)); setPort("mod", Port(1, 0)); setPort("output", Port(0, 1, output: true, sensitive: true))
        case "d": setPort("rate", Port(-1, 0, min: 1)); setPort("mod", Port(1, 0, min: 1)); setPort("output", Port(0, 1, bang: true, output: true))
        case "f": setPort("a", Port(-1, 0)); setPort("b", Port(1, 0)); setPort("output", Port(0, 1, bang: true, output: true))
        case "g": setPort("x", Port(-3, 0)); setPort("y", Port(-2, 0)); setPort("len", Port(-1, 0, min: 1))
        case "h": setPort("output", Port(0, 1, output: true))
        case "i": setPort("step", Port(-1, 0)); setPort("mod", Port(1, 0)); setPort("output", Port(0, 1, output: true, sensitive: true))
        case "k": setPort("len", Port(-1, 0, min: 1))
        case "o": setPort("x", Port(-2, 0)); setPort("y", Port(-1, 0)); setPort("output", Port(0, 1, output: true))
        case "p": setPort("key", Port(-2, 0)); setPort("len", Port(-1, 0, min: 1)); setPort("val", Port(1, 0))
        case "q": setPort("x", Port(-3, 0)); setPort("y", Port(-2, 0)); setPort("len", Port(-1, 0, min: 1))
        case "r": setPort("a", Port(-1, 0)); setPort("b", Port(1, 0)); setPort("output", Port(0, 1, output: true, sensitive: true))
        case "t": setPort("key", Port(-2, 0)); setPort("len", Port(-1, 0, min: 1)); setPort("output", Port(0, 1, output: true))
        case "u": setPort("step", Port(-1, 0, min: 0)); setPort("max", Port(1, 0, min: 1)); setPort("output", Port(0, 1, bang: true, output: true))
        case "v": setPort("write", Port(-1, 0)); setPort("read", Port(1, 0))
        case "x": setPort("x", Port(-2, 0)); setPort("y", Port(-1, 0)); setPort("val", Port(1, 0))
        case "z": setPort("rate", Port(-1, 0)); setPort("target", Port(1, 0)); setPort("output", Port(0, 1, output: true, sensitive: true))
        case ":", "%": setPort("channel", Port(1, 0)); setPort("octave", Port(2, 0, max: 8)); setPort("note", Port(3, 0)); setPort("velocity", Port(4, 0, max: 16, def: "f")); setPort("length", Port(5, 0, max: 32, def: "1"))
        case "!": setPort("channel", Port(1, 0)); setPort("knob", Port(2, 0)); setPort("value", Port(3, 0))
        case "?": setPort("channel", Port(1, 0, max: 15)); setPort("lsb", Port(2, 0)); setPort("msb", Port(3, 0))
        case "=": setPort("path", Port(1, 0))
        default: break
        }
    }

    // helpers (Operator.js)
    func listenGlyph(_ p: Port?) -> Character {
        guard let p = p else { return "." }
        let g = o.glyphAt(x + p.x, y + p.y)
        return ((g == "." || g == "*") && p.def != nil) ? p.def! : g
    }
    func listenValue(_ p: Port?) -> Int {
        guard let p = p else { return 0 }
        let g = listenGlyph(p)
        return min(p.cMax, max(p.cMin, o.valueOf(g)))
    }
    func hasNeighbor(_ g: Character) -> Bool { o.glyphAt(x + 1, y) == g || o.glyphAt(x - 1, y) == g || o.glyphAt(x, y + 1) == g || o.glyphAt(x, y - 1) == g }
    func shouldUpperCase() -> Bool {
        guard let out = port("output"), out.sensitive else { return false }
        let v = listenGlyph(Port(1, 0))
        let s = String(v)
        if s.lowercased() == s.uppercased() { return false }
        if s.uppercased() != s { return false }
        return true
    }
    func outputGlyph(_ g: Character?, _ p: Port?) {
        guard let p = p, let g = g else { return }
        o.write(x + p.x, y + p.y, shouldUpperCase() ? Character(String(g).uppercased()) : g)
    }
    func outputStr(_ s: String?, _ p: Port?) {      // JS output(`${res}`, port): res is a glyph string
        guard let s = s, let p = p else { return }
        guard s.count == 1, let g = s.first else { o.write(x + p.x, y + p.y, "\0"); return }
        outputGlyph(g, p)
    }
    func bang(_ b: Bool) {
        guard let p = port("output") else { return }
        o.write(x + p.x, y + p.y, b ? "*" : ".")
        o.lock(x + p.x, y + p.y)
    }
    func move(_ dx: Int, _ dy: Int) {
        let nx = x + dx, ny = y + dy
        if !o.inBounds(nx, ny) { o.write(x, y, "*"); return }
        if o.glyphAt(nx, ny) != "." { o.write(x, y, "*"); return }
        o.write(x, y, ".")
        x += dx; y += dy
        o.write(x, y, glyph)
        o.lock(x, y)
    }
    func lockSelf() { o.lock(x, y) }

    // Operator.run
    func run() {
        var payloadStr: String? = nil
        var payloadBang = false
        var payloadGlyph: Character? = nil
        switch kind {
        case "*": o.write(x, y, "."); return                          // bang: erase itself
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9": return  // null operators do nothing
        case "$":                                                      // self: only the locking part matters inside a plugin
            for k in 1...36 { let g = o.glyphAt(x + k, y); o.lock(x + k, y); if g == "." { break } }
            return
        default: break
        }
        // operation (an early return here only ends the operation - the ports are still locked afterwards, as in Operator.run)
        func operation() {
        switch kind {
        case "a": payloadGlyph = o.keyOf(listenValue(port("a")) + listenValue(port("b")))
        case "b": payloadGlyph = o.keyOf(abs(listenValue(port("b")) - listenValue(port("a"))))
        case "c":
            let rate = listenValue(port("rate")), mod = listenValue(port("mod"))
            payloadGlyph = o.keyOf(mod == 0 ? 0 : (o.f / rate) % mod)     // JS: x % 0 = NaN -> keys[NaN] undefined -> nothing written
            if mod == 0 { payloadGlyph = nil }
        case "d":
            let rate = listenValue(port("rate")), mod = listenValue(port("mod"))
            payloadBang = (o.f % (mod * rate) == 0) || mod == 1
        case "e": move(1, 0); passive = false
        case "f": payloadBang = listenGlyph(port("a")) == listenGlyph(port("b"))
        case "g":
            let len = listenValue(port("len")), px = listenValue(port("x")), py = listenValue(port("y")) + 1
            for offset in 0..<len {
                let inP = Port(offset + 1, 0), outP = Port(px + offset, py, output: true)
                setPort("in\(offset)", inP); setPort("out\(offset)", outP)
                outputGlyph(listenGlyph(inP), outP)
            }
        case "h": o.lock(x + 0, y + 1)
        case "i":
            let step = listenValue(port("step")), mod = listenValue(port("mod")), val = listenValue(port("output"))
            payloadGlyph = mod != 0 ? o.keyOf((val + step) % mod) : "0"
        case "j":
            let val = listenGlyph(Port(0, -1))
            if val != "J" {
                var i = 0
                while o.inBounds(x, y + i) { i += 1; if listenGlyph(Port(0, i)) != glyph { break } }
                setPort("input", Port(0, -1)); setPort("output", Port(0, i, output: true))
                payloadGlyph = val
            }
        case "k":
            let len = listenValue(port("len"))
            for offset in 0..<len {
                let key = o.glyphAt(x + offset + 1, y)
                o.lock(x + offset + 1, y)
                if key == "." { continue }
                let inP = Port(offset + 1, 0), outP = Port(offset + 1, 1, output: true)
                setPort("in\(offset)", inP); setPort("out\(offset)", outP)
                outputGlyph(o.valueIn(key), outP)
            }
        case "l": let a = listenValue(port("a")), b = listenValue(port("b")); payloadGlyph = o.keyOf(a > b ? b : a)
        case "m": payloadGlyph = o.keyOf(listenValue(port("a")) * listenValue(port("b")))
        case "n": move(0, -1); passive = false
        case "o":
            let px = listenValue(port("x")), py = listenValue(port("y"))
            setPort("read", Port(px + 1, py))
            payloadGlyph = listenGlyph(port("read"))
        case "p":
            let len = listenValue(port("len")), key = listenValue(port("key"))
            for offset in 0..<len { o.lock(x + offset, y + 1) }
            setPort("output", Port(key % len, 1, output: true))
            payloadGlyph = listenGlyph(port("val"))
        case "q":
            let len = listenValue(port("len")), px = listenValue(port("x")), py = listenValue(port("y"))
            for offset in 0..<len {
                let inP = Port(px + offset + 1, py), outP = Port(offset - len + 1, 1, output: true)
                setPort("in\(offset)", inP); setPort("out\(offset)", outP)
                outputGlyph(listenGlyph(inP), outP)
            }
        case "r":
            let a = listenValue(port("a")), b = listenValue(port("b"))
            if a == b { payloadGlyph = o.keyOf(a) }
            else if a > b { payloadGlyph = o.keyOf(Int(o.rng.next() * Double(a - b + 1) + Double(b))) }
            else { payloadGlyph = o.keyOf(Int(o.rng.next() * Double(b - a + 1) + Double(a))) }
        case "s": move(0, 1); passive = false
        case "t":
            let len = listenValue(port("len")), key = listenValue(port("key"))
            for offset in 0..<len { o.lock(x + offset + 1, y) }
            setPort("val", Port((key % len) + 1, 0))
            payloadGlyph = listenGlyph(port("val"))
        case "u":
            let step = listenValue(port("step")), mx = listenValue(port("max"))
            let bucket = (step * (o.f + mx - 1)) % mx + step
            payloadBang = bucket >= mx
        case "v":
            let write = listenGlyph(port("write")), read = listenGlyph(port("read"))
            if write == "." && read != "." { setPort("output", Port(0, 1, output: true)) }
            if write != "." { o.variables[write] = read } else { payloadGlyph = o.valueIn(read) }
        case "w": move(-1, 0); passive = false
        case "x":
            let px = listenValue(port("x")), py = listenValue(port("y")) + 1
            setPort("output", Port(px, py, output: true))
            payloadGlyph = listenGlyph(port("val"))
        case "y":
            let val = listenGlyph(Port(-1, 0))
            if val != "Y" {
                var i = 0
                while o.inBounds(x + i, y) { i += 1; if listenGlyph(Port(i, 0)) != glyph { break } }
                setPort("input", Port(-1, 0)); setPort("output", Port(i, 0, output: true))
                payloadGlyph = val
            }
        case "z":
            let rate = listenValue(port("rate")), target = listenValue(port("target")), val = listenValue(port("output"))
            let mod = val <= target - rate ? rate : (val >= target + rate ? -rate : target - val)
            payloadGlyph = o.keyOf(val + mod)
        case "#":
            var xx = x + 1
            while xx <= o.w { o.lock(xx, y); if o.glyphAt(xx, y) == glyph { break }; xx += 1 }
            o.lock(x, y)
        case ":":
            if !hasNeighbor("*") { return }
            if listenGlyph(port("channel")) == "." || listenGlyph(port("octave")) == "." || listenGlyph(port("note")) == "." { return }
            if jsIsNumeric(listenGlyph(port("note"))) { return }
            let channel = listenValue(port("channel")); if channel > 15 { return }
            o.midiPush(channel, listenValue(port("octave")), listenGlyph(port("note")), listenValue(port("velocity")), listenValue(port("length")))
        case "%":
            if !hasNeighbor("*") { return }
            if listenGlyph(port("channel")) == "." || listenGlyph(port("octave")) == "." || listenGlyph(port("note")) == "." { return }
            if jsIsNumeric(listenGlyph(port("note"))) { return }
            let channel = listenValue(port("channel")); if channel > 15 { return }
            o.monoPush(channel, listenValue(port("octave")), listenGlyph(port("note")), listenValue(port("velocity")), listenValue(port("length")))
        case "!":
            if !hasNeighbor("*") { return }
            if listenGlyph(port("channel")) == "." || listenGlyph(port("knob")) == "." { return }
            let channel = listenValue(port("channel")); if channel > 15 { return }
            let knob = listenValue(port("knob")), raw = listenValue(port("value"))
            o.ccStack.append((0, channel, knob, Int((Double(127 * raw) / 35.0).rounded(.up))))
        case "?":
            if !hasNeighbor("*") { return }
            if listenGlyph(port("channel")) == "." || listenGlyph(port("lsb")) == "." { return }
            let channel = listenValue(port("channel")), rl = listenValue(port("lsb")), rm = listenValue(port("msb"))
            o.ccStack.append((1, channel, Int((Double(127 * rl) / 35.0).rounded(.up)), Int((Double(127 * rm) / 35.0).rounded(.up))))
        case "=":                                                      // osc: locks the message cells; sending is not possible inside a plugin
            for k in 2...36 { let g = o.glyphAt(x + k, y); o.lock(x + k, y); if g == "." { break } }
            return
        case ";":                                                      // udp: same
            for k in 1...36 { let g = o.glyphAt(x + k, y); o.lock(x + k, y); if g == "." { break } }
            return
        default: break
        }
        }
        operation()
        // permissions: lock every non-bang port
        for (_, p) in ports where !p.bang { o.lock(x + p.x, y + p.y) }
        // output
        if let outp = port("output") {
            if outp.bang { _ = payloadStr; bangOut(payloadBang) }
            else if kind != "h" { outputGlyph(payloadGlyph, outp) }
        }
    }
    func bangOut(_ b: Bool) { bang(b) }
}

/// JS: !isNaN(glyph) for a single character - true only for digits (and a lone whitespace/empty string, which cannot occur in a grid)
func jsIsNumeric(_ g: Character) -> Bool { g.isASCII && g.isNumber }
