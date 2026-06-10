#!/usr/bin/env bash
# phantom.sh — hide/unhide files using the unlinked-but-open inode technique
# Usage:
#   phantom.sh hide   <file>          keep file open, unlink from filesystem
#   phantom.sh unhide <name>          re-link file back to original path
#   phantom.sh search [--all]         find hidden files (managed, or all deleted+open)
#   phantom.sh list                   list all managed hidden files

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DB_FILE="${PHANTOM_DB:-$HOME/.phantom_db}"
KEEPER_NAME="phantom-keeper"        # argv[0] used by keeper processes

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[phantom] $*"; }

require_root_for_all() {
    [[ $EUID -eq 0 ]] || die "'search --all' requires root to read all /proc/<pid>/fd entries"
}

db_add() {
    local name="$1" pid="$2" fd="$3" orig="$4"
    echo -e "${name}\t${pid}\t${fd}\t${orig}" >> "$DB_FILE"
}

db_remove() {
    local name="$1"
    local tmp; tmp=$(mktemp)
    grep -v "^${name}"$'\t' "$DB_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$DB_FILE"
}

db_lookup() {
    # prints: pid fd orig_path
    local name="$1"
    local line
    line=$(grep "^${name}"$'\t' "$DB_FILE" 2>/dev/null || true)
    [[ -n "$line" ]] || die "no managed hidden file named '${name}'"
    echo "$line" | awk -F'\t' '{print $2, $3, $4}'
}

db_exists() {
    grep -q "^${1}"$'\t' "$DB_FILE" 2>/dev/null
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_hide() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "usage: phantom.sh hide <file>"
    [[ -e "$target" ]] || die "file not found: $target"
    [[ -f "$target" ]] || die "only regular files are supported"

    local orig_path
    orig_path=$(realpath "$target")
    local name
    name=$(basename "$orig_path")

    db_exists "$name" && die "'${name}' is already managed (unhide it first)"

    # Open a file descriptor to the file inside a background keeper process.
    # We exec sleep with a custom argv[0] so it's identifiable in ps/top.
    # The keeper holds FD 3 open on the target file.
    # Launch keeper: a Python process that opens the file and sleeps forever.
    # Python is used because it gives us a reliable, inspectable process that
    # won't be optimised away. setsid detaches from terminal so it survives logout.
    local fd=3
    setsid python3 -c "
import os, sys, time, signal
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
fd = os.open('${orig_path}', os.O_RDONLY)
os.dup2(fd, ${fd})
os.close(fd)
# rename process in /proc/self/comm
try:
    with open('/proc/self/comm', 'w') as f:
        f.write('${KEEPER_NAME}')
except Exception:
    pass
while True:
    time.sleep(86400)
" &
    local keeper_pid=$!

    # Give the process a moment to open the fd
    sleep 0.5

    # Verify the keeper actually has the fd open
    [[ -e "/proc/${keeper_pid}/fd/${fd}" ]] || {
        kill "$keeper_pid" 2>/dev/null || true
        die "keeper process failed to open fd on '${orig_path}'"
    }

    # Record in DB before unlinking (safety first)
    db_add "$name" "$keeper_pid" "$fd" "$orig_path"

    # Unlink the file — it disappears from the directory but inode lives on
    rm "$orig_path"
    info "hidden: '${name}'"
    info "  original path : $orig_path"
    info "  keeper PID    : $keeper_pid"
    info "  live fd       : /proc/${keeper_pid}/fd/${fd}"
}

cmd_unhide() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: phantom.sh unhide <name>"

    read -r pid fd orig_path <<< "$(db_lookup "$name")"

    # Verify keeper is still alive
    [[ -d "/proc/${pid}" ]] || die "keeper process (PID ${pid}) is gone — file may be lost"

    local proc_fd="/proc/${pid}/fd/${fd}"
    [[ -e "$proc_fd" ]] || die "fd ${fd} not found in /proc/${pid}/fd/"

    # Re-link the inode back into the filesystem
    local dest_dir
    dest_dir=$(dirname "$orig_path")
    [[ -d "$dest_dir" ]] || mkdir -p "$dest_dir"

    ln "$proc_fd" "$orig_path" \
        || die "ln failed — are you running as the same user/root?"

    # Kill the keeper now that the file is re-linked
    kill "$pid" 2>/dev/null || true

    db_remove "$name"

    info "unhidden: '${name}'"
    info "  restored to: $orig_path"
}

