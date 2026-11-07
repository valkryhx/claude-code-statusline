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

jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# --- Line 1: model + git + path + context ---------------------------------
model=$(jqr '.model.display_name // "Unknown"')
cwd=$(jqr '.workspace.current_dir // .cwd // "."')

# Reasoning effort and extended thinking. Both are optional in the payload:
# `effort` is absent on models without reasoning effort, `thinking` is always
# present but only meaningful when enabled.
effort=$(jqr '.effort.level // empty')
thinking=$(jqr '.thinking.enabled // empty')

model_str="🤖 ${model}"
if [ -n "$effort" ]; then
  model_str="${model_str} · ${effort}"
fi
if [ "$thinking" = "true" ]; then
  model_str="${model_str} 🧠"
fi

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  diff_stats=$(git -C "$cwd" diff --shortstat HEAD 2>/dev/null)
  added=$(printf '%s' "$diff_stats" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
  deleted=$(printf '%s' "$diff_stats" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
  [ -z "$added" ] && added=0
  [ -z "$deleted" ] && deleted=0
  git_info="🌿 ${branch} ${green}+${added}${reset}/${red}-${deleted}${reset}"
else
  git_info="🌿 no git"
fi

# Project directory, shown relative to $HOME as ~/... when it lives there.
# CC sends native separators on Windows (D:\repo\x), while Git Bash's $HOME is a
# posix path (/c/Users/...). Keep two forms: `disp` is what we print (just
# separators normalised, drive letter intact), `posix` adds the /x drive prefix
# so it can be compared against $HOME.
slashify() { printf '%s' "$1" | tr '\\' '/'; }
to_posix() {
  p=$(slashify "$1")
  case "$p" in
    [A-Za-z]:/*) printf '/%s%s' "$(printf '%s' "${p%%:*}" | tr 'A-Z' 'a-z')" "${p#?:}" ;;
    *)           printf '%s' "$p" ;;
  esac
}
cwd_disp=$(slashify "$cwd")
cwd_posix=$(to_posix "$cwd")
home_posix=$(to_posix "$HOME")
case "$cwd_posix" in
  "$home_posix")   dir_disp="~" ;;
  "$home_posix"/*) dir_disp="~${cwd_posix#"$home_posix"}" ;;
  *)               dir_disp="$cwd_disp" ;;
esac
path_info="📁 ${dir_disp}"

# --- Context budget --------------------------------------------------------
# Claude Code's .context_window.context_window_size comes from its model
# catalog, not from your proxy config: the claude-opus-5 entry declares a 1M
# native window, so CC reports 1000000 even when the real usable budget is
# smaller. The window that actually fires is the auto-compact window, which
# cc-switch pins via CLAUDE_CODE_AUTO_COMPACT_WINDOW (verified present in this
# script's environment). Measure against that, or the bar reads 11% while a
# third of the budget is already gone.
cw_size=$(jqr '.context_window.context_window_size // empty')
used_tokens=$(jqr '.context_window.total_input_tokens // empty')

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
  used_pct=$(jqr '.context_window.used_percentage // empty')
  used_int=${used_pct%%.*}
  [ -z "$used_int" ] && used_int=0
fi

bar_filled=$(( used_int / 5 ))
bar_empty=$(( 20 - bar_filled ))
[ "$bar_empty" -lt 0 ] && bar_empty=0
[ "$bar_filled" -gt 20 ] && bar_filled=20

bar=""
i=0
while [ "$i" -lt "$bar_filled" ]; do bar="${bar}█"; i=$((i + 1)); done
i=0
while [ "$i" -lt "$bar_empty" ]; do bar="${bar}░"; i=$((i + 1)); done

if [ "$used_int" -lt 50 ]; then
  bar_color=$'\033[32m'
elif [ "$used_int" -lt 80 ]; then
  bar_color=$'\033[33m'
else
  bar_color=$'\033[31m'
fi

# token counts: "<used>k/<budget>k"
tokens_str=""
if [ -n "$used_tokens" ] && [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null; then
  used_k=$(printf '%d.%d' $(( used_tokens / 1000 )) $(( (used_tokens % 1000) / 100 )))
  budget_k=$(printf '%d' $(( budget / 1000 )))
  tokens_str=" ${used_k}k/${budget_k}k"
elif [ -n "$used_tokens" ] && [ "$used_tokens" != "null" ]; then
  tokens_str=$(printf ' %dk' $(( used_tokens / 1000 )))
fi

context_bar="💭 ${bar_color}${bar}${reset} ${used_int}%${dim}${tokens_str}${reset}"

# --- Line 2: cost + reset (ccusage, cached 5 min) + cache health ----------
cache_file="$HOME/.claude/ccusage-cache.json"
cache_max_age=300

# Portable mtime: GNU first (Git Bash / Linux), BSD second (macOS).
get_mtime() {
  stat -c %Y "$1" 2>/dev/null && return 0
  stat -f %m "$1" 2>/dev/null && return 0
  return 1
}

needs_refresh=1
if [ -f "$cache_file" ]; then
  cache_mtime=$(get_mtime "$cache_file")
  case "$cache_mtime" in
    ''|*[!0-9]*) needs_refresh=1 ;;
    *)
      now=$(date +%s)
      if [ $(( now - cache_mtime )) -lt $cache_max_age ]; then
        needs_refresh=0
      fi
      ;;
  esac
fi

if [ "$needs_refresh" -eq 1 ]; then
  ccusage_out=$(ccusage blocks --json 2>/dev/null)
  if [ -n "$ccusage_out" ] && printf '%s' "$ccusage_out" | jq . >/dev/null 2>&1; then
    printf '%s' "$ccusage_out" > "$cache_file"
  fi
fi

if [ -f "$cache_file" ]; then
  ccusage_out=$(cat "$cache_file")
  active_block=$(printf '%s' "$ccusage_out" | jq -c '[.blocks[] | select(.isActive == true)] | last' 2>/dev/null)
  if [ -z "$active_block" ] || [ "$active_block" = "null" ]; then
    active_block=$(printf '%s' "$ccusage_out" | jq -c '.blocks | last' 2>/dev/null)
  fi

  cost_usd=$(printf '%s' "$active_block" | jq -r '.costUSD // 0' 2>/dev/null)
  case "$cost_usd" in
    ''|*[!0-9.]*) cost_usd=0 ;;
  esac
  cost_str=$(printf "💰 \$%.2f spent" "$cost_usd")

  end_time=$(printf '%s' "$active_block" | jq -r '.endTime // empty' 2>/dev/null)
  if [ -n "$end_time" ]; then
    end_epoch=$(date -d "${end_time}" +%s 2>/dev/null || \
                date -jf "%Y-%m-%dT%H:%M:%S" "${end_time%%.*}" +%s 2>/dev/null || \
                echo "0")
    case "$end_epoch" in
      ''|*[!0-9]*) end_epoch=0 ;;
    esac
    now_epoch=$(date +%s)
    diff_secs=$(( end_epoch - now_epoch ))
    if [ "$diff_secs" -gt 0 ]; then
      hours=$(( diff_secs / 3600 ))
      mins=$(( (diff_secs % 3600) / 60 ))
      time_str="⏱️  ${hours}h ${mins}m until reset"
    else
      time_str="⏱️  resetting…"
    fi
  else
    time_str="⏱️  —"
  fi
else
  cost_str="💰 —"
  time_str="⏱️  —"
fi

# Prompt-cache health (319 statusLine payload: prompt_cache.*)
cache_health=$(jqr '.prompt_cache.warm // empty')
hit_ratio=$(jqr '.prompt_cache.hit_ratio // empty')
cache_str=""
if [ -n "$cache_health" ] && [ "$cache_health" != "null" ]; then
  if [ "$cache_health" = "true" ]; then
    cache_str="${green}🗄 warm${reset}"
  else
    cache_str="${yellow}🗄 cold${reset}"
  fi
  if [ -n "$hit_ratio" ] && [ "$hit_ratio" != "null" ]; then
    cache_str="${cache_str}${dim}$(printf '%s' "$hit_ratio" | awk '{printf " %.0f%%", $1*100}')${reset}"
  fi
fi

# --- Output ---------------------------------------------------------------
if [ -n "$cache_str" ]; then
  printf '%s   %s   %s   %s\n' "${model_str}" "${git_info}" "${path_info}" "${context_bar}"
  printf '%s   %s   %s\n' "${cost_str}" "${time_str}" "${cache_str}"
else
  printf '%s   %s   %s   %s\n' "${model_str}" "${git_info}" "${path_info}" "${context_bar}"
  printf '%s   %s\n' "${cost_str}" "${time_str}"
fi
