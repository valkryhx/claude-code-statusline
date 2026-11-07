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

# The per-call trio (cache / in / out) gets one hue per figure so the group reads
# as a set at a glance, without the saturated primaries that glare against a dark
# background. Each hue comes in three weights, and the weight is what makes the
# number read as a number rather than as part of a word:
#
#   label  the word, at roughly a third of the value's brightness -- present but
#          clearly subordinate
#   value  bold and near the top of the hue's range, so the eye lands on digits
#   unit   the `k`, back down at label weight: it repeats identically every turn,
#          so it should not compete with the number it qualifies
#
# `out` is the only warm note on the row -- it marks the one figure that is not
# input, which is what makes the group scannable without reading the labels.
c_cache_v=$'\033[1m\033[38;2;176;226;240m'   # aqua
c_cache_l=$'\033[38;2;74;116;130m'
c_in_v=$'\033[1m\033[38;2;198;204;255m'      # periwinkle
c_in_l=$'\033[38;2;88;96;148m'
c_out_v=$'\033[1m\033[38;2;250;212;172m'     # amber
c_out_l=$'\033[38;2;140;106;72m'

# The cumulative figure on the left of the rule stays neutral: it is the number
# the bar above it already draws, so giving it a hue would put a fourth colour
# on a row whose point is that the three per-call figures are the coloured ones.
# It is still bold-and-dim pair, so it reads as a number rather than as text.
ctx_v=$'\033[1m'
ctx_u=$'\033[38;2;132;138;148m'

# Line 1's two variable values, same treatment as the token figures: bold, in a
# hue of their own, with their fixed companion words left dim. The branch is the
# louder of the two -- it is the only field that changes when you switch lines of
# work -- while the directory stays quiet enough to be read only when wanted.
# The branch hue is a cool teal, deliberately not the bar's blue: line 1 is
# identity, line 2 is budget, and sharing a hue would blur that split.
c_branch_v=$'\033[1m\033[38;2;148;226;213m'   # teal
c_clean=$'\033[38;2;110;136;132m'             # dim teal, for "clean"c_dir=$'\033[38;2;150;156;168m'               # quiet grey for the path

# A shared dim neutral for the small fixed words that caption a value (`hit`,
# `clean`, `no git`). One definition, so every caption on the row recedes by the
# same amount instead of each picking its own grey.
c_label=$'\033[38;2;118;124;134m'

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
  # NOT `// ""` here. The jq alternative operator treats `false` as empty, so
  # `false // ""` yields "" and a cold cache would read as "field absent" --
  # the `cold` note could never fire. Only `null` means absent for a boolean.
  (if .prompt_cache.warm == null then "" else (.prompt_cache.warm | tostring) end),
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
  # The branch name is a value, not a label: it changes as you switch branches
  # and it is the one field on this row that says which line of work you are on.
  # Bold plus its own hue lifts it off the row the same way the token figures are
  # lifted on line 2 -- the row keeps one highlighting idiom instead of two.
  # `stream` stays cool and distinct from the bar's blue so the two rows do not
  # read as one continuous ramp.
  branch_str="${c_branch_v}${branch}${reset}"
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
    git_info="${branch_str} ${green}+${added}${reset}/${red}-${deleted}${reset} ${yellow}?${untracked}${reset}"
  elif [ "$added" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    git_info="${branch_str} ${c_clean}clean${reset}"
  else
    git_info="${branch_str} ${green}+${added}${reset}/${red}-${deleted}${reset}"
  fi
else
  git_info="${c_clean}no git${reset}"
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
path_info="${c_dir}${dir_disp}${reset}"
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

# Per-cell gradient, true-colour. Each filled cell interpolates between colour
# stops by its own position along the bar, so the ramp is continuous instead of
# quantised to a handful of 256-colour slots (which banded visibly at two cells
# per step).
#
# Palette is selectable with CLAUDE_BAR. Every ramp starts cool and ends warm so
# high usage reads as heat even before you parse the percentage; what changes is
# how loud the journey is.
#
#   sky      ice -> pale azure -> airy blue, light at every fill level (default)
#   rose     pale pink -> rose -> cherry -> crimson
#   plasma   cyan -> violet -> magenta -> rose
#   aurora   mint -> sky -> indigo -> orchid
#   sunset   sand -> coral -> magenta -> plum
#   neon     lime -> cyan -> electric violet -> hot pink
#   sage     muted green -> brick, the low-glare option
#   slate    grey -> near white, monochrome
bar_theme=${CLAUDE_BAR:-sky}
case "$bar_theme" in
  sky)    stops=(226 244 254  199 232 253  167 217 252  135 200 249  104 180 243) ;;   # ice->pale azure->airy blue
  rose)   stops=(255 182 213  251 113 133  244 63 94  220 38 60  153 27 27) ;;
  plasma) stops=(34 211 238  99 102 241  168 85 247  236 72 153) ;;   # cyan->violet->magenta->rose
  aurora) stops=(52 211 153  56 189 248  79 70 229  232 121 249) ;;   # mint->sky->indigo->orchid
  sunset) stops=(251 191 36  251 146 60  244 63 94  192 38 211) ;;    # amber->coral->rose->plum
  neon)   stops=(163 230 53  34 211 238  139 92 246  255 0 128) ;;    # lime->cyan->violet->hotpink
  sage)   stops=(120 160 106 156 168 96 214 176 84 198 118 74 168 74 72) ;;
  slate)  stops=(110 118 128 156 164 174 208 212 218) ;;
  *)      stops=(226 244 254  199 232 253  167 217 252  135 200 249  104 180 243) ;;
