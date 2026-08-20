#!/usr/bin/env bash
# Claude Code status line — Two-line Powerline layout
# ┌ Line 1: 📁 DIR │  GIT ±N ▶ MOD │ STY │ THK │ SKL │ AGT
# └ Line 2: CTX [▓▓░░] % │ 💲 cost │ ⏱ 5h │ 📅 7d │ 📊 session
# Requires: jq, Nerd Font (FiraCode Nerd Font)

input=$(cat)

# ══════════════════════════════════════════
# ANSI Colors & Styles
# ══════════════════════════════════════════
reset=$'\e[0m'
bold=$'\e[1m'
dim=$'\e[2m'

# Background colors
bg_left=$'\e[48;5;236m'      # dark gray — left panel
bg_right=$'\e[48;5;234m'     # darker gray — right panel
bg_line2=$'\e[48;5;235m'     # medium gray — line 2

# Left panel (line 1)
c_folder=$'\e[38;5;75m'      # blue — folder
c_branch=$'\e[38;5;114m'     # green — git branch
c_changes=$'\e[38;5;215m'    # orange — changes
c_clean=$'\e[38;5;114m'      # green — clean
c_sep_l=$'\e[38;5;245m'      # gray — separators

# Right panel (line 1)
c_label=$'\e[38;5;245m'      # gray — labels
c_model=$'\e[38;5;183m'      # purple — model
c_style=$'\e[38;5;216m'      # peach — style
c_think_on=$'\e[38;5;156m'   # green — thinking ON
c_think_off=$'\e[38;5;245m'  # gray — thinking OFF
c_skills=$'\e[38;5;147m'     # lavender — skills
c_agent=$'\e[38;5;210m'      # salmon — agents
c_sep_r=$'\e[38;5;242m'      # separator right

# Line 2 — metrics
c_ctx=$'\e[38;5;81m'         # cyan — context
c_ctx_warn=$'\e[38;5;215m'   # orange — ctx > 70%
c_ctx_crit=$'\e[38;5;203m'   # red — ctx > 90%
c_bar_fill=$'\e[38;5;81m'    # cyan — bar filled
c_bar_empty=$'\e[38;5;240m'  # dark — bar empty
c_bar_warn=$'\e[38;5;215m'   # orange — bar > 70%
c_bar_crit=$'\e[38;5;203m'   # red — bar > 90%
c_cost=$'\e[38;5;228m'       # yellow — cost
c_limit=$'\e[38;5;117m'      # blue — rate limits
c_limit_warn=$'\e[38;5;215m' # orange — limits > 70%
c_limit_crit=$'\e[38;5;203m' # red — limits > 90%
c_session=$'\e[38;5;250m'    # light gray — session info
c_lines_add=$'\e[38;5;114m'  # green — lines added
c_lines_del=$'\e[38;5;203m'  # red — lines removed
c_sep_2=$'\e[38;5;242m'      # separator line 2

# Powerline transition
arrow_fg=$'\e[38;5;236m'
arrow_bg=$'\e[48;5;234m'

# Icons (hex escape for PUA icons that don't survive file writes)
ico_folder="📁"
ico_git=$(printf '\xee\x9c\xa5')    # U+E725 nf-dev-git_branch
ico_changes="󰏫"
ico_clean="󰄬"
ico_model="󰧑"
ico_style="󰃣"
ico_arrow=$(printf '\xee\x82\xb0')  # U+E0B0 nf-pl-left_hard_divider

# ══════════════════════════════════════════
# Parse ALL JSON fields
# ══════════════════════════════════════════

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
model_id=$(echo "$input" | jq -r '.model.id // ""')
style=$(echo "$input" | jq -r '.output_style.name // empty')

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
used_pct_int=$(printf "%.0f" "${used_pct:-0}" 2>/dev/null || echo "0")
remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
dir=$(basename "${cwd:-.}")

git_branch=""
git_changes=""
git_added=""
git_deleted=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  git_changes=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | xargs)
  # Lines added/deleted (git diff --numstat → sum)
  git_added=$(git -C "$cwd" diff --numstat 2>/dev/null | awk '{a+=$1} END {if(a>0) print a}')
  git_deleted=$(git -C "$cwd" diff --numstat 2>/dev/null | awk '{d+=$2} END {if(d>0) print d}')
fi

five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
api_duration_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')

session_id=$(echo "$input" | jq -r '.session_id // empty')
version=$(echo "$input" | jq -r '.version // empty')

agent_name=$(echo "$input" | jq -r '.agent.name // empty')
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')

