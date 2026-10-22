#!/usr/bin/env bash
# installer/modules/config_base.sh
#
# Step 3b: configure the base system after extraction.
#
# - Bind-mount virtual filesystems into /mnt/orion
# - Apply locale, timezone, keymap, hostname from STATE
# - Set root password (or disable root)
# - Create the unprivileged user with their password
# - Add the user to wheel + per-DE groups

installer_module_config_base() {
  local target=/mnt/orion
  log "preparing chroot at $target"
  for sub in dev proc sys run; do
    mountpoint -q "$target/$sub" && continue
    case "$sub" in
      dev)  mount --bind /dev  "$target/dev" ;;
      proc) mount -t proc proc "$target/proc" ;;
      sys)  mount --rbind /sys  "$target/sys" ;;
      run)  mount -t tmpfs tmpfs "$target/run" ;;
    esac
  done
  mkdir -p "$target/dev/pts" "$target/dev/shm"
  mount -t devpts devpts "$target/dev/pts" 2>/dev/null || true
  [[ -d /dev/shm ]] && mountpoint -q "$target/dev/shm" || \
    mount --bind /dev/shm "$target/dev/shm" 2>/dev/null || true

  log "applying locale, timezone, hostname"
  # Locale
  echo "${STATE[lang]} UTF-8" > "$target/etc/locale.gen"
  for lc in en_US.UTF-8 en_GB.UTF-8; do
    [[ "$lc" == "${STATE[lang]}" ]] && continue
    echo "$lc UTF-8" >> "$target/etc/locale.gen"
  done
  chroot "$target" locale-gen
  echo "LANG=${STATE[lang]}" > "$target/etc/locale.conf"
  # Timezone
  chroot "$target" ln -sf "/usr/share/zoneinfo/${STATE[timezone]}" /etc/localtime
  # Hostname
  echo "${STATE[hostname]}" > "$target/etc/hostname"
  # Keymap
  echo "KEYMAP=${STATE[keymap]}" > "$target/etc/vconsole.conf"

  log "configuring users"
  chroot "$target" passwd -l root >/dev/null 2>&1 || true
  if [[ -n "${STATE[root_password]}" ]]; then
    chroot "$target" bash -c "echo 'root:${STATE[root_password]}' | chpasswd"
  fi
  # Create the user
  if ! chroot "$target" id -u "${STATE[user_name]}" >/dev/null 2>&1; then
    chroot "$target" useradd -m -G wheel,users,video,audio,input \
        -s /bin/bash "${STATE[user_name]}"
  fi
  chroot "$target" bash -c "echo '${STATE[user_name]}:${STATE[user_password]}' | chpasswd"

  ok "base configuration applied"
}
