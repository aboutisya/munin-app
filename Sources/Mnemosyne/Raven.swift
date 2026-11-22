import AppKit

/// Силуэт ворона в координатах 1024×1024, ось Y вниз (как в SVG). Сидит на ветке, смотрит влево.
/// Общий для иконки приложения (`make icon`) и значка в строке меню.
func ravenPath() -> NSBezierPath {
    let p = NSBezierPath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    p.move(to: pt(206, 384))                                                                  // кончик клюва с крючком
    p.curve(to: pt(372, 300), controlPoint1: pt(250, 352), controlPoint2: pt(318, 312))       // верх клюва переходит в лоб
    p.curve(to: pt(522, 292), controlPoint1: pt(420, 262), controlPoint2: pt(486, 262))       // темя
    p.curve(to: pt(668, 450), controlPoint1: pt(586, 330), controlPoint2: pt(630, 384))       // спина
    p.curve(to: pt(812, 676), controlPoint1: pt(726, 540), controlPoint2: pt(776, 610))       // к хвосту
    p.line(to: pt(864, 782))                                                                  // клин хвоста
    p.line(to: pt(804, 790))
    p.curve(to: pt(700, 690), controlPoint1: pt(770, 748), controlPoint2: pt(736, 712))       // низ хвоста
    p.curve(to: pt(548, 690), controlPoint1: pt(650, 712), controlPoint2: pt(596, 712))       // брюхо
    p.curve(to: pt(410, 548), controlPoint1: pt(474, 664), controlPoint2: pt(426, 610))       // грудь
    // Взъерошенные перья на горле — примета ворона.
    p.line(to: pt(392, 530)); p.line(to: pt(404, 510)); p.line(to: pt(380, 492))
    p.line(to: pt(392, 472)); p.line(to: pt(364, 452)); p.line(to: pt(372, 432))
    p.curve(to: pt(318, 398), controlPoint1: pt(346, 414), controlPoint2: pt(334, 404))
    p.curve(to: pt(214, 398), controlPoint1: pt(282, 396), controlPoint2: pt(240, 402))       // низ клюва
    p.curve(to: pt(206, 384), controlPoint1: pt(206, 396), controlPoint2: pt(202, 390))       // крючок
    p.close()
    // Лапы и ветка.
    p.append(NSBezierPath(roundedRect: NSRect(x: 560, y: 676, width: 16, height: 76), xRadius: 8, yRadius: 8))
    p.append(NSBezierPath(roundedRect: NSRect(x: 602, y: 678, width: 16, height: 74), xRadius: 8, yRadius: 8))
    p.append(NSBezierPath(roundedRect: NSRect(x: 452, y: 742, width: 300, height: 20), xRadius: 10, yRadius: 10))
    return p
}

/// Линия крыла — прорезь цветом плашки.
func ravenWing() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 500, y: 430))
    p.curve(to: NSPoint(x: 790, y: 700), controlPoint1: NSPoint(x: 600, y: 470), controlPoint2: NSPoint(x: 720, y: 560))
    p.lineWidth = 12
    p.lineCapStyle = .round
    return p
}

/// Габариты силуэта (ось Y вниз): для значка в строке меню.
let ravenBounds = CGRect(x: 206, y: 262, width: 658, height: 528)
