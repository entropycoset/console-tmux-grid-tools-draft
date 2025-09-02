#!/usr/bin/env bash
set -euo pipefail

N_ROWS=${1:-3}        # total rows
M_COLS=${2:-3}        # columns for normal rows
SPECIAL_COLS=${3:-2}  # columns in special first row
SESSION="sess_$RANDOM"

MIN_WIDTH=10
MIN_HEIGHT=5

debug() { echo "[DEBUG] $*"; }

# --- CREATE DETACHED SESSION ---
debug "Creating detached session..."
TOP_PANE=$(tmux new-session -d -P -F "#{pane_id}" -s "$SESSION" -n main)

# --- ATTACH BRIEFLY TO INITIALIZE TMUX ---
tmux attach-session -t "$SESSION" \; detach-client

# --- GET REAL TERMINAL SIZE ---
TERM_WIDTH=$(tmux display-message -p -t "$TOP_PANE" "#{window_width}")
TERM_HEIGHT=$(tmux display-message -p -t "$TOP_PANE" "#{window_height}")
debug "Terminal size inside tmux: ${TERM_WIDTH}x${TERM_HEIGHT}"

# --- SPLIT SPECIAL ROW EVENLY ---
debug "Splitting special top row into $SPECIAL_COLS evenly..."
SPECIAL_PANES=("$TOP_PANE")
if (( SPECIAL_COLS > 1 )); then
    for ((c=1;c<SPECIAL_COLS;c++)); do
        NEW_PANE=$(tmux split-window -h -t "${SPECIAL_PANES[-1]}" -P -F "#{pane_id}")
        SPECIAL_PANES+=("$NEW_PANE")
    done
fi

# --- CREATE REMAINING ROWS ---
debug "Creating remaining $((N_ROWS-1)) rows..."
NORMAL_ROWS=()
for ((r=1;r<N_ROWS;r++)); do
    NEW_ROW=$(tmux split-window -v -t "${SPECIAL_PANES[0]}" -P -F "#{pane_id}")
    NORMAL_ROWS+=("$NEW_ROW")
done

# --- SPLIT NORMAL ROWS INTO M_COLS evenly ---
debug "Splitting normal rows into $M_COLS columns..."
NORMAL_ROWS_PANES=()
for ROW_PANE in "${NORMAL_ROWS[@]}"; do
    PANES=("$ROW_PANE")
    if (( M_COLS > 1 )); then
        for ((c=1;c<M_COLS;c++)); do
            NEW_PANE=$(tmux split-window -h -t "${PANES[-1]}" -P -F "#{pane_id}")
            PANES+=("$NEW_PANE")
        done
    fi
    NORMAL_ROWS_PANES+=("$(IFS=, ; echo "${PANES[*]}")")
done

# --- MANUAL RESIZE ALL PANES ---
debug "Manually resizing panes..."
# Top special row
BASE_WIDTH=$(( TERM_WIDTH / SPECIAL_COLS ))
REMAIN_WIDTH=$(( TERM_WIDTH - BASE_WIDTH*(SPECIAL_COLS-1) ))
TARGET_HEIGHT=$(( TERM_HEIGHT / N_ROWS ))
for idx in "${!SPECIAL_PANES[@]}"; do
    WIDTH=$(( idx==SPECIAL_COLS-1 ? REMAIN_WIDTH : BASE_WIDTH ))
    tmux resize-pane -t "${SPECIAL_PANES[$idx]}" -x "$WIDTH" -y "$TARGET_HEIGHT" || true
done
# Normal rows
for row_idx in "${!NORMAL_ROWS_PANES[@]}"; do
    IFS=',' read -r -a panes <<< "${NORMAL_ROWS_PANES[$row_idx]}"
    BASE_WIDTH=$(( TERM_WIDTH / M_COLS ))
    REMAIN_WIDTH=$(( TERM_WIDTH - BASE_WIDTH*(M_COLS-1) ))
    for col_idx in "${!panes[@]}"; do
        WIDTH=$(( col_idx==M_COLS-1 ? REMAIN_WIDTH : BASE_WIDTH ))
        tmux resize-pane -t "${panes[$col_idx]}" -x "$WIDTH" -y "$TARGET_HEIGHT" || true
    done
done

# --- FINAL TILED LAYOUT ---
tmux select-layout -t "$SESSION":0 tiled

# --- WAIT FOR PANES READY ---
debug "Waiting for all panes to reach minimum size..."
ALL_PANES=("${SPECIAL_PANES[@]}")
for row_str in "${NORMAL_ROWS_PANES[@]}"; do
    IFS=',' read -r -a row_p <<< "$row_str"
    ALL_PANES+=("${row_p[@]}")
done
for pane in "${ALL_PANES[@]}"; do
    for attempt in {1..50}; do
        w=$(tmux display-message -p -t "$pane" "#{pane_width}")
        h=$(tmux display-message -p -t "$pane" "#{pane_height}")
        (( w >= MIN_WIDTH && h >= MIN_HEIGHT )) && break
        sleep 0.05
    done
done
debug "All panes logical sizes OK."

# --- LAUNCH MC ONCE PER PANE WITH DEBUG ---
debug "Launching mc in panes..."
MC_IDX=0
# Top special row
for idx in "${!SPECIAL_PANES[@]}"; do
    pane="${SPECIAL_PANES[$idx]}"
    echo "[DEBUG] MC $MC_IDX -> Pane ID=$pane (special top row, col $idx)"
    tmux send-keys -t "$pane" "sleep 0.25; mkdir -p /tmp/$MC_IDX; mc /tmp/$MC_IDX" C-m
    ((MC_IDX++))
done
# Normal rows
for row_str in "${NORMAL_ROWS_PANES[@]}"; do
    IFS=',' read -r -a panes <<< "$row_str"
    for col_idx in "${!panes[@]}"; do
        pane="${panes[$col_idx]}"
        echo "[DEBUG] MC $MC_IDX -> Pane ID=$pane (row, col $col_idx)"
        tmux send-keys -t "$pane" "sleep 0.25; mkdir -p /tmp/$MC_IDX; mc /tmp/$MC_IDX" C-m
        ((MC_IDX++))
    done
done

# --- BIND QUIT KEYS ---
tmux bind-key -n M-q kill-session      # Alt+q
tmux bind-key Q kill-session           # Ctrl+b then uppercase Q

# --- ATTACH SESSION ---
debug "Session ready. Attaching..."
tmux attach-session -t "$SESSION"

