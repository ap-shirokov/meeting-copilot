# Meeting Copilot v0.4 — macOS desktop app

Native visible SwiftUI window. MLX Whisper transcribes microphone and system sound on your Mac; GPT analyzes text through a locally running LiteLLM proxy using the previously authorized ChatGPT session. No paid API fallback. macOS 14+ Apple Silicon.

## Build a .dmg

Use macOS with Xcode command line tools (`xcode-select --install`). In this directory run:

```bash
bash scripts/build-dmg.command
```

Result: `dist/Meeting-Copilot-0.4.0.dmg`. Open DMG, drag `Meeting Copilot.app` to Applications, then launch it. This unsigned developer build uses ad-hoc signing; macOS may require **System Settings → Privacy & Security → Open Anyway** for this trusted local build. The build script must be run on a Mac; a Linux environment cannot produce or test a real macOS DMG.

## Existing local dependencies

Uses `~/Documents/Whisper/.venv/bin/python`, `~/.meeting-copilot-litellm/bin/litellm`, and `~/.meeting-copilot-litellm.env` from the previous setup. If the defaults differ, set `COPILOT_PYTHON` before launching from Terminal (Finder launches do not inherit shell variables). The app starts the LiteLLM proxy itself if port 4000 is free. If an existing proxy uses port 4000 it reuses it. For reliable launch with local auth, keep the existing environment file with master key (chmod 600).

Transcript and microphone audio are processed locally in short chunks; text is sent to GPT when you click Ask. A call is not recorded until you click Start. For workplace meetings comply with recording and confidentiality policies and obtain appropriate consent.

## Capabilities / limitations

- Separate **Я** (mic) and **Другие** (system sound); not full speaker diarization.
- Resizable visible window; it **will appear** in screen sharing like a normal app.
- Transcript export as text, suggestions and question field, token / request / latency stats.
- MLX Whisper segments are ~5 seconds; real-time speed and quality depend on the Mac.
- ChatGPT subscription routing depends on LiteLLM and availability of the supported Codex provider model; subscription limits apply.
- This source was not compiled on a Mac in the authoring environment. The GitHub Actions workflow builds it on an actual macOS runner and stores the DMG as a downloadable build artifact.

## GitHub release workflow

`gh auth login` then `gh repo create ap-shirokov/meeting-copilot --public --source=. --remote=origin --push` in the repository root. Alternatively create a repository in the GitHub UI and push with git. GitHub Actions produces a DMG on `macos-15`; inspect workflow and artifacts to verify the build. Don't commit OAuth tokens, the local master-key env file or audio recordings.