# Thinking mode — detect effort level (low/medium/high/max)
thinking="off"
thinking_level=""
if [[ "$model_id" =~ (opus|sonnet) ]] && [[ "$CLAUDE_CODE_DISABLE_THINKING" != "1" ]] && [[ "$MAX_THINKING_TOKENS" != "0" ]]; then
  thinking="on"
  # Effort level: env var > project settings > user settings > default (medium)
  if [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    thinking_level="$CLAUDE_CODE_EFFORT_LEVEL"
  else
    # Check project settings first, then user settings
    for sf in "${cwd}/.claude/settings.json" "$HOME/.claude/settings.json"; do
      if [ -f "$sf" ]; then
        lvl=$(jq -r '.effortLevel // empty' "$sf" 2>/dev/null)
        if [ -n "$lvl" ]; then
          thinking_level="$lvl"
          break
        fi
      fi
    done
    thinking_level="${thinking_level:-medium}"
  fi
fi

# Skills count
skills_dir="$HOME/.claude/skills"
if [ -d "$skills_dir" ]; then
  skill_count=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d ! -name '_shared' 2>/dev/null | wc -l | xargs)
else
  skill_count=0
fi

# Worktree count
worktree_count=0
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  worktree_count=$(git -C "$cwd" worktree list 2>/dev/null | wc -l | xargs)
  worktree_count=$(( worktree_count - 1 ))
  [ "$worktree_count" -lt 0 ] && worktree_count=0
fi

# Duration formatting (ms → human readable)
format_duration() {
  local ms=$1
  if [ -z "$ms" ] || [ "$ms" = "null" ]; then echo "--"; return; fi
  local sec=$(( ms / 1000 ))
  if [ "$sec" -lt 60 ]; then
    echo "${sec}s"
  elif [ "$sec" -lt 3600 ]; then
    echo "$(( sec / 60 ))m$(( sec % 60 ))s"
  else
    echo "$(( sec / 3600 ))h$(( sec / 60 % 60 ))m"
  fi
}

# Token formatting (1234567 → 1.2M, 12345 → 12.3k)
format_tokens() {
  local t=$1
  if [ -z "$t" ] || [ "$t" = "null" ]; then echo "--"; return; fi
  if [ "$t" -ge 1000000 ] 2>/dev/null; then
    awk "BEGIN { printf \"%.1fM\", $t / 1000000 }"
  elif [ "$t" -ge 1000 ] 2>/dev/null; then
    awk "BEGIN { printf \"%.1fk\", $t / 1000 }"
  else
    echo "$t"
  fi
}

# Reset countdown (unix timestamp → "⟳2h13m", "⟳3d5h", "⟳45m")
format_reset() {
  local ts=$1
  if [ -z "$ts" ] || [ "$ts" = "null" ]; then return; fi
  local now diff
  now=$(date +%s)
  diff=$(( ts - now ))
  [ "$diff" -le 0 ] && echo "⟳now" && return
  if [ "$diff" -ge 86400 ]; then
    printf "⟳%dd%dh" $(( diff / 86400 )) $(( diff % 86400 / 3600 ))
  elif [ "$diff" -ge 3600 ]; then
    printf "⟳%dh%dm" $(( diff / 3600 )) $(( diff % 3600 / 60 ))
  elif [ "$diff" -ge 60 ]; then
    printf "⟳%dm" $(( diff / 60 ))
  else
    printf "⟳%ds" "$diff"
  fi
}

# Context size label (200000 → 200k, 1000000 → 1M)
ctx_label=""
if [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ]; then
  ctx_label=$(format_tokens "$ctx_size")
fi

# ══════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════
pick_color() {
  local pct=$1 normal=$2 warn=$3 crit=$4
  if [ "$pct" -ge 90 ] 2>/dev/null; then
    echo "$crit"
  elif [ "$pct" -ge 70 ] 2>/dev/null; then
    echo "$warn"
  else
    echo "$normal"
  fi
}

progress_bar() {
  local pct=$1 total=${2:-10}
  local normal=$3 warn=$4 crit=$5
  local pct_int
  pct_int=$(printf "%.0f" "$pct" 2>/dev/null || echo "0")
  local filled=$(( pct_int * total / 100 ))
  [ "$filled" -gt "$total" ] && filled=$total
  [ "$filled" -lt 0 ] && filled=0
  local empty=$(( total - filled ))
  local bar_color
  bar_color=$(pick_color "$pct_int" "$normal" "$warn" "$crit")
  local bar="" empty_part=""
  for ((i=0; i<filled; i++)); do bar+="▓"; done
  for ((i=0; i<empty; i++)); do empty_part+="░"; done
  printf '%s%s%s%s' "$bar_color" "$bar" "${c_bar_empty}" "$empty_part"
}

