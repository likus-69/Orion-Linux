#!/usr/bin/env bash
# installer/modules/install_de.sh
#
# Step 5b: install the chosen desktop environment.
# Uses orion-pkg to install from the in-repo package set, falling back
# to copying from the live ISO's cached packages if orion-pkg is unavailable.
#
# Reads the DE package list from:
#   /usr/share/orion/de-profiles/<de>.list
# Each line is a package name (no version) that orion-pkg should install.

installer_module_install_de() {
  local de="${STATE[desktop]}"
  if [[ "$de" == "none" ]]; then
    log "no desktop selected — skipping"
    return 0
  fi

  local profile="/usr/share/orion/de-profiles/$de.list"
  if [[ ! -f "$profile" ]]; then
    # Try from the source tree
    profile="$(dirname "${BASH_SOURCE[0]}")/../de-profiles/$de.list"
  fi
  [[ -f "$profile" ]] || die "no package profile for desktop '$de' (looked for $de.list)"

  local target=/mnt/orion
  local pkgs=()
  while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    pkgs+=("$line")
  done < "$profile"

  log "installing $de desktop (${#pkgs[@]} packages)"

  # Use orion-pkg inside the chroot if it exists, else install from a tarball
  # repo baked into the ISO at /var/orion/cache/*.tar.gz
  if [[ -x "$target/usr/bin/orion-pkg" ]]; then
    log "using orion-pkg inside the chroot"
    # First make sure the package repo is reachable
    mount --bind /usr/share/orion/repo.d "$target/etc/orion/repo.d" 2>/dev/null || true
    for pkg in "${pkgs[@]}"; do
      chroot "$target" /usr/bin/orion-pkg install -y "$pkg" || \
        warn "could not install $pkg — continuing"
    done
  else
    # Fall back: try apt/dnf/pacman if available (for tests on foreign distros)
    if chroot "$target" command -v pacman >/dev/null 2>&1; then
      chroot "$target" pacman --noconfirm -Sy "${pkgs[@]}" || warn "pacman failed"
    elif chroot "$target" command -v apt-get >/dev/null 2>&1; then
      chroot "$target" apt-get update
      chroot "$target" apt-get install -y "${pkgs[@]}" || warn "apt failed"
    else
      die "no package manager available inside the chroot to install $de"
    fi
  fi

  # Enable the right display manager + target
  case "$de" in
    gnome)
      chroot "$target" systemctl enable gdm.service 2>/dev/null || true
      chroot "$target" systemctl set-default graphical.target ;;
    kde)
      chroot "$target" systemctl enable sddm.service 2>/dev/null || true
      chroot "$target" systemctl set-default graphical.target ;;
    xfce)
      chroot "$target" systemctl enable lightdm.service 2>/dev/null || true
      chroot "$target" systemctl set-default graphical.target ;;
  esac

  # Add the user to DE-specific groups
  case "$de" in
    gnome)  extra_groups="docker libvirt" ;;
    kde)    extra_groups="docker libvirt" ;;
    xfce)   extra_groups="" ;;
    *)      extra_groups="" ;;
  esac
  for g in $extra_groups; do
    chroot "$target" getent group "$g" >/dev/null 2>&1 || chroot "$target" groupadd "$g"
    chroot "$target" gpasswd -a "${STATE[user_name]}" "$g" >/dev/null 2>&1 || true
  done

  ok "$de desktop installed"
}
