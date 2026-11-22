import AppKit
import MnemosyneCore
import SwiftUI

/// «Транскрипт»: тонкий плеер и реплики. Клик по реплике — воспроизвести с её начала.
struct TranscriptTab: View {
    let library: LibraryModel
    let detail: MeetingDetail
    let proxy: ScrollViewProxy
    @State private var filter = ""
    @State private var searching = false

    var body: some View {
        let player = library.player
        VStack(alignment: .leading, spacing: 16) {
            playerBar(player)
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.sec)
                    TextField("Найти в транскрипте", text: $filter).textFieldStyle(.plain)
                    Button("Готово") { searching = false; filter = "" }.buttonStyle(.plain).foregroundStyle(Theme.sec)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hover))
            }
            if let t = detail.transcript {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines(t).enumerated()), id: \.offset) { _, u in
                        line(u, transcript: t, player: player).id(u.start)
                    }
                }
                if lines(t).isEmpty {
                    Text(filter.isEmpty ? "В записи не распознано ни одной реплики." : "Ничего не нашлось.")
                        .foregroundStyle(Theme.sec)
                }
            } else {
                Text(detail.meta.status.needsProcessing ? "Запись ещё распознаётся." : "Транскрипта нет.")
                    .font(.system(size: 15)).foregroundStyle(Theme.sec)
            }
        }
        .onAppear {
            player.ensureLoaded(detail)
            // Переход по таймкоду с другой вкладки: вкладка создаётся уже с целью прокрутки.
            if player.scrollTarget != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scroll(to: player.scrollTarget) }
            }
        }
        .onChange(of: player.scrollTarget) { _, target in scroll(to: target) }
        .background(Button("") { searching = true }.keyboardShortcut("f").opacity(0))
    }

    private func scroll(to target: Double?) {
        guard let target, let t = detail.transcript else { return }
        let u = t.utterances.last { $0.start <= target + 0.5 } ?? t.utterances.first
        if let u { withAnimation { proxy.scrollTo(u.start, anchor: .center) } }
        library.player.scrollTarget = nil
    }

    private func lines(_ t: Transcript) -> [Utterance] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return t.utterances }
        return t.utterances.filter { $0.text.lowercased().contains(q) || (t.speaker($0.speaker)?.label.lowercased().contains(q) ?? false) }
    }

    private func playerBar(_ player: PlayerModel) -> some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.win)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .disabled(player.unavailable)
            .keyboardShortcut(.space, modifiers: [])

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line).frame(height: 3)
                    Capsule().fill(Theme.ink)
                        .frame(width: player.duration > 0 ? geo.size.width * CGFloat(min(1, player.current / player.duration)) : 0, height: 3)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { p in
                    guard player.duration > 0 else { return }
                    player.seek(to: Double(p.x / geo.size.width) * player.duration, play: player.isPlaying)
                }
            }
            .frame(height: 32)

            Text(player.unavailable ? "Аудио удалено" : "\(TranscriptMarkdown.timestamp(player.current).dropFirstHours) / \(TranscriptMarkdown.timestamp(player.duration).dropFirstHours)")
                .font(Theme.mono).foregroundStyle(Theme.sec)

            Button { searching.toggle() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.hover))
            }
            .buttonStyle(.plain)
            .help("Найти в транскрипте (⌘F)")
        }
    }

    private func line(_ u: Utterance, transcript t: Transcript, player: PlayerModel) -> some View {
        let active = player.isPlaying || player.current > 0 ? (player.current >= u.start && player.current < u.end + 0.5) : false
        return Button {
            player.ensureLoaded(detail)
            player.seek(to: u.start, play: true)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(TranscriptMarkdown.timestamp(u.start).dropFirstHours)
                    .font(Theme.mono).foregroundStyle(Theme.sec)
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.speaker(u.speaker)?.label ?? u.speaker).font(.system(size: 13, weight: .semibold))
                    Text(u.text).font(.system(size: 15)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Скопировать реплику") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(TranscriptMarkdown.timestamp(u.start))] \(t.speaker(u.speaker)?.label ?? ""): \(u.text)", forType: .string)
            }
        }
    }
}

extension String {
    /// `00:14:55` → `14:55`.
    var dropFirstHours: String { hasPrefix("00:") && count == 8 ? String(dropFirst(3)) : self }
}
