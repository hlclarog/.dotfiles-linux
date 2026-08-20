# Claude Code — Statusline

Four-row statusline for [Claude Code](https://claude.ai/code) with Nerd Font icons, ANSI colors, progress bars, and dynamic thresholds. Zebra-stripe backgrounds with `▸` triangle separators.

## Preview

```
R1  📁 .dotfiles-mac ▸  master 󰄬 (+12 -3)
R2  MOD 󰧑 Claude Opus 4.6 (1M) ▸ STY 󰃣 Gentleman ▸ THK 🧠 MED ▸ SKL 󰯁 15
R3  CTX [▓▓▓▓▓░░░░░░░] 42% (1.0M) ▸ 󰧑 ↓425.0k ↑12.5k
R4  💲5.65 ▸ 󱑂 5h [▓▓▓▓▓▓▓░░░░░] 64% ⟳32m ▸ 󰃭 7d [▓▓▓░░░░░░░░░] 32% ⟳4d7h ▸ ⏱ 56m5s ▸ v2.1.90
```

## Features

### Row 1 — Project & Git

| Section | Icon | Description |
|---------|------|-------------|
| **DIR** | 📁 | Current project directory |
| **GIT** |  | Branch name + file count + line diff `(+N -N)` |

### Row 2 — AI Configuration

| Section | Icon | Description |
|---------|------|-------------|
| **MOD** | 󰧑 | Active Claude model |
| **STY** | 󰃣 | Output style (e.g., Gentleman) |
| **THK** | 🧠 | Thinking effort: `LOW` / `MED` / `HIGH` / `MAX` / `OFF` |
| **SKL** | 󰯁 | Number of skills in `~/.claude/skills/` |
| **AGT** | 󰚔 | Active agent name + worktree count (conditional) |

### Row 3 — Context Window

| Section | Icon | Description |
|---------|------|-------------|
| **CTX** | `[▓▓░░]` | Context window progress bar + percentage + window size |
| **Tokens** | 󰧑 | Input ↓ / Output ↑ token counts (formatted: k/M) |

### Row 4 — Usage & Session

| Section | Icon | Description |
|---------|------|-------------|
| **Cost** | 💲 | Session cost in USD |
| **5h** | 󱑂 | 5-hour rate limit progress bar + percentage + reset countdown |
| **7d** | 󰃭 | 7-day rate limit progress bar + percentage + reset countdown |
| **Duration** | ⏱ | Session duration (auto-formats: s/m/h) |
| **Version** | v | Claude Code version |

### Visual Design

- **Zebra-stripe backgrounds**: odd rows dark (#262626), even rows light (#3a3a3a)
- **Triangle separators**: `▸` in subtle gray between sections
- **Progress bars**: context window and both rate limits (5h, 7d) use `[▓▓░░]` bars
- **Reset countdown**: shown in orange after rate limit bars (e.g., `⟳32m`)

### Dynamic Colors

Thresholds apply to context window and rate limits:

| Range | Color | Meaning |
|-------|-------|---------|
| 0–69% | Cyan/Blue | Normal |
| 70–89% | Orange | Warning |
| 90–100% | Red | Critical |

Thinking level colors:
- **LOW** → gray
- **MED** → green
- **HIGH** → green bold
- **MAX** → magenta bold (Opus 4.6 only)

## Requirements

- **Claude Code** CLI or Desktop App
- **jq** — JSON parsing
- **git** — branch/diff info
- **awk** — numeric formatting
- **perl** — ANSI stripping
- **Nerd Font** — icon rendering (recommended: [FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads))

## Installation

### Automatic (recommended)

```bash
cd ~/.dotfiles/tools/claude-code   # or wherever this repo is cloned
bash install.sh
```

The installer will:
1. Check all dependencies
2. Copy `statusline-command.sh` to `~/.claude/`
3. Configure `settings.json` with the correct command path
4. Auto-detect OS (macOS/Linux/Windows) for the shell command
5. Run a verification test

### Manual

1. Copy the script:

```bash
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

2. Add to `~/.claude/settings.json`:

**macOS / Linux:**
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

**Windows (Git Bash / MSYS2):**
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash -l /c/Users/YOUR_USER/.claude/statusline-command.sh"
  }
}
```

3. Restart Claude Code.

## Customization

### Colors

Edit the ANSI color palette at the top of `statusline-command.sh`. Colors use 256-color codes (`\e[38;5;Nm`):

```bash
c_folder=$'\e[38;5;75m'      # blue — change this to your preference
c_branch=$'\e[38;5;114m'     # green
c_model=$'\e[38;5;183m'      # purple
```

Reference: [256 ANSI Color Chart](https://www.ditig.com/256-colors-cheat-sheet)

### Progress Bar

Adjust the bar length (default 12 blocks):

```bash
bar=$(progress_bar "$used_pct" 12 ...)   # change 12 to desired length
```

### Thresholds

Modify warning/critical breakpoints in `pick_color()`:

```bash
if [ "$pct" -ge 90 ]; then    # critical threshold
elif [ "$pct" -ge 70 ]; then  # warning threshold
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Icons show as `?` or boxes | Install a Nerd Font and set it in your terminal |
| No output | Run `echo '{}' \| bash ~/.claude/statusline-command.sh` — check for errors |
| `jq: command not found` | Install jq: `brew install jq` / `scoop install jq` / `apt install jq` |
| Colors not showing | Ensure terminal supports 256 colors (`echo $TERM` should be `xterm-256color`) |
| Git info missing | Script runs `git` in the workspace dir — ensure git is in PATH |
| Thinking shows OFF | Set `CLAUDE_CODE_EFFORT_LEVEL=medium` or use `/effort medium` in Claude Code |

## JSON Input Schema

The statusline script receives this JSON via stdin from Claude Code:

```
model.display_name, model.id, output_style.name,
context_window.{used_percentage, context_window_size, total_input_tokens, total_output_tokens},
workspace.current_dir, rate_limits.{five_hour, seven_day}.{used_percentage, resets_at},
cost.{total_cost_usd, total_duration_ms, total_lines_added, total_lines_removed},
session_id, version, exceeds_200k_tokens, agent.name, worktree.name
```

Full schema: [Claude Code Statusline Docs](https://docs.anthropic.com/en/docs/claude-code/statusline)
