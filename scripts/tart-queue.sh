#!/bin/bash
# One local Tart guest at a time, served in arrival order.
#
# Sourced by every script that boots a Debut VM. Each caller registers a ticket and waits until
# it is the oldest live one, so a second task waits its turn instead of failing, and nothing
# boots a competing clone. The queue lives outside any checkout, VM name or share override, so
# worktrees and overrides all join the same line.
#
# A ticket belongs to a process identified by PID plus start time, so a recycled PID never
# inherits a dead run's place. Tickets of dead owners are pruned by whoever looks next.
#
# macOS ships bash 3.2: no BASHPID, associative arrays or mapfile here.

TART_QUEUE_DIR="${DEBUT_TART_QUEUE_DIR:-$HOME/Library/Caches/Debut/TartQueue}"
TART_QUEUE_POLL="${DEBUT_TART_QUEUE_POLL:-2}"
TART_QUEUE_REPORT_EVERY="${DEBUT_TART_QUEUE_REPORT_EVERY:-30}"
TART_QUEUE_TICKET=""

# $$ names the top-level script even inside a subshell. `exec` makes sh replace the command
# substitution's own fork, so its parent is the calling shell itself.
tart_queue_current_pid() {
    TART_QUEUE_PID="$(exec /bin/sh -c 'echo $PPID')"
}

tart_queue_start_time() {
    { LC_ALL=C /bin/ps -o lstart= -p "$1" 2>/dev/null || true; } | sed 's/^ *//; s/ *$//'
}

tart_queue_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

tart_queue_ticket_alive() {
    local ticket="$1" pid start
    pid="$(tart_queue_field "$ticket" pid)"
    start="$(tart_queue_field "$ticket" start)"
    [[ -n "$pid" && -n "$start" ]] || return 1
    [[ "$(tart_queue_start_time "$pid")" == "$start" ]]
}

# Live tickets, oldest first. Dead owners are removed on the way.
tart_queue_live_tickets() {
    local ticket
    [[ -d "$TART_QUEUE_DIR" ]] || return 0
    for ticket in "$TART_QUEUE_DIR"/*.ticket; do
        [[ -e "$ticket" ]] || continue
        if tart_queue_ticket_alive "$ticket"; then
            echo "$ticket"
        else
            rm -f "$ticket"
        fi
    done
}

tart_queue_describe() {
    local ticket="$1" pid started owner now
    pid="$(tart_queue_field "$ticket" pid)"
    started="$(tart_queue_field "$ticket" created)"
    owner="$(tart_queue_field "$ticket" owner)"
    now="$(date +%s)"
    echo "$owner (PID $pid, queued $(( now - ${started:-$now} ))s ago)"
}

# tart_queue_enter <description>
# Returns once this caller is at the head. Interrupting the wait removes the ticket.
tart_queue_enter() {
    local description="$1" pid start name tmp position total head waited_since last_report
    local previous_position=""
    tart_queue_current_pid
    pid="$TART_QUEUE_PID"
    start="$(tart_queue_start_time "$pid")"
    if [[ -z "$start" ]]; then
        echo "Could not read the start time of PID $pid for the Tart queue." >&2
        return 1
    fi
    mkdir -p "$TART_QUEUE_DIR"
    # Zero-padded microseconds then PID, so lexical order is arrival order and ties are stable.
    name="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%017.0f", time() * 1e6')-$(printf '%07d' "$pid")"
    tmp="$TART_QUEUE_DIR/.$name.tmp"
    {
        echo "pid=$pid"
        echo "start=$start"
        echo "created=$(date +%s)"
        echo "owner=$description"
    } > "$tmp"
    mv "$tmp" "$TART_QUEUE_DIR/$name.ticket"
    TART_QUEUE_TICKET="$TART_QUEUE_DIR/$name.ticket"

    waited_since="$(date +%s)"
    last_report=0
    while true; do
        position=0
        total=0
        head=""
        local ticket
        for ticket in $(tart_queue_live_tickets); do
            total=$(( total + 1 ))
            [[ -z "$head" ]] && head="$ticket"
            [[ "$ticket" == "$TART_QUEUE_TICKET" ]] && position="$total"
        done
        if (( position == 0 )); then
            echo "The Tart queue ticket disappeared: $TART_QUEUE_TICKET" >&2
            TART_QUEUE_TICKET=""
            return 1
        fi
        if (( position == 1 )); then
            if [[ -n "$previous_position" ]]; then
                echo "Tart queue: acquired after $(( $(date +%s) - waited_since ))s of waiting."
            fi
            return 0
        fi
        if [[ "$position" != "$previous_position" ]] \
            || (( $(date +%s) - last_report >= TART_QUEUE_REPORT_EVERY )); then
            echo "Tart queue: position $position of $total; running: $(tart_queue_describe "$head"); waited $(( $(date +%s) - waited_since ))s."
            previous_position="$position"
            last_report="$(date +%s)"
        fi
        sleep "$TART_QUEUE_POLL"
    done
}

# Releases only this caller's own ticket.
tart_queue_leave() {
    if [[ -n "$TART_QUEUE_TICKET" ]]; then
        rm -f "$TART_QUEUE_TICKET"
        TART_QUEUE_TICKET=""
    fi
}

# Prints the live head's description, or nothing when the queue is idle.
tart_queue_holder() {
    local head
    head="$(tart_queue_live_tickets | head -1)"
    [[ -n "$head" ]] && tart_queue_describe "$head"
    return 0
}

tart_queue_status() {
    local ticket index=0
    for ticket in $(tart_queue_live_tickets); do
        index=$(( index + 1 ))
        if (( index == 1 )); then
            echo "Running: $(tart_queue_describe "$ticket")"
        else
            echo "Waiting $(( index - 1 )): $(tart_queue_describe "$ticket")"
        fi
    done
    (( index > 0 )) || echo "Tart queue: idle"
}
