# AI Chat for DankMaterialShell

A chat slideout for DankMaterialShell that works with any AI provider. It defaults to
[Pollinations](https://pollinations.ai)' free, keyless text API, so it works with no setup.

## Providers

| Provider | Key needed | Notes |
| --- | --- | --- |
| `pollinations` (default) | No | `GET https://text.pollinations.ai/{prompt}?model=...`; reply is not streamed |
| `openai` | Yes | `https://api.openai.com` |
| `anthropic` | Yes | `https://api.anthropic.com` |
| `gemini` | Yes | `https://generativelanguage.googleapis.com` |
| `ollama` | No | Local server, `http://localhost:11434` |
| `custom` | Optional | Any OpenAI-compatible API: OpenRouter, LM Studio, vLLM, Ollama `/v1`, ... Set the base URL yourself |

Each provider keeps its own base URL, model, and key. Streaming is used for every provider except Pollinations.

## Features

- Editable base URL per provider
- **Test connection** button: lists models, verifies the URL and key, and fills the model dropdown
- API keys from settings, or (recommended) from an environment variable such as `OPENAI_API_KEY`
- System prompt, temperature, max tokens, optional conversation memory
- Resizable panel: drag its left edge (double-click to reset), use the **Panel width** slider in settings, or the expand button; the width is remembered
- Markdown rendering, retry/regenerate, copy chat, persistent history

## Requirements

- DankMaterialShell with plugin support (uses `DSlideout`, available in recent builds)
- `curl`, and `wl-copy` for clipboard actions

## Install

```bash
# Newer DMS builds load plugins from ~/.config/dms/plugins,
# older ones from ~/.config/DankMaterialShell/plugins. Use the one your DMS reads.
cp -r AIChat ~/.config/dms/plugins/
dms restart
```

Enable "AI Chat" in DMS Settings -> Plugins (or `dms ipc call plugins enable aiChat`), then toggle it with:

```bash
dms ipc call plugins toggle aiChat
```

```kdl
# Niri
Mod+A { spawn "dms" "ipc" "call" "plugins" "toggle" "aiChat"; }
```

```conf
# Hyprland
bind = SUPER, A, exec, dms ipc call plugins toggle aiChat
```

## Notes

- Keys saved in settings are stored in plain text in `~/.config/DankMaterialShell/plugin_settings.json`. Prefer an environment variable.
- With Pollinations the prompt travels in the URL, so long chats are trimmed (about 6000 characters).
- Prompts go to whichever remote provider you pick. Avoid sensitive data.
- Panel width is saved as `panelWidth` in the plugin settings (min 360px, max 1400px or screen width).
- History: `~/.local/state/DankMaterialShell/plugins/aiChat/session.json`

Based on the AI Assistant example plugin by devnullvoid (MIT).
