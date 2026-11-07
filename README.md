# claude-code-statusline

A status line for [Claude Code](https://claude.ai/claude-code) showing model, git diff,
context budget, spend and prompt-cache health.

```
🤖 Opus 5   🌿 main +216/-22   💭 ████████░░░░░░░░░░░░ 29% 114.8k/400k
💰 $10.93 spent   ⏱️  0h 34m until reset   🗄 warm 99%
```

Based on [claude-hud](https://www.npmjs.com/package/claude-hud) 1.1.0 (MIT), with three
defects fixed. Read [Troubleshooting](#troubleshooting) before debugging a blank status
line — the most likely cause fails **silently**.

---

## For agents: install procedure

Follow the steps in order. Each step ends with a verification command; do not proceed
past a failing one. Commands assume Git Bash syntax on Windows, where `~` is
`$HOME` and Windows drives map as `D:\x` → `/d/x`.

### Step 1: Verify prerequisites

```bash
node --version      # any modern LTS
npm --version
git --version
bash --version      # must exist; on Windows this is Git Bash, not the WSL stub
```

`jq` and `ccusage` may be absent — the script bootstraps jq and degrades gracefully
without ccusage, but install both for the full display:

```bash
winget install jqlang.jq          # Windows
brew install jq                   # macOS
sudo apt install jq               # Debian/Ubuntu

npm install -g ccusage
```

Verify — **expected: `jq` prints a version, `ccusage` resolves to a path**:

```bash
jq --version
command -v ccusage
```

Either may print "not found" without breaking rendering — jq is bootstrapped by the
script and ccusage only feeds the spend/reset fields — but both are required for the
complete display.

> On Windows, `winget install jqlang.jq` adds jq to the **user** PATH, which an
> already-running shell will not see. Verify with `where.exe jq` in PowerShell rather
> than trusting the current shell's `which`. The script probes the WinGet Links
> directory itself, so a missing PATH entry does not break rendering.

### Step 2: Install the script

```bash
mkdir -p ~/.claude
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

Verify — **expected: `SYNTAX OK`**:

```bash
bash -n ~/.claude/statusline-command.sh && echo "SYNTAX OK"
```

### Step 3: Wire it into `settings.json`

Merge this key into `~/.claude/settings.json` **without discarding existing keys**
(`env`, `permissions`, `enabledPlugins`, `effortLevel`, …). Read the file, parse it as
JSON, add the key, write it back — do not hand-edit or overwrite.

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

**The `command` string is platform-specific and gets this wrong easily:**

| Platform | Correct `command` |
| --- | --- |
| Windows | `bash "C:/Users/<you>/.claude/statusline-command.sh"` — forward slashes, double-quoted |
| macOS / Linux | `bash ~/.claude/statusline-command.sh` or an absolute POSIX path |

On Windows, **backslashes and unquoted paths both fail** — see
[Symptom A](docs/why-the-context-bar-was-wrong.md#1-the-command-silently-does-nothing-on-windows).

Verify — **expected: exit 0 and two non-empty lines**:

```bash
echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"total_input_tokens":1000,"context_window_size":200000}}' \
  | bash "C:/Users/<you>/.claude/statusline-command.sh"
echo "exit=$?"
```

### Step 4: Verify the JSON is still valid

An invalid `settings.json` makes Claude Code ignore the whole file, including the
`statusLine` you just added. **Expected: `JSON OK`.**

```bash
node -e "const fs=require('fs'),p=require('path');const f=p.join(process.env.HOME||process.env.USERPROFILE,'.claude','settings.json');const s=JSON.parse(fs.readFileSync(f,'utf8'));console.log('JSON OK');console.log('statusLine:',JSON.stringify(s.statusLine||null))"
```

The output should also echo back the `statusLine` object you just wrote. If it prints
`statusLine: null`, the key was not added — fix Step 3 before restarting.

### Step 5: Restart and confirm

Claude Code reads `statusLine` at startup. Restart it, then check that the line renders
under the prompt.

If it stays blank, capture what CC actually sends rather than guessing — see
[Troubleshooting](#troubleshooting).

---

## Troubleshooting

Map the symptom to a cause before changing anything. Causes 1 and 2 are the ones that
fail silently.

| Symptom | Likely cause | Reference |
| --- | --- | --- |
| **A.** Status line renders blank, `exit=127`, `No such file or directory` with the path collapsed to `C:Users...` | Backslashes in `command` eaten by the inner Git Bash | [docs §1](docs/why-the-context-bar-was-wrong.md#1-the-command-silently-does-nothing-on-windows) |
| **B.** Blanks intermittently; `stat: File: ... Namelen: ...` and `syntax error in expression` on stderr | GNU `stat` accepts `-f` and exits 0, so the BSD-path fallback never fires | [docs §2](docs/why-the-context-bar-was-wrong.md#2-stat--f-m-swallows-the-fallback-on-gnu-systems) |
| **C.** Percentage looks too low against your configured budget; shows 11% when ~29% is used | Bar divides by catalog `context_window_size`, not the auto-compact window | [docs §3](docs/why-the-context-bar-was-wrong.md#3-context_window_size-is-not-your-budget) |
| **D.** `jq: command not found` in stderr, model and context fields blank | jq missing, or not on the PATH CC hands to the subprocess | [docs §1](docs/why-the-context-bar-was-wrong.md#1-the-command-silently-does-nothing-on-windows) |
| **E.** `💰 —` and `⏱️ —` | ccusage missing, or it produced no parseable `blocks` output | [README → Install](#step-1-verify-prerequisites) |
| **F.** Nothing renders and nothing on stderr either | `settings.json` invalid, `statusLine` key wrong, or CC not restarted | [Step 4](#step-4-verify-the-json-is-still-valid) |

### Capture the real payload

Anything that reads fields from the statusLine payload **must** be verified against
what Claude Code actually sends. A hand-constructed payload will confirm your assumption
instead of testing it — that is exactly how cause C was initially misdiagnosed as
"working correctly".

Temporarily add this at the top of the script, let the status line re-run on its
`refreshInterval` timer, then inspect the file:

```bash
input=$(cat)
printf '%s' "$input" > "$HOME/.claude/statusline-last-input.json"   # temporary
```

Fields worth checking first:

```bash
jq '.context_window, .model, .prompt_cache' ~/.claude/statusline-last-input.json
```

Remove the capture block once done.

Also confirm which environment variables reached the subprocess, since the context
budget depends on one:

```bash
{ echo "AUTO_COMPACT_WINDOW=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-<unset>}"
  echo "MAX_CONTEXT_TOKENS=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-<unset>}"
} > "$HOME/.claude/statusline-last-env.txt"
```

### Enabling debug output

Claude Code logs status-line stderr. To surface it:

```bash
claude --debug          # or set the equivalent in your client
```

A healthy run logs `status_line_command` once and no repeated `StatusLine [...] stderr:`.

---

## The context budget is not `context_window_size`

The one behaviour that surprises people, and the only fix here that is not
Windows-specific.

Claude Code reports `.context_window.context_window_size` from its **model catalog**,
not from your proxy or provider configuration. `claude-opus-5` is declared as a 1M
native window, so CC reports `1000000` even when the budget that actually applies is
smaller — for example an auto-compact window pinned to 400k.

Measuring against the catalog value makes the bar understate usage in the dangerous
direction: 114,883 tokens against a 400k budget is 29% used, but shows as 11%.

The script therefore prefers `CLAUDE_CODE_AUTO_COMPACT_WINDOW` as the denominator when
it is set, numeric, and smaller than the catalog window, and falls back to the catalog
value otherwise. It computes the percentage from `total_input_tokens` so the bar and the
token count always agree.

Full reasoning, source coordinates and verification method:
[`docs/why-the-context-bar-was-wrong.md`](docs/why-the-context-bar-was-wrong.md).

---

## Configuration

| Env var | Effect |
| --- | --- |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Sets the context bar's denominator when numeric, > 0, and smaller than the catalog window |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Not read by this script |

Behaviour with unusual values, all verified:

| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Denominator used |
| --- | --- |
| unset | catalog `context_window_size` |
| `400000`, catalog `1000000` | `400000` |
| `999999`, catalog `200000` | `200000` (never widens) |
| `abc` / empty | catalog value |
| tokens > budget | percentage exceeds 100, bar clamps at 20 cells |

---

## Uninstall

```bash
rm -f ~/.claude/statusline-command.sh ~/.claude/ccusage-cache.json
```

Then remove the `statusLine` key from `~/.claude/settings.json` — parse and rewrite the
JSON, do not hand-edit. Restart Claude Code.

---

## Repository layout

| Path | Contents |
| --- | --- |
| [`statusline-command.sh`](statusline-command.sh) | The script |
| [`docs/why-the-context-bar-was-wrong.md`](docs/why-the-context-bar-was-wrong.md) | The three defects: symptoms, root cause, CC source coordinates, verification method |
| [`LICENSE`](LICENSE) | MIT, noting the claude-hud derivation |

## License

MIT. Upstream claude-hud is MIT-licensed; see [LICENSE](LICENSE).
