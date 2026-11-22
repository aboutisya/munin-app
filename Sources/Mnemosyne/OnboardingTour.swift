import AppKit
import SwiftUI

/// Экраны знакомства перед настройкой: что умеет Мунин. Сценки анимированы, монохром, красный — только запись (§14).
/// При «Уменьшить движение» каждая сценка сразу показывает итоговый кадр.

// MARK: - Каркас экрана

/// Сцена сверху, заголовок, текст и три строки с иконками.
struct TourPage<Stage: View>: View {
    let title: String
    let text: String
    let points: [(icon: String, text: String)]
    @ViewBuilder let stage: () -> Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TourStage(content: stage)
            Text(title).font(.system(size: 24, weight: .bold)).tracking(-0.4).padding(.top, 26)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.sec)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: p.icon).font(.system(size: 13)).foregroundStyle(Theme.sec).frame(width: 18)
                        Text(p.text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 18)
        }
    }
}

/// Подложка сценки: светло-серая карточка во всю ширину.
struct TourStage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.side))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Карточка-окно внутри сценки.
private struct Card<Content: View>: View {
    var width: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.win))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

/// Серая полоска-заглушка текста.
private struct Bar: View {
    var width: CGFloat
    var height: CGFloat = 7
    var body: some View { Capsule().fill(Theme.line).frame(width: width, height: height) }
}

// MARK: - Сценарий анимации

/// Проигрывает шаги по кругу: `durations[i]` — сколько держать шаг i. При «Уменьшить движение» сразу ставит `still`.
@MainActor
func playScript(_ durations: [Double], still: Int, reduce: Bool,
                animation: Animation = .spring(duration: 0.45, bounce: 0.15), set: (Int) -> Void) async {
    if reduce { set(still); return }
    while !Task.isCancelled {
        for (i, d) in durations.enumerated() {
            withAnimation(animation) { set(i) }
            try? await Task.sleep(for: .seconds(d))
            if Task.isCancelled { return }
        }
    }
}

// MARK: - Ворон

/// Силуэт ворона из `Raven.swift`, вписанный в рамку.
struct RavenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let b = ravenBounds
        let s = min(rect.width / b.width, rect.height / b.height)
        let t = CGAffineTransform(translationX: rect.midX - b.midX * s, y: rect.midY - b.midY * s).scaledBy(x: s, y: s)
        return Path(ravenPath().cgPath).applying(t)
    }
}

// MARK: - 0. Приветствие

struct TourWelcome: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TourStage {
                ZStack {
                    if !reduce {
                        TimelineView(.animation) { tl in
                            let t = tl.date.timeIntervalSinceReferenceDate
                            ZStack {
                                ForEach(0..<3, id: \.self) { i in
                                    let p = (t / 3.2 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                                    Circle().strokeBorder(Theme.sec.opacity(0.35 * (1 - p)), lineWidth: 1)
                                        .frame(width: 96 + 220 * p, height: 96 + 220 * p)
                                }
                            }
                        }
                    }
                    BrandMark(size: 84)
                        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                        .scaleEffect(shown ? 1 : 0.6)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 12)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Мунин").font(.system(size: 30, weight: .bold)).tracking(-0.6)
                Text("помнит встречи за вас").font(.system(size: 20)).foregroundStyle(Theme.sec)
            }
            .padding(.top, 26)
            .opacity(shown ? 1 : 0)
            Text("Записывает встречу, расшифровывает её на этом Mac и через Claude Code готовит саммари, решения и задачи. Сначала покажу, что он умеет, потом три коротких шага настройки.")
                .font(.system(size: 15)).foregroundStyle(Theme.sec)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .opacity(shown ? 1 : 0)
            Text("Мунин — ворон Одина, его имя значит «память». Каждый день он облетал мир и рассказывал Одину, что видел. Этот делает то же со встречами.")
                .font(.system(size: 13)).foregroundStyle(Theme.sec).italic()
                .fixedSize(horizontal: false, vertical: true).padding(.top, 18)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            if reduce { shown = true } else { withAnimation(.spring(duration: 0.7, bounce: 0.3).delay(0.1)) { shown = true } }
        }
    }
}

// MARK: - 1. Запись

