# claude-code-statusline

A status line for [Claude Code](https://claude.ai/claude-code): which model is actually
answering, reasoning effort, git state, project path, and the context budget.

```
moma/deepseek-latest-flash → deepseek-v4.1-flash-1017 · high · thinking   │   main +216/-22   │   D:/git_repos/my-project
████████░░░░░░░░░░░░ 29%   │   114.8k/400k   │   cache 160.9k  in 3.5k  out 420   │   warm 99%
```

| Element | Source |
| --- | --- |
| Model | configured route (`.model.id` → `ANTHROPIC_DEFAULT_*_MODEL_NAME`) → answered model (transcript `message.model`); see below |
| `· high` | `.effort.level` — omitted when the model reports no effort |
| `· thinking` | `.thinking.enabled` — shown only when extended thinking is on |
| Branch / diff | `git diff --numstat HEAD`, plus count of untracked files; a clean tree reads `main clean` rather than `+0/-0` |
| Path | `.workspace.current_dir`, shortened to `~/...` when under `$HOME` |
| Bar + `29%` | cumulative context ÷ budget (see below); the bar is a per-cell colour gradient |
| `114.8k/400k` | same numbers in k, whole thousands without a decimal |
| `cache 160.9k in 3.5k out 420` | **per-call** cache reads, input and output of the last response |
| `warm 99%` | `.prompt_cache.hit_ratio` — ≥95% green, 80–95% orange, below that red |

### Visual structure

Two rows, two jobs: line 1 is **identity** (what session you are in), line 2 is the
**context budget** (what moves turn to turn).

- Groups are separated by a dim `│` rule rather than whitespace alone. At three
  spaces apart, "next field" and "next group" read the same; the rule costs one glyph
  and states the boundary. It is coloured `90` (bright black), not `2` (dim) — dimmed,
  it smears into the surrounding spaces.
- Field labels (`cache`, `in`, `out`) are dim and their values stay bright, so the row
  scans as numbers instead of words. The `k` unit is uniform and `/` is dimmed.
- Empty fields drop out entirely, so a payload missing one collapses the gap rather
  than leaving a blank column.

### Narrow terminals

Line 1 degrades in steps as `$COLUMNS` shrinks, shedding the least identifying part
first. Nothing is ever truncated mid-word — a mangled model name would defeat the
row's purpose, so whole fields yield instead:

| Columns | Line 1 shows |
| --- | --- |
| ≥ 100 | model route · effort · thinking │ branch │ path |
| ~85 | drops `· thinking` |
| ~75 | drops effort too |
| ~70 | drops the provider half of `a → b`, keeps the answered model |
| < 60 | drops the branch, leaves the model alone |

Line 2 loses its detail groups before line 1 loses its identity: below 100 columns the
per-call trio (`cache in out`) goes, below 80 the cache figure goes, leaving the bar
and its token count.

The bar is a **per-cell gradient**: each filled cell takes its colour from its own
position, so the leading cell already shows the level and the trail behind it shows how
you got there. Colours come from a muted 256-colour ramp (sage → olive → amber → clay →
brick) rather than the vivid primaries, which glare on a dark terminal. The percentage
keeps a coarse green/yellow/red tint so it stays legible even when the bar is short.
Requires a terminal that supports 256 colours; on a 16-colour terminal the gradient
degrades to the nearest available shade.

### Cumulative versus per-call tokens

These two figures are easy to confuse, and the payload names them ambiguously:

| Field | Meaning |
| --- | --- |
| `context_window.total_input_tokens` | tokens **currently in the context window**, cumulative — this is what `114.8k/400k` shows |
| `context_window.total_output_tokens` | output tokens of the **most recent response** |
| `context_window.current_usage.input_tokens` `+ cache_creation_input_tokens` | input the **last request** actually sent |
| `context_window.current_usage.cache_read_input_tokens` | that request's cache reads |

So `114.8k` cannot be compared with `out 420` — different scopes. `cache`, `in` and
`out` are the trio that belong together, all from one API response. `in` sums fresh
input plus cache creation; `cache` is the read portion, which is cheap but is most of
the prompt, which is why `in` looks small next to the cumulative figure on its left.

Based on [claude-hud](https://www.npmjs.com/package/claude-hud) 1.1.0 (MIT), with the
defects fixed that are documented in
[`docs/why-the-context-bar-was-wrong.md`](docs/why-the-context-bar-was-wrong.md). Read
[Troubleshooting](#troubleshooting) before debugging a blank status line — the most
likely cause fails **silently**.

---

## Which model is it really?

`.model.display_name` in the statusLine payload is the model Claude Code **asked for**,
not the one that answered. Behind a gateway, router or cc-switch the request name is
rewritten upstream, so the payload can name a model you are not running.

An observed case: the payload said `Opus 5` while every assistant message in the
transcript was tagged `deepseek-v4.1-flash-1017`, and the proxy log showed
`model=moma/deepseek-latest-flash request_model=claude-opus-5`.

The transcript records both sides of that rewrite:

| Field | Meaning |
| --- | --- |
| `requestedModel` | what CC sent (e.g. `claude-opus-5`) |
| `message.model` | what the API returned (e.g. `deepseek-v4.1-flash-1017`) |

The script reads `message.model` from the last assistant record via
`.transcript_path`, and pairs it with the configured route from the
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL_NAME` env vars that cc-switch writes
(the slot is chosen by `.model.id`). Nothing is hardcoded per provider:

| configured env | transcript | shown |
| --- | --- | --- |
| `deepseek-v4.1-flash-1017` | `deepseek-v4.1-flash-1017` | `deepseek-v4.1-flash-1017` |
| `moma/deepseek-latest-flash` | `deepseek-v4.1-flash-1017` | `moma/deepseek-latest-flash → deepseek-v4.1-flash-1017` |
| unset | `deepseek-v4.1-flash-1017` | `deepseek-v4.1-flash-1017` |
| unset | unreadable transcript | payload `.model.display_name` |

The transcript read is one `tail` of the last 200 lines, so it adds no measurable cost.

---

## No ccusage, no spend

An earlier version of this script shelled out to `ccusage blocks --json` for a spend
figure and rate-limit reset timer. `ccusage` takes 3–4 seconds on a transcript this
size, which is longer than the status line's own refresh interval, so the line stalled
waiting on it. Both figures were removed; the second line now carries the context
budget alone. If you want cost back, call `ccusage` from the background as described in
the commit history rather than inline.

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

`jq` is the only external dependency. Install it:

```bash
winget install jqlang.jq          # Windows
brew install jq                   # macOS
sudo apt install jq               # Debian/Ubuntu
```

Verify — **expected: a version string**:

```bash
jq --version
```

> On Windows, `winget install jqlang.jq` adds jq to the **user** PATH, which an
> already-running shell will not see. Verify with `where.exe jq` in PowerShell rather
> than trusting the current shell's `which`. The script probes the WinGet Links
> directory itself, so a missing PATH entry does not break rendering — but jq must
> exist somewhere for anything to render.

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
echo '{"model":{"display_name":"Test"},"effort":{"level":"high"},"thinking":{"enabled":true},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"total_input_tokens":1000,"context_window_size":200000}}' \
  | bash "C:/Users/<you>/.claude/statusline-command.sh"
echo "exit=$?"
```

The rendered model segment should read `Test · high · thinking`. If the effort and
thinking suffixes are missing, the payload lacks `.effort.level` / `.thinking.enabled` —
both are optional and omitted on models without reasoning support.

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
| **E.** No `in` / `out` / `cache` figures | `.context_window.current_usage` is null — CC sends null before the first API response | [payload capture](#capture-the-real-payload) |
| **F.** Nothing renders and nothing on stderr either | `settings.json` invalid, `statusLine` key wrong, or CC not restarted | [Step 4](#step-4-verify-the-json-is-still-valid) |
| **G.** No `· high` / `· thinking` next to the model | `.effort.level` or `.thinking.enabled` absent from the payload — expected on models without reasoning effort, or with thinking off | [payload capture](#capture-the-real-payload) |

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
jq '.context_window, .effort, .thinking, .model, .workspace.current_dir, .prompt_cache' ~/.claude/statusline-last-input.json
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
rm -f ~/.claude/statusline-command.sh ~/.claude/ccusage-cache.json ~/.claude/statusline-probe-env.txt
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