# ══════════════════════════════════════════════════════════════
# 4 flat rows — no panels, uniform backgrounds per row
# R1: 📁 DIR │  GIT ±N (+added -deleted)
# R2: MOD 󰧑 model │ STY 󰃣 style │ THK 🧠 level │ SKL 󰯁 N │ AGT
# R3: CTX [▓▓░░░░░░░░░░] %% (size) │ 󰧑 ↓in ↑out
# R4: 💲cost │ 󱑂 5h [▓▓░░░░░░░░░░] %% ⟳reset │ 󰃭 7d [▓▓░░░░░░░░░░] %% ⟳reset │ ⏱ dur │ ver
# ══════════════════════════════════════════════════════════════

bg_r1=$'\e[48;5;235m'   # row 1 — dark (odd)
bg_r2=$'\e[48;5;237m'   # row 2 — light (even)
bg_r3=$'\e[48;5;235m'   # row 3 — dark (odd)
bg_r4=$'\e[48;5;237m'   # row 4 — light (even)
sep=$'\e[38;5;242m'      # separator color for all rows

# ── Row 1: Dir + Git ──
R1="${bg_r1} "
R1+="${c_folder}${bold}${ico_folder} ${dir}${reset}${bg_r1}"
if [ -n "$git_branch" ]; then
  R1+=" ${sep}▸${reset}${bg_r1} "
  R1+="${c_branch}${bold}${ico_git} ${git_branch}${reset}${bg_r1}"
  if [ "$git_changes" -gt 0 ] 2>/dev/null; then
    R1+=" ${c_changes}${ico_changes} ${git_changes}${reset}${bg_r1}"
  else
    R1+=" ${c_clean}${ico_clean}${reset}${bg_r1}"
  fi
  if [ -n "$git_added" ] || [ -n "$git_deleted" ]; then
    R1+=" ${sep}(${reset}${bg_r1}"
    [ -n "$git_added" ] && R1+="${c_lines_add}+${git_added}${reset}${bg_r1}"
    [ -n "$git_added" ] && [ -n "$git_deleted" ] && R1+=" "
    [ -n "$git_deleted" ] && R1+="${c_lines_del}-${git_deleted}${reset}${bg_r1}"
    R1+="${sep})${reset}${bg_r1}"
  fi
fi
R1+=" ${reset}"

# ── Row 2: AI Config ──
R2="${bg_r2} "
R2+="${c_label}${dim}MOD${reset}${bg_r2} ${c_model}${bold}${ico_model} ${model}${reset}${bg_r2}"
if [ -n "$style" ] && [ "$style" != "null" ]; then
  R2+=" ${sep}▸${reset}${bg_r2} ${c_label}${dim}STY${reset}${bg_r2} ${c_style}${ico_style} ${style}${reset}${bg_r2}"
fi
R2+=" ${sep}▸${reset}${bg_r2} ${c_label}${dim}THK${reset}${bg_r2} "
if [ "$thinking" = "on" ]; then
  case "$thinking_level" in
    low)  R2+="${c_think_off}🧠 LOW${reset}${bg_r2}" ;;
    high) R2+="${c_think_on}${bold}🧠 HIGH${reset}${bg_r2}" ;;
    max)  c_think_max=$'\e[38;5;213m'; R2+="${c_think_max}${bold}🧠 MAX${reset}${bg_r2}" ;;
    *)    R2+="${c_think_on}🧠 MED${reset}${bg_r2}" ;;
  esac
else
  R2+="${c_think_off}🧠 OFF${reset}${bg_r2}"
fi
R2+=" ${sep}▸${reset}${bg_r2} ${c_label}${dim}SKL${reset}${bg_r2} ${c_skills}󰯁 ${skill_count}${reset}${bg_r2}"
if [ -n "$agent_name" ] || [ "$worktree_count" -gt 0 ]; then
  R2+=" ${sep}▸${reset}${bg_r2} ${c_label}${dim}AGT${reset}${bg_r2} "
  [ -n "$agent_name" ] && R2+="${c_agent}󰚔 ${agent_name}${reset}${bg_r2}"
  if [ "$worktree_count" -gt 0 ]; then
    [ -n "$agent_name" ] && R2+=" "
    R2+="${c_agent}+${worktree_count}wt${reset}${bg_r2}"
  fi
fi
R2+=" ${reset}"

