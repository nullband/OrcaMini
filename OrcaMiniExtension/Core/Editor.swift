// Editor - Orca's cursor, selection, typing, drag, comment, copy/paste and undo history, ported from cursor.js + history.js.
// The touch UI (on-screen keyboard, arrow pad) only calls these; behaviour is identical to the desktop Orca.
import Foundation

public final class History {
    var index = 0
    var frames: [String] = []
    public init() {}
    public func reset() { index = 0; frames = [] }
    public func record(_ data: String) {
        if index == frames.count { append(data) } else { fork(data) }
        trim()
        index = frames.count
    }
    func append(_ data: String) {
        if data.isEmpty { return }
        if index - 1 >= 0 && index - 1 < frames.count && frames[index - 1] == data { return }
        frames.append(data)
    }
    func fork(_ data: String) { frames = Array(frames.prefix(index + 1)); append(data) }
    func trim(limit: Int = 30) { if frames.count < limit { return }; frames.removeFirst() }
    func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }
    /// returns the frame to apply, or nil
    public func undo() -> String? {
        if index == 0 { return nil }
        index = clamp(index - 1, 0, frames.count - 2)
        return index >= 0 && index < frames.count ? frames[index] : nil
    }
    public func redo() -> String? {
        if index + 1 > frames.count - 1 { return nil }
        index = clamp(index + 1, 0, frames.count - 1)
        return frames[index]
    }
}

public final class OrcaEditor {
    public let orca: OrcaEngine
    public let history = History()
    public private(set) var x = 0, y = 0, w = 0, h = 0
    public private(set) var minX = 0, maxX = 0, minY = 0, maxY = 0
    public var ins = false

    public init(_ engine: OrcaEngine) { orca = engine; history.reset(); history.record(orca.text()) }

    func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }

    /// load a new patch (Orca's whenOpen): resets the history
    public func open(patch text: String) { orca.loadPatch(text); history.reset(); history.record(orca.text()); x = 0; y = 0; w = 0; h = 0; calculateBounds() }

    /// grow/shrink the grid (cells kept). Undo history restarts because every stored frame has the old size.
    public func resizeGrid(w nw: Int, h nh: Int) {
        orca.resize(w: nw, h: nh)
        history.reset(); history.record(orca.text())
        x = min(x, orca.w - 1); y = min(y, orca.h - 1); w = 0; h = 0; calculateBounds()
    }
    public func select(_ nx: Int? = nil, _ ny: Int? = nil, _ nw: Int? = nil, _ nh: Int? = nil) {
        let X = nx ?? x, Y = ny ?? y, W = nw ?? w, H = nh ?? h
        let rx = clamp(X, 0, orca.w - 1), ry = clamp(Y, 0, orca.h - 1)
        let rw = clamp(W, -x, orca.w - 1), rh = clamp(H, -y, orca.h - 1)      // sic: the desktop clamps w/h against the OLD x/y
        if x == rx && y == ry && w == rw && h == rh { return }
        x = rx; y = ry; w = rw; h = rh
        calculateBounds()
    }
    public func selectAll() { select(0, 0, orca.w, orca.h); ins = false }
    public func move(_ dx: Int, _ dy: Int) { select(x + dx, y - dy) }
    public func moveTo(_ nx: Int, _ ny: Int) { select(nx, ny) }
    public func scale(_ dw: Int, _ dh: Int) { select(x, y, w + dw, h - dh) }
    public func scaleTo(_ nw: Int, _ nh: Int) { select(x, y, nw, nh) }
    public func reset(pos: Bool = false) { select(pos ? 0 : x, pos ? 0 : y, 0, 0); ins = false }
    public func read() -> Character { orca.glyphAt(x, y) }

    public func write(_ g: Character) {
        if !orca.isAllowed(g) { return }
        if orca.write(x, y, g) && ins { move(1, 0) }
        history.record(orca.text())
    }
    public func erase() {
        for yy in minY...maxY { for xx in minX...maxX { orca.write(xx, yy, ".") } }
        history.record(orca.text())
    }
    /// Orca's Backspace: in insert mode erase then step back, otherwise erase the selection
    public func backspace() { if ins { erase(); move(-1, 0) } else { erase() } }

    public func drag(_ dx: Int, _ dy: Int) {
        ins = false
        let block = selection()
        erase()
        move(dx, dy)
        writeBlock(minX, minY, block, overlap: false)
        history.record(orca.text())
    }
    public func selection() -> String { getBlock(minX, minY, maxX - minX + 1, maxY - minY + 1) }
    func getBlock(_ bx: Int, _ by: Int, _ bw: Int, _ bh: Int) -> String {
        var lines = ""
        for yy in by..<(by + bh) { var line = ""; for xx in bx..<(bx + bw) { let g = orca.glyphAt(xx, yy); line.append(g == "\0" ? "" : String(g)) }; lines += line + "\n" }
        return lines
    }
    func writeBlock(_ bx: Int, _ by: Int, _ block: String, overlap: Bool) {
        if block.isEmpty { return }
        var yy = by
        for line in block.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var xx = bx
            for g in line { orca.write(xx, yy, overlap && g == "." ? orca.glyphAt(xx, yy) : g); xx += 1 }
            yy += 1
        }
    }
    public func comment() {
        let block = selection()
        let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let ch: Character = block.first == "#" ? "." : "#"
        let res = lines.map { line -> String in
            let chars = Array(line)
            let inner = chars.count > 1 ? String(chars[1..<max(1, chars.count - 1)]) : ""      // JS substr(1, len-2)
            return "\(ch)\(inner)\(ch)"
        }.joined(separator: "\n")
        writeBlock(minX, minY, res, overlap: false)
        history.record(orca.text())
    }
    public func toUpperCase() { writeBlock(minX, minY, selection().uppercased(), overlap: false) }
    public func toLowerCase() { writeBlock(minX, minY, selection().lowercased(), overlap: false) }
    public func copyText() -> String { selection() }
    public func paste(_ text: String) {
        let data = text.trimmingCharacters(in: .whitespacesAndNewlines)
        writeBlock(minX, minY, data, overlap: ins)
        history.record(orca.text())
        let lines = data.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        scaleTo((lines.first?.count ?? 1) - 1, lines.count - 1)
    }
    public func undo() { if let f = history.undo(), f.count == orca.cells.count { orca.replaceAll(f) } }
    public func redo() { if let f = history.redo(), f.count == orca.cells.count { orca.replaceAll(f) } }
    func calculateBounds() {
        minX = x < x + w ? x : x + w; minY = y < y + h ? y : y + h
        maxX = x > x + w ? x : x + w; maxY = y > y + h ? y : y + h
    }
}
extension OrcaEngine {
    public func replaceAll(_ s: String) { cells = Array(s) }
}