cmd_search() {
    local show_all=false
    [[ "${1:-}" == "--all" ]] && show_all=true

    local managed_pids=()
    local managed_names=()

    # Load managed entries for cross-reference
    if [[ -f "$DB_FILE" ]]; then
        while IFS=$'\t' read -r name pid fd orig; do
            managed_pids+=("$pid")
            managed_names+=("$name")
        done < "$DB_FILE"
    fi

    is_managed_pid() {
        local p="$1"
        for mp in "${managed_pids[@]+"${managed_pids[@]}"}"; do
            [[ "$mp" == "$p" ]] && return 0
        done
        return 1
    }

    local found_any=false

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " PHANTOM SEARCH"
    $show_all && echo " Mode: managed + all system-wide deleted-open files" \
               || echo " Mode: managed files only"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── Section 1: managed files ──────────────────────────────────────────────
    echo ""
    echo "┌─ MANAGED (phantom.sh) ─────────────────────────────"
    if [[ ${#managed_pids[@]} -eq 0 ]]; then
        echo "│  (none)"
    else
        local i=0
        while IFS=$'\t' read -r name pid fd orig; do
            local proc_fd="/proc/${pid}/fd/${fd}"
            local alive="✓ alive"
            local size="?"
            [[ -d "/proc/${pid}" ]] || alive="✗ keeper dead"
            if [[ -e "$proc_fd" ]]; then
                size=$(stat -L -c "%s" "$proc_fd" 2>/dev/null || echo "?")
                size=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B")
            fi
            echo "│  name     : $name"
            echo "│  orig path: $orig"
            echo "│  keeper   : PID $pid  ($alive)"
            echo "│  fd path  : $proc_fd"
            echo "│  size     : $size"
            echo "│"
            found_any=true
            ((i++)) || true
        done < "$DB_FILE"
    fi
    echo "└────────────────────────────────────────────────────"

    # ── Section 2: all deleted-but-open files (--all) ─────────────────────────
    if $show_all; then
        $show_all && { [[ $EUID -eq 0 ]] || info "warning: not root — some /proc entries may be unreadable"; }

        echo ""
        echo "┌─ ALL DELETED-BUT-OPEN FILES (system-wide) ─────────"

        local count=0
        # Walk /proc/*/fd/* and look for symlinks pointing to "(deleted)" paths
        for fd_link in /proc/*/fd/*; do
            # Skip if not a symlink or unreadable
            [[ -L "$fd_link" ]] || continue

            local target_path
            target_path=$(readlink "$fd_link" 2>/dev/null) || continue

            # The kernel appends " (deleted)" to the symlink target for unlinked inodes
            [[ "$target_path" == *" (deleted)" ]] || continue

            local pid
            pid=$(echo "$fd_link" | awk -F/ '{print $3}')

            # Skip kernel threads and unreadable pids
            [[ -r "/proc/${pid}/comm" ]] || continue

            local comm
            comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")

            local real_path="${target_path% (deleted)}"
            local size
            size=$(stat -L -c "%s" "$fd_link" 2>/dev/null || echo "?")
            [[ "$size" != "?" ]] && size=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B")

            local managed_tag=""
            is_managed_pid "$pid" && managed_tag=" [phantom-managed]"

            echo "│  deleted path : $real_path"
            echo "│  held by      : PID $pid ($comm)${managed_tag}"
            echo "│  fd           : $fd_link"
            echo "│  size on disk : $size"
            echo "│"
            ((count++)) || true
            found_any=true
        done

        [[ $count -eq 0 ]] && echo "│  (none found — try running as root for full visibility)"
        echo "└────────────────────────────────────────────────────"
    fi

    echo ""
    $found_any || info "nothing found."
}

cmd_list() {
    if [[ ! -f "$DB_FILE" ]] || [[ ! -s "$DB_FILE" ]]; then
        info "no managed hidden files."
        return
    fi

    printf "%-20s %-8s %-4s %s\n" "NAME" "PID" "FD" "ORIGINAL PATH"
    printf "%-20s %-8s %-4s %s\n" "----" "---" "--" "-------------"
    while IFS=$'\t' read -r name pid fd orig; do
        local alive=""
        [[ -d "/proc/${pid}" ]] || alive=" [DEAD]"
        printf "%-20s %-8s %-4s %s%s\n" "$name" "$pid" "$fd" "$orig" "$alive"
    done < "$DB_FILE"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  phantom.sh hide   <file>       Hide a file (unlink + keep inode alive)
  phantom.sh unhide <name>       Restore a hidden file to its original path
  phantom.sh search [--all]      Search for hidden files
                                   --all: also show all system-wide deleted-open files
  phantom.sh list                List managed hidden files
EOF
}

[[ $# -lt 1 ]] && { usage; exit 1; }

case "$1" in
    hide)   cmd_hide   "${2:-}" ;;
    unhide) cmd_unhide "${2:-}" ;;
    search) cmd_search "${2:-}" ;;
    list)   cmd_list ;;
    *)      usage; exit 1 ;;
esac