esac

# Interpolate channel `ch` (0=R,1=G,2=B) of the stop list at `pos` (0-100).
# Stops are evenly spaced; the segment index is pos*(n-1)/100 and the fraction
# is what remains inside that segment, so pos=100 lands exactly on the last stop.
rgb_at() {
  local pos=$1 ch=$2
  local n=$(( ${#stops[@]} / 3 ))
  local seg=$(( pos * (n - 1) / 100 ))
  [ "$seg" -ge $(( n - 1 )) ] && seg=$(( n - 2 ))
  local lo=$(( seg * 100 / (n - 1) ))
  local hi=$(( (seg + 1) * 100 / (n - 1) ))
  local frac=$(( hi > lo ? (pos - lo) * 100 / (hi - lo) : 100 ))
  [ "$frac" -lt 0 ] && frac=0
  [ "$frac" -gt 100 ] && frac=100
  local a=$(( stops[seg * 3 + ch] ))
  local b=$(( stops[(seg + 1) * 3 + ch] ))
  printf '%d' $(( a + (b - a) * frac / 100 ))
}

bar=""
i=0
while [ "$i" -lt "$bar_filled" ]; do
  # Position of this cell along the *whole* bar, so a 40% bar stops at 40% of
  # the ramp rather than always reaching the end colour.
  cell_pos=$(( (i + 1) * 100 / 20 ))
  bar="${bar}"$'\033'"[38;2;$(rgb_at "$cell_pos" 0);$(rgb_at "$cell_pos" 1);$(rgb_at "$cell_pos" 2)m█"
  i=$((i + 1))
done
if [ "$bar_empty" -gt 0 ]; then
  # The unfilled run is a translucent metallic track.
  #
  # Terminals have no alpha, so translucency is done the way a terminal can: the
  # light-shade glyph ░ fills only ~25% of the cell, letting the background read
  # through -- that IS the transparency. The earlier ░ bar looked like noise
  # because it paired the sparse glyph with a dim colour; the sparse glyph needs
  # a bright ink to read as glass rather than grit.
  #
  # Metal comes from a sheen that runs along the track: a bright pale-blue at the
  # leading edge (where the fill ends, as if catching light) deepening toward the
  # far end. The blue lean keeps it in the same family as the sky ramp; the fade
  # is shallow, so the unfilled run stays airy rather than turning into a dark bar.
  #
  # CLAUDE_BAR_TRACK overrides the bright end as "r;g;b".
  tail_cells=""
  track_hi=${CLAUDE_BAR_TRACK:-186;210;232}
  tr_hi_r=${track_hi%%;*}
  tr_rest=${track_hi#*;}
  tr_hi_g=${tr_rest%%;*}
  tr_hi_b=${tr_rest#*;}
  fade_span=$bar_empty
  [ "$fade_span" -gt 1 ] && fade_span=$(( bar_empty - 1 ))
  i=0
  while [ "$i" -lt "$bar_empty" ]; do
    # Fall to ~62% of the bright end across the track, so the sheen has a
    # direction without the far end going dark -- the run should stay light.
    fade=$(( 100 - i * 38 / fade_span ))
    tr_r=$(( tr_hi_r * fade / 100 ))
    tr_g=$(( tr_hi_g * fade / 100 ))
    tr_b=$(( tr_hi_b * fade / 100 ))
    tail_cells="${tail_cells}"$'\033'"[38;2;${tr_r};${tr_g};${tr_b}m░"
    i=$((i + 1))
  done
  bar="${bar}${tail_cells}"
fi
bar="${bar}${reset}"

# The percentage takes the ramp's own colour at its position, so the number and
# the bar never disagree about which zone you are in. Lifted toward white
# proportional to how dark the stop is, so every position ends up with roughly
# the same legibility instead of the pale end reading bright and the red end
# reading muddy.
pct_pos=$used_int
[ "$pct_pos" -gt 100 ] && pct_pos=100
pct_r=$(rgb_at "$pct_pos" 0)
pct_g=$(rgb_at "$pct_pos" 1)
pct_b=$(rgb_at "$pct_pos" 2)
# Lift = how much headroom the darkest channel has. A pale stop needs almost
# none; the crimson end needs a lot to stay readable on a dark background.
pct_min=$pct_r
[ "$pct_g" -lt "$pct_min" ] && pct_min=$pct_g
[ "$pct_b" -lt "$pct_min" ] && pct_min=$pct_b
pct_lift=$(( 210 - pct_min ))
[ "$pct_lift" -lt 20 ] && pct_lift=20
[ "$pct_lift" -gt 62 ] && pct_lift=62
pct_r=$(( pct_r + (255 - pct_r) * pct_lift / 100 ))
pct_g=$(( pct_g + (255 - pct_g) * pct_lift / 100 ))
pct_b=$(( pct_b + (255 - pct_b) * pct_lift / 100 ))
bar_color=$'\033'"[38;2;${pct_r};${pct_g};${pct_b}m"

# The bar carries only the visual plus its percentage; line 2 spells out the
# token counts, so repeating them here would just be noise.
context_bar="${bar} ${bar_color}${used_int}%${reset}"

# Prompt-cache hit rate, from `.prompt_cache.hit_ratio`.
#
# This is a SESSION-WIDE figure, not this call's: CC keeps a ledger of every
# main-conversation request and accumulates cacheRead / cacheCreation / input
# tokens across them (m0494:1963, `summary()` at m0494:1983-1995), so the ratio
# is cache_read / (cache_read + cache_creation + uncached input) over the whole
# session. It is the field's own documented meaning ("cache_read / (cache_read
# + cache_creation + uncached input), 0-1", m0591:111909). For a single call's
# cache read, that is the `cache` figure to the left, which comes from
# `current_usage.cache_read_input_tokens` and is NOT divided by anything.
#
# The label therefore reads `hit`, not `warm`: `warm` is a different field
# in the same object (`.prompt_cache.warm`, a boolean for whether the cached
# prefix is still inside its TTL right now). Call it warm and the number
# invites exactly the wrong reading -- a temperature where a ratio belongs.
#
# Higher is better, so the colour scale runs the opposite way to the context
# bar: >=95% green, 80-95% orange, below that shading to red as the rate falls.
cache_str=""
if [ -n "$cache_hit" ] && [ "$cache_hit" != "null" ]; then
  hit_int=$(printf '%s' "$cache_hit" | awk '{printf "%d", ($1 * 100) + 0.5}')
  case "$hit_int" in
    '' | *[!0-9]*) hit_int=0 ;;
  esac
  # Same three-weight idiom as the token figures: the label drops to a dim
  # neutral, the number takes the zone's colour and bold, and the `%` falls back
  # to the label weight. An all-one-colour `hit 99%` put the word and the number
  # at the same emphasis, which is the complaint this answers -- the number is
  # the thing being reported, the word only names it.
  if [ "$hit_int" -ge 95 ]; then
    cache_color=$'\033[1m\033[32m'      # green
    cache_unit=$'\033[38;2;96;150;96m'
  elif [ "$hit_int" -ge 80 ]; then
    cache_color=$'\033[1m\033[38;2;226;184;88m'   # amber, lifted for dark bg
    cache_unit=$'\033[38;2;150;122;58m'
  else
    cache_color=$'\033[1m\033[38;2;232;112;112m'  # red, lifted
    cache_unit=$'\033[38;2;152;74;74m'
  fi
  cache_str="${c_label}hit${reset} ${cache_color}${hit_int}${reset}${cache_unit}%${reset}"
  # A stale prefix is the one cache condition worth a word of its own, because
  # the next request pays full price for the whole context. Shown beside the
  # ratio rather than replacing it: the ratio says how the session has gone,
  # this says what the next turn will cost.
  if [ "$cache_warm" = "false" ]; then
    cache_str="${cache_str} ${cache_unit}cold${reset}"
  fi
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

# Same figure, but the number and its `k` come back in two weights, so the unit
# reads as a suffix rather than as another digit. Callers pass the value colour
# and the (dimmer) unit colour.
fmt_k2() {
  local plain digits
  plain=$(fmt_k "$1")
  case "$plain" in
    *k) digits=${plain%k} ;;
    *)  digits=$plain ;;
  esac
  if [ "$digits" = "$plain" ]; then
    printf '%s%s%s' "$2" "$digits" "$reset"
  else
    printf '%s%s%s%s%s%s' "$2" "$digits" "$reset" "$3" "k" "$reset"
  fi
}

ctx_parts=""
if [ -n "$used_tokens" ] && [ "$used_tokens" != "null" ]; then
  if [ -n "$budget" ] && [ "$budget" -gt 0 ] 2>/dev/null; then
    ctx_parts="$(fmt_k2 "$used_tokens" "$ctx_v" "$ctx_u")${dim}/${reset}$(fmt_k2 "$budget" "$ctx_u" "$ctx_u")"
  else
    ctx_parts="$(fmt_k2 "$used_tokens" "$ctx_v" "$ctx_u")"
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
# Label, value and unit carry three different weights of one hue. The gap
# between them is what separates a number from the word next to it: the label
# sits around a third of the value's brightness and the value is bold, so at a
# glance the row is three coloured numbers with small captions, not a run of
# same-weight text. The `k` goes back to label weight -- it is identical every
# turn, so it should not compete with the digits.
io_parts=""
if [ -n "$cache_read_tokens" ] && [ "$cache_read_tokens" != "null" ] && [ "$cache_read_tokens" != "0" ]; then
  io_parts="${c_cache_l}cache${reset} $(fmt_k2 "$cache_read_tokens" "$c_cache_v" "$c_cache_l")"
fi
if [ -n "$in_tokens" ] && [ "$in_tokens" != "null" ]; then
  io_parts="${io_parts:+${io_parts}  }${c_in_l}in${reset} $(fmt_k2 "$in_tokens" "$c_in_v" "$c_in_l")"
fi
if [ -n "$out_tokens" ] && [ "$out_tokens" != "null" ]; then
  io_parts="${io_parts:+${io_parts}  }${c_out_l}out${reset} $(fmt_k2 "$out_tokens" "$c_out_v" "$c_out_l")"
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
#
# Operates on the plain text and re-applies the colour, so the escape sequence
# never reaches the `${p##*/}` split.
shorten_path() {
  local p="$1" limit="${2:-40}"
  if [ "$(vis_width "$p")" -le "$limit" ]; then printf '%s%s%s' "$c_dir" "$p" "$reset"; return; fi
  printf '%s…/%s%s' "$c_dir" "${p##*/}" "$reset"
}

line1=$(join_groups "$model_str" "$git_info" "$path_info")
if [ "$term_cols" -gt 0 ] && [ "$(vis_width "$line1")" -gt "$term_cols" ]; then
  path_info=$(shorten_path "$dir_disp" 24)
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
