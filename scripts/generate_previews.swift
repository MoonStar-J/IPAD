// Documentation illustrations based on LibraryView and EditorView.
// These are design previews, not screenshots captured from the iPad app.
// Run: swift scripts/generate_previews.swift docs/previews
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
let secondary = NSColor(srgbRed: 0.46, green: 0.48, blue: 0.52, alpha: 1)
let accent = NSColor(srgbRed: 0.235, green: 0.396, blue: 0.620, alpha: 1)
let border = NSColor(white: 0.85, alpha: 1)

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: NSColor, radius: CGFloat = 0) {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
}
func line(_ x: CGFloat, _ y: CGFloat, _ ex: CGFloat, _ ey: CGFloat, _ c: NSColor = border, width: CGFloat = 1) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: ex, y: ey))
    p.lineWidth = width; p.lineCapStyle = .round; c.setStroke(); p.stroke()
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 18, _ c: NSColor = ink,
          weight: NSFont.Weight = .regular, width: CGFloat = 1000, height: CGFloat = 70) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .paragraphStyle: paragraph
    ])
}
func icon(_ name: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 22, _ c: NSColor = accent) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c])) else { return }
    image.draw(in: NSRect(x: x, y: y, width: size, height: size), from: .zero, operation: .sourceOver,
               fraction: 1, respectFlipped: true, hints: nil)
}
func render(_ name: String, _ drawing: () -> Void) throws {
    let w = 1440, h = 1100
    guard let cg = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8,
                             bytesPerRow: w * 8, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Canvas failed") }
    cg.scaleBy(x: 2, y: 2); cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    box(0, 0, CGFloat(w), CGFloat(h), color(0xF7F8FA))
    drawing()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = cg.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
func frame(_ number: String, _ title: String, _ subtitle: String) {
    text(number + "  /  " + title, 44, 25, 29, ink, weight: .semibold)
    text(subtitle, 44, 69, 17, secondary)
    box(40, 122, 1360, 922, color(0xE1E4E9), radius: 25)
    box(40, 118, 1360, 920, .white, radius: 25)
    text("YE O B A E K   ·   디자인 미리보기 / 실제 앱 실행 캡처 아님", 44, 1062, 14, secondary)
}

try render("library") {
    frame("01", "보관함", "노트와 PDF를 한곳에. 폴더, 즐겨찾기, 검색으로 정리하세요.")
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 118, width: 1360, height: 920), xRadius: 25, yRadius: 25).addClip()
    box(40, 118, 258, 920, color(0xF0F1F4))
    box(298, 118, 1102, 920, color(0xF7F7FA))
    text("여백", 68, 148, 31, ink, weight: .bold)
    box(56, 212, 226, 48, color(0xDFE7F2), radius: 10)
    icon("square.grid.2x2", 72, 225); text("모든 노트", 107, 224, 19, accent, weight: .medium)
    text("4", 251, 227, 16, accent)
    icon("star", 72, 285); text("즐겨찾기", 107, 284, 19); text("2", 251, 287, 16, secondary)
    text("폴더", 72, 358, 14, secondary, weight: .semibold)
    for (i, title) in ["공부", "개인 기록"].enumerated() {
        let y = CGFloat(397 + i * 55)
        icon("folder", 72, y); text(title, 107, y - 1, 19); text("2", 251, y + 2, 16, secondary)
    }
    icon("folder.badge.plus", 72, 507); text("새로운 폴더", 107, 506, 18, accent)
    line(72, 570, 264, 570, color(0xDEE0E5))
    icon("trash", 72, 598); text("최근 삭제된 항목", 107, 597, 17); text("0", 251, 600, 16, secondary)
    icon("internaldrive", 84, 990, 17, secondary); text("이 iPad에 저장됨", 112, 988, 14, secondary)
    line(298, 118, 298, 1038, color(0xE0E2E6))
    text("모든 노트", 334, 153, 19, ink, weight: .semibold)
    icon("square.and.arrow.down", 1291, 151, 24)
    icon("square.and.pencil", 1344, 151, 24)
    line(298, 199, 1400, 199, color(0xE9E9EE))
    box(334, 222, 1030, 44, color(0xECECF1), radius: 11)
    icon("magnifyingglass", 351, 235, 18, secondary)
    text("노트 이름 또는 입력한 텍스트 검색", 383, 231, 17, secondary)
    text("생각이 머무는 곳.", 334, 311, 38, ink, weight: .medium)
    text("가볍게 펼치고, 자유롭게 기록하세요.", 336, 369, 18, secondary)
    text("4개의 노트", 336, 443, 16, secondary)
    icon("arrow.up.arrow.down", 1220, 445, 17); text("최근 수정순", 1249, 442, 16, accent)
    let names = ["미적분학", "생각 수집", "논문 읽기", "일상의 기록"]
    let colors = [0x4F73A3, 0x6E8C78, 0xB09169, 0xA67075]
    let pages = ["12페이지 · 2026. 9. 7.", "6페이지 · 2026. 9. 7.", "24페이지 · 2026. 9. 6.", "8페이지 · 2026. 9. 5."]
    for i in 0..<4 {
        let x = CGFloat(336 + i * 253), y: CGFloat = 488, w: CGFloat = 216, h: CGFloat = 277
        box(x, y + 6, w, h, color(0xE2E4EA), radius: 13)
        box(x, y, w, h, color(colors[i]), radius: 13)
        box(x + 12, y, 14, h, NSColor.black.withAlphaComponent(0.08))
        icon(i == 2 ? "doc.richtext" : "book.closed", x + 40, y + 29, 28, .white)
        if i < 2 { icon("star.fill", x + 181, y + 17, 15, .white) }
        text(names[i], x + 40, y + 188, 25, .white, weight: .medium, width: 170)
        text(i == 2 ? "PDF NOTEBOOK" : "NOTEBOOK", x + 40, y + 239, 10, .white.withAlphaComponent(0.75), weight: .semibold)
        text(names[i], x, y + h + 20, 18, ink, weight: .semibold)
        text(pages[i], x, y + h + 52, 14, secondary)
    }
    NSGraphicsContext.restoreGraphicsState()
}

