# Сторонние компоненты

## Внутри приложения

| Компонент | Лицензия | Где |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.3 — VAD и диаризация | Apache License 2.0 | статически в бинарнике |
| [Mermaid](https://github.com/mermaid-js/mermaid) 11.4.1 — диаграммы | MIT | `Contents/Resources/mermaid.min.js` |
| [uv](https://github.com/astral-sh/uv) 0.11.2 — установка Python-окружения распознавания | MIT или Apache License 2.0 | `Contents/MacOS/uv` |

## Скачивается при первом запуске

| Компонент | Лицензия | Откуда |
|---|---|---|
| Python 3.13 ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | PSF License | GitHub, через uv |
| [mlx-whisper](https://github.com/ml-explore/mlx-examples) и его зависимости (MLX, NumPy, SciPy, Numba, tiktoken, huggingface_hub) | MIT, BSD, Apache 2.0 | PyPI, через uv |
| Модель [whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) (OpenAI Whisper, конвертация MLX) | MIT | Hugging Face |
| Модели FluidAudio (Silero VAD, сегментация и эмбеддинги спикеров) | см. карточки моделей на Hugging Face | Hugging Face |

## Не входит и не распространяется

- Claude Code — ставит и авторизует сам пользователь, анализ идёт по его подписке.
- Скилл `ru-text` — сторонний, необязательный; если установлен у пользователя, приложение может им пользоваться.

Полные тексты лицензий — по ссылкам на репозитории компонентов.
