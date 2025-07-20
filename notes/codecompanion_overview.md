# CodeCompanion.nvim Overview

This note captures the structure, purpose, and key concepts of CodeCompanion.nvim so future sessions can quickly get up to speed.

## What is CodeCompanion.nvim?

CodeCompanion.nvim is a Neovim plugin that provides AI-powered coding assistance via large language models (LLMs). It unifies chat, inline transformations, refactoring, prompt libraries, agents/tools, and workflows into a seamless in-editor experience.

## Key Features

- **Chat & inline modes**: Converse with LLMs or apply edits inline.
- **Multiple adapters**: Built‑in support for Anthropic, Copilot, GitHub Models, DeepSeek, Gemini, Mistral, Novita, Ollama, OpenAI, Azure, HuggingFace, xAI, or custom adapters.
- **Prompt library & action palette**: Ready-made prompts for common tasks (e.g. explaining code, fixing errors).
- **Variables & slash commands**: Inject dynamic context (LSP diagnostics, file paths) and execute built‑in slash commands (/symbols, /fetch, /workspace).
- **Agents & tools**: Run shell commands, file search, diffs, web search, etc., within chat.
- **Workflows**: Multi-step, configurable sequences of prompts and tools.
- **Extensibility**: API for creating custom adapters, prompts, tools, and workflows.

## Project Layout

```
README.md              ← overview & badges
minimal.lua            ← minimal setup example
doc/                   ← website-style docs & built-in help (:help codecompanion)
lua/codecompanion/     ← core implementation (init, config, commands, adapters, strategies, providers, utils)
notes/                 ← (this folder) session notes and summaries
```

## Core Concepts

### Adapters
Modules that connect to specific LLM services via a unified interface (connect, run, etc.).

### Strategies
Different interaction modes:
- **chat**: chat buffer for back‑and‑forth conversation.
- **inline**: apply AI edits directly into current buffer.
- **cmd**: command-line wrapper for scripting.

### Prompt Library & Actions
Built-in library of prompts and an action palette for common developer tasks.

### Chat Buffer Features
- Slash commands, variables, agents/tools, and workflows embedded in chat.

### Extension API
Public APIs under `lua/codecompanion/_extensions` and docs in `doc/extending/…` for adding new adapters, prompts, tools, and workflows.

## How It All Fits Together

1. **Entry**: `require('codecompanion').setup()` in `lua/codecompanion/init.lua`
2. **Configuration**: user options merged with defaults; health checks run.
3. **Adapters & Strategies**: registered and instantiated to provide UI and LLM connectivity.
4. **Providers**: slash-commands, variables, actions feed context into prompts and UI.

---

*End of overview notes.*
