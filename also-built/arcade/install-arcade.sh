#!/usr/bin/env bash
# Light OS with MAME, booting straight into the game menu.
#
# Turns a freshly installed Debian 13 WITHOUT a desktop into an arcade machine:
# at power-on only the "arcade" user logs in and MAME opens full screen.
#
# Usage:  sudo ./install-arcade.sh
# Safe to run again (idempotent).
set -euo pipefail

MAME=/usr/games/mame   # Debian installs MAME here (outside sudo's PATH)
ARCADE_USER="${ARCADE_USER:-arcade}"
ARCADE_HOME="/home/${ARCADE_USER}"

log() { printf '\n==> %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Run the script with sudo: sudo $0" >&2
  exit 1
fi

log "1/6 Installing the minimum packages (MAME + X11, no desktop)"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  mame \
  xserver-xorg-core xserver-xorg-input-libinput xinit x11-xserver-utils \
  libgl1-mesa-dri \
  alsa-utils

log "2/6 Creating the '${ARCADE_USER}' user (no sudo and no login password)"
if ! id "$ARCADE_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$ARCADE_USER"
fi
usermod -aG audio,video,input "$ARCADE_USER"
# Least privilege: the account cannot log in with a password (only autologin on tty1)
passwd -l "$ARCADE_USER" >/dev/null

log "3/6 Automatic login on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${ARCADE_USER} --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl set-default multi-user.target

log "4/6 Booting straight into MAME"
# Logging in on tty1 starts X; tty2 (Ctrl+Alt+F2) keeps a normal console for administration.
cat > "${ARCADE_HOME}/.bash_profile" <<'EOF'
if [[ -z ${DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
  exec startx -- -nocursor
fi
EOF

# X starts only MAME, with no window manager. If MAME closes, it opens again.
cat > "${ARCADE_HOME}/.xinitrc" <<'EOF'
xset s off s noblank -dpms
cd "$HOME"
while true; do
  /usr/games/mame -rompath "$HOME/roms" -skip_gameinfo
  sleep 1
done
EOF

# MAME's menu lists only the games whose ROMs are installed
mkdir -p "${ARCADE_HOME}/roms" "${ARCADE_HOME}/.mame"
if [[ ! -f "${ARCADE_HOME}/.mame/ui.ini" ]]; then
  echo "last_used_filter          Available" > "${ARCADE_HOME}/.mame/ui.ini"
fi
# Arcade stick: in MAME's menus, button 1 (Ctrl / the stick's button 1) and Start (1) also select, not just Enter
mkdir -p "${ARCADE_HOME}/.mame/cfg"
if [[ ! -f "${ARCADE_HOME}/.mame/cfg/default.cfg" ]]; then
  cat > "${ARCADE_HOME}/.mame/cfg/default.cfg" <<'EOF'
<?xml version="1.0"?>
<mameconfig version="10">
    <system name="default">
        <input>
            <port type="UI_SELECT">
                <newseq type="standard">KEYCODE_ENTER OR KEYCODE_ENTER_PAD OR KEYCODE_LCONTROL OR KEYCODE_1 OR JOYCODE_1_BUTTON1</newseq>
            </port>
        </input>
    </system>
</mameconfig>
EOF
fi
chown -R "${ARCADE_USER}:${ARCADE_USER}" \
  "${ARCADE_HOME}/.bash_profile" "${ARCADE_HOME}/.xinitrc" "${ARCADE_HOME}/roms" "${ARCADE_HOME}/.mame"

log "5/6 Faster boot (GRUB with no wait and no messages)"
if [[ -f /etc/default/grub ]]; then
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"/' /etc/default/grub
  update-grub
else
  echo "/etc/default/grub not found, step skipped."
fi

log "6/6 Check"
echo "MAME version: $("$MAME" -version 2>/dev/null || echo 'NOT INSTALLED')"
echo "User: $(id "$ARCADE_USER")"
echo "Boot target: $(systemctl get-default)"
echo "ROM folder: ${ARCADE_HOME}/roms ($(find "${ARCADE_HOME}/roms" -type f | wc -l) files)"

cat <<EOF

Done. Copy the ROMs (.zip files, not unzipped) into ${ARCADE_HOME}/roms
and reboot with:  sudo reboot
EOF
