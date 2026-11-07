#!/usr/bin/env bash
# statusline-command.sh — Claude Code status line
#
# Based on claude-hud@1.1.0 (MIT), patched to work on Windows/Git-Bash and to
# measure the context bar against the budget that actually applies.
#
# Patched vs upstream claude-hud@1.1.0:
#   1. jq bootstrap: a winget/locally installed jq is not always on the PATH
#      that Claude Code hands to Git Bash, so probe the known install dirs.
#   2. portable mtime: upstream tried `stat -f %m` (BSD) first; GNU stat accepts
#      -f as "show filesystem status" and exits 0, so the `stat -c %Y` fallback
#      never fired and the cache arithmetic blew up. Order is reversed + guarded.
#   3. context budget: upstream divides by .context_window.context_window_size,
#      which comes from Claude Code's model catalog rather than from your proxy
#      config. CLAUDE_CODE_AUTO_COMPACT_WINDOW is the window that actually fires,
#      so measure against that. See docs/why-the-context-bar-was-wrong.md.
#   4. richer context line: token counts and prompt-cache health from the
#      statusLine JSON payload (context_window.*, prompt_cache.*).

input=$(cat)

# --- 0. jq bootstrap -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  for d in \
    "$HOME/AppData/Local/Microsoft/WinGet/Links" \
    "/c/Program Files/jq" \
    "/c/ProgramData/chocolatey/bin" \
    "/usr/bin" \
    "/usr/local/bin"
  do
    if [ -x "$d/jq.exe" ] || [ -x "$d/jq" ]; then
      PATH="$d:$PATH"
      break
    fi
  done
fi

reset=$'\033[0m'
green=$'\033[32m'
yellow=$'\033[33m'
red=$'\033[31m'
dim=$'\033[2m'
# Secondary tone for units and labels. Dim alone disappears on some terminals;
# pairing it with the terminal's own foreground keeps it readable while still
# receding behind the values it annotates.
faint=$'\033[2m'
# A thin vertical rule between groups. Deliberately not dimmed: at 2m it reads
# as a smudge between two runs of spaces rather than as a boundary, which is
# worse than no rule at all.
sep=$'\033[90m│\033[0m'

