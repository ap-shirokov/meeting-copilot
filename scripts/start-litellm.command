#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.meeting-copilot-litellm"
if [ ! -x "$VENV/bin/litellm" ]; then echo 'Сначала запусти scripts/setup-litellm.command'; exit 1; fi
if [ ! -f "$HOME/.config/litellm/chatgpt/auth.json" ]; then echo 'Нет ChatGPT сессии: запусти scripts/setup-litellm.command'; exit 1; fi
# Only bind the localhost interface; no paid API keys or fallback deployed.
exec "$VENV/bin/litellm" --config "$PWD/scripts/litellm-config.yaml" --host 127.0.0.1 --port 4000
