#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v gh >/dev/null; then
  echo 'GitHub CLI отсутствует. Установи: brew install gh'
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo 'Выполни gh auth login и повтори.'
  exit 1
fi
if [ ! -d .git ]; then git init -b main; fi
if ! git config user.email >/dev/null; then echo 'Укажи git config user.email для коммитов'; exit 1; fi
if ! git config user.name >/dev/null; then echo 'Укажи git config user.name для коммитов'; exit 1; fi
git add .
if ! git diff --cached --quiet; then git commit -m 'Build Meeting Copilot macOS desktop UI and DMG workflow'; fi
if gh repo view ap-shirokov/meeting-copilot >/dev/null 2>&1; then
  if ! git remote get-url origin >/dev/null 2>&1; then git remote add origin https://github.com/ap-shirokov/meeting-copilot.git; fi
  git push -u origin main
else
  gh repo create ap-shirokov/meeting-copilot --public --source=. --remote=origin --push
fi
echo 'Repo: https://github.com/ap-shirokov/meeting-copilot'
echo 'DMG will be available in Actions after successful macOS build.'