struct TourRecord: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 0 — ждём, 1 — нажали, 2 — пишем, 3 — остановили.
    @State private var step = 0
    @State private var started = Date()

    var body: some View {
        TourPage(
            title: "Запись в одно нажатие",
            text: "Мунин живёт в строке меню и не мешает звонку. Не нужно звать бота во встречу или давать доступ к экрану.",
            points: [
                ("command", "⌃⌥⌘R или ворон в строке меню — начать и остановить."),
                ("calendar", "Календарь напомнит о встрече и подставит название и участников."),
                ("waveform", "Ваш микрофон и звук Zoom, Толка или Meet пишутся отдельными дорожками."),
            ]
        ) {
            VStack(spacing: 0) {
                menuBar
                Spacer(minLength: 0)
                popover
                Spacer(minLength: 0)
            }
        }
        .task {
            await playScript([1.2, 0.35, 4.2, 1.6], still: 2, reduce: reduce) { s in
                if s == 2 { started = Date() }
                step = s
            }
        }
    }

    private var recording: Bool { step == 2 }

    /// Полоска строки меню с вороном.
    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").font(.system(size: 11))
            Image(systemName: "battery.75percent").font(.system(size: 12))
            ZStack(alignment: .topTrailing) {
                RavenShape().fill(Theme.ink).frame(width: 18, height: 14)
                if recording {
                    Circle().fill(Theme.red).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(step == 1 ? Theme.line : .clear))
            Text("11:00").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.win.opacity(0.7))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var popover: some View {
        Card(width: 300) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.sec)
                Text("Дизайн-ревью оплаты").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("11:00–11:30").font(.system(size: 12)).foregroundStyle(Theme.sec).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                track("Я", seed: 1)
                track("Собеседники", seed: 7)
            }
            .padding(.horizontal, 14).padding(.top, 12)

            HStack {
                timer
                Spacer()
                Text(recording ? "Остановить" : "Записать")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.red))
                    .scaleEffect(step == 1 ? 0.92 : 1)
            }
            .padding(14)
        }
        .offset(y: 6)
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let s = recording ? Int(tl.date.timeIntervalSince(started)) + 754 : (step == 3 ? 758 : 0)
            HStack(spacing: 6) {
                Circle().fill(recording ? Theme.red : Theme.line).frame(width: 7, height: 7)
                Text(String(format: "%02d:%02d", s / 60, s % 60))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(recording ? Theme.ink : Theme.sec)
                    .contentTransition(.numericText())
            }
        }
    }

    /// Дорожка: подпись и «живые» столбики, пока идёт запись.
    private func track(_ name: String, seed: Double) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 11)).foregroundStyle(Theme.sec).frame(width: 78, alignment: .leading)
            TimelineView(.animation(paused: !recording || reduce)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<36, id: \.self) { i in
                        let x = Double(i)
                        let v = recording || reduce
                            ? 0.25 + 0.75 * abs(sin(x * 0.7 + seed + t * 3.1) * sin(x * 0.23 + seed * 2 + t * 1.7))
                            : 0.08
                        Capsule().fill(Theme.ink.opacity(recording || reduce ? 0.75 : 0.25))
                            .frame(width: 3, height: max(2, 20 * v))
                    }
                }
                .frame(height: 20)
            }
        }
    }
}

// MARK: - 2. Расшифровка

