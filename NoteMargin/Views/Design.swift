import SwiftUI

extension CoverColor {
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.31, green: 0.45, blue: 0.64)
        case .sage: return Color(red: 0.43, green: 0.55, blue: 0.47)
        case .sand: return Color(red: 0.69, green: 0.57, blue: 0.41)
        case .rose: return Color(red: 0.65, green: 0.44, blue: 0.46)
        case .graphite: return Color(red: 0.34, green: 0.37, blue: 0.41)
        }
    }
}

struct NoteCover: View {
    let note: Notebook
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12).fill(note.cover.color.gradient)
            Rectangle().fill(.black.opacity(0.09)).frame(width: 14).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: note.pdfAssetName == nil ? "book.closed" : "doc.richtext")
                    .font(.title2.weight(.light)).opacity(0.85)
                Spacer()
                Text(note.title).font(.system(.title3, design: .serif).weight(.medium)).lineLimit(3)
                Text(note.pdfAssetName == nil ? "NOTEBOOK" : "PDF NOTEBOOK")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(2).opacity(0.7)
            }
            .foregroundStyle(.white).padding(24).padding(.leading, 10)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if note.isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.white.opacity(0.9)).padding(14)
            }
        }
        .shadow(color: note.cover.color.opacity(0.15), radius: 8, x: 0, y: 5)
        .accessibilityHidden(true)
    }
}

