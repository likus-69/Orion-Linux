#!/usr/bin/env bash
# installer/modules/pick_de.sh
#
# Step 5a: let the user choose a desktop environment.
# Sets STATE[desktop] to one of: gnome, kde, xfce, none.

installer_module_pick_de() {
  local de
  de=$(whip --title "Desktop" --menu "Pick a desktop environment (or none for CLI-only)" \
        $ROWS $COLS 5 \
        "gnome" "GNOME 47 (Wayland, polished, heavier)" \
        "kde"   "KDE Plasma 6 (Wayland, customizable)" \
        "xfce"  "XFCE 4.20 (X11, lightweight, fast on ARM)" \
        "none"  "No desktop — CLI only (good for servers)" \
        3>&1 1>&2 2>&3 || echo "none")
  STATE[desktop]="$de"
  ok "desktop: $de"
}
