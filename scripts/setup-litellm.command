#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
VENV="$HOME/.meeting-copilot-litellm"
PYTHON="${LITELLM_BOOTSTRAP_PYTHON:-}"
if [ -z "$PYTHON" ]; then
  for candidate in /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 /usr/local/bin/python3.11 /usr/local/bin/python3.12 /usr/local/bin/python3.13; do
    if [ -x "$candidate" ]; then PYTHON="$candidate"; break; fi
  done
fi
if [ -z "$PYTHON" ]; then
  echo 'Не найден Python 3.11+. Установи: brew install python@3.11'
  exit 1
fi
if ! "$PYTHON" -c 'import sys; assert sys.version_info >= (3,10), sys.version' >/dev/null 2>&1; then
  echo "LiteLLM требует Python >=3.10; выбран: $PYTHON"; exit 1
fi
if [ -x "$VENV/bin/python" ] && ! "$VENV/bin/python" -c 'import sys; assert sys.version_info >= (3,10)' >/dev/null 2>&1; then
  echo "Найдено старое окружение Python 3.9. Пересоздаю только $VENV"
  mv "$VENV" "$VENV.backup-$(date +%Y%m%d-%H%M%S)"
fi
if [ ! -x "$VENV/bin/python" ]; then "$PYTHON" -m venv "$VENV"; fi
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install 'litellm[proxy]>=1.109.0'
echo 'Вход в ChatGPT: открой ссылку и введи код, который появится ниже.'
"$VENV/bin/python" -c 'from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token()'
chmod 700 "$HOME/.config/litellm" "$HOME/.config/litellm/chatgpt" 2>/dev/null || true
chmod 600 "$HOME/.config/litellm/chatgpt/auth.json" 2>/dev/null || true
echo 'Готово. Запусти scripts/start-litellm.command в отдельном терминале.'
