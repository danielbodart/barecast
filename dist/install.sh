#!/usr/bin/env bash
set -euo pipefail

# Zerocast installer.
# Ships in the dist tarball alongside the binaries.
#
# In a git checkout (dev mode), installs in-situ pointing at the source tree.
# Otherwise, copies to ~/.local/share/zerocast/ for a proper user install.
#
# Usage:
#   ./install.sh              Full interactive setup

SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null && pwd)"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zerocast"
RECORDINGS_DIR="$INSTALL_DIR/recordings"
NEEDS_REBOOT=false

# ─── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    printf '%s [Y/n] ' "$prompt"
    read -r answer
    case "${answer,,}" in
        ""|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_default_no() {
    local prompt="$1"
    printf '%s [y/N] ' "$prompt"
    read -r answer
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

is_dev_mode() {
    [ -d "$SCRIPT_DIR/../.git" ] || [ -d "$SCRIPT_DIR/../src" ]
}

# ─── Permissions ──────────────────────────────────────────────────────────────

check_permissions() {
    # Check input group membership (for /dev/uinput remote input)
    if ! id -nG | grep -qw input; then
        echo ""
        echo "=== Input Group Setup ==="
        echo "The 'input' group is needed for remote keyboard/mouse via /dev/uinput."
        if confirm "Add current user to 'input' group? (requires sudo)"; then
            if sudo usermod -aG input "$USER"; then
                NEEDS_REBOOT=true
                echo "Added to 'input' group."
            else
                echo "WARNING: Failed. Run manually: sudo usermod -aG input $USER"
            fi
        fi
    fi

    # Check /dev/uinput access
    local uinput_rule='/etc/udev/rules.d/99-uinput.rules'
    if [ ! -f "$uinput_rule" ]; then
        echo ""
        echo "Setting up /dev/uinput access..."
        if confirm "Install udev rule for /dev/uinput? (requires sudo)"; then
            if echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee "$uinput_rule" >/dev/null; then
                sudo udevadm control --reload-rules || true
                sudo udevadm trigger /dev/uinput || true
                echo "udev rule installed."
            else
                echo "WARNING: Failed. Run manually:"
                echo "  echo 'KERNEL==\"uinput\", MODE=\"0660\", GROUP=\"input\"' | sudo tee $uinput_rule"
            fi
        fi
    fi

    # Check video group membership
    if ! id -nG | grep -qw video; then
        echo ""
        if confirm "Add current user to 'video' group? (for GPU access, requires sudo)"; then
            if sudo usermod -aG video "$USER"; then
                NEEDS_REBOOT=true
                echo "Added to 'video' group."
            else
                echo "WARNING: Failed. Run manually: sudo usermod -aG video $USER"
            fi
        fi
    fi

    # Check tty group membership (needed for headless Xorg VT access)
    if ! id -nG | grep -qw tty; then
        echo ""
        if confirm "Add current user to 'tty' group? (for headless Xorg, requires sudo)"; then
            if sudo usermod -aG tty "$USER"; then
                NEEDS_REBOOT=true
                echo "Added to 'tty' group."
            else
                echo "WARNING: Failed. Run manually: sudo usermod -aG tty $USER"
            fi
        fi
    fi
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

install_service() {
    local work_dir="$1"
    local binary="$2"
    local with_updates="${3:-false}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    {
        echo "[Unit]"
        echo "Description=Zerocast screen sharing daemon"
        if $with_updates; then
            echo "StartLimitBurst=3"
            echo "StartLimitIntervalSec=60"
            echo "OnFailure=zerocast-rollback.service"
        fi
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "WorkingDirectory=$work_dir"
        if $with_updates; then
            echo "ExecStartPre=$INSTALL_DIR/zerocast-apply-update.sh"
        fi
        echo "ExecStart=$binary daemon"
        echo "Restart=always"
        echo "RestartSec=5"
        echo "Environment=DISPLAY=:0"
        echo "Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > "$service_dir/zerocast.service"

    systemctl --user daemon-reload
    systemctl --user enable zerocast.service 2>/dev/null || true
    echo "zerocast.service installed."
}

# ─── Update Infrastructure ─────────────────────────────────────────────────

install_update_timer() {
    local service_dir="$HOME/.config/systemd/user"

    cat > "$service_dir/zerocast-update.service" <<EOF
[Unit]
Description=Check for zerocast updates

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/zerocast-update.sh
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF

    cat > "$service_dir/zerocast-update.timer" <<EOF
[Unit]
Description=Daily zerocast update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now zerocast-update.timer 2>/dev/null || true
    echo "zerocast-update.timer installed."
}

install_rollback_service() {
    local service_dir="$HOME/.config/systemd/user"

    cat > "$service_dir/zerocast-rollback.service" <<EOF
[Unit]
Description=Zerocast auto-rollback

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/zerocast-rollback.sh
EOF

    systemctl --user daemon-reload
    echo "zerocast-rollback.service installed."
}

# ─── Install Files ────────────────────────────────────────────────────────

install_files() {
    echo "Installing to $INSTALL_DIR ..."

    [ -f "$SCRIPT_DIR/bin/zerocast" ] || die "zerocast binary not found in $SCRIPT_DIR/bin/"
    [ -f "$SCRIPT_DIR/VERSION" ] || die "VERSION file not found in dist."

    local ver
    ver=$(cat "$SCRIPT_DIR/VERSION")
    local release_dir="$INSTALL_DIR/releases/v$ver"

    mkdir -p "$release_dir"

    # Copy bin/ into versioned directory
    cp -a "$SCRIPT_DIR/bin" "$release_dir/"
    cp "$SCRIPT_DIR/VERSION" "$release_dir/"

    # Save current version for rollback (if upgrading)
    local current_target
    current_target=$(readlink "$INSTALL_DIR/current" 2>/dev/null || true)
    if [ -n "$current_target" ]; then
        local current_name
        current_name=$(basename "$current_target")
        if [ "$current_name" != "v$ver" ]; then
            echo "$current_name" > "$INSTALL_DIR/.previous-version"
            date +%s > "$INSTALL_DIR/.update-applied-at"
        fi
    fi

    # Atomic symlink swap
    ln -sfn "releases/v$ver" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Install update scripts
    for script in zerocast-update.sh zerocast-apply-update.sh zerocast-rollback.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        fi
    done

    # Clean up old releases (keep current + previous)
    local prev
    prev=$(cat "$INSTALL_DIR/.previous-version" 2>/dev/null || true)
    for dir in "$INSTALL_DIR/releases"/v*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [ "$name" = "v$ver" ] && continue
        [ "$name" = "$prev" ] && continue
        echo "Removing old release: $name"
        rm -rf "$dir"
    done

    # Symlink binaries + update command into ~/.local/bin
    mkdir -p "$HOME/.local/bin"
    ln -sf "$INSTALL_DIR/current/bin/zerocast" "$HOME/.local/bin/zerocast"
    ln -sf "$INSTALL_DIR/current/bin/zerocast-kms" "$HOME/.local/bin/zerocast-kms"
    ln -sf "$INSTALL_DIR/zerocast-update.sh" "$HOME/.local/bin/zerocast-update"

    # Create recordings directory
    mkdir -p "$RECORDINGS_DIR"

    echo "Installed v$ver."
    echo "Binaries: $INSTALL_DIR/current/bin/"
    echo "Symlinks: ~/.local/bin/zerocast, ~/.local/bin/zerocast-kms"

    # Install setuid helper to /usr/local/bin (must be on a non-nosuid filesystem)
    if [ -f "$release_dir/bin/zerocast-xorg" ]; then
        echo ""
        echo "=== Privileged Helper Setup ==="
        echo "zerocast-xorg needs setuid root (for headless Xorg VT access)."
        echo "It must be installed to /usr/local/bin (home dirs may have nosuid)."
        if confirm "Install zerocast-xorg to /usr/local/bin? (requires sudo)"; then
            if sudo cp "$release_dir/bin/zerocast-xorg" /usr/local/bin/zerocast-xorg && \
               sudo chown root:root /usr/local/bin/zerocast-xorg && \
               sudo chmod u+s /usr/local/bin/zerocast-xorg; then
                echo "Installed /usr/local/bin/zerocast-xorg (setuid root)"
            else
                echo "WARNING: Failed. Run manually:"
                echo "  sudo cp $release_dir/bin/zerocast-xorg /usr/local/bin/zerocast-xorg"
                echo "  sudo chown root:root /usr/local/bin/zerocast-xorg"
                echo "  sudo chmod u+s /usr/local/bin/zerocast-xorg"
            fi
        fi
    fi

    # Set capabilities on KMS helper
    if [ -f "$release_dir/bin/zerocast-kms" ]; then
        sudo setcap cap_sys_admin+ep "$release_dir/bin/zerocast-kms" 2>/dev/null || true
    fi

    # Sudoers rule for passwordless auto-update of privileged helpers
    local sudoers_file="/etc/sudoers.d/zerocast"
    if [ ! -f "$sudoers_file" ]; then
        echo ""
        echo "A sudoers rule allows auto-updates to install the setuid helper"
        echo "without prompting for a password on each service restart."
        if confirm "Install sudoers rule for passwordless helper updates?"; then
            local rule="$USER ALL=(root) NOPASSWD: /usr/bin/cp * /usr/local/bin/zerocast-xorg, /usr/bin/chown root\:root /usr/local/bin/zerocast-xorg, /usr/bin/chmod u+s /usr/local/bin/zerocast-xorg, /usr/sbin/setcap cap_sys_admin+ep *"
            if echo "$rule" | sudo tee "$sudoers_file" >/dev/null && \
               sudo chmod 440 "$sudoers_file"; then
                echo "Sudoers rule installed."
            else
                echo "WARNING: Failed. Helper updates will require manual sudo."
            fi
        fi
    fi

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
        echo ""
        echo "NOTE: ~/.local/bin is not on your PATH."
        echo "Add to your shell rc file:"
        # shellcheck disable=SC2016
        echo '  export PATH="$HOME/.local/bin:$PATH"'
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

cmd_install() {
    [ -f "$SCRIPT_DIR/bin/zerocast" ] || die "zerocast binary not found in $SCRIPT_DIR/bin/"

    local service_file="$HOME/.config/systemd/user/zerocast.service"
    local is_upgrade=false
    local was_active=false

    if [ -f "$service_file" ]; then
        is_upgrade=true
        if systemctl --user is-active --quiet zerocast.service 2>/dev/null; then
            was_active=true
        fi
        echo "Previous zerocast installation detected."
        if $was_active; then
            echo "Stopping current service..."
            systemctl --user stop zerocast.service 2>/dev/null || true
        fi
    fi

    if is_dev_mode; then
        echo "=== Zerocast Developer Setup ==="
        echo "(detected git checkout)"
        echo ""

        local project_dir
        project_dir="$(cd "$SCRIPT_DIR/.." && pwd)"

        check_permissions

        # Dev mode: symlink into ~/.local/bin pointing at source tree
        mkdir -p "$HOME/.local/bin"
        ln -sf "$SCRIPT_DIR/bin/zerocast" "$HOME/.local/bin/zerocast"
        ln -sf "$SCRIPT_DIR/bin/zerocast-kms" "$HOME/.local/bin/zerocast-kms"
        echo "Symlinks: ~/.local/bin/zerocast → $SCRIPT_DIR/bin/"

        install_service "$project_dir" "$SCRIPT_DIR/bin/zerocast" false
    else
        echo "=== Zerocast Installer ==="
        echo ""

        # Always update files + symlinks (this is the upgrade)
        install_files
        check_permissions

        if $is_upgrade; then
            # Upgrade: preserve existing service config, just update binaries
            local has_updates=false
            [ -f "$HOME/.config/systemd/user/zerocast-update.timer" ] && has_updates=true

            install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/zerocast" $has_updates
        else
            # Fresh install: ask about auto-updates
            local enable_updates=true
            echo ""
            if ! confirm "Enable automatic updates?"; then
                enable_updates=false
            fi

            install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/zerocast" $enable_updates

            if $enable_updates; then
                install_update_timer
                install_rollback_service
            fi
        fi
    fi

    echo ""
    if $NEEDS_REBOOT; then
        echo "=== Reboot Required ==="
        echo "You were added to group(s). This only takes effect after a reboot."
        echo "The service is enabled and will start automatically on boot."
    elif $is_upgrade && $was_active; then
        echo "Restarting service..."
        systemctl --user restart zerocast.service
        echo "Service restarted. Check status with:"
        echo "  systemctl --user status zerocast.service"
    elif confirm "Start the daemon now?"; then
        systemctl --user restart zerocast.service
        echo "Service started. Check status with:"
        echo "  systemctl --user status zerocast.service"
        echo ""
        echo "Share your screen with:"
        echo "  zerocast share app <command>"
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start zerocast.service"
        echo ""
        echo "Then share your screen:"
        echo "  zerocast share app <command>"
    fi
}

cmd_install