struct TourTranscript: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 0 — пусто, 1…4 — появляются реплики, 5 — спикеры узнаны по именам, 6 — держим.
    @State private var step = 0

    private let lines: [(ts: String, voice: String, name: String, text: String)] = [
        ("00:12", "Я", "Я", "Начнём с экрана оплаты, Анна обновила макет."),
        ("00:19", "Спикер 2", "Анна", "Да, убрала второй шаг — карта теперь сразу на первом."),
        ("00:34", "Спикер 3", "Павел", "Для бэкенда это ок, но нужен новый статус платежа."),
        ("00:47", "Я", "Я", "Тогда фиксируем: делаем один шаг, Павел заводит статус."),
    ]

    var body: some View {
        TourPage(
            title: "Расшифровка без облака",
            text: "Whisper распознаёт речь прямо на Mac. Аудио и транскрипт лежат в вашей папке и никуда не отправляются.",
            points: [
                ("person.2.wave.2", "Мунин различает спикеров, узнаёт вас по голосу и подсказывает имена остальных."),
                ("play.circle", "Клик по таймкоду — и запись играет с этой реплики."),
                ("lock", "Работает без интернета: расшифровке нужна только модель на диске."),
            ]
        ) {
            HStack(spacing: 18) {
                chip
                Card(width: 400) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            if step > i {
                                row(l, named: step >= 5)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            }
                        }
                    }
                    .padding(14)
                    .frame(height: 188, alignment: .topLeading)
                }
            }
        }
        .task { await playScript([0.6, 0.9, 0.9, 0.9, 1.1, 2.6, 0.6], still: 5, reduce: reduce) { step = $0 } }
    }

    /// Значок «на этом Mac» с бегущей волной.
    private var chip: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.win)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                    .frame(width: 84, height: 64)
                Image(systemName: "laptopcomputer").font(.system(size: 30, weight: .light))
                Image(systemName: "lock.fill").font(.system(size: 9)).offset(y: -3)
            }
            Text(step >= 1 && step <= 4 ? "Распознаю…" : "На этом Mac")
                .font(.system(size: 11)).foregroundStyle(Theme.sec).contentTransition(.opacity)
        }
    }

    private func row(_ l: (ts: String, voice: String, name: String, text: String), named: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(l.ts).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.sec)
            Text(named ? l.name : l.voice)
                .font(.system(size: 12, weight: l.name == "Я" ? .bold : .semibold))
                .foregroundStyle(named || l.name == "Я" ? Theme.ink : Theme.sec)
                .contentTransition(.opacity)
                .frame(width: 62, alignment: .leading)
            Text(l.text).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 3. Разбор

struct TourAnalysis: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 0 — думает, 1 — коротко, 2 — решения, 3 — задачи, 4 — схема, 5 — задача отмечена, 6 — держим.
    @State private var step = 0

    var body: some View {
        TourPage(
            title: "Саммари, решения и задачи",
            text: "Claude Code разбирает транскрипт по вашей подписке, без API-ключей: о чём договорились, кто что делает и к какому сроку.",
            points: [
                ("checklist", "Задачи со всех встреч собираются в один список, их можно отмечать."),
                ("point.3.connected.trianglepath.dotted", "Схемы процессов и решений — отдельной вкладкой, картинкой."),
                ("text.bubble", "Обратная связь по вашей речи: тональность и что улучшить."),
            ]
        ) {
            HStack(alignment: .top, spacing: 14) {
                Card(width: 330) { doc }
                Card(width: 170) { diagram }
            }
            .padding(.vertical, 18)
        }
        .task { await playScript([1.3, 0.8, 0.8, 0.9, 1.2, 2.4, 0.6], still: 5, reduce: reduce) { step = $0 } }
    }

    private var doc: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 11))
                    .symbolEffect(.pulse, isActive: step == 0 && !reduce)
                Text(step == 0 ? "Claude анализирует встречу…" : "Дизайн-ревью оплаты")
                    .font(.system(size: 13, weight: .semibold)).contentTransition(.opacity)
            }
            section("Коротко", on: step >= 1) {
                Text("Оплата сокращается до одного шага, нужен новый статус платежа.").font(.system(size: 12))
            } placeholder: { VStack(alignment: .leading, spacing: 5) { Bar(width: 260); Bar(width: 180) } }
            section("Решения", on: step >= 2) {
                Text("— Карта вводится на первом шаге").font(.system(size: 12))
            } placeholder: { Bar(width: 200) }
            section("Задачи", on: step >= 3) {
                VStack(alignment: .leading, spacing: 5) {
                    task("Завести статус «ожидает 3DS»", who: "Павел · до пт", done: step >= 5)
                    task("Обновить макет в Figma", who: "Анна · завтра", done: false)
                }
            } placeholder: { VStack(alignment: .leading, spacing: 5) { Bar(width: 230); Bar(width: 190) } }
        }
        .padding(14)
    }

    private func section<A: View, B: View>(_ cap: String, on: Bool, @ViewBuilder content: () -> A,
                                           @ViewBuilder placeholder: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(cap).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sec)
            ZStack(alignment: .topLeading) {
                placeholder().opacity(on ? 0 : 1)
                content().opacity(on ? 1 : 0).offset(y: on ? 0 : 4)
            }
        }
    }

    private func task(_ text: String, who: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                .foregroundStyle(done ? Theme.ink : Theme.sec)
                .contentTransition(.symbolEffect(.replace))
            Text(text).font(.system(size: 12)).strikethrough(done, color: Theme.sec)
                .foregroundStyle(done ? Theme.sec : Theme.ink)
            Text(who).font(.system(size: 11)).foregroundStyle(Theme.sec)
        }
    }

    /// Мини-схема: три узла, связи прорисовываются.
    private var diagram: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Схема").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sec)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 71, y: 26)); p.addLine(to: CGPoint(x: 71, y: 66))
                    p.move(to: CGPoint(x: 71, y: 92)); p.addLine(to: CGPoint(x: 34, y: 132))
                    p.move(to: CGPoint(x: 71, y: 92)); p.addLine(to: CGPoint(x: 108, y: 132))
                }
                .trim(from: 0, to: step >= 4 ? 1 : 0)
                .stroke(Theme.sec, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                node("Карта", at: CGPoint(x: 71, y: 14), on: step >= 4)
                node("Оплата", at: CGPoint(x: 71, y: 79), on: step >= 4)
                node("Успех", at: CGPoint(x: 34, y: 145), on: step >= 4)
                node("3DS", at: CGPoint(x: 108, y: 145), on: step >= 4)
            }
            .frame(width: 142, height: 160)
            .animation(.easeInOut(duration: 0.9), value: step)
        }
        .padding(14)
    }

    private func node(_ t: String, at p: CGPoint, on: Bool) -> some View {
        Text(t).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .scaleEffect(on ? 1 : 0.7).opacity(on ? 1 : 0.25)
            .position(p)
    }
}

