#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
NUM_PANES=6
MIN_WIDTH=20
MIN_HEIGHT=10
MIN_ROWS=2
SESSION="sess_$RANDOM"

debug() { echo "[DEBUG] $*"; }

# --- CHECKS ---
command -v tmux >/dev/null 2>&1 || { echo "tmux not found"; exit 1; }
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session $SESSION already exists, exiting"
    exit 1
fi

# --- CLEANUP ---
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

# --- CREATE DETACHED SESSION ---
debug "Creating detached session..."
PANE_IDS=()
PANE_IDS+=("$(tmux new-session -d -P -F "#{pane_id}" -s "$SESSION" -n main)")

# --- ATTACH BRIEFLY TO REGISTER TERMINAL SIZE ---
debug "Attaching briefly to get real terminal size..."
tmux attach-session -t "$SESSION" \; detach-client

# --- GET USABLE WINDOW SIZE ---
term_width=$(tmux display-message -p -t "$SESSION":0 -F "#{window_width}")
term_height=$(tmux display-message -p -t "$SESSION":0 -F "#{window_height}")
debug "Terminal size: ${term_width}x${term_height}"

# --- COMPUTE GRID ---
rows=$MIN_ROWS
while true; do
    cols=$(( (NUM_PANES + rows - 1) / rows ))
    pane_width=$(( term_width / cols ))
    pane_height=$(( term_height / rows ))
    if (( pane_width >= MIN_WIDTH && pane_height >= MIN_HEIGHT )); then
        break
    fi
    ((rows++))
done
cols=$(( (NUM_PANES + rows - 1) / rows ))
debug "Using grid: ${rows} rows x ${cols} columns"

# --- SPLIT ROWS ---
debug "Splitting rows..."
for ((r=1; r<rows; r++)); do
    PANE_IDS+=("$(tmux split-window -v -t "${PANE_IDS[0]}" -P -F "#{pane_id}")")
done
ROW_PANES=("${PANE_IDS[@]}")

# --- SPLIT COLUMNS ---
debug "Splitting columns..."
NEW_PANE_IDS=()
for row_pane in "${ROW_PANES[@]}"; do
    NEW_PANE_IDS+=("$row_pane")
    for ((c=1; c<cols; c++)); do
        NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
    done
done
PANE_IDS=("${NEW_PANE_IDS[@]:0:NUM_PANES}")

# --- FINAL TILED LAYOUT ---
debug "Applying final tiled layout..."
tmux select-layout -t "$SESSION":0 tiled

# --- WAIT UNTIL PANES HAVE MIN SIZE (polling loop) ---
debug "Waiting for all panes to reach minimum size..."
for pane in "${PANE_IDS[@]}"; do
    for attempt in {1..50}; do
        w=$(tmux display-message -p -t "$pane" "#{pane_width}")
        h=$(tmux display-message -p -t "$pane" "#{pane_height}")
        if (( w >= MIN_WIDTH && h >= MIN_HEIGHT )); then
            break
        fi
        sleep 0.05
    done
    w=$(tmux display-message -p -t "$pane" "#{pane_width}")
    h=$(tmux display-message -p -t "$pane" "#{pane_height}")
    if (( w < MIN_WIDTH || h < MIN_HEIGHT )); then
        echo "ERROR: Pane $pane too small: ${w}x${h}"
        tmux kill-session -t "$SESSION"
        exit 1
    fi
done
debug "All panes ready."

# --- SEND COMMANDS TO PANES ---
debug "Starting mc commands in panes..."
for idx in "${!PANE_IDS[@]}"; do
    tmux send-keys -t "${PANE_IDS[$idx]}" \
        "echo '>>> Pane $idx'; mkdir -p /tmp/$idx && mc /tmp/$idx" C-m
done

# --- BIND QUIT KEYS ---
tmux bind-key -n M-q kill-session
tmux bind-key Q kill-session

trap - EXIT
debug "Session ready. Attaching..."
tmux attach-session -t "$SESSION"

