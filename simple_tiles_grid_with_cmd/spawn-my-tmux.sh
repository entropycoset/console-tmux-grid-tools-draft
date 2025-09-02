#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
NUM_PANES=6
MIN_WIDTH=20
MIN_HEIGHT=10
SESSION="sess_$RANDOM"

# --- CHECKS ---
command -v tmux >/dev/null 2>&1 || { echo "tmux not found"; exit 1; }
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session $SESSION already exists, exiting"
    exit 1
fi

# --- CLEANUP ON ERROR ---
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

# --- CREATE DETACHED SESSION ---
PANE_IDS=()
PANE_IDS+=("$(tmux new-session -d -P -F "#{pane_id}" -s "$SESSION" -n main)")

# --- DETERMINE USABLE WINDOW SIZE ---
# Must query window_width/window_height for the detached session
term_width=$(tmux display-message -p -t "$SESSION":0 -F "#{window_width}")
term_height=$(tmux display-message -p -t "$SESSION":0 -F "#{window_height}")

# --- COMPUTE GRID (rows x cols) ---
rows=1
while true; do
    cols=$(( (NUM_PANES + rows - 1) / rows ))  # ceil(NUM_PANES / rows)
    pane_width=$(( term_width / cols ))
    pane_height=$(( term_height / rows ))
    if (( pane_width >= MIN_WIDTH && pane_height >= MIN_HEIGHT )); then
        break
    fi
    ((rows++))
done
cols=$(( (NUM_PANES + rows - 1) / rows ))
echo "Using grid: ${rows} rows x ${cols} columns (usable ${term_width}x${term_height})"

# --- SPLIT ROWS ---
for ((r=1; r<rows; r++)); do
    PANE_IDS+=("$(tmux split-window -v -t "${PANE_IDS[0]}" -P -F "#{pane_id}")")
done
ROW_PANES=("${PANE_IDS[@]}")

# --- SPLIT COLUMNS ---
NEW_PANE_IDS=()
for row_pane in "${ROW_PANES[@]}"; do
    NEW_PANE_IDS+=("$row_pane")
    for ((c=1; c<cols; c++)); do
        NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
    done
done

# Trim to exactly NUM_PANES
PANE_IDS=("${NEW_PANE_IDS[@]:0:NUM_PANES}")

# --- EVEN OUT LAYOUT ---
tmux select-layout -t "$SESSION":0 tiled

# --- SHORT WAIT FOR SHELLS ---
sleep 0.5

# --- SEND COMMANDS ---
for idx in "${!PANE_IDS[@]}"; do
    tmux send-keys -t "${PANE_IDS[$idx]}" \
        "echo '>>> Pane $idx'; mkdir -p /tmp/$idx && mc /tmp/$idx" C-m
done

# --- BIND QUIT KEYS ---
tmux bind-key -n M-q kill-session      # Alt+q
tmux bind-key Q kill-session           # Ctrl+b then uppercase Q

trap - EXIT
echo "Session $SESSION ready with $NUM_PANES panes. Use Alt+q or Ctrl+b Q to quit."
tmux attach -t "$SESSION"