// MARK: - 4. Отправка

struct TourShare: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let messenger: String
    /// 0 — саммари, 1 — нажали, 2 — скопировано, 3 — сообщение в чате, 4 — держим.
    @State private var step = 0

    var body: some View {
        TourPage(
            title: "Итоги — коллегам за секунду",
            text: "Для чата Мунин готовит отдельную версию: без личных заметок, вычитанную и размеченную под ваш мессенджер.",
            points: [
                ("doc.on.doc", "Одна кнопка копирует текст, схемы вставляются картинками."),
                ("magnifyingglass", "Поиск по всем встречам находит, кто и когда это сказал."),
                ("folder", "Всё хранится в обычной папке: markdown и аудио, их легко забрать."),
            ]
        ) {
            HStack(alignment: .center, spacing: 16) {
                Card(width: 240) { summary }
                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(Theme.sec)
                    .opacity(step >= 2 ? 1 : 0.3)
                Card(width: 250) { chat }
            }
        }
        .task { await playScript([1.4, 0.3, 0.9, 3.0, 0.5], still: 3, reduce: reduce) { step = $0 } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Публичное саммари").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sec)
            Text("Дизайн-ревью оплаты").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) { Bar(width: 200); Bar(width: 170); Bar(width: 185) }
            HStack(spacing: 5) {
                if step >= 2 { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).transition(.scale) }
                Text(step >= 2 ? "Скопировано" : "Копировать публичное").contentTransition(.opacity)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.win)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink))
            .scaleEffect(step == 1 ? 0.93 : 1)
            .padding(.top, 4)
        }
        .padding(14)
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "number").font(.system(size: 11)).foregroundStyle(Theme.sec)
                Text("payments-team").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(messenger).font(.system(size: 10)).foregroundStyle(Theme.sec)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                bubble(name: "Павел")
                if step >= 3 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Вы").font(.system(size: 10, weight: .semibold))
                        Text("**Дизайн-ревью оплаты**").font(.system(size: 11))
                        Text("— Оплата в один шаг\n— Павел: статус 3DS, до пт")
                            .font(.system(size: 11)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hover))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
            .frame(height: 150)

            HStack {
                Text(step == 2 ? "⌘V" : "Сообщение").font(.system(size: 11)).foregroundStyle(Theme.sec)
                    .contentTransition(.opacity)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .padding([.horizontal, .bottom], 10)
        }
    }

    private func bubble(name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 10, weight: .semibold))
            Text("Скиньте итоги, плиз").font(.system(size: 11))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}
