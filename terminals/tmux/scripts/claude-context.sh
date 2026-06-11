#!/usr/bin/env bash
# Show Claude Code context window usage in tmux pane border.
# Usage: claude-context.sh <pane_pid>
# Only emits output when a Claude session is found as a descendant of the pane process.

PANE_PID="${1:-0}"
CONTEXT_MAX=200000
BAR_WIDTH=8
CACHE_DIR="/tmp/claude-tmux"
mkdir -p "$CACHE_DIR"

PANE_CACHE="$CACHE_DIR/pane-$PANE_PID"
OUTPUT_CACHE="$CACHE_DIR/ctx-$PANE_PID"

# --- Find claude PID for this pane (cached) ---

claude_pid=""
session_file=""

if [[ -f "$PANE_CACHE" ]]; then
  claude_pid=$(cat "$PANE_CACHE")
  if kill -0 "$claude_pid" 2>/dev/null && [[ -f "$HOME/.config/claude/sessions/${claude_pid}.json" ]]; then
    session_file="$HOME/.config/claude/sessions/${claude_pid}.json"
  else
    rm -f "$PANE_CACHE" "$OUTPUT_CACHE"
    claude_pid=""
  fi
fi

if [[ -z "$claude_pid" ]]; then
  for sf in "$HOME/.config/claude/sessions"/*.json; do
    [[ -f "$sf" ]] || continue
    pid=$(basename "$sf" .json)
    kill -0 "$pid" 2>/dev/null || continue
    # Walk up process tree from pid, looking for pane_pid as an ancestor
    current=$pid
    for _ in 1 2 3 4 5 6 7 8; do
      ppid=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')
      [[ -z "$ppid" || "$ppid" -le 1 ]] && break
      if [[ "$ppid" == "$PANE_PID" ]]; then
        claude_pid=$pid
        session_file=$sf
        echo "$claude_pid" > "$PANE_CACHE"
        break 2
      fi
      current=$ppid
    done
  done
fi

[[ -z "$session_file" ]] && exit 0

# --- Find JSONL for this session ---

session_id=$(grep -o '"sessionId":"[^"]*"' "$session_file" | cut -d'"' -f4)
[[ -z "$session_id" ]] && exit 0

jsonl_file=$(find "$HOME/.config/claude/projects" -name "${session_id}.jsonl" 2>/dev/null | head -1)
[[ -z "$jsonl_file" ]] && exit 0

# --- Check output cache (invalidate on JSONL mtime change) ---

jsonl_mtime=$(stat -f %m "$jsonl_file" 2>/dev/null)
if [[ -f "$OUTPUT_CACHE" ]]; then
  cached_mtime=$(head -1 "$OUTPUT_CACHE")
  if [[ "$cached_mtime" == "$jsonl_mtime" ]]; then
    tail -n +2 "$OUTPUT_CACHE"
    exit 0
  fi
fi

# --- Parse last assistant message token counts ---

last_line=$(grep '"type":"assistant"' "$jsonl_file" 2>/dev/null | tail -1)
[[ -z "$last_line" ]] && exit 0

input_tokens=$(echo "$last_line" | grep -o '"input_tokens":[0-9]*' | head -1 | cut -d: -f2)
cache_create=$(echo "$last_line" | grep -o '"cache_creation_input_tokens":[0-9]*' | head -1 | cut -d: -f2)
cache_read=$(echo "$last_line"   | grep -o '"cache_read_input_tokens":[0-9]*'   | head -1 | cut -d: -f2)

total=$(( ${input_tokens:-0} + ${cache_create:-0} + ${cache_read:-0} ))
[[ $total -eq 0 ]] && exit 0

# --- Render bar ---

pct=$((total * 100 / CONTEXT_MAX))
[[ $pct -gt 100 ]] && pct=100
filled=$((pct * BAR_WIDTH / 100))
empty=$((BAR_WIDTH - filled))

bar=""
for ((i = 0; i < filled; i++)); do bar+="█"; done
for ((i = 0; i < empty; i++)); do bar+="░"; done

if   [[ $pct -lt 50 ]]; then color="#[fg=green]"
elif [[ $pct -lt 80 ]]; then color="#[fg=yellow]"
else                          color="#[fg=red]"
fi

output=$(printf " %s󱙺 %s %d%%%s" "$color" "$bar" "$pct" "#[default]")

printf "%s\n%s" "$jsonl_mtime" "$output" > "$OUTPUT_CACHE"
printf "%s" "$output"
