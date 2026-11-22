#!/usr/bin/env python3
"""Демо-встреча «Мунина» со всеми заполненными вкладками — посмотреть, как выглядит готовая карточка.

Запуск: python3 scripts/make-demo.py [папка встреч, по умолчанию ~/Meetings]
Потом: MNEMOSYNE_RERENDER=<id> build/Мунин.app/Contents/MacOS/Mnemosyne — Markdown и PNG диаграмм.
Удалить: папка «… Демо: синк по квотам экспериментов» в Корзину.

Звук: реплики озвучены голосом Milena (`say`), разные собеседники — сдвигом высоты тона.
"""
import json, os, shutil, struct, subprocess, sys, tempfile, uuid, wave
from datetime import datetime, timezone, timedelta

ROOT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Meetings")
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
SR = 48000
LOCAL = datetime.now().astimezone().tzinfo
START = datetime(2026, 11, 20, 11, 0, tzinfo=LOCAL)
TITLE = "Демо: синк по квотам экспериментов"
MEETING_ID = "D3E0D3E0-0000-4000-8000-000000000001"

# Кто говорит: (дорожка, высота тона, темп). me — мой микрофон, остальные — звонок.
VOICES = {
    "me": ("me", 0.86, 1.08),
    "others:S1": ("others", 1.0, 1.0),     # Мария
    "others:S2": ("others", 0.78, 1.04),   # Олег
    "others:S3": ("others", 1.12, 0.98),   # безымянная собеседница
}

LINES = [
    ("me", "Всем привет. Сегодня решаем, что делаем с квотами трафика: три команды за неделю упёрлись в лимит и не смогли запустить эксперименты."),
    ("others:S1", "Я посмотрела данные. За ноябрь квоту исчерпывали двенадцать раз, и в девяти случаях трафик держали эксперименты, которые уже набрали выборку."),
    ("others:S2", "То есть проблема не в размере квоты, а в том, что никто не останавливает завершённые тесты."),
    ("others:S1", "Да. Если освобождать трафик автоматически, когда эксперимент набрал мощность, текущих квот хватит."),
    ("me", "Звучит разумно. Олег, сколько займёт автоматическое освобождение?"),
    ("others:S2", "Если делать нормально, с уведомлением владельца и окном на отмену, то две недели. Быстрый вариант за три дня, но без отмены."),
    ("me", "Без отмены рискованно. Кто-то держит эксперимент дольше осознанно, например ради долгосрочных метрик."),
    ("others:S2", "Тогда две недели, и это не обсуждается. Я не буду выкатывать то, что выключает чужие тесты без спроса."),
    ("me", "Хорошо, никто не просит выкатывать сырое. Давайте поймём, что нам нужно к релизу двадцать седьмого."),
    ("others:S1", "Мне кажется, к релизу достаточно отчёта: список экспериментов, которые набрали выборку и всё ещё держат трафик. Владельцы сами их остановят."),
    ("others:S2", "Отчёт сделаю за два дня, данные уже есть в конфигураторе."),
    ("others:S3", "Можно ещё в интерфейсе подсветить такие эксперименты: жёлтый бейдж «выборка набрана». Это полдня работы."),
    ("me", "Отлично. Тогда фиксируем: к двадцать седьмому отчёт и бейдж, автоматическое освобождение в следующий спринт."),
    ("others:S2", "Согласен."),
    ("others:S1", "Согласна. Только давайте договоримся, что считаем «набрал выборку»: по MDE из дизайна эксперимента, а не по календарю."),
    ("me", "Да, по MDE. Мария, напишешь короткое правило, чтобы Олег мог его закодить?"),
    ("others:S1", "Напишу до вторника."),
    ("me", "И ещё. Я в прошлый раз сказал, что квоты просто поднимем, и этим всех запутал. Беру на себя сообщение в канал, что меняем подход."),
    ("others:S2", "Было бы хорошо. Ко мне уже приходили с вопросом, почему квоты до сих пор не подняли."),
    ("me", "Сегодня напишу. Дмитрию тоже перешлю, он отвечает за клиентские квоты в он-прем."),
    ("others:S1", "Тогда всё. Созвонимся в среду, посмотрим на отчёт."),
    ("me", "Спасибо всем."),
]


