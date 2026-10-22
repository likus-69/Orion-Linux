#!/usr/bin/env bash
# scripts/04-config-system.sh
#
# Stage 04 — system configuration (LFS chapters 9 & 10).
#
# - Writes /etc/os-release, /etc/orion-release, hostname
# - Generates fstab from a template (callers may override mounts)
# - Sets hostname, locale, timezone, keymap, vconsole
# - Creates the root user and a default unprivileged user
# - Configures systemd: enables/disables units per Orion defaults
# - Installs orion-pkg and the installer into $LFS

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="04-config-system"
orion_banner

# --- 1. Branding files -------------------------------------------------------
orion_run_stage "branding" "install /etc/os-release + motd + issue" -- bash -c '
  install -Dm0644 config/os-release    '"$LFS"'/etc/os-release
  install -Dm0644 config/orion-release '"$LFS"'/etc/orion-release
  install -Dm0644 config/issue          '"$LFS"'/etc/issue
  install -Dm0644 config/motd           '"$LFS"'/etc/motd
  install -Dm0644 config/hostname       '"$LFS"'/etc/hostname
  install -Dm0644 config/fstab.template '"$LFS"'/etc/fstab.template
  # Branding assets
  install -Dm0644 config/branding/logo.txt '"$LFS"'/usr/share/orion/logo.txt
'

# --- 2. Locale + timezone + keymap -------------------------------------------
orion_run_stage "locale" "generate en_US.UTF-8 + en_GB.UTF-8" -- bash -c '
  orion_chroot "
    set -e
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    cat > /etc/locale.conf <<EOF
LANG=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
EOF
  "
'

orion_run_stage "timezone" "set timezone to UTC (override in installer)" -- bash -c '
  orion_chroot "
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    # Also pre-install Africa/Kampala, since that is the project tz
    test -f /usr/share/zoneinfo/Africa/Kampala
  "
'

orion_run_stage "vconsole" "set default keymap + console font" -- bash -c '
  cat > '"$LFS"'/etc/vconsole.conf <<EOF
KEYMAP=us
FONT=eurlatgr
EOF
'

# --- 3. Users + groups ------------------------------------------------------
orion_run_stage "users" "create root password + wheel group + default user" -- bash -c '
  orion_chroot "
    set -e
    # Lock the root password — installer sets it
    passwd -l root >/dev/null
    # Wheel group exists on systemd-based distros; make sure
    getent group wheel >/dev/null 2>&1 || groupadd -r wheel
    # sudo rules: %wheel ALL=(ALL:ALL) ALL
    mkdir -p /etc/sudoers.d
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
    chmod 0440 /etc/sudoers.d/10-wheel
    # Default unprivileged user; password is set by installer
    if ! id -u orion >/dev/null 2>&1; then
      useradd -m -G wheel,users,video,audio,input -s /bin/bash orion
      passwd -l orion >/dev/null
    fi
  "
'

# --- 4. systemd default target + enabled units -------------------------------
orion_run_stage "systemd" "configure systemd defaults" -- bash -c '
  orion_chroot "
    set -e
    ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
    # Networking
    systemctl enable systemd-networkd || true
    systemctl enable systemd-resolved || true
    systemctl enable iwd 2>/dev/null || true   # wifi (installed later)
    systemctl enable sshd 2>/dev/null || true   # openssh
    # Time sync
    systemctl enable systemd-timesyncd || true
    # Journal
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  "
'

# --- 5. Install orion-pkg + installer ----------------------------------------
orion_run_stage "orion-pkg" "install orion-pkg into $LFS" -- bash -c '
  set -e
  install -Dm0755 orion-pkg/orion-pkg '"$LFS"'/usr/bin/orion-pkg
  install -Dm0644 orion-pkg/completions/orion-pkg.bash '"$LFS"'/usr/share/bash-completion/completions/orion-pkg
  install -Dm0644 orion-pkg/README.md '"$LFS"'/usr/share/doc/orion-pkg/README.md
  # Package manifest root (where orion-pkg tracks installs)
  mkdir -p '"$LFS"'/var/orion/installed '"$LFS"'/var/orion/cache
  # Seed a manifest for "base" group so list shows something useful
  cat > '"$LFS"'/var/orion/installed/base.meta <<EOF
name=base
version='"$ORION_VERSION"'
arch='"$ORION_ARCH"'
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
files=/.kbuildignore
EOF
'

orion_run_stage "installer" "install the orion-installer" -- bash -c '
  set -e
  install -Dm0755 installer/orion-installer '"$LFS"'/usr/bin/orion-installer
  install -Dm0755 -d '"$LFS"'/usr/lib/orion-installer
  install -Dm0755 installer/modules/*.sh '"$LFS"'/usr/lib/orion-installer/
  install -Dm0644 installer/de-profiles/*.list '"$LFS"'/usr/share/orion/de-profiles/
  # Make the installer launch on first boot for the live ISO
  mkdir -p '"$LFS"'/etc/systemd/system/getty@tty1.service.d
  cat > '"$LFS"'/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I $TERM
EOF
'

# --- 6. skel + root dotfiles -------------------------------------------------
orion_run_stage "skel" "populate /etc/skel with sensible defaults" -- bash -c '
  mkdir -p '"$LFS"'/etc/skel
  cat > '"$LFS"'/etc/skel/.bashrc <<EOF
# ~/.bashrc — Orion Linux default
PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\$ "
alias ls="ls --color=auto"
alias ll="ls -alF"
alias la="ls -A"
alias grep="grep --color=auto"
export EDITOR=vim
export PAGER=less
EOF
  cat > '"$LFS"'/etc/skel/.profile <<EOF
# ~/.profile — Orion Linux default
[ -f ~/.bashrc ] && . ~/.bashrc
EOF
  # And install for root
  install -Dm0644 '"$LFS"'/etc/skel/.bashrc '"$LFS"'/root/.bashrc
  install -Dm0644 '"$LFS"'/etc/skel/.profile '"$LFS"'/root/.profile
'

orion_log "stage 04 complete — system configured"
# vim: set ts=2 sw=2 noet:
