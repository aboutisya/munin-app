"""Распознавание для «Мунина»: mlx-whisper через Python API, без ffmpeg.

WAV (16 кГц, моно, 16 бит) читается здесь же и передаётся массивом. Вывод тот же, что у CLI
`mlx_whisper --verbose True --output-format json`: строки `[мм:сс.ммм --> мм:сс.ммм] текст`
в stdout для прогресса и `<имя>.json` в папке вывода.
"""
import argparse
import json
import os
import sys
import wave

import numpy as np


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            sys.exit(f"ожидается WAV 16 кГц моно 16 бит: {path}")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("--model", required=True)
    p.add_argument("--output-dir", required=True)
    p.add_argument("--language")
    p.add_argument("--initial-prompt")
    a = p.parse_args()

    import mlx_whisper

    result = mlx_whisper.transcribe(
        read_wav(a.wav),
        path_or_hf_repo=a.model,
        language=a.language,
        initial_prompt=a.initial_prompt,
        word_timestamps=True,
        condition_on_previous_text=False,
        hallucination_silence_threshold=2,
        verbose=True,
    )
    name = os.path.splitext(os.path.basename(a.wav))[0] + ".json"
    with open(os.path.join(a.output_dir, name), "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)


if __name__ == "__main__":
    main()