struct NotebookForm: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: NoteStore
    var existing: Notebook?
    var folderID: UUID?
    var projectID: UUID?
    var onCreated: (UUID) -> Void = { _ in }
    @State private var title = ""
    @State private var paper: PaperStyle = .ruled
    @State private var infinite = false
    @State private var cover: CoverColor = .blue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        NoteCover(note: Notebook(title: title.trimmedOrUntitled, cover: cover))
                            .frame(width: 138).padding(.vertical, 10)
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
                Section("노트 이름") { TextField("제목 없는 노트", text: $title).submitLabel(.done).accessibilityIdentifier("create-note-title") }
                Section("표지 색상") {
                    HStack(spacing: 20) {
                        ForEach(CoverColor.allCases) { value in
                            Button { cover = value } label: {
                                Circle().fill(value.color).frame(width: 38, height: 38)
                                    .overlay { if value == cover { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel(value.title)
                                .accessibilityAddTraits(value == cover ? .isSelected : [])
                        }
                    }.frame(maxWidth: .infinity)
                }
                if existing == nil {
                    Section("노트 형식") {
                        Picker("캔버스", selection: $infinite) {
                            Text("고정 페이지").tag(false)
                            Text("무한 캔버스").tag(true)
                        }.pickerStyle(.segmented).accessibilityIdentifier("note-canvas-mode")
                    }
                    Section("첫 페이지 용지") {
                        Picker("용지", selection: $paper) {
                            ForEach(PaperStyle.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(existing == nil ? "새로운 노트" : "노트 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "만들기" : "완료") {
                        if let existing {
                            if store.updateNote(existing.id, { $0.title = title.trimmedOrUntitled; $0.cover = cover }) { dismiss() }
                        } else if let id = store.createNote(title: title, paper: paper, cover: cover, folderID: folderID, projectID: projectID, infinite: infinite) {
                            dismiss()
                            onCreated(id)
                        }
                    }.bold().accessibilityIdentifier("create-note-confirm")
                }
            }
            .onAppear { if let existing { title = existing.title; cover = existing.cover } }
        }
        .presentationDetents([.large])
        .storeErrorAlert()
    }
}

struct StoreErrorAlert: ViewModifier {
    @EnvironmentObject private var store: NoteStore
    func body(content: Content) -> some View {
        content.alert("작업을 완료하지 못했습니다", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

extension View {
    func storeErrorAlert() -> some View { modifier(StoreErrorAlert()) }
}

// Original 24-point line drawings: a split nib, graphite facets and a slanted
// marker edge. These are vector geometry, not images from another app.
enum InkTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser, pixelEraser, lasso, rectangle
    var id: String { rawValue }
    var isInk: Bool { self == .pen || self == .pencil || self == .marker }
    var isSelection: Bool { self == .lasso || self == .rectangle }
    var isEraser: Bool { self == .eraser || self == .pixelEraser }
    var title: String {
        switch self {
        case .pen: "펜"
        case .pencil: "연필"
        case .marker: "형광펜"
        case .eraser: "획 지우개"
        case .pixelEraser: "부분 지우개"
        case .lasso: "자유 선택"
        case .rectangle: "네모 선택"
        }
    }
}

struct InkToolGlyph: Shape {
    var tool: InkTool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ points: [CGPoint], closed: Bool = false) {
            guard let first = points.first else { return }
            p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }
            if closed { p.closeSubpath() }
        }
        func pts(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }
        switch tool {
        case .pen:
            line(pts([(5,19),(8,7),(17,3),(21,7),(17,16),(5,19)]))
            line(pts([(5,19),(12,12)])); p.addEllipse(in: CGRect(x: 11, y: 10, width: 3, height: 3))
            line(pts([(9,7),(17,15)])); line(pts([(4,22),(15,22)]))
        case .pencil:
            line(pts([(4,20),(6,13),(16,3),(21,8),(11,18),(4,20)]))
            line(pts([(6,13),(11,18)])); line(pts([(14,5),(19,10)])); line(pts([(9,14),(16,7)]))
            line(pts([(4,20),(7,19)]))
        case .marker:
            line(pts([(4,17),(9,12),(8,10),(16,2),(22,8),(14,16),(12,15),(8,19)]))
            line(pts([(9,7),(17,15)])); line(pts([(3,21),(14,21)]))
        case .eraser, .pixelEraser:
            line(pts([(3,14),(13,3),(21,10),(12,20),(9,20),(3,14)]))
            line(pts([(7,10),(15,17)]))
            if tool == .pixelEraser {
                for x: CGFloat in [16, 20] { p.addRect(CGRect(x: x, y: 20, width: 1, height: 1)) }
            } else { line(pts([(15,21),(22,21)])) }
        case .rectangle:
            for points: [(CGFloat, CGFloat)] in [[(3,9),(3,3),(9,3)],[(15,3),(21,3),(21,9)],[(21,15),(21,21),(15,21)],[(9,21),(3,21),(3,15)]] { line(pts(points)) }
            p.addEllipse(in: CGRect(x: 11, y: 11, width: 2, height: 2))
        case .lasso:
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 12))
            p.move(to: CGPoint(x: 8, y: 14))
            p.addCurve(to: CGPoint(x: 6, y: 22), control1: CGPoint(x: 16, y: 22), control2: CGPoint(x: 1, y: 24))
            p.addCurve(to: CGPoint(x: 10, y: 16), control1: CGPoint(x: 10, y: 20), control2: CGPoint(x: 11, y: 18))
        }
        let scale = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale))
    }
}

