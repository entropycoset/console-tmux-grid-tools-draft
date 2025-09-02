#!/usr/bin/env bash
set -euo pipefail

# --- ARGUMENTS ---
N_ROWS=${1:-2}        # total rows
M_COLS=${2:-3}        # default number of columns
SPECIAL_COLS=${3:-1}  # columns for first (or last) row

NUM_PANES=$(( (N_ROWS-1)*M_COLS + SPECIAL_COLS ))

SESSION="sess_$RANDOM"
MIN_WIDTH=20
MIN_HEIGHT=10

debug() { echo "[DEBUG] $*"; }

# --- CHECKS ---
command -v tmux >/dev/null 2>&1 || { echo "tmux not found"; exit 1; }
command -v tput >/dev/null 2>&1 || { echo "tput not found"; exit 1; }

# --- CLEANUP ---
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

# --- CREATE DETACHED SESSION ---
debug "Creating detached session..."
PANE_IDS=()
PANE_IDS+=("$(tmux new-session -d -P -F "#{pane_id}" -s "$SESSION" -n main)")

# --- ATTACH BRIEFLY TO GET TERMINAL SIZE ---
debug "Attaching briefly to get real terminal size..."
tmux attach-session -t "$SESSION" \; detach-client

# --- SPLIT ROWS ---
debug "Splitting rows..."
ROW_PANES=("${PANE_IDS[@]}")
for ((r=1; r<N_ROWS; r++)); do
    ROW_PANES+=("$(tmux split-window -v -t "${ROW_PANES[0]}" -P -F "#{pane_id}")")
done

# --- SPLIT COLUMNS ---
debug "Splitting columns..."
NEW_PANE_IDS=()
for idx_row in "${!ROW_PANES[@]}"; do
    row_pane="${ROW_PANES[$idx_row]}"
    NEW_PANE_IDS+=("$row_pane")

    if (( idx_row == 0 )); then
        # Special row columns
        COLS=$SPECIAL_COLS
        for ((c=1; c<COLS; c++)); do
            NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
        done
    else
        # Remaining rows use M_COLS
        for ((c=1; c<M_COLS; c++)); do
            NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
        done
    fi
done

# Limit to NUM_PANES
PANE_IDS=("${NEW_PANE_IDS[@]:0:NUM_PANES}")

# --- FINAL TILED LAYOUT ---
debug "Applying final tiled layout..."
tmux select-layout -t "$SESSION":0 tiled

# --- WAIT UNTIL PANES HAVE MIN SIZE ---
debug "Waiting for panes to reach minimum size..."
for pane in "${PANE_IDS[@]}"; do
    for attempt in {1..50}; do
        w=$(tmux display-message -p -t "$pane" "#{pane_width}")
        h=$(tmux display-message -p -t "$pane" "#{pane_height}")
        if (( w >= MIN_WIDTH && h >= MIN_HEIGHT )); then
            break
        fi
        sleep 0.05
    done
done
debug "All panes logical sizes OK."

# --- SEND COMMANDS TO PANES ---
for idx in "${!PANE_IDS[@]}"; do
    pane="${PANE_IDS[$idx]}"
    tmux send-keys -t "$pane" \
        "echo '>>> Pane $idx (ID: $pane)'; \
         IDX=$idx; \
         TARGET_COLS=\$(tmux display-message -p -t $pane \"#{pane_width}\"); \
         TARGET_LINES=\$(tmux display-message -p -t $pane \"#{pane_height}\"); \
         SECONDS_WAITED=0; \
         while true; do \
             LINES=\$(tput lines); COLS=\$(tput cols); \
             if (( LINES >= TARGET_LINES - 3 && LINES <= TARGET_LINES + 3 && COLS >= TARGET_COLS - 3 && COLS <= TARGET_COLS + 3 )); then break; fi; \
             sleep 0.05; \
             SECONDS_WAITED=\$((SECONDS_WAITED + 1)); \
             if (( SECONDS_WAITED % 40 == 0 )); then \
                 echo \"[DEBUG] Pane \$IDX waiting for terminal size: got \${LINES}x\${COLS}, expected ~\${TARGET_LINES}x\${TARGET_COLS}\"; \
             fi; \
             if (( SECONDS_WAITED >= 200 )); then \
                 echo \"[WARN] Pane \$IDX timed out waiting for size. Launching mc anyway.\"; \
                 break; \
             fi; \
         done; \
         sleep 0.25; \
         mkdir -p /tmp/\$IDX && mc /tmp/\$IDX" C-m
done

# --- BIND QUIT KEYS ---
tmux bind-key -n M-q kill-session      # Alt+q
tmux bind-key Q kill-session           # Ctrl+b then uppercase Q

# --- FINAL ATTACH ---
trap - EXIT
debug "Session ready. Attaching..."
tmux attach-session -t "$SESSION"

