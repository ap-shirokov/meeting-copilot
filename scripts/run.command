#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export COPILOT_ROOT="$PWD"
export PATH="/opt/homebrew/bin:$PATH"
export COPILOT_MODEL="${COPILOT_MODEL:-chatgpt/gpt-5.3-instant}"
export COPILOT_LITELLM_URL="http://127.0.0.1:4000"
export COPILOT_PYTHON="${COPILOT_PYTHON:-$HOME/Documents/Whisper/.venv/bin/python}"
export WHISPER_MODEL="${WHISPER_MODEL:-mlx-community/whisper-large-v3-mlx}"
export COPILOT_WORKER="$PWD/scripts/whisper_worker.py"
if ! command -v swiftc >/dev/null; then echo 'Нужны Xcode Command Line Tools'; exit 1; fi
if ! "$COPILOT_PYTHON" -c 'import mlx_whisper' 2>/dev/null; then echo "Нет mlx_whisper в $COPILOT_PYTHON"; exit 1; fi
if ! command -v ffmpeg >/dev/null; then echo 'Не найден ffmpeg: brew install ffmpeg'; exit 1; fi
if ! curl -fsS --max-time 3 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1 && ! curl -fsS --max-time 3 http://127.0.0.1:4000/v1/models >/dev/null 2>&1; then
 echo 'LiteLLM не отвечает на localhost:4000. Запусти scripts/start-litellm.command в отдельном терминале.'; exit 1
fi
echo "Meeting Copilot: Whisper=$WHISPER_MODEL, LLM=$COPILOT_MODEL via LiteLLM (без API fallback)"
mkdir -p build/MeetingCopilot.app/Contents/MacOS
cp scripts/Info.plist build/MeetingCopilot.app/Contents/Info.plist
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia Sources/main.swift -o build/MeetingCopilot.app/Contents/MacOS/MeetingCopilot
codesign --force --deep --sign - build/MeetingCopilot.app >/dev/null 2>&1 || true
exec "$PWD/build/MeetingCopilot.app/Contents/MacOS/MeetingCopilot"