try render("editor") {
    frame("02", "필기 화면", "종이에 집중하는 작업 공간. Apple Pencil 필기와 텍스트, PDF 메모를 담습니다.")
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 118, width: 1360, height: 920), xRadius: 25, yRadius: 25).addClip()
    box(40, 118, 1360, 920, color(0xEDEEF2))
    box(40, 118, 1360, 80, .white)
    icon("chevron.left", 68, 147, 21); text("보관함", 99, 145, 18, accent)
    icon("arrow.uturn.backward", 204, 146, 24)
    icon("arrow.uturn.forward", 252, 146, 24, color(0xBEC5D0))
    text("미적분학", 666, 146, 20, ink, weight: .semibold)
    icon("rectangle.stack", 1160, 146, 24)
    icon("plus", 1215, 146, 23)
    icon("square.and.arrow.up", 1269, 144, 25)
    icon("ellipsis.circle", 1327, 146, 24)
    line(40, 198, 1400, 198, color(0xDCDDE3))
    let px: CGFloat = 458, py: CGFloat = 227, pw: CGFloat = 524, ph: CGFloat = 699
    box(px - 3, py + 4, pw + 6, ph + 4, color(0xDEE0E5), radius: 3)
    box(px, py, pw, ph, .white)
    for y in stride(from: py + 55, to: py + ph - 20, by: 22) {
        line(px + 27, y, px + pw - 27, y, color(0xE2E7EC), width: 0.6)
    }
    text("CHAPTER 01", px + 44, py + 32, 11, accent, weight: .semibold)
    text("극한과 연속", px + 43, py + 69, 29, ink, weight: .semibold)
    text("함수의 변화를 이해하는 첫 번째 단계", px + 44, py + 114, 14, secondary)
    box(px + 41, py + 169, 287, 22, color(0xFFF0AB), radius: 3)
    text("가까워진다는 것과 같다는 것은 다르다.", px + 44, py + 164, 15, ink, weight: .medium)
    text("x가 a에 가까워질 때, f(x)가 L에 가까워지면", px + 44, py + 208, 14)
    text("함수의 극한은 L이라고 표현한다.", px + 44, py + 239, 14)
    text("lim  f(x) = L", px + 85, py + 296, 29, accent, weight: .medium)
    text("x → a", px + 90, py + 332, 13, accent)
    line(px + 67, py + 559, px + 303, py + 559, ink, width: 1.4)
    line(px + 94, py + 577, px + 94, py + 388, ink, width: 1.4)
    icon("chevron.right", px + 298, py + 552, 14, ink)
    icon("chevron.up", px + 87, py + 383, 14, ink)
    let curve = NSBezierPath()
    curve.move(to: NSPoint(x: px + 109, y: py + 546))
    curve.curve(to: NSPoint(x: px + 275, y: py + 409), controlPoint1: NSPoint(x: px + 177, y: py + 544), controlPoint2: NSPoint(x: px + 239, y: py + 477))
    accent.setStroke(); curve.lineWidth = 3; curve.lineCapStyle = .round; curve.stroke()
    text("y = x²", px + 301, py + 399, 20, accent)
    text("x", px + 315, py + 550, 14)
    text("y", px + 74, py + 371, 14)
    text("핵심 정리", px + 44, py + 605, 15, ink, weight: .semibold)
    text("극한값과 실제 함수값을 구분해서 생각하기.", px + 44, py + 639, 14)
    // Symbolic representation of the system PencilKit palette.
    box(454, 947, 532, 63, color(0xDFE1E6), radius: 24)
    box(454, 943, 532, 63, .white, radius: 24)
    let tools = ["pencil.tip", "pencil", "highlighter", "eraser", "lasso", "ruler"]
    for (i, name) in tools.enumerated() {
        let x = CGFloat(475 + 54 * i)
        if i == 0 { box(x - 6, 952, 43, 43, color(0xE4ECF7), radius: 11) }
        icon(name, x + 3, 960, 25, i == 0 ? accent : ink)
    }
    line(808, 955, 808, 991, color(0xE1E4E8))
    for (i, value) in [0x222833, 0x3C659E, 0xCE6666, 0xDAB64A].enumerated() {
        let x = CGFloat(829 + i * 36)
        box(x, 964, 22, 22, color(value), radius: 11)
        if i == 1 { icon("checkmark", x + 4, 968, 14, .white) }
    }
    box(40, 1008, 1360, 30, .white)
    icon("chevron.left", 68, 1018, 12, color(0xBAC0C9)); text("1 / 12", 98, 1015, 13, secondary)
    icon("chevron.right", 157, 1018, 12, accent)
    icon("checkmark.circle", 1202, 1017, 15, secondary); text("저장됨", 1225, 1014, 13, secondary)
    text("100%", 1320, 1014, 13, secondary)
    NSGraphicsContext.restoreGraphicsState()
}
print("Generated library.png and editor.png")
