import AppKit
import SwiftUI

/// Токены из макета (монохром, один акцентный красный). Светлая и тёмная тема.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let win = dynamic(0xFFFFFF, 0x161617)
    static let side = dynamic(0xFAFAF9, 0x1B1B1C)
    static let ink = dynamic(0x111111, 0xF2F2F2)
    static let sec = dynamic(0x6B6B6B, 0xA0A0A0)
    static let line = dynamic(0xECECEA, 0x2A2A2B)
    static let hover = dynamic(0xF3F3F1, 0x242426)
    /// Наведение: светлее выбранного, чтобы выбранная строка оставалась заметной.
    static let hoverSoft = dynamic(0xF7F7F5, 0x1F1F21)
    static let red = Palette.red

    static let column: CGFloat = 760
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// Подпись раздела: «Коротко», «Решения».
struct SectionCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sec)
    }
}

/// Серый моноширинный таймкод; клик — перейти к реплике.
struct Timestamp: View {
    let text: String
    let action: (() -> Void)?
    init(_ text: String, action: (() -> Void)? = nil) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Button { action?() } label: {
            Text(Timestamp.short(text)).font(Theme.mono)
        }
        .buttonStyle(TimestampStyle())
        .disabled(action == nil)
        .help("Перейти к реплике")
    }

    /// `00:14:55` → `14:55`, `01:02:03` остаётся.
    static func short(_ ts: String) -> String {
        ts.hasPrefix("00:") && ts.count == 8 ? String(ts.dropFirst(3)) : ts
    }

    static func seconds(_ ts: String) -> Double? {
        let parts = ts.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

/// Кружок с инициалами.
struct Avatar: View {
    let name: String
    var body: some View {
        Text(Avatar.initials(name))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.sec)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.hover))
            .overlay(Circle().strokeBorder(Theme.win, lineWidth: 2))
    }

    static func initials(_ name: String) -> String {
        if name == "Я" { return "Я" }
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// Таймкод: серый, при наведении — чёрный на светлой подложке.
struct TimestampStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering && enabled ? Theme.ink : Theme.sec)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering && enabled ? Theme.hover : .clear))
                .padding(.horizontal, -5).padding(.vertical, -1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Кнопка-пилюля из макета: серая или чёрная. Неактивная — контур без заливки.
struct Pill: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, dark: dark) }

    struct Styled: View {
        let configuration: Configuration
        let dark: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: dark ? .semibold : .regular))
                .foregroundStyle(!enabled ? Theme.sec : dark ? Theme.win : Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(
                    Capsule().fill(!enabled ? Color.clear : dark ? Theme.ink.opacity(hovering ? 0.86 : 1) : (hovering ? Theme.line : Theme.hover))
                )
                .overlay(Capsule().strokeBorder(enabled ? Color.clear : Theme.line))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Мягкая подсветка строки при наведении.
struct HoverHighlight: ViewModifier {
    var selected = false
    var radius: CGFloat = 8
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(selected ? Theme.hover : hovering ? Theme.hoverSoft : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

extension View {
    func hoverHighlight(selected: Bool = false, radius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(selected: selected, radius: radius))
    }
}

/// Знак «Мунина» — иконка приложения без системных полей: ворон на чёрной плашке.
struct BrandMark: View {
    var size: CGFloat = 22
    /// Плашка занимает 824 из 1024 пикселей иконки — увеличиваем, чтобы поля ушли за край.
    private static let plate: CGFloat = 1024 / 824

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * Self.plate, height: size * Self.plate)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// Подчёркнутая серая ссылка: «Изменить», «Добавить».
struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).underline().foregroundStyle(Theme.sec)
        }
        .buttonStyle(.plain)
    }
}

/// Строка списка: «—» или кружок задачи, текст, таймкод справа.
struct ListRow<Lead: View, Content: View>: View {
    let lead: Lead
    let content: Content
    let ts: String?
    let jump: ((String) -> Void)?

    init(ts: String?, jump: ((String) -> Void)?, @ViewBuilder lead: () -> Lead, @ViewBuilder content: () -> Content) {
        self.ts = ts
        self.jump = jump
        self.lead = lead()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            lead
            content.frame(maxWidth: .infinity, alignment: .leading)
            if let ts, !ts.isEmpty { Timestamp(ts) { jump?(ts) } }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
    }
}
