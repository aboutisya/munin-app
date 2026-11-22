import AppKit
import SwiftUI

/// «Мои заметки»: свободный текст к встрече. Хранится в `notes.md` в папке встречи и сохраняется сам.
struct NotesTab: View {
    let detail: MeetingDetail

    static let file = "notes.md"

    @State private var text = ""
    @State private var loadedFrom: URL?
    @State private var saved = true
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var url: URL { detail.folder.appending(path: Self.file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Видны только вам: в саммари и публичное не попадают.")
                    .font(.system(size: 13)).foregroundStyle(Theme.sec)
                Spacer()
                Text(saved ? (text.isEmpty ? "" : "Сохранено") : "Сохраняю…")
                    .font(.system(size: 12)).foregroundStyle(Theme.sec)
                    .contentTransition(.opacity)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Мысли, договорённости, ссылки — всё, что хочется сохранить к этой встрече.")
                        .font(.system(size: 15)).foregroundStyle(Theme.sec.opacity(0.7))
                        .padding(.horizontal, 21).padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 16).padding(.vertical, 16)
            }
            .frame(minHeight: 420)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.sec.opacity(0.5) : Theme.line))
        }
        .onAppear(perform: load)
        .onChange(of: detail.folder) { old, _ in flush(to: old.appending(path: Self.file)); load() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear { flush(to: loadedFrom) }
    }

    private func load() {
        pending?.cancel()
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadedFrom = url
        saved = true
    }

    /// Пишем через полсекунды после последнего нажатия, чтобы не дёргать диск на каждой букве.
    private func scheduleSave() {
        guard loadedFrom == url else { return }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if current == text { saved = true; return }
        saved = false
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write(text, to: url)
        }
    }

    private func flush(to target: URL?) {
        pending?.cancel()
        guard let target, !saved else { return }
        // Папку переименовали вместе с названием встречи — пишем по новому адресу.
        let dir = target.deletingLastPathComponent()
        write(text, to: FileManager.default.fileExists(atPath: dir.path) ? target : url)
    }

    private func write(_ value: String, to target: URL) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: target)
        } else {
            try? value.write(to: target, atomically: true, encoding: .utf8)
        }
        saved = true
    }
}
