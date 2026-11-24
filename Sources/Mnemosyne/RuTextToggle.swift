import AppKit
import MnemosyneCore
import SwiftUI

/// «Вычитывать через ru-text»: необязательный сторонний скилл. Не установлен — переключатель неактивен.
struct RuTextToggle: View {
    let settings: AppSettings
    @State private var on: Bool
    private let installed = SkillInstaller.isInstalled("ru-text")

    init(settings: AppSettings) {
        self.settings = settings
        _on = State(initialValue: settings.useRuText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Вычитывать через ru-text", isOn: $on)
                .disabled(!installed)
                .onChange(of: on) { _, v in settings.useRuText = v }
            HStack(spacing: 6) {
                Text(installed
                     ? String(localized: "Сторонний скилл редактуры русского текста. Текст чище, но встреча обходится примерно на 25 тыс. токенов дороже, плюс 50 тыс. читаются из кэша.")
                     : String(localized: "Не установлен — Claude вычитает текст сам. ru-text — сторонний скилл редактуры русского текста."))
                    .font(.system(size: 12)).foregroundStyle(Theme.sec)
                    .fixedSize(horizontal: false, vertical: true)
                if !installed {
                    LinkButton(String(localized: "Что это")) { NSWorkspace.shared.open(URL(string: "https://ru-text.org")!) }
                }
            }
        }
    }
}
