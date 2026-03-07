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

    # Atomic symlink swap: ln creates new symlink, mv atomically replaces via rename(2)
    ln -sfn "releases/$pending" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Update privileged helpers (setuid xorg helper, capabilities on kms)
    if [ -f "$release_dir/bin/zerocast-xorg" ] && command -v sudo >/dev/null 2>&1; then
        if sudo -n cp "$release_dir/bin/zerocast-xorg" /usr/local/bin/zerocast-xorg 2>/dev/null && \
           sudo -n chown root:root /usr/local/bin/zerocast-xorg 2>/dev/null && \
           sudo -n chmod u+s /usr/local/bin/zerocast-xorg 2>/dev/null; then
            echo "Updated /usr/local/bin/zerocast-xorg (setuid root)"
        else
            echo "WARNING: Could not update zerocast-xorg (run ./run.ts setup manually)" >&2
        fi
    fi
    if [ -f "$release_dir/bin/zerocast-kms" ] && command -v sudo >/dev/null 2>&1; then
        sudo -n setcap cap_sys_admin+ep "$release_dir/bin/zerocast-kms" 2>/dev/null || true
    fi

    rm -f "$pending_file"

    echo "Applied update: $pending"
}

main "$@"
