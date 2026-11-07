# claude-code-statusline

A status line for [Claude Code](https://claude.ai/claude-code) that shows the model,
git diff, context budget, spend and prompt-cache health.

```
🤖 Opus 5   🌿 main +216/-22   💭 ████████░░░░░░░░░░░░ 29% 114.8k/400k
💰 $10.93 spent   ⏱️  0h 34m until reset   🗄 warm 99%
```

| Element | Source |
| --- | --- |
| 🤖 Model | `.model.display_name` |
| 🌿 Branch / diff | `git rev-parse` + `git diff --shortstat` |
| 💭 Context bar | `.context_window.total_input_tokens` ÷ budget (see below) |
| 💰 Spend | `ccusage blocks --json`, cached 5 min |
| ⏱️ Reset | active block's `endTime` |
| 🗄 Cache | `.prompt_cache.warm` / `.hit_ratio` |

Based on [claude-hud](https://www.npmjs.com/package/claude-hud) 1.1.0 (MIT), with the
fixes below.

## Install

Requires **bash**, **jq** and **ccusage**.

```bash
# jq
winget install jqlang.jq        # Windows
brew install jq                 # macOS
sudo apt install jq             # Debian/Ubuntu

# ccusage
npm install -g ccusage
```

Copy the script and point `statusLine` at it in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"C:/Users/<you>/.claude/statusline-command.sh\"",
    "padding": 0,
    "refreshInterval": 10
  }
}
```

On Windows the path **must** use forward slashes and be quoted — see
[the backslash trap](docs/why-the-context-bar-was-wrong.md#1-the-command-silently-does-nothing-on-windows).

## The context budget is not `context_window_size`

This is the one thing worth reading the docs for.

Claude Code reports `.context_window.context_window_size` from its **model catalog**,
not from your proxy or provider configuration. `claude-opus-5` is declared as a 1M
native window, so CC reports `1000000` even when the budget that actually applies is
smaller — for example when an auto-compact window is pinned to 400k.

Measuring against the catalog value makes the bar lie in the dangerous direction:
114,883 tokens against a 400k budget is 29% used, but shows as 11%.

This script therefore prefers `CLAUDE_CODE_AUTO_COMPACT_WINDOW` as the denominator
when it is set and smaller than the catalog window, and falls back to the catalog
value otherwise. Full reasoning, evidence and the CC internals involved:
[`docs/why-the-context-bar-was-wrong.md`](docs/why-the-context-bar-was-wrong.md).

## Configuration

| Env var | Effect |
| --- | --- |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Sets the context bar's denominator (when smaller than the catalog window) |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Not read by this script |

## Uninstall

Remove the `statusLine` key from `~/.claude/settings.json` and delete
`~/.claude/statusline-command.sh` and `~/.claude/ccusage-cache.json`.

## License

MIT. Upstream claude-hud is MIT-licensed; see [LICENSE](LICENSE).
