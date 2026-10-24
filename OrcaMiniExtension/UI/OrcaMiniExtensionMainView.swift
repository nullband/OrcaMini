//
//  OrcaMiniExtensionMainView.swift
//  OrcaMiniExtension
//
//  The touch UI: the grid (pinch to zoom, scroll to pan, tap to move the cursor) and a slide-up on-screen keyboard.
//  Every edit goes through OrcaEditor, which is verified identical to the desktop Orca's cursor/typing/undo.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct OrcaMiniExtensionMainView: View {
    var parameterTree: ObservableAUParameterGroup
    @ObservedObject var runtime: OrcaRuntime

    @State private var showKeys = true
    @State private var selMode = false        // arrows scale the selection instead of moving the cursor (Orca: Shift+arrows)
    @State private var dragMode = false       // arrows drag the selected block (Orca: Alt+arrows)
    @State private var leap = false           // arrows jump a whole grid width/height (Orca: Cmd+arrows)
    @State private var capsLetters = false    // letter keys type UPPERCASE operators
    @State private var zoom: CGFloat = 1.0
    @State private var zoomAtGestureStart: CGFloat = 1.0
    @State private var showSave = false
    @State private var saveName = ""
    @State private var showLibrary = false
    @State private var showImporter = false
    @State private var shareItem: ShareItem? = nil

    private let bg = Color.black
    private let dim = Color(white: 0.30)
    private let amber = Color(red: 1.0, green: 0.71, blue: 0.27)
    private let mint = Color(red: 0.45, green: 0.87, blue: 0.76)
    private let speedNames = ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            gridArea
            if showKeys { keyboard.transition(.move(edge: .bottom)) }
        }
        .background(bg)
        .animation(.easeInOut(duration: 0.18), value: showKeys)
        .onAppear { runtime.refresh() }
        .alert("Save patch", isPresented: $showSave) {
            TextField("name", text: $saveName)
            Button("Save") { runtime.savePatch(named: saveName) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showLibrary) { LibraryView(runtime: runtime, isPresented: $showLibrary) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .data]) { result in
            if case .success(let url) = result { runtime.importFile(url) }
        }
    }

    // MARK: top bar
    private var topBar: some View {
        let s = runtime.snapshot
        return HStack(spacing: 10) {
            Text("ORCA·MINI").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundColor(mint)
            Text(s.playing ? "▶ \(s.frame)f" : "■ host stopped").font(.system(size: 11, design: .monospaced)).foregroundColor(s.playing ? mint : dim)
            Spacer()
            barButton("<") { runtime.speedDown() }
            Text(speedNames[max(0, min(7, s.speed))]).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(amber).frame(minWidth: 40)
            barButton(">") { runtime.speedUp() }
            fileMenu
            barButton("↶") { runtime.edit { $0.undo() } }
            barButton("↷") { runtime.edit { $0.redo() } }
            barButton(showKeys ? "⌨︎ ▾" : "⌨︎ ▴") { showKeys.toggle() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    private var fileMenu: some View {
        Menu {
            Button("New (clear grid)") { runtime.newPatch() }
            Button("Save…") { saveName = "patch-" + Self.stamp(); showSave = true }
            Button("Load…") { showLibrary = true }
            Button("Export…") { if let u = runtime.exportFile(named: "patch-" + Self.stamp()) { shareItem = ShareItem(url: u) } }
            Button("Import…") { showImporter = true }
        } label: {
            Text("FILE").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color(white: 0.18)).cornerRadius(5)
        }
    }
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }

    private func barButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color(white: 0.18)).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    // MARK: grid
    private func cellSize() -> CGSize { CGSize(width: 15 * zoom, height: 22 * zoom) }

    private var gridArea: some View {
        let s = runtime.snapshot
        let cs = cellSize()
        return GeometryReader { geo in
          ScrollView([.horizontal, .vertical], showsIndicators: false) {
            Canvas { ctx, size in drawGrid(ctx, s, cs) }
                .frame(width: CGFloat(s.w) * cs.width + 8, height: CGFloat(s.h) * cs.height + 8)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    let x = Int((v.location.x - 4) / cs.width), y = Int((v.location.y - 4) / cs.height)
                    runtime.edit { $0.select(x, y, 0, 0) }
                })
        }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in zoom = max(0.5, min(3.0, zoomAtGestureStart * v.magnification)) }
            .onEnded { _ in zoomAtGestureStart = zoom })
        .onTapGesture(count: 2) { zoom = 1.0; zoomAtGestureStart = 1.0 }
        .onChange(of: zoom) { _, _ in fillGrid(geo.size) }
        .onChange(of: geo.size) { _, new in fillGrid(new) }
        .onAppear { fillGrid(geo.size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// as many whole cells as fit in the visible area at the current zoom: the grid grows to that (zoom out = more room)
    private func fillGrid(_ size: CGSize) {
        let cs = cellSize()
        runtime.ensureGrid(cols: Int((size.width - 8) / cs.width), rows: Int((size.height - 8) / cs.height))
    }

    private func drawGrid(_ ctx: GraphicsContext, _ s: GridSnapshot, _ cs: CGSize) {
        let minX = min(s.cx, s.cx + s.cw), maxX = max(s.cx, s.cx + s.cw)
        let minY = min(s.cy, s.cy + s.ch), maxY = max(s.cy, s.cy + s.ch)
        let font = Font.system(size: 14 * zoom, weight: .regular, design: .monospaced)
        for y in 0..<s.h {
            for x in 0..<s.w {
                let i = y * s.w + x
                guard i < s.cells.count else { continue }
                let g = s.cells[i]
                let rect = CGRect(x: 4 + CGFloat(x) * cs.width, y: 4 + CGFloat(y) * cs.height, width: cs.width, height: cs.height)
                let selected = x >= minX && x <= maxX && y >= minY && y <= maxY
                let isCursor = x == s.cx && y == s.cy
                if isCursor { ctx.fill(Path(rect), with: .color(amber)) }
                else if selected { ctx.fill(Path(rect), with: .color(Color(white: 0.22))) }
                var color: Color = dim
                if g != "." {
                    if isCursor { color = .black }
                    else if g == "*" { color = amber }
                    else if g.isNumber || g.isLowercase { color = Color(white: 0.85) }
                    else if g.isUppercase { color = mint }
                    else { color = Color(red: 0.95, green: 0.45, blue: 0.55) }       // : ! ? % = ; # $ specials
                } else if isCursor { color = .black }
                ctx.draw(Text(String(g)).font(font).foregroundColor(color), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        if s.ins {
            ctx.draw(Text("INS").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(amber), at: CGPoint(x: 18, y: 4 + CGFloat(s.h) * cs.height + 2))
        }
    }

    // MARK: keyboard
    private let letters = Array("abcdefghijklmnopqrstuvwxyz")
    private let digits = Array("0123456789")
    private let specials = Array("*#$:!?%=;.")

    private var keyboard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { glyphBlock; toolBlock.frame(width: 300) }          // wide: glyphs left, tools + arrows right
            VStack(spacing: 6) { glyphBlock; toolBlock }                                                // narrow window: stacked
        }
        .padding(8).background(Color(white: 0.10))
    }

    private var glyphBlock: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) { ForEach(digits, id: \.self) { glyphKey($0) } }
            HStack(spacing: 5) { ForEach(Array(letters[0..<13]), id: \.self) { glyphKey($0, letter: true) } }
            HStack(spacing: 5) { ForEach(Array(letters[13..<26]), id: \.self) { glyphKey($0, letter: true) } }
            HStack(spacing: 5) {
                toggleKey("⇧ ABC", on: capsLetters, wide: true) { capsLetters.toggle() }
                ForEach(specials, id: \.self) { glyphKey($0) }
            }
        }
    }

    private var toolBlock: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {                                  // the selection group, together
                toggleKey("SEL", on: selMode) { selMode.toggle(); if selMode { dragMode = false } }
                actionKey("ALL") { runtime.edit { $0.selectAll() } }
                actionKey("COPY") { runtime.copyToPasteboard() }
                actionKey("PASTE") { runtime.pasteFromPasteboard() }
            }
            HStack(spacing: 5) {
                actionKey("CUT") { runtime.copyToPasteboard(); runtime.edit { $0.erase() } }
                actionKey("CMT") { runtime.edit { $0.comment() } }
                actionKey("ABC") { runtime.edit { $0.toUpperCase() } }
                actionKey("abc") { runtime.edit { $0.toLowerCase() } }
            }
            HStack(spacing: 5) {
                toggleKey("INS", on: runtime.snapshot.ins) { runtime.edit { $0.ins.toggle() } }
                actionKey("⌫", size: 24) { runtime.edit { $0.backspace() } }
                toggleKey("DRAG", on: dragMode) { dragMode.toggle(); if dragMode { selMode = false } }
                toggleKey("LEAP", on: leap) { leap.toggle() }
            }
            VStack(spacing: 4) {                                  // arrows laid out like a keyboard: up above down, left and right either side
                arrow("↑", 0, 1)
                HStack(spacing: 4) { arrow("←", -1, 0); arrow("↓", 0, -1); arrow("→", 1, 0) }
            }
            .padding(.top, 2)
        }
    }

    private func glyphKey(_ c: Character, letter: Bool = false) -> some View {
        let shown = letter && capsLetters ? Character(String(c).uppercased()) : c
        return Button { runtime.edit { $0.write(shown) } } label: {
            Text(String(shown)).font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 42).background(Color(white: 0.20)).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private func actionKey(_ t: String, size: CGFloat = 12, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 40).background(Color(white: 0.28)).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private func toggleKey(_ t: String, on: Bool, wide: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(on ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: wide ? 42 : 40).background(on ? amber : Color(white: 0.28)).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    /// arrows only move the cursor (as in Orca). SEL scales the selection, DRAG drags the block, LEAP jumps a whole grid width/height
    private func arrow(_ t: String, _ dx: Int, _ dy: Int) -> some View {
        Button {
            let sn = runtime.snapshot
            let mx = leap ? dx * sn.w : dx, my = leap ? dy * sn.h : dy
            runtime.edit { if selMode { $0.scale(mx, my) } else if dragMode { $0.drag(mx, my) } else { $0.move(mx, my) } }
        } label: {
            Text(t).font(.system(size: 24, weight: .bold)).foregroundColor(.white).frame(width: 78, height: 54).background(Color(white: 0.28)).cornerRadius(8)
        }.buttonStyle(.plain)
    }
}


// MARK: library / share
struct ShareItem: Identifiable { let id = UUID(); let url: URL }

struct LibraryView: View {
    @ObservedObject var runtime: OrcaRuntime
    @Binding var isPresented: Bool
    @State private var names: [String] = []
    var body: some View {
        NavigationView {
            List {
                if names.isEmpty { Text("No saved patches yet. Use FILE, Save…").foregroundColor(.gray) }
                ForEach(names, id: \.self) { n in
                    Button(n) { runtime.loadSaved(n); isPresented = false }
                }
                .onDelete { idx in for i in idx { runtime.deleteSaved(names[i]) }; names = runtime.libraryNames() }
            }
            .navigationTitle("Saved patches")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } } }
        }
        .onAppear { names = runtime.libraryNames() }
    }
}

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
