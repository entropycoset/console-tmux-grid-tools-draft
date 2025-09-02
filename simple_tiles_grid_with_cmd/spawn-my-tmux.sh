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
command -v tput >/dev/null 2>&1 || { echo "tput not found"; exit 1; }

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

# --- SPLIT ROWS ---
rows=$MIN_ROWS
debug "Splitting rows..."
for ((r=1; r<rows; r++)); do
    PANE_IDS+=("$(tmux split-window -v -t "${PANE_IDS[0]}" -P -F "#{pane_id}")")
done
ROW_PANES=("${PANE_IDS[@]}")

# --- SPLIT COLUMNS ---
debug "Splitting columns..."
NEW_PANE_IDS=()
for idx_row in "${!ROW_PANES[@]}"; do
    row_pane="${ROW_PANES[$idx_row]}"
    NEW_PANE_IDS+=("$row_pane")

    # First row special: only 2 columns
    if (( idx_row == 0 )); then
        for ((c=1; c<2; c++)); do
            NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
        done
    else
        # Other rows: distribute remaining panes equally
        remaining=$((NUM_PANES - ${#NEW_PANE_IDS[@]}))
        if (( remaining > 0 )); then
            for ((c=1; c<remaining; c++)); do
                NEW_PANE_IDS+=("$(tmux split-window -h -t "$row_pane" -P -F "#{pane_id}")")
            done
        fi
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
    w=$(tmux display-message -p -t "$pane" "#{pane_width}")
    h=$(tmux display-message -p -t "$pane" "#{pane_height}")
    if (( w < MIN_WIDTH || h < MIN_HEIGHT )); then
        echo "ERROR: Pane $pane too small: ${w}x${h}"
        tmux kill-session -t "$SESSION"
        exit 1
    fi
done
debug "All panes logical sizes OK."

# --- SEND COMMANDS TO PANES USING PANE IDS (NOT NAMES) ---
debug "Starting mc commands in panes..."
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

# --- DISABLE EXIT TRAP BEFORE FINAL ATTACH ---
trap - EXIT

# --- FINAL ATTACH ---
debug "Session ready. Attaching..."
tmux attach-session -t "$SESSION"