# ── Row 3: Context + Tokens ──
R3="${bg_r3} "
R3+="${c_label}${dim}CTX${reset}${bg_r3} "
if [ -n "$used_pct" ]; then
  bar=$(progress_bar "$used_pct" 12 "$c_bar_fill" "$c_bar_warn" "$c_bar_crit")
  ctx_color=$(pick_color "$used_pct_int" "$c_ctx" "$c_ctx_warn" "$c_ctx_crit")
  R3+="${sep}[${bar}${reset}${bg_r3}${sep}]${reset}${bg_r3} "
  R3+="${ctx_color}${bold}$(printf "%.0f%%" "$used_pct")${reset}${bg_r3}"
  [ -n "$ctx_label" ] && R3+=" ${dim}(${ctx_label})${reset}${bg_r3}"
  [ "$exceeds_200k" = "true" ] && R3+=" ${c_ctx_crit}${bold}⚠ >200k${reset}${bg_r3}"
else
  R3+="${sep}[${c_bar_empty}░░░░░░░░░░░░${reset}${bg_r3}${sep}]${reset}${bg_r3} ${dim}--%${reset}${bg_r3}"
fi
if [ -n "$input_tokens" ] && [ "$input_tokens" != "null" ]; then
  in_fmt=$(format_tokens "$input_tokens")
  out_fmt=$(format_tokens "$output_tokens")
  R3+=" ${sep}▸${reset}${bg_r3} ${c_ctx}󰧑${reset}${bg_r3} ${c_lines_add}↓${in_fmt}${reset}${bg_r3} ${c_changes}↑${out_fmt}${reset}${bg_r3}"
fi
R3+=" ${reset}"

# ── Row 4: Usage (cost + rate limits with bars + duration + version) ──
R4="${bg_r4} "

# Cost
if [ -n "$cost_usd" ] && [ "$cost_usd" != "null" ]; then
  R4+="${c_cost}💲$(printf "%.2f" "$cost_usd")${reset}${bg_r4}"
fi

# Rate limit 5h — with progress bar
if [ -n "$five_pct" ]; then
  five_int=$(printf "%.0f" "$five_pct" 2>/dev/null || echo "0")
  lim_color=$(pick_color "$five_int" "$c_limit" "$c_limit_warn" "$c_limit_crit")
  bar_5h=$(progress_bar "$five_pct" 12 "$c_bar_fill" "$c_bar_warn" "$c_bar_crit")
  R4+=" ${sep}▸${reset}${bg_r4} ${lim_color}󱑂 5h${reset}${bg_r4} "
  R4+="${sep}[${bar_5h}${reset}${bg_r4}${sep}]${reset}${bg_r4} "
  R4+="${lim_color}${bold}$(printf "%.0f%%" "$five_pct")${reset}${bg_r4}"
  five_rst=$(format_reset "$five_reset")
  [ -n "$five_rst" ] && R4+=" ${c_changes}${five_rst}${reset}${bg_r4}"
fi

# Rate limit 7d — with progress bar
if [ -n "$week_pct" ]; then
  week_int=$(printf "%.0f" "$week_pct" 2>/dev/null || echo "0")
  lim_color=$(pick_color "$week_int" "$c_limit" "$c_limit_warn" "$c_limit_crit")
  bar_7d=$(progress_bar "$week_pct" 12 "$c_bar_fill" "$c_bar_warn" "$c_bar_crit")
  R4+=" ${sep}▸${reset}${bg_r4} ${lim_color}󰃭 7d${reset}${bg_r4} "
  R4+="${sep}[${bar_7d}${reset}${bg_r4}${sep}]${reset}${bg_r4} "
  R4+="${lim_color}${bold}$(printf "%.0f%%" "$week_pct")${reset}${bg_r4}"
  week_rst=$(format_reset "$week_reset")
  [ -n "$week_rst" ] && R4+=" ${c_changes}${week_rst}${reset}${bg_r4}"
fi

# Session duration
if [ -n "$duration_ms" ] && [ "$duration_ms" != "null" ]; then
  dur=$(format_duration "$duration_ms")
  R4+=" ${sep}▸${reset}${bg_r4} ${c_session}⏱ ${dur}${reset}${bg_r4}"
fi

# Version
if [ -n "$version" ] && [ "$version" != "null" ]; then
  R4+=" ${sep}▸${reset}${bg_r4} ${dim}v${version}${reset}${bg_r4}"
fi

R4+=" ${reset}"

# ══════════════════════════════════════════
# Output 4 rows
# ══════════════════════════════════════════

printf '%s\n' "$R1"
printf '%s\n' "$R2"
printf '%s\n' "$R3"
printf '%s\n' "$R4"