def synth(text, pitch, tempo, tmp):
    aiff = os.path.join(tmp, "l.aiff")
    raw = os.path.join(tmp, "l.raw")
    subprocess.run(["say", "-v", "Milena", "-o", aiff, text], check=True)
    # Сдвиг высоты: asetrate меняет и тон, и скорость; atempo возвращает скорость.
    af = f"aresample=22050,asetrate=22050*{pitch},aresample={SR},atempo={1 / pitch * tempo:.4f}"
    subprocess.run([FFMPEG, "-loglevel", "error", "-y", "-i", aiff, "-af", af, "-ac", "1", "-ar", str(SR),
                    "-f", "s16le", raw], check=True)
    return open(raw, "rb").read()


def ts(sec):
    s = int(sec)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def main():
    folder = os.path.join(ROOT, START.strftime("%Y-%m-%d_%H%M_") + TITLE.replace(":", " -"))
    if os.path.exists(folder):
        shutil.rmtree(folder)
    os.makedirs(folder)
    tmp = tempfile.mkdtemp()

    # 1. Озвучка и таймлайн.
    tracks = {"me": bytearray(), "others": bytearray()}
    utterances, t = [], 1.2
    for speaker, text in LINES:
        role, pitch, tempo = VOICES[speaker]
        pcm = synth(text, pitch, tempo, tmp)
        dur = len(pcm) / 2 / SR
        for r in tracks:
            pad = int(t * SR) * 2 - len(tracks[r])
            tracks[r] += b"\0" * max(0, pad)
        tracks[role] += pcm
        words, w_t = [], t
        tokens = text.split()
        per = dur / max(1, sum(len(w) for w in tokens))
        for w in tokens:
            d = len(w) * per
            words.append({"text": w, "start": round(w_t, 2), "end": round(w_t + d, 2), "probability": 0.95})
            w_t += d
        utterances.append({"speaker": speaker, "track": role, "start": round(t, 2), "end": round(t + dur, 2),
                           "text": text, "words": words})
        t += dur + 0.7
    total = t + 1.0
    for r, data in tracks.items():
        data += b"\0" * max(0, int(total * SR) * 2 - len(data))
        wav = os.path.join(tmp, f"{r}.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(bytes(data))
        subprocess.run([FFMPEG, "-loglevel", "error", "-y", "-i", wav, "-c:a", "aac", "-b:a", "64k",
                        os.path.join(folder, f"audio_{r}.m4a")], check=True)
    shutil.rmtree(tmp)
    U = [u["start"] for u in utterances]  # таймкоды реплик по номеру

    # 2. Транскрипт.
    talk = {}
    for u in utterances:
        talk[u["speaker"]] = talk.get(u["speaker"], 0) + u["end"] - u["start"]
    iso = lambda d: d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    end = START + timedelta(seconds=total)
    transcript = {
        "schema": 1, "meetingId": MEETING_ID, "language": "ru", "createdAt": iso(end + timedelta(minutes=2)),
        "removedEcho": 1, "removedHallucinations": 2,
        "speakers": [
            {"id": "others:S1", "label": "Мария Смирнова", "track": "others", "nameSource": "voice",
             "email": "maria@example.com", "talkSeconds": talk["others:S1"]},
            {"id": "me", "label": "Я", "track": "me", "nameSource": "me", "talkSeconds": talk["me"]},
            {"id": "others:S2", "label": "Олег Петров", "track": "others", "nameSource": "manual",
             "email": "oleg@example.com", "talkSeconds": talk["others:S2"]},
            {"id": "others:S3", "label": "Собеседник 3", "track": "others", "nameSource": "generic",
             "talkSeconds": talk["others:S3"], "suggestedName": "Анна Ковалёва", "suggestedEmail": "anna@example.com"},
        ],
        "utterances": utterances,
    }
    json.dump(transcript, open(os.path.join(folder, "transcript.json"), "w"), ensure_ascii=False, indent=2)

    # 3. Событие и meta.
    person = lambda name, email, me=False, org=False: {"name": name, "email": email, "status": "accepted", "isMe": me, "isOrganizer": org}
    attendees = [person("Илья", "me@example.com", me=True, org=True), person("Мария Смирнова", "maria@example.com"),
                 person("Олег Петров", "oleg@example.com"), person("Дмитрий Орлов", "dmitry@example.com")]
    event_id = "demo-quota-sync"
    event = {"eventId": event_id, "start": iso(START), "end": iso(START + timedelta(minutes=30)),
             "title": "Синк по квотам экспериментов", "calendar": "Работа", "isAllDay": False,
             "location": "", "notes": "Повестка: квоты трафика, что успеваем к релизу 27 ноября.",
             "callURL": "https://example.ktalk.ru/quota-sync", "organizer": attendees[0], "attendees": attendees,
             "myStatus": "accepted"}
    context = f"{event_id}@{int(START.timestamp())}"
    step = lambda m1, m2: {"status": "done", "startedAt": iso(end + timedelta(minutes=m1)), "finishedAt": iso(end + timedelta(minutes=m2))}
    meta = {
        "schema": 1, "id": MEETING_ID, "title": TITLE, "startedAt": iso(START), "endedAt": iso(end),
        "mode": "online", "status": "done", "voiceProcessing": False, "deviceEvents": [],
        "tracks": [{"role": "me", "file": "audio_me.m4a", "device": "Микрофон MacBook Pro", "startHostNanos": 1000000000, "durationSeconds": total},
                   {"role": "others", "file": "audio_others.m4a", "device": "Звук приложений", "startHostNanos": 1000000000, "durationSeconds": total}],
        "event": event, "participants": attendees,
        "steps": {"transcribe": step(0, 1), "diarize": step(0, 1), "merge": step(1, 1), "analyze": step(2, 3), "public": step(3, 3)},
        "analysisHash": "demo", "analysisContext": context, "publicHash": "demo",
        "doneTasks": ["переслать итоги дмитрию: он отвечает за клиентские квоты в on-prem"],
        "usage": [{"step": "analyze", "model": "sonnet", "at": iso(end + timedelta(minutes=3)), "inputTokens": 14200, "outputTokens": 6100, "durationMs": 41000},
                  {"step": "public", "model": "sonnet", "at": iso(end + timedelta(minutes=3)), "inputTokens": 31000, "outputTokens": 1400, "durationMs": 12000}],
    }
    json.dump(meta, open(os.path.join(folder, "meta.json"), "w"), ensure_ascii=False, indent=2)

    # 4. Анализ — как его вернул бы скилл meeting-analysis.
    q = lambda i, text=None: {"quote": text or LINES[i][1], "ts": ts(U[i])}
    analysis = {
        "schema_version": 1, "language": "ru",
        "participants": {"count": 4, "mentioned_not_present": ["Дмитрий Орлов"], "people": [
            {"speaker": "С1", "name": "Мария Смирнова", "source": ["calendar", "voice"], "confidence": 0.95},
            {"speaker": "С2", "name": "Олег Петров", "source": ["calendar", "transcript"], "confidence": 0.9},
            {"speaker": "С3", "name": "", "source": ["transcript"], "confidence": 0.2}]},
        "tldr": [
            "Квоты трафика поднимать не нужно: в 9 из 12 случаев их держали эксперименты, которые уже набрали выборку.",
            "К релизу 27 ноября делаем отчёт по таким экспериментам и бейдж «выборка набрана» в интерфейсе.",
            "Автоматическое освобождение трафика переносим в следующий спринт: только с уведомлением владельца и окном отмены.",
            "Я пишу в канал, что подход к квотам меняется: в прошлый раз я пообещал просто поднять квоты.",
        ],
        "summary_by_topics": [
            {"topic": "Почему кончаются квоты", "start": ts(U[1]), "markdown":
                "- За ноябрь квоту исчерпывали **12 раз**, в 9 случаях трафик держали эксперименты с набранной выборкой.\n- Вывод Олега и Марии: проблема не в размере квоты, а в том, что завершённые тесты никто не останавливает."},
            {"topic": "Автоматическое освобождение трафика", "start": ts(U[4]), "markdown":
                "- Нормальная реализация с уведомлением и окном отмены — **две недели**, быстрая без отмены — три дня.\n- Без отмены рискованно: часть экспериментов держат дольше ради долгосрочных метрик.\n- Олег жёстко против варианта без отмены — с этим все согласились."},
            {"topic": "Что успеваем к релизу 27 ноября", "start": ts(U[8]), "markdown":
                "- Отчёт: эксперименты, которые набрали выборку и держат трафик. Владельцы останавливают сами.\n- Бейдж «выборка набрана» в интерфейсе — полдня работы.\n- «Набрал выборку» считаем **по MDE из дизайна**, а не по календарю."},
            {"topic": "Коммуникация", "start": ts(U[17]), "markdown":
                "- В прошлый раз я пообещал поднять квоты, и это всех запутало. Сегодня пишу в канал о новом подходе и пересылаю Дмитрию."},
        ],
        "insights": [
            {"text": "Запрос «поднимите квоты» был симптомом: реальная проблема — нет сигнала, что эксперимент можно останавливать. Бейдж и отчёт закрывают её дешевле любых изменений квот.", "ts": ts(U[2])},
            {"text": "У Олега сильная позиция против изменений, которые трогают чужие эксперименты без спроса. Это стоит учесть при дизайне автоосвобождения: начать с уведомлений и только потом автоматику.", "ts": ts(U[7])},
            {"text": "Клиентские квоты on-prem (Дмитрий) не обсуждали — правило по MDE может разойтись с тем, как квоты считают у клиентов.", "ts": ts(U[19])},
        ],
        "decisions": [
            {"text": "К релизу 27 ноября — отчёт по экспериментам с набранной выборкой и бейдж в интерфейсе; автоосвобождение — в следующий спринт.", "ts": ts(U[12]), "owner": "Я"},
            {"text": "«Выборка набрана» определяем по MDE из дизайна эксперимента, а не по календарю.", "ts": ts(U[14]), "owner": "С1"},
            {"text": "Автоосвобождение трафика — только с уведомлением владельца и окном отмены.", "ts": ts(U[7]), "owner": "С2"},
        ],
        "action_items": [
            {"what": "Написать правило «выборка набрана» по MDE", "who": "С1", "due": "2026-11-24", "due_said": "до вторника", "ts": ts(U[16])},
            {"what": "Отчёт: эксперименты, которые набрали выборку и держат трафик", "who": "С2", "due": "2026-11-24", "due_said": "за два дня", "ts": ts(U[10])},
            {"what": "Бейдж «выборка набрана» в интерфейсе", "who": "С3", "due": "2026-11-27", "due_said": "к двадцать седьмому", "ts": ts(U[12])},
            {"what": "Написать в канал, что подход к квотам меняется", "who": "Я", "due": "2026-11-20", "due_said": "сегодня", "ts": ts(U[19])},
            {"what": "Переслать итоги Дмитрию: он отвечает за клиентские квоты в on-prem", "who": "Я", "due": "2026-11-20", "due_said": "сегодня", "ts": ts(U[19])},
            {"what": "Посмотреть отчёт на созвоне", "who": "", "due": "2026-11-25", "due_said": "в среду", "ts": ts(U[20])},
        ],
        "diagrams": [
            {"type": "flowchart", "title": "Автоосвобождение трафика (следующий спринт)", "mermaid":
                "flowchart TD\n  A[Эксперимент набрал выборку по MDE] --> B[Уведомление владельцу]\n  B --> C{Отменил за 48 часов?}\n  C -- Да --> D[Эксперимент держит трафик дальше]\n  C -- Нет --> E[Трафик возвращается в квоту]\n  D --> F[Повторное напоминание через неделю]"},
            {"type": "timeline", "title": "План по квотам", "mermaid":
                "timeline\n  title План по квотам\n  24 ноября : Правило «выборка набрана» : Отчёт по экспериментам\n  27 ноября : Релиз — отчёт и бейдж\n  Следующий спринт : Автоосвобождение с окном отмены"},
        ],
        "sentiment": {
            "overall": {"label": "рабочая, с коротким напряжением посередине", "score": 0.25, "evidence": [q(7), q(13, "Согласен.")]},
            "per_participant": [
                {"speaker": "С1", "label": "спокойная, опирается на данные", "evidence": [q(1, "За ноябрь квоту исчерпывали двенадцать раз")]},
                {"speaker": "С2", "label": "настороженный, жёстко защищает качество", "evidence": [q(7, "Тогда две недели, и это не обсуждается.")]},
                {"speaker": "С3", "label": "конструктивная, предлагает быстрое решение", "evidence": [q(11, "Это полдня работы.")]},
                {"speaker": "Я", "label": "собранный, один раз сорвался в оборону", "evidence": [q(8, "Хорошо, никто не просит выкатывать сырое.")]},
            ]},
        "conflict": {
            "detected": True, "kinds": ["сроки", "качество против скорости"],
            "summary": "Олег жёстко отказался от быстрого варианта без отмены («это не обсуждается»). Я ответил с упрёком, и напряжение спало, только когда разговор перешёл к тому, что нужно к релизу.",
            "my_speech_feedback": [
                {"quote": "Хорошо, никто не просит выкатывать сырое.", "ts": ts(U[8]),
                 "problem": "Звучит как упрёк: Олег слышит, что его позицию считают перестраховкой, и защищается сильнее.",
                 "better": "Согласен, без отмены нельзя. Что мы можем дать командам к релизу, не трогая чужие тесты?",
                 "principle": "de_escalation"},
                {"quote": "Мария, напишешь короткое правило, чтобы Олег мог его закодить?", "ts": ts(U[15]),
                 "problem": "Нет срока и формата — Мария назвала срок сама, но могла и не назвать.",
                 "better": "Мария, сможешь до вторника написать правило по MDE в виде условия, которое Олег закодит?",
                 "principle": "clarity"},
            ]},
    }
    json.dump(analysis, open(os.path.join(folder, "analysis.json"), "w"), ensure_ascii=False, indent=2)

    # 5. Публичное саммари — как его вернул бы meeting-public после /ru-text.
    public = """#### Синк по квотам экспериментов, 20 ноября

Квоты трафика поднимать не будем: в 9 из 12 случаев их держали эксперименты, которые уже набрали выборку. К релизу 27 ноября делаем отчёт по таким экспериментам и бейдж в интерфейсе, а автоматическое освобождение трафика переносим в следующий спринт.

**Договорились**
- К релизу 27 ноября: отчёт по экспериментам с набранной выборкой и бейдж «выборка набрана».
- «Выборка набрана» считаем по MDE из дизайна эксперимента, а не по календарю.
- Автоосвобождение трафика — только с уведомлением владельца и окном отмены.

**Задачи**
| Что | Кто | Срок |
|:--|:--|:--|
| Правило «выборка набрана» по MDE | Мария Смирнова | до 24 ноября |
| Отчёт по экспериментам, которые держат трафик | Олег Петров | до 24 ноября |
| Бейдж «выборка набрана» в интерфейсе | не назначен | до 27 ноября |
| Сообщение в канал о новом подходе к квотам | я | 20 ноября |

**Схемы** — приложу картинками ниже: «Автоосвобождение трафика», «План по квотам».
"""
    for name in ("summary_public.md", "summary_public.generated.md"):
        open(os.path.join(folder, name), "w").write(public)
    print(folder)
    print(MEETING_ID)


main()
