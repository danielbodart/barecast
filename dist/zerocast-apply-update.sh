#!/usr/bin/env bash
set -euo pipefail

# Apply a staged zerocast update (atomic symlink swap).
# Called as ExecStartPre= before zerocast daemon starts.
# Only acts if .update-pending exists.

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zerocast"

main() {
    local pending_file="$INSTALL_DIR/.update-pending"

    [ -f "$pending_file" ] || exit 0

    local pending
    pending=$(cat "$pending_file")
    [ -n "$pending" ] || exit 0

    local release_dir="$INSTALL_DIR/releases/$pending"
    [ -d "$release_dir/bin" ] || { echo "ERROR: Staged release $pending not found" >&2; exit 1; }

    # Save current version for rollback
    local current_target
    current_target=$(readlink "$INSTALL_DIR/current" 2>/dev/null || true)
    if [ -n "$current_target" ]; then
        basename "$current_target" > "$INSTALL_DIR/.previous-version"
        date +%s > "$INSTALL_DIR/.update-applied-at"
    fi

    # Set CAP_SYS_ADMIN on new zerocast-kms if present
    local new_kms="$release_dir/bin/zerocast-kms"
    if [ -f "$new_kms" ]; then
        sudo setcap cap_sys_admin+ep "$new_kms" 2>/dev/null || true
    fi

    # Atomic symlink swap: ln creates new symlink, mv atomically replaces via rename(2)
    ln -sfn "releases/$pending" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    rm -f "$pending_file"

    echo "Applied update: $pending"
}

main "$@"
