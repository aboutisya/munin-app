// Иконка «Мунина»: светлый силуэт ворона Одина на чёрной плашке.
// Запуск: cat Sources/Mnemosyne/Raven.swift scripts/make-icon.swift > /tmp/icon.swift && swift /tmp/icon.swift Resources/AppIcon.icns
// (make icon делает то же самое)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let set = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Сетка macOS: плашка 824×824 с отступом 100, скругление ~185.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1))!
        .draw(in: shape, angle: -90)
    // Тонкий блик по верхней кромке, чтобы плашка не была плоской.
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 183 * s, yRadius: 183 * s)
    rim.lineWidth = 3 * s
    rim.stroke()

    // Ворон: путь в координатах 1024 с осью Y вниз — переворачиваем и чуть сдвигаем к центру плашки.
    NSGraphicsContext.current?.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 0, yBy: CGFloat(px))
    t.scaleX(by: s, yBy: -s)
    t.translateX(by: 505, yBy: 522)   // центр силуэта — в центр плашки
    t.scale(by: 0.86)
    t.translateX(by: -535, yBy: -526)
    t.concat()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    ravenPath().fill()
    let plate = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    if px >= 64 {
        plate.setStroke()
        ravenWing().stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: set.appending(path: "icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? draw(1024).write(to: out.deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "Готово: \(out.path)" : "iconutil: ошибка \(p.terminationStatus)")
