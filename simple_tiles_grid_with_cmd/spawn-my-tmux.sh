#!/usr/bin/env bash
set -euo pipefail

# Usage: ./spawn-my-tmux.sh ROWS COLS SPECIAL_COLS
N_ROWS=${1:-3}
M_COLS=${2:-3}
Z_COLS=${3:-2}

MIN_WIDTH=5
MIN_HEIGHT=10
MC_SLEEP=0.25
TOLERANCE=3

debug() { echo "[DEBUG] $*"; }

SESSION="sess_$RANDOM"
ALL_PANES=()

# --- Create detached session ---
debug "Creating detached session..."
tmux new-session -d -s "$SESSION" -x 200 -y 50
debug "Session $SESSION created"

# --- Attach briefly to force tmux window to match terminal ---
debug "Attaching briefly to force tmux window to match terminal..."
tmux attach-session -t "$SESSION" \; detach-client
TERM_WIDTH=$(tmux display-message -p -t "$SESSION" "#{client_width}")
TERM_HEIGHT=$(tmux display-message -p -t "$SESSION" "#{client_height}")
debug "Terminal size inside tmux after attach: ${TERM_WIDTH}x${TERM_HEIGHT}"

if (( TERM_WIDTH < 10 || TERM_HEIGHT < 5 )); then
    debug "ERROR: tmux reports very small window size! Exiting."
    tmux kill-session -t "$SESSION"
    exit 1
fi

# --- Split special top row ---
debug "Splitting special top row into $Z_COLS evenly..."
TOP_PANES=()
tmux select-pane -t 0
for ((i=1;i<Z_COLS;i++)); do
    tmux split-window -h -t 0
done
tmux select-layout tiled
sleep 0.1

for p in $(tmux list-panes -F "#{pane_index}" | head -n "$Z_COLS"); do
    TOP_PANES+=("%$p")
    ALL_PANES+=("%$p")
done

# --- Create remaining rows ---
debug "Creating remaining $((N_ROWS-1)) rows..."
for ((r=1;r<N_ROWS;r++)); do
    tmux split-window -v -t 0
done
sleep 0.1

# --- Split normal rows into M_COLS columns ---
debug "Splitting normal rows into $M_COLS columns..."
for row in $(seq 1 $((N_ROWS-1))); do
    row_pane_idx=$(tmux list-panes -F "#{pane_index} #{pane_top}" | awk -v r=$row '$2>0' | head -n1 | awk '{print $1}')
    tmux select-pane -t "$row_pane_idx"
    for ((c=1;c<M_COLS;c++)); do
        tmux split-window -h -t "$row_pane_idx"
    done
    tmux select-layout tiled
    sleep 0.05

    for p in $(tmux list-panes -F "#{pane_index} #{pane_top}" | awk -v r=$row '$2>0' | awk '{print "%"$1}'); do
        ALL_PANES+=("$p")
    done
done

# --- Manual resizing for special top row evenly ---
debug "Manually resizing special top row panes evenly..."
TOP_WIDTH=$(( TERM_WIDTH / Z_COLS ))
for idx in "${!TOP_PANES[@]}"; do
    tmux resize-pane -t "${TOP_PANES[$idx]}" -x "$TOP_WIDTH"
    debug "Special pane $idx manually resized to $TOP_WIDTH columns"
done

# --- Wait for all panes to reach minimum size ---
debug "Waiting for all panes to reach minimum size with tolerance ±$TOLERANCE..."
for pane in "${ALL_PANES[@]}"; do
    last_debug=0
    while true; do
        w=$(tmux display-message -p -t "$pane" "#{pane_width}")
        h=$(tmux display-message -p -t "$pane" "#{pane_height}")
        if (( w >= MIN_WIDTH && h >= MIN_HEIGHT )); then
            break
        fi
        now=$(date +%s)
        if (( now - last_debug >= 2 )); then
            debug "Pane $pane waiting: got ${h}x${w}, need >= ${MIN_HEIGHT}x${MIN_WIDTH}"
            last_debug=$now
        fi
        sleep 0.05
    done
done
debug "All panes logical sizes OK."

# --- Launch MC in panes without blocking ---
debug "Launching MC in panes..."
MC_IDX=0
for pane in "${ALL_PANES[@]}"; do
    debug "MC $MC_IDX -> Pane ID=$pane"

    # Queue command
    tmux send-keys -t "$pane" "sleep $MC_SLEEP; mkdir -p /tmp/$MC_IDX; mc /tmp/$MC_IDX" C-m

    # Wait until mc spawned in pane (non-blocking)
    pane_pid=$(tmux display-message -p -t "$pane" "#{pane_pid}")
    for attempt in {1..50}; do
        if pgrep -P "$pane_pid" mc >/dev/null 2>&1; then
            debug "MC $MC_IDX started in Pane $pane"
            break
        fi
        sleep 0.05
    done
    ((MC_IDX++))
done

# --- Bind Ctrl-B Q to kill session ---
tmux bind-key Q kill-session -t "$SESSION"

# --- Attach session after all MC spawned ---
debug "All MC instances spawned. Attaching session..."
tmux attach-session -t "$SESSION"

