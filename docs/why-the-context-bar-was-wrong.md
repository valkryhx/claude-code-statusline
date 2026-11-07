# Why the context bar was wrong

Three defects found while installing claude-hud 1.1.0 on Windows. The third is the
most important and is not Windows-specific.

---

## 1. The command silently does nothing on Windows

claude-hud's installer writes this into `~/.claude/settings.json`:

```
bash C:\Users\<you>\.claude\statusline-command.sh
```

Claude Code runs command-type status lines through **Git Bash** on Windows. The inner
bash consumes the backslashes before the script path is resolved:

```
bash: C:Users<you>.claudestatusline-command.sh: No such file or directory
```

Exit code 127, empty stdout, and the status line renders as blank. Nothing in the
Claude Code UI says anything went wrong.

Forward slashes with quotes work:

```
bash "C:/Users/<you>/.claude/statusline-command.sh"
```

Verified by spawning exactly the way CC does (`shell: <git bash>`) and comparing:

| Command | Exit | Stdout |
| --- | --- | --- |
| `bash C:\Users\...\statusline-command.sh` | 127 | `""` |
| `bash "C:/Users/.../statusline-command.sh"` | 0 | full render |
| `bash /c/Users/.../statusline-command.sh` | 0 | renders, but GNU `stat -f` breaks the cache |

The third form is legitimate but runs into defect 2.

---

## 2. `stat -f %m` swallows the fallback on GNU systems

claude-hud caches `ccusage` output and refreshes it every 5 minutes:

```bash
cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
```

`-f` is the **BSD/macOS** syntax for "format". GNU `stat` reads `-f` as "display
filesystem status", prints a block-device report, and **exits 0**. The `||` fallback
never fires, `cache_mtime` becomes mount-table text, and the age arithmetic throws:

```
stat: File: "...ccusage-cache.json"
  ID: c897e7ce... Namelen: 255     Type: UNKNOWN
...
1794071260: syntax error in expression (error token is "...")
```

Fixed by trying GNU first and validating that the result is a plain integer:

```bash
get_mtime() {
  stat -c %Y "$1" 2>/dev/null && return 0
  stat -f %m "$1" 2>/dev/null && return 0
  return 1
}
```

---

## 3. `context_window_size` is not your budget

This one produces a plausible-looking number that is simply wrong, which makes it the
easiest to miss.

### What was observed

Measured from a real payload, not a constructed one:

```
context_window_size              = 1000000      ← what CC sends
CLAUDE_CODE_AUTO_COMPACT_WINDOW  = 400000       ← what was configured
total_input_tokens               = 114883
used_percentage                  = 11           ← computed against 1000000
```

114,883 ÷ 400,000 is **29%**, not 11%. The bar was understating consumption by a
factor of nearly three — the direction that gets you compacted or rejected by surprise.

### Why

`context_window_size` is resolved from Claude Code's **model catalog**, which knows
nothing about a proxy or gateway config. Sources are from Claude Code 2.1.319:

```
claude-opus-5 catalog entry            m0118:698-703
  context: { window: 1e6, native_1m: true, supports_1m_beta: true, ... }

statusline payload                     m0591:168782
  context_window: xut(ot, Ze)
  Ze = Yh(Xe, jp())                    m0591:168704

Yh → kA() ?? wA(e, n)                  m0191:24353
wA → NOr(e,n) ? Math.max(SA(e), h.maximum_window ?? h.window, a$) : ...
                                       m0191:24415
a$ = 1e6                               m0191:24246   ← 1M floor
```

So for `claude-opus-5` the result is `Math.max(1e6, 1e6, 1e6)` = `1000000`. Correct
for the catalog entry, wrong for this deployment.

The auto-compact window is a **separate** computation:

```
resolveAutoCompactWindow()             m0591:82678
  let h = Wan(i.CLAUDE_CODE_AUTO_COMPACT_WINDOW);
  if (h !== undefined) return { window: Math.min(s, h), configured: h, source: "env" };
```

It is used for the compaction threshold and reported only in **telemetry**
(`autoCompactWindow` / `autoCompactWindowOrigin`, `m0591:104826`) — it is **not** in
the statusLine payload. There is no field to read; the only signal available to a
status line script is the environment variable itself, which is present in the
subprocess environment (verified).

### Two independent paths

| Field | Computed by | Affected by `AUTO_COMPACT_WINDOW` |
| --- | --- | --- |
| `context_window.context_window_size` | `wA()` / `SA()` | no |
| auto-compact threshold | `resolveAutoCompactWindow()` | yes |

Setting `CLAUDE_CODE_MAX_CONTEXT_TOKENS` can move the first one, but only when
`DISABLE_COMPACT` is also set (`m0191:24404`) — which turns compaction off entirely
and risks the upstream rejecting an oversized request.

### What this script does

Use `CLAUDE_CODE_AUTO_COMPACT_WINDOW` as the denominator when it is a plain integer,
greater than zero, and smaller than the catalog window; otherwise use the catalog
window. Compute the percentage from `total_input_tokens` so the bar and the token
count always agree, and fall back to CC's own `used_percentage` when tokens are absent.

Verified against the real payload above: 29%, `114.8k/400k`.

---

## Method note

The context-budget defect was initially diagnosed as "1000k is correct" — because the
verification payload had been **constructed by hand** with `context_window_size: 400000`
already in it. That tests the script's reading of a field, not whether Claude Code
populates it as assumed.

The fix was to capture what CC actually sends: temporarily write `$input` to a file at
the top of the script, let the status line re-run on its own timer, and inspect the
real payload. Anything that reads fields out of a payload should be verified this way.