# One jq invocation for every payload field. Each separate `jq` call costs a
# full process start (~100ms on Windows) and this script re-runs every
# refreshInterval, so the fields are read in a single pass.
#
# Fields are joined with \x1f (unit separator), NOT tabs: tab is shell
# whitespace, so `read` with IFS=$'\t' collapses runs of empty fields and every
# later variable shifts left. That silently swapped model tier and output tokens
# whenever used_percentage was absent.
#
# Paths are converted inside jq rather than with `tr` afterwards, because @tsv
# escapes a backslash as `\\` and `tr` would then produce a doubled slash.
#
# `cache_read_tokens` is the per-call cache-read input. It is reported because
# `total_input_tokens` is NOT a per-call figure: CC describes it as the tokens
# currently in the context window, cumulative. The per-call input is
# `current_usage.input_tokens` (+ cache_creation), which is what pairs with the
# per-call `total_output_tokens`.
IFS=$(printf '\037') read -r model cwd effort thinking transcript cw_size used_tokens cache_warm cache_hit used_pct tier out_tokens in_tokens cache_read_tokens <<EOF
$(printf '%s' "$input" | jq -r '[
  (.model.display_name // ""),
  ((.workspace.current_dir // .cwd // ".") | gsub("\\\\"; "/")),
  (.effort.level // ""),
  (.thinking.enabled // ""),
  ((.transcript_path // "") | gsub("\\\\"; "/")),
  (.context_window.context_window_size // ""),
  (.context_window.total_input_tokens // ""),
  (.prompt_cache.warm // ""),
  (.prompt_cache.hit_ratio // ""),
  (.context_window.used_percentage // ""),
  (.model.id // ""),
  (.context_window.total_output_tokens // ""),
  (if .context_window.current_usage == null then ""
   else ((.context_window.current_usage.input_tokens // 0)
         + (.context_window.current_usage.cache_creation_input_tokens // 0))
   end),
  (.context_window.current_usage.cache_read_input_tokens // "")
] | map(tostring) | join("\u001f")' 2>/dev/null)
EOF
[ -z "$model" ] && model="Unknown"

# `.model.display_name` is the model Claude Code *asked for*, not the one that
# answered. Behind a gateway, router or cc-switch the request name (e.g.
# claude-opus-5) is rewritten upstream, so the label can name a model you are
# not running. The transcript records both: `requestedModel` is the request,
# `message.model` is what the API returned.
#
# The display shows the configured route when there is one, since that is what
# the user set and what identifies the upstream, and the answered model when it
# differs. Nothing here is hardcoded: the configured name comes from the
# ANTHROPIC_DEFAULT_*_MODEL_NAME env vars that cc-switch writes, selected by
# which tier the request belongs to.
#
# Cost note: reading the transcript is cheap (one tail); it rides on the git
# bash start this script has already paid.
answered_model=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  answered_model=$(
    tail -n 200 "$transcript" 2>/dev/null \
      | grep '"type":"assistant"' 2>/dev/null \
      | tail -n 1 \
      | grep -o '"model":"[^"]*"' 2>/dev/null \
      | tail -n 1 \
      | sed 's/^"model":"//; s/"$//'
  )
fi

# Which tier is this session running? payload .model.id is the request name,
# e.g. claude-opus-5 -> the OPUS slot that cc-switch aliases to the real model.
tier=$(printf '%s' "$tier" | tr 'A-Z' 'a-z')
configured_model=""
case "$tier" in
  *opus*)   configured_model=$ANTHROPIC_DEFAULT_OPUS_MODEL_NAME ;;
  *sonnet*) configured_model=$ANTHROPIC_DEFAULT_SONNET_MODEL_NAME ;;
  *haiku*)  configured_model=$ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME ;;
  *fable*)  configured_model=$ANTHROPIC_DEFAULT_FABLE_MODEL_NAME ;;
esac
[ -z "$configured_model" ] && configured_model="$ANTHROPIC_MODEL"

# Label: configured route when known, else the answered model, else the
# payload name. Append the answered model only when it adds information.
if [ -n "$configured_model" ]; then
  model_label="$configured_model"
  if [ -n "$answered_model" ] && [ "$answered_model" != "$configured_model" ]; then
    model_label="${model_label} → ${answered_model}"
  fi
elif [ -n "$answered_model" ]; then
  model_label="$answered_model"
else
  model_label="$model"
fi

model_str="${model_label}"
if [ -n "$effort" ]; then
  model_str="${model_str} · ${effort}"
fi
if [ "$thinking" = "true" ]; then
  model_str="${model_str} · thinking"
fi

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  # Untracked files are counted too. `git diff --shortstat HEAD` ignores them,
  # so a project whose new files are not yet added showed +0/-0 while plainly
  # having changes -- indistinguishable from a clean tree. numstat lists
  # per-file line deltas; untracked files have no diff, so they are counted by
  # number instead of by line.
  numstat=$(git -C "$cwd" diff --numstat HEAD 2>/dev/null)
  added=$(printf '%s\n' "$numstat" | awk '$1 ~ /^[0-9]+$/ {a += $1} END {print a + 0}')
  deleted=$(printf '%s\n' "$numstat" | awk '$2 ~ /^[0-9]+$/ {d += $2} END {print d + 0}')
  untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  case "$untracked" in
    '' | *[!0-9]*) untracked=0 ;;
  esac
  if [ "$untracked" -gt 0 ]; then
    git_info="${branch} ${green}+${added}${reset}/${red}-${deleted}${reset} ${yellow}?${untracked}${reset}"
  elif [ "$added" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    git_info="${branch} clean"
  else
    git_info="${branch} ${green}+${added}${reset}/${red}-${deleted}${reset}"
  fi
else
  git_info="no git"
fi

# Project directory, shown relative to $HOME as ~/... when it lives there.
# `cwd` already has forward slashes (converted inside the jq pass), so only the
# drive-letter form is needed for the $HOME comparison: Git Bash spells the home
# dir as /c/Users/... while CC sends C:/Users/...
to_posix() {
  case "$1" in
    [A-Za-z]:/*) printf '/%s%s' "$(printf '%s' "${1%%:*}" | tr 'A-Z' 'a-z')" "${1#?:}" ;;
    *)           printf '%s' "$1" ;;
  esac
}
cwd_posix=$(to_posix "$cwd")
home_posix=$(to_posix "$HOME")
case "$cwd_posix" in
  "$home_posix")   dir_disp="~" ;;
  "$home_posix"/*) dir_disp="~${cwd_posix#"$home_posix"}" ;;
  *)               dir_disp="$cwd" ;;
esac
path_info="${dir_disp}"

# --- Context budget --------------------------------------------------------
# Claude Code's .context_window.context_window_size comes from its model
# catalog, not from your proxy config: the claude-opus-5 entry declares a 1M
# native window, so CC reports 1000000 even when the real usable budget is
# smaller. The window that actually fires is the auto-compact window, which
# cc-switch pins via CLAUDE_CODE_AUTO_COMPACT_WINDOW (verified present in this
# script's environment). Measure against that, or the bar reads 11% while a
# third of the budget is already gone.
# cw_size / used_tokens / hit_ratio come from the single jq pass at the top.
budget=$cw_size
acw=$CLAUDE_CODE_AUTO_COMPACT_WINDOW
case "$acw" in
  '' | *[!0-9]*) ;;   # unset, or not a plain integer: keep the catalog window
  *)
    if [ -n "$cw_size" ] && [ "$acw" -gt 0 ] && [ "$acw" -lt "$cw_size" ]; then
      budget=$acw
    fi
    ;;
esac

if [ -n "$used_tokens" ] && [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null; then
  used_int=$(( (used_tokens * 100 + budget / 2) / budget ))
else
  used_int=${used_pct%%.*}
  [ -z "$used_int" ] && used_int=0
fi

bar_filled=$(( used_int / 5 ))
bar_empty=$(( 20 - bar_filled ))
[ "$bar_empty" -lt 0 ] && bar_empty=0
[ "$bar_filled" -gt 20 ] && bar_filled=20

# Per-cell gradient. Each filled cell takes its colour from its own position
# along the bar, so a half-full bar runs green into yellow while a nearly-full
# one reaches red at its right edge -- the colour of the leading cell tells you
# the level at a glance, and the trail behind it shows how you got there.
#
# Muted 256-colour ramp. The vivid primaries (46/226/196) glare against a dark
# terminal; these are their desaturated neighbours, listed from low usage to
# high: sage green -> olive -> amber -> clay -> brick.
bar_palette=(71 107 143 179 180 221 216 215 209 203 167)
bar=""
i=0
while [ "$i" -lt "$bar_filled" ]; do
  pidx=$(( i * 10 / 19 ))
  [ "$pidx" -gt 10 ] && pidx=10
  bar="${bar}"$'\033'"[38;5;${bar_palette[$pidx]}m█"
  i=$((i + 1))
done
if [ "$bar_empty" -gt 0 ]; then
  tail_cells=""
  i=0
  while [ "$i" -lt "$bar_empty" ]; do tail_cells="${tail_cells}░"; i=$((i + 1)); done
  bar="${bar}${dim}${tail_cells}"
fi
bar="${bar}${reset}"

# The percentage keeps the coarse level colour so the number stays legible even
# where the gradient's last cell is still green (low usage).
if [ "$used_int" -lt 50 ]; then
  bar_color=$'\033[32m'
elif [ "$used_int" -lt 80 ]; then
  bar_color=$'\033[33m'
else
  bar_color=$'\033[31m'
fi

# The bar carries only the visual plus its percentage; line 2 spells out the
# token counts, so repeating them here would just be noise.
context_bar="${bar} ${bar_color}${used_int}%${reset}"

# Prompt-cache hit rate. Higher is better, so the colour scale runs the
# opposite way to the context bar: >=95% green, 80-95% orange, below that
# shading to red as the hit rate falls.
cache_str=""
if [ -n "$cache_hit" ] && [ "$cache_hit" != "null" ]; then
  hit_int=$(printf '%s' "$cache_hit" | awk '{printf "%d", ($1 * 100) + 0.5}')
  case "$hit_int" in
    '' | *[!0-9]*) hit_int=0 ;;
  esac
  if [ "$hit_int" -ge 95 ]; then
    cache_color=$'\033[32m'
  elif [ "$hit_int" -ge 80 ]; then
    cache_color=$'\033[33m'
  else
    cache_color=$'\033[31m'
  fi
  cache_str="${cache_color}warm ${hit_int}%${reset}"
fi

# --- Line 2: context detail -----------------------------------------------
# Line 1 carries identity (model, branch, directory). Line 2 carries the context
# budget: the bar, then tokens against the budget and the last response's output.

# Token counts are shown in k, the unit people are used to for context budgets.
# Whole thousands drop the decimal (400k, not 400.0k) and values under 1000 stay
# raw ("out 420" reads better than "out 0.4k").
fmt_k() {
  case "$1" in
    '' | *[!0-9]*) return ;;
  esac
  if [ "$1" -lt 1000 ]; then
    printf '%d' "$1"
  elif [ $(( $1 % 1000 )) -eq 0 ]; then
    printf '%dk' $(( $1 / 1000 ))
  else
    printf '%d.%dk' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 ))
  fi
}

ctx_parts=""
if [ -n "$used_tokens" ] && [ "$used_tokens" != "null" ]; then
  if [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null; then
    ctx_parts="$(fmt_k "$used_tokens")${dim}/${reset}$(fmt_k "$budget")"
  else
    ctx_parts="$(fmt_k "$used_tokens")"
  fi
fi

# Per-call token accounting, all from `current_usage` (one API response):
#   in    fresh input + cache creation -- what the request actually paid to send
#   out   output of that same response
#   cache cache reads served for that request (cheap, but it is most of the
#         prompt, so it explains why `in` looks small next to the cumulative
#         context figure on the left)
# Unlike `114.8k/400k`, none of these are cumulative.
#
# Labels recede and values stay bright, so the row scans as numbers rather than
# as words. The units are uniform ("k") and the labels are all three letters
# wide except `out`, which keeps the columns from shifting as values change.
io_parts=""
if [ -n "$cache_read_tokens" ] && [ "$cache_read_tokens" != "null" ] && [ "$cache_read_tokens" != "0" ]; then
  io_parts="${dim}cache${reset} $(fmt_k "$cache_read_tokens")"
fi
if [ -n "$in_tokens" ] && [ "$in_tokens" != "null" ]; then
  io_parts="${io_parts:+${io_parts}  }${dim}in${reset} $(fmt_k "$in_tokens")"
fi
if [ -n "$out_tokens" ] && [ "$out_tokens" != "null" ]; then
  io_parts="${io_parts:+${io_parts}  }${dim}out${reset} $(fmt_k "$out_tokens")"
fi

# --- Output ---------------------------------------------------------------
# Two rows, two jobs. Line 1 is identity -- what session you are in. Line 2 is
# the context budget, which is what moves turn to turn, so it gets the bar and
# the numbers.
#
# Groups are separated by a dim rule rather than only whitespace: at this
# density three spaces is not enough contrast between "next field" and "next
# group", and the rule costs one glyph. Narrow terminals drop the least
# important group first instead of wrapping into a second visual line.
term_cols=${COLUMNS:-0}
case "$term_cols" in
  '' | *[!0-9]*) term_cols=0 ;;
esac

join_groups() {
  local out="" seg
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    out="${out:+${out}   ${sep}   }${seg}"
  done
  printf '%s' "$out"
}

# Visible width, ignoring ANSI escapes and counting wide characters as 2 so the
# budget below matches what the terminal actually draws.
vis_width() {
  printf '%s' "$1" \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk 'BEGIN{n=0} {
        s=$0; gsub(/\x1b\[[0-9;]*m/,"",s);
        n=0;
        for (i=1;i<=length(s);i++) {
          c=substr(s,i,1);
          n += (c ~ /[\x00-\x7f]/) ? 1 : 2
        }
        print n
      }'
}

# Line 1 can outgrow the terminal when the model id and the directory are both
# long, which is the common case behind a gateway. Shed the least useful part
# first: the directory tail keeps its last components (the ones that identify
# the project), and the model falls back to its final path segment.
shorten_path() {
  local p="$1" limit="${2:-40}"
  if [ "$(vis_width "$p")" -le "$limit" ]; then printf '%s' "$p"; return; fi
  printf '…/%s' "${p##*/}"
}

line1=$(join_groups "$model_str" "$git_info" "$path_info")
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  path_info=$(shorten_path "$path_info" 24)
  line1=$(join_groups "$model_str" "$git_info" "$path_info")
fi
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  # Drop the directory: the branch already implies the repo in most sessions.
  line1=$(join_groups "$model_str" "$git_info")
fi
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  # Effort and thinking recede before anything identifying does.
  model_str=$(printf '%s' "$model_str" | sed 's/ · thinking$//')
  line1=$(join_groups "$model_str" "$git_info")
fi
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  model_str=$(printf '%s' "$model_str" | sed 's/ · [A-Za-z]*$//')
  line1=$(join_groups "$model_str" "$git_info")
fi
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  # A gateway route such as "moma/deepseek-latest-flash → deepseek-v4.1-flash-1017"
  # is now the longest field. Keep the answered model: it is the one producing
  # tokens, and the provider half is implied by having configured it.
  case "$model_str" in
    *' → '*) model_str="${model_str##*→ }" ;;
  esac
  line1=$(join_groups "$model_str" "$git_info")
fi
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  # Last resort: the model alone. Truncating it would mangle the very field the
  # row exists to report, so the branch yields instead.
  line1="$model_str"
fi

# Below ~100 columns the per-call trio is the first thing to go: it is the most
# detailed and the least frequently consulted. Below ~80 the cache figure goes
# too, leaving the bar and its token count.
line2_groups=("$context_bar" "$ctx_parts")
if [ "$term_cols" -eq 0 ] || [ "$term_cols" -ge 100 ]; then
  line2_groups+=("$io_parts")
fi
if [ "$term_cols" -eq 0 ] || [ "$term_cols" -ge 80 ]; then
  line2_groups+=("$cache_str")
fi
line2=$(join_groups "${line2_groups[@]}")

printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
exit 0
