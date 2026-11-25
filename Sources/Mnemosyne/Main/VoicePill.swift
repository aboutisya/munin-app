import AVFoundation
import MnemosyneCore
import SwiftUI

/// Проигрыватель слепков голоса: одновременно звучит один, прогресс — для полоски-волны.
@MainActor @Observable
final class SamplePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingId: String?
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var envelopes: [URL: [Float]] = [:]
    @ObservationIgnored private var durations: [URL: Double] = [:]

    func toggle(_ id: String, url: URL) {
        if playingId == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingId = id
        progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingId = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    func envelope(_ url: URL, bars: Int) -> [Float] {
        if let e = envelopes[url], e.count == bars { return e }
        let e = VoiceSamples.envelope(url, count: bars)
        envelopes[url] = e
        return e
    }

    func duration(_ url: URL) -> Double {
        if let d = durations[url] { return d }
        let d = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        durations[url] = d
        return d
    }

    /// Файл слепка пересоздали — забыть волну и длительность.
    func forget(_ url: URL) {
        envelopes[url] = nil
        durations[url] = nil
    }
}

/// Капсула со слепком голоса: кнопка, волна, длительность. Файл может готовиться асинхронно
/// (слепок неизвестного голоса вырезается из аудио встречи при первом показе).
struct VoicePill: View {
    let id: String
    var large = false
    let player: SamplePlayer
    let resolve: () async -> URL?

    @State private var url: URL?
    @State private var missing = false
    @State private var hovering = false

    private var bars: Int { large ? 34 : 18 }

    var body: some View {
        Group {
            if missing {
                Text("аудио удалено").font(.system(size: 12)).foregroundStyle(Theme.sec)
            } else {
                Button { if let url { player.toggle(id, url: url) } } label: { content }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .help("Послушать")
            }
        }
        .task(id: id) {
            if let u = await resolve() { url = u } else { missing = true }
        }
    }

    private var content: some View {
        let playing = player.playingId == id
        let env = url.map { player.envelope($0, bars: bars) } ?? []
        let h: CGFloat = large ? 20 : 16
        let total = url.map { player.duration($0) } ?? 0
        let shown = playing ? total * player.progress : total
        return HStack(spacing: large ? 10 : 8) {
            ZStack {
                Circle().fill(Theme.ink)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 10 : 8)).foregroundStyle(Theme.win)
                    .offset(x: playing ? 0 : 0.5)
            }
            .frame(width: large ? 24 : 20, height: large ? 24 : 20)
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let v = i < env.count ? CGFloat(env[i]) : 0.15
                    let played = playing && Double(i) / Double(bars) < player.progress
                    Capsule().fill(played ? Theme.ink : Theme.sec.opacity(0.35))
                        .frame(width: 2, height: max(3, v * h))
                }
            }
            .frame(height: h)
            Text(Self.time(shown)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.sec)
                .frame(minWidth: 26, alignment: .leading)
        }
        .padding(.leading, large ? 6 : 4).padding(.trailing, large ? 14 : 12)
        .frame(height: large ? 36 : 28)
        .background(Capsule().fill(hovering ? Theme.hoverSoft : .clear))
        .overlay(Capsule().strokeBorder(Theme.line))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }
}