enum InkPalette {
    static let defaults = ["000000", "007AFF", "FF3B30", "FF9500", "FFFFFF"]
    static func values(_ stored: String) -> [String] {
        let parts = stored.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return (0..<5).map { i in
            guard i < parts.count, parts[i].count == 6, UInt32(parts[i], radix: 16) != nil else { return defaults[i] }
            return parts[i].uppercased()
        }
    }
    static func color(_ hex: String) -> Color {
        let rgb = UInt32(hex, radix: 16) ?? 0
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

struct DrawingToolsView: View {
    @ObservedObject var session: DrawingSession
    @Binding var expanded: Bool
    var vertical = false
    var onMove: (CGPoint, CGPoint, Bool) -> Void = { _, _, _ in }
    @AppStorage("inkTools.colors") private var storedColors = InkPalette.defaults.joined(separator: ",")
    @State private var editingColor = 0
    @State private var selectedColorSlot: Int?
    @State private var colorSettings = false
    @State private var widthSettings = false
    @State private var eraserSettings = false
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("ink-tool-dock"))
            .onChanged { onMove($0.startLocation, $0.location, false) }
            .onEnded { onMove($0.startLocation, $0.location, true) }
    }
    private let colors: [(String, Color)] = [("검정", .black), ("파랑", .blue), ("빨강", .red), ("초록", .green), ("노랑", .yellow), ("흰색", .white)]
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if expanded {
                // Both rails keep their own scroll position. The separator is
                // outside them, so it also provides a stationary drag handle.
                let railLayout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                railLayout {
                    toolRail
                    Capsule().fill(Color.secondary.opacity(0.45))
                        .frame(width: vertical ? 24 : 2, height: vertical ? 2 : 24)
                        .frame(width: vertical ? 44 : 18, height: vertical ? 18 : 44)
                        .contentShape(Rectangle())
                        .gesture(moveGesture)
                        .accessibilityLabel("도구 팔레트 이동 손잡이")
                        .accessibilityHint("끌어서 화면의 위, 아래, 왼쪽, 오른쪽 가장자리에 놓습니다")
                        .accessibilityIdentifier("ink-tools-drag")
                    colorRail
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            } else {
                Button { expanded = true } label: {
                    InkToolGlyph(tool: session.selectedTool).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 29, height: 29).foregroundStyle(.primary)
                        .frame(width: 60, height: 60)
                        .background(.regularMaterial, in: Circle())
                        .overlay(alignment: .bottom) {
                            Capsule().fill(session.selectedTool.isInk ? session.inkColor : Color.accentColor).frame(width: 18, height: 4).padding(.bottom, 8)
                        }.overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                }.highPriorityGesture(moveGesture)
                    .accessibilityHint("누르면 펼치고, 끌면 화면 가장자리로 이동합니다")
                    .accessibilityLabel(session.selectedTool.title + " · 필기 도구 펼치기").accessibilityIdentifier("ink-tools-expand")
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
    private var toolRail: some View {
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            layout {
                ForEach(InkTool.allCases.filter { $0.isInk }) { tool in
                    Button { session.selectTool(tool) } label: {
                        InkToolGlyph(tool: tool).stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                            .frame(width: 24, height: 24).frame(width: 44, height: 44)
                            .foregroundStyle(session.selectedTool == tool ? Color.accentColor : Color.primary)
                            .background(session.selectedTool == tool ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.accessibilityLabel(tool.title).accessibilityIdentifier("ink-tool-" + tool.rawValue)
                        .accessibilityAddTraits(session.selectedTool == tool ? .isSelected : [])
                }
                eraserToolButton
                selectionToolButton
                if session.selectedTool.isSelection {
                    selectionModeMenu
                    Text(session.selectedStrokeCount == 0 ? "선택" : "\(session.selectedStrokeCount)획")
                        .font(.caption).frame(width: 44, height: 44)
                        .accessibilityLabel(selectionStatus).accessibilityIdentifier("ink-selection-status")
                    selectionMenu.frame(width: 44, height: 44)
                } else if session.selectedTool.isInk {
                    Button { widthSettings = true } label: {
                        Text(session.inkWidth.formatted(.number.precision(.fractionLength(1))))
                            .font(.callout.monospacedDigit()).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("도구 굵기 및 자").accessibilityIdentifier("ink-width-settings")
                        .popover(isPresented: $widthSettings) { widthControls.padding().frame(width: 280).presentationCompactAdaptation(.popover) }
                }
                undoButtons
                Button { expanded = false } label: {
                    Image(systemName: vertical ? "chevron.right" : "chevron.down").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("필기 도구 접기").accessibilityIdentifier("ink-tools-collapse")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ink-tools-tool-rail")
        .accessibilityLabel("필기 도구 목록")
    }
    private var eraserTool: InkTool {
        session.selectedTool.isEraser ? session.selectedTool : session.lastEraserTool
    }
    private var eraserToolButton: some View {
        Button {
            if session.selectedTool.isEraser { eraserSettings = true }
            else { session.selectTool(session.lastEraserTool) }
        } label: {
            InkToolGlyph(tool: eraserTool).stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 24).frame(width: 44, height: 44)
                .foregroundStyle(session.selectedTool.isEraser ? Color.accentColor : Color.primary)
                .background(session.selectedTool.isEraser ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .accessibilityLabel("지우개")
        .accessibilityValue(eraserTool.title + " · " + session.eraserWidth.formatted(.number.precision(.fractionLength(1))))
        .accessibilityIdentifier("ink-tool-eraser")
        .accessibilityHint(session.selectedTool.isEraser ? "다시 누르면 지우는 방식과 폭을 변경합니다" : "마지막 지우개를 선택합니다")
        .accessibilityAddTraits(session.selectedTool.isEraser ? .isSelected : [])
        .popover(isPresented: $eraserSettings) {
            eraserControls.padding(16).frame(width: 280).presentationCompactAdaptation(.popover)
        }
    }
    private var eraserControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("지우개").font(.headline)
            Picker("지우는 방식", selection: Binding(get: { eraserTool }, set: { session.selectTool($0) })) {
                Text("획").tag(InkTool.eraser).accessibilityIdentifier("ink-eraser-mode-stroke")
                Text("부분").tag(InkTool.pixelEraser).accessibilityIdentifier("ink-eraser-mode-partial")
            }.pickerStyle(.segmented).accessibilityIdentifier("ink-eraser-mode")
            HStack {
                Text("폭")
                Spacer()
                Text(session.eraserWidth.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $session.eraserWidth, in: session.eraserWidthRange, step: 1)
                .accessibilityLabel("지우개 폭").accessibilityIdentifier("ink-eraser-width-slider")
                .onChange(of: session.eraserWidth) { _, _ in session.applyTool() }
            HStack {
                Spacer()
                Button("완료") { eraserSettings = false }.accessibilityIdentifier("ink-eraser-settings-done")
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ink-eraser-settings")
    }
    private var selectionTool: InkTool {
        session.selectedTool.isSelection ? session.selectedTool : session.lastSelectionTool
    }
    private var selectionModeTitle: String { selectionTool == .lasso ? "자유형" : "박스형" }
    private var selectionToolButton: some View {
        Button { session.selectTool(session.lastSelectionTool) } label: {
            InkToolGlyph(tool: selectionTool).stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 24).frame(width: 44, height: 44)
                .foregroundStyle(session.selectedTool.isSelection ? Color.accentColor : Color.primary)
                .background(session.selectedTool.isSelection ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .accessibilityLabel("선택").accessibilityValue(selectionModeTitle)
        .accessibilityIdentifier("ink-tool-selection")
        .accessibilityHint("마지막으로 사용한 방식으로 필기를 선택합니다")
        .accessibilityAddTraits(session.selectedTool.isSelection ? .isSelected : [])
    }
    private var selectionModeMenu: some View {
        Menu {
            Button { session.selectTool(.lasso) } label: {
                Label("자유형", systemImage: selectionTool == .lasso ? "checkmark" : "lasso")
            }.accessibilityIdentifier("ink-selection-mode-freeform")
            Button { session.selectTool(.rectangle) } label: {
                Label("박스형", systemImage: selectionTool == .rectangle ? "checkmark" : "rectangle.dashed")
            }.accessibilityIdentifier("ink-selection-mode-box")
        } label: {
            Text(selectionModeTitle).font(.caption).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("선택 방식").accessibilityValue(selectionModeTitle)
        .accessibilityIdentifier("ink-selection-mode")
    }
    private var colorRail: some View {
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            layout { ForEach(0..<5) { index in colorButton(index) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ink-tools-color-rail")
        .accessibilityLabel("펜 색상 목록")
    }
    private var palette: [String] { InkPalette.values(storedColors) }
    private var selectedColorIndex: Int? {
        let hex = InkPalette.hex(session.inkColor)
        if let index = selectedColorSlot, palette.indices.contains(index), palette[index] == hex { return index }
        return palette.firstIndex(of: hex)
    }
    private func colorButton(_ index: Int) -> some View {
        let hex = palette[index], selected = selectedColorIndex == index
        return Button {
            if selected { editingColor = index; colorSettings = true }
            else { selectedColorSlot = index; session.inkColor = InkPalette.color(hex); session.applyTool() }
        } label: {
            Circle().fill(InkPalette.color(hex)).frame(width: 24, height: 24)
                .overlay(Circle().stroke(.gray.opacity(0.6), lineWidth: 1))
                .padding(4).overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("펜 색상 \(index + 1)").accessibilityValue(hex)
            .accessibilityIdentifier("ink-color-\(index)")
            .accessibilityHint(selected ? "누르면 색상 변경 창을 엽니다" : "누르면 이 색상을 선택합니다")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(!session.selectedTool.isInk)
            .accessibilityAction(named: "색상 변경") { editingColor = index; colorSettings = true }
            .popover(isPresented: Binding(get: { colorSettings && editingColor == index }, set: { colorSettings = $0 })) {
                colorControls.padding().frame(width: 300).presentationCompactAdaptation(.popover)
            }
    }
    private func setPaletteColor(_ color: Color) {
        var values = palette; values[editingColor] = InkPalette.hex(color)
        storedColors = values.joined(separator: ","); selectedColorSlot = editingColor
        session.inkColor = color; session.applyTool()
    }
    private var colorControls: some View {
        VStack(spacing: 12) {
            Text("펜 색상 \(editingColor + 1) 변경").font(.headline)
            HStack(spacing: 4) {
                ForEach(colors, id: \.0) { name, color in
                    Button { setPaletteColor(color) } label: {
                        Circle().fill(color).frame(width: 28, height: 28).overlay(Circle().stroke(.gray, lineWidth: 1)).frame(width: 40, height: 44)
                    }.accessibilityLabel(name + " 잉크")
                }
            }
            ColorPicker("사용자 지정 색상", selection: Binding(get: { InkPalette.color(palette[editingColor]) }, set: setPaletteColor), supportsOpacity: false)
            Text("#" + palette[editingColor]).font(.caption.monospaced())
            Button("완료") { colorSettings = false }
        }
    }
    private var widthControls: some View {
        VStack(spacing: 12) {
            Text(session.selectedTool.title + " 굵기").font(.headline)
            Slider(value: $session.inkWidth, in: 0.1...12, step: 0.1).accessibilityLabel("도구 굵기")
                .accessibilityIdentifier("ink-width-slider")
                .onChange(of: session.inkWidth) { _, _ in session.applyTool() }
            Text(session.inkWidth.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
            Toggle("자", isOn: $session.rulerActive).disabled(!session.selectedTool.isInk)
                .onChange(of: session.rulerActive) { _, _ in session.applyTool() }
        }
    }
    private var undoButtons: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle()) }.disabled(!session.canUndo).accessibilityLabel("실행 취소")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle()) }.disabled(!session.canRedo).accessibilityLabel("다시 실행")
        }
    }
    private var selectionStatus: String {
        if session.selectedStrokeCount > 0 { return "\(session.selectedStrokeCount)획 선택 · 안쪽을 끌어 이동" }
        return selectionTool == .lasso ? "필기를 자유형으로 둘러싸세요" : "필기를 네모로 둘러싸세요"
    }
    private var selectionMenu: some View {
        Menu {
            Text(selectionStatus)
            Text("모서리로 크기 조절 · 안쪽을 끌어 이동 · 두 손가락으로 화면 이동")
            Button("복사", systemImage: "doc.on.doc") { session.host?.copySelectedInk() }.disabled(session.selectedStrokeCount == 0)
            Button("잘라내기", systemImage: "scissors") { session.host?.copySelectedInk(cut: true) }.disabled(session.selectedStrokeCount == 0)
            Button("복제", systemImage: "plus.square.on.square") { session.host?.pasteInk(duplicate: true) }.disabled(session.selectedStrokeCount == 0)
            Button("붙여넣기", systemImage: "doc.on.clipboard") { session.host?.pasteInk() }.disabled(DrawingSession.copiedInk == nil)
            Button(session.selectionIsGrouped ? "그룹 해제" : "그룹화", systemImage: "square.3.layers.3d") {
                if session.selectionIsGrouped { session.host?.ungroupSelectedInk() }
                else { session.host?.groupSelectedInk() }
            }.disabled(session.selectedStrokeCount < 2 && !session.selectionIsGrouped)
            Button("저장", systemImage: "square.and.arrow.down") { session.saveSelectedInk() }
                .disabled(session.selectedStrokeCount == 0)
            Menu("필기 크기", systemImage: "arrow.up.left.and.arrow.down.right") {
                Button("작게 (90%)") { session.host?.scaleSelectedInk(by: 0.9) }
                Button("크게 (110%)") { session.host?.scaleSelectedInk(by: 1.1) }
            }.disabled(session.selectedStrokeCount == 0)
            Button("삭제", systemImage: "trash", role: .destructive) { session.host?.deleteSelectedInk() }.disabled(session.selectedStrokeCount == 0)
            Button("선택 해제") { session.host?.clearInkSelection() }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("편집").accessibilityIdentifier("ink-selection-menu")
    }
}


/// Selection actions are independent of the palette's scroll/collapse state.
/// The host publishes the final selection rect, not every live pointer sample.
private struct InkSelectionActionBar: View {
    @ObservedObject var session: DrawingSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                action("복제", icon: "plus.square.on.square", id: "duplicate") { session.host?.pasteInk(duplicate: true) }
                action("잘라내기", icon: "scissors", id: "cut") { session.host?.copySelectedInk(cut: true) }
                action("복사", icon: "doc.on.doc", id: "copy") { session.host?.copySelectedInk() }
                action("붙여넣기", icon: "doc.on.clipboard", id: "paste") { session.host?.pasteInk() }
                    .disabled(DrawingSession.copiedInk == nil)
                action(session.selectionIsGrouped ? "그룹 해제" : "그룹화", icon: "square.3.layers.3d", id: "group") {
                    if session.selectionIsGrouped { session.host?.ungroupSelectedInk() }
                    else { session.host?.groupSelectedInk() }
                }.disabled(session.selectedStrokeCount < 2 && !session.selectionIsGrouped)
                action("삭제", icon: "trash", id: "delete", destructive: true) { session.host?.deleteSelectedInk() }
                action("저장", icon: "square.and.arrow.down", id: "save") { session.saveSelectedInk() }
            }
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        .accessibilityIdentifier("ink-selection-actions")
    }

    private func action(_ title: String, icon: String, id: String, destructive: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .frame(width: 58, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("ink-selection-action-" + id)
    }
}

/// The entire tool surface stays inside the viewport, on one of its four edges.
struct ToolDock: Equatable {
    enum Edge: String, CaseIterable {
        case top, bottom, left, right
        var isVertical: Bool { self == .left || self == .right }
    }
    func paletteSize(viewport: CGSize, expanded: Bool) -> CGSize {
        if !expanded { return CGSize(width: 60, height: 60) }
        return edge.isVertical
            ? CGSize(width: 56, height: min(440, max(60, viewport.height - 24)))
            : CGSize(width: min(430, max(60, viewport.width - 24)), height: 56)
    }
    var edge: Edge = .bottom
    var fraction: Double = 1
    static func limits(viewport: CGSize, tool: CGSize) -> CGRect {
        let x = min(viewport.width / 2, tool.width / 2 + 12)
        let y = min(viewport.height / 2, tool.height / 2 + 12)
        return CGRect(x: x, y: y, width: max(0, viewport.width - 2 * x), height: max(0, viewport.height - 2 * y))
    }
    func center(viewport: CGSize, tool: CGSize) -> CGPoint {
        let r = Self.limits(viewport: viewport, tool: tool)
        let t = min(1, max(0, fraction.isFinite ? fraction : 1))
        switch edge {
        case .top: return CGPoint(x: r.minX + r.width * t, y: r.minY)
        case .bottom: return CGPoint(x: r.minX + r.width * t, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.minY + r.height * t)
        case .right: return CGPoint(x: r.maxX, y: r.minY + r.height * t)
        }
    }
    static func nearest(to point: CGPoint, viewport: CGSize, tool: CGSize) -> Self {
        let r = limits(viewport: viewport, tool: tool)
        let x = min(r.maxX, max(r.minX, point.x)), y = min(r.maxY, max(r.minY, point.y))
        let choices: [(Edge, CGFloat)] = [(.top, abs(point.y - r.minY)), (.bottom, abs(point.y - r.maxY)), (.left, abs(point.x - r.minX)), (.right, abs(point.x - r.maxX))]
        let edge = choices.min { $0.1 < $1.1 }!.0
        let t = (edge == .top || edge == .bottom) ? (x - r.minX) / max(1, r.width) : (y - r.minY) / max(1, r.height)
        return Self(edge: edge, fraction: t)
    }
}
struct ToolObstacleKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}
extension View {
    func toolObstacle() -> some View { anchorPreference(key: ToolObstacleKey.self, value: .bounds) { [$0] } }
}

extension ToolDock {
    struct Placement {
        var dock: ToolDock
        var size: CGSize
        var center: CGPoint
        var expanded: Bool
    }
    /// Subtract occupied intervals from each edge, using that edge's FINAL size.
    static func resolve(point: CGPoint, viewport: CGRect, obstacles: [CGRect], expanded: Bool) -> Placement? {
        var candidates: [Placement] = []
        for edge in Edge.allCases {
            let dock = ToolDock(edge: edge, fraction: 0)
            let size = dock.paletteSize(viewport: viewport.size, expanded: expanded)
            guard size.width + 24 <= viewport.width, size.height + 24 <= viewport.height,
                  !expanded || (edge.isVertical ? size.height : size.width) >= 180 else { continue }
            let limits = limits(viewport: viewport.size, tool: size).offsetBy(dx: viewport.minX, dy: viewport.minY)
            let vertical = edge.isVertical
            let fixed = edge == .left ? limits.minX : edge == .right ? limits.maxX : edge == .top ? limits.minY : limits.maxY
            let low = vertical ? limits.minY : limits.minX, high = vertical ? limits.maxY : limits.maxX
            var intervals: [ClosedRange<CGFloat>] = [low...high]
            for obstacle in obstacles where !obstacle.isEmpty && !obstacle.isNull {
                let forbidden = obstacle.insetBy(dx: -size.width/2-6, dy: -size.height/2-6)
                guard vertical ? (forbidden.minX...forbidden.maxX).contains(fixed) : (forbidden.minY...forbidden.maxY).contains(fixed) else { continue }
                let a = vertical ? forbidden.minY : forbidden.minX, b = vertical ? forbidden.maxY : forbidden.maxX
                intervals = intervals.flatMap { range -> [ClosedRange<CGFloat>] in
                    if b < range.lowerBound || a > range.upperBound { return [range] }
                    var result: [ClosedRange<CGFloat>] = []
                    if a > range.lowerBound { result.append(range.lowerBound...min(range.upperBound,a)) }
                    if b < range.upperBound { result.append(max(range.lowerBound,b)...range.upperBound) }
                    return result
                }
            }
            for interval in intervals {
                let variable = min(interval.upperBound, max(interval.lowerBound, vertical ? point.y : point.x))
                let center = vertical ? CGPoint(x: fixed,y: variable) : CGPoint(x: variable,y: fixed)
                candidates.append(Placement(dock: ToolDock(edge: edge, fraction: Double((variable-low)/max(1,high-low))), size: size, center: center, expanded: expanded))
            }
        }
        if let best = candidates.min(by: { hypot($0.center.x-point.x,$0.center.y-point.y) < hypot($1.center.x-point.x,$1.center.y-point.y) }) { return best }
        return expanded ? resolve(point: point, viewport: viewport, obstacles: obstacles, expanded: false) : nil
    }
}

struct DockedDrawingTools: View {
    @ObservedObject var session: DrawingSession
    @AppStorage("inkTools.dock.edge") private var edge = "bottom"
    @AppStorage("inkTools.dock.fraction") private var fraction = 1.0
    @State private var expanded = true
    var obstacles: [CGRect] = []
    @State private var moving: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var compactTools = false
    var body: some View {
        GeometryReader { geometry in
            let dock = ToolDock(edge: ToolDock.Edge(rawValue: edge) ?? .bottom, fraction: fraction)
            let area = CGRect(origin: .zero, size: geometry.size).inset(by: UIEdgeInsets(top: geometry.safeAreaInsets.top, left: geometry.safeAreaInsets.leading, bottom: geometry.safeAreaInsets.bottom, right: geometry.safeAreaInsets.trailing))
            let desiredSize = dock.paletteSize(viewport: area.size, expanded: expanded)
            let desired = dock.center(viewport: area.size, tool: desiredSize)
            let requested = CGPoint(x: desired.x+area.minX, y: desired.y+area.minY)
            let placement = ToolDock.resolve(point: requested, viewport: area, obstacles: obstacles, expanded: expanded)
            if let placement {
                let size = placement.size
                let center = moving ?? placement.center
                DrawingToolsView(session: session, expanded: Binding(get: { placement.expanded }, set: { value in
                    if value && !placement.expanded && expanded { compactTools = true } else { expanded = value }
                }), vertical: placement.dock.edge.isVertical) { start, location, ended in
                    let origin = dragOrigin ?? placement.center
                    if dragOrigin == nil { dragOrigin = origin }
                    let target = CGPoint(x: origin.x + location.x-start.x, y: origin.y + location.y-start.y)
                    if ended {
                        if let final = ToolDock.resolve(point: target, viewport: area, obstacles: obstacles, expanded: expanded) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                edge = final.dock.edge.rawValue; fraction = final.dock.fraction; moving = nil
                            }
                        } else { moving = nil }
                        dragOrigin = nil
                    } else { moving = target }
                }
                .frame(width: size.width, height: size.height)
                .position(center)
                .popover(isPresented: $compactTools) {
                    DrawingToolsView(session: session, expanded: .constant(true))
                        .frame(width: min(430, geometry.size.width-24), height: 56).padding(8)
                }
                .accessibilityAction(named: "위쪽으로 이동") { edge = "top"; fraction = 0.5 }
                .accessibilityAction(named: "아래쪽으로 이동") { edge = "bottom"; fraction = 0.5 }
                .accessibilityAction(named: "왼쪽으로 이동") { edge = "left"; fraction = 0.5 }
                .accessibilityAction(named: "오른쪽으로 이동") { edge = "right"; fraction = 0.5 }
            }
            if session.selectedStrokeCount > 0,
               let selectionRect = session.selectionActionRect,
               selectionRect.intersects(CGRect(origin: .zero, size: geometry.size)) {
                let barSize = CGSize(width: min(430, max(60, geometry.size.width - 16)), height: 60)
                let size = placement?.size ?? desiredSize
                let paletteCenter = moving ?? placement?.center ?? requested
                let paletteFrame = CGRect(x: paletteCenter.x - size.width / 2, y: paletteCenter.y - size.height / 2,
                                          width: size.width, height: size.height)
                InkSelectionActionBar(session: session)
                    .frame(width: barSize.width, height: barSize.height)
                    .position(actionBarCenter(selection: selectionRect, viewport: geometry.size,
                                              bar: barSize, palette: paletteFrame))
            }
        }
        .coordinateSpace(name: "ink-tool-dock")
        .sheet(item: $session.selectedInkExport) { export in
            ShareSheet(urls: export.urls)
        }
    }

    private func actionBarCenter(selection: CGRect, viewport: CGSize, bar: CGSize, palette: CGRect) -> CGPoint {
        let margin: CGFloat = 8, gap: CGFloat = 12
        let x = min(max(selection.midX, bar.width / 2 + margin), viewport.width - bar.width / 2 - margin)
        let top = bar.height / 2 + margin
        let bottom = max(top, viewport.height - bar.height / 2 - margin)
        let above = selection.minY - bar.height / 2 - gap
        let below = selection.maxY + bar.height / 2 + gap
        let candidates = [above, below, top, bottom].filter { $0 >= top && $0 <= bottom }
        let y = candidates.first { value in
            !CGRect(x: x - bar.width / 2, y: value - bar.height / 2, width: bar.width, height: bar.height)
                .insetBy(dx: -4, dy: -4).intersects(palette)
        } ?? min(bottom, max(top, above))
        return CGPoint(x: x, y: y)
    }
}
