#!/usr/bin/env bash
# SmallSur-style XFCE installer for Debian/Ubuntu-family XFCE systems.
# Version 2: explicit destinations + dynamic theme discovery + strict verification.
set -Eeuo pipefail
IFS=$'\n\t'

STATE="${HOME}/.local/state/smallsur-xfce"
SRC="${STATE}/src"
BACKUP="${STATE}/backups"
LOG="${STATE}/install.log"
mkdir -p "$STATE" "$SRC" "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

trap 'echo "[FAIL] Unexpected error at line $LINENO. See: $LOG" >&2' ERR

info(){ echo "[INFO] $*"; }
ok(){ echo "[ OK ] $*"; }
warn(){ echo "[WARN] $*"; }
fail(){ echo "[FAIL] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Run as the normal desktop user, NOT with sudo."
command -v apt-get >/dev/null || fail "apt-get not found."
command -v dpkg-query >/dev/null || fail "dpkg-query not found."
command -v git >/dev/null || true

if [[ ! "${XDG_CURRENT_DESKTOP:-}" =~ [Xx][Ff][Cc][Ee] ]]; then
    fail "This must be executed inside an XFCE desktop session. Current: ${XDG_CURRENT_DESKTOP:-unknown}"
fi
[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || fail "No graphical session detected."

# ---------- package layer ----------
info "Updating APT metadata..."
sudo apt-get update

PKGS=(
  git curl ca-certificates
  sassc libglib2.0-dev-bin libglib2.0-dev libxml2-utils
  imagemagick optipng inkscape
  plank xfce4-goodies xfce4-whiskermenu-plugin xfce4-power-manager
)

AVAILABLE=()
for p in "${PKGS[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
        AVAILABLE+=("$p")
    else
        warn "APT package unavailable, skipping: $p"
    fi
done
sudo apt-get install -y "${AVAILABLE[@]}"

for p in git plank xfconf-query; do
    if [[ "$p" == "xfconf-query" ]]; then
        command -v xfconf-query >/dev/null || fail "xfconf-query is missing."
    else
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' \
          || fail "Package verification failed: $p"
    fi
done
ok "Base packages verified."

# AppMenu is optional because availability differs between Debian-family releases.
if apt-cache show xfce4-appmenu-plugin >/dev/null 2>&1; then
    sudo apt-get install -y xfce4-appmenu-plugin
    dpkg-query -W -f='${Status}' xfce4-appmenu-plugin 2>/dev/null | grep -q 'install ok installed' \
      || fail "xfce4-appmenu-plugin installation verification failed."
    ok "XFCE AppMenu plugin verified."
else
    warn "xfce4-appmenu-plugin is unavailable in these repositories; continuing without it."
fi

# ---------- source layer ----------
clone(){
    local url="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
        (cd "$dir" && git fetch --depth=1 origin && git reset --hard origin/HEAD)
    else
        rm -rf "$dir"
        git clone --depth=1 "$url" "$dir"
    fi
    [[ -f "$dir/install.sh" || -d "$dir/.git" ]] || fail "Source verification failed: $dir"
}

clone "https://github.com/vinceliuice/WhiteSur-gtk-theme.git" "${SRC}/WhiteSur-gtk-theme"
clone "https://github.com/vinceliuice/WhiteSur-icon-theme.git" "${SRC}/WhiteSur-icon-theme"
clone "https://github.com/vinceliuice/WhiteSur-cursors.git" "${SRC}/WhiteSur-cursors"
clone "https://github.com/jothi-prasath/SmallSur.git" "${SRC}/SmallSur"
ok "Upstream repositories verified."

THEMES="${HOME}/.themes"
ICONS="${HOME}/.local/share/icons"
mkdir -p "$THEMES" "$ICONS"

# ---------- WhiteSur GTK/XFWM/Plank ----------
info "Installing WhiteSur GTK/XFWM/Plank theme into explicit user destination: $THEMES"

GTK="${SRC}/WhiteSur-gtk-theme/install.sh"
chmod +x "$GTK"

# Explicit destination avoids any ambiguity about where upstream installs.
# Use the current upstream CLI: -c accepts light/dark.
bash "$GTK" -d "$THEMES" -c dark -c light

# Discover, don't assume, the actual generated directory names.
mapfile -t DARK_DIRS < <(
    find "$THEMES" -maxdepth 1 -mindepth 1 -type d \
      \( -iname 'WhiteSur-Dark' -o -iname 'WhiteSur-dark' -o -iname 'WhiteSur-Dark-*' -o -iname 'WhiteSur-dark-*' \) \
      -print | sort
)

# A valid XFCE theme directory must actually contain XFWM assets or GTK files.
VALID_DARK=""
for d in "${DARK_DIRS[@]}"; do
    if [[ -d "$d/xfwm4" || -d "$d/gtk-3.0" || -f "$d/gtk-3.0/gtk.css" ]]; then
        VALID_DARK="$d"
        break
    fi
done

# If the installer returned success but no dark directory exists, inspect the
# destination before failing. This makes the failure diagnostic, not misleading.
if [[ -z "$VALID_DARK" ]]; then
    echo "---- ~/.themes after WhiteSur installation ----"
    find "$THEMES" -maxdepth 2 -type d -print | sort || true
    echo "------------------------------------------------"
    fail "WhiteSur dark theme was NOT installed correctly. The installer returned without producing a valid dark XFCE/GTK theme."
fi

THEME_NAME="$(basename "$VALID_DARK")"
ok "WhiteSur dark theme verified: $THEME_NAME"

# Light theme verification is separate.
if find "$THEMES" -maxdepth 1 -mindepth 1 -type d \
   \( -iname 'WhiteSur-Light' -o -iname 'WhiteSur-light' -o -iname 'WhiteSur-Light-*' -o -iname 'WhiteSur-light-*' \) \
   -print -quit | grep -q .; then
    ok "WhiteSur light theme verified."
else
    warn "Dark theme is valid, but no WhiteSur light variant was detected."
fi

# ---------- Icons ----------
info "Installing WhiteSur icons..."
ICON="${SRC}/WhiteSur-icon-theme/install.sh"
chmod +x "$ICON"
bash "$ICON" -d "$ICONS"

ICON_DIR="${ICONS}/WhiteSur-dark"
if [[ -d "$ICON_DIR" ]]; then
    ICON_NAME="WhiteSur-dark"
elif [[ -d "${ICONS}/WhiteSur" ]]; then
    ICON_NAME="WhiteSur"
else
    mapfile -t IFOUND < <(find "$ICONS" -maxdepth 1 -mindepth 1 -type d -iname 'WhiteSur*' -print | sort)
    [[ ${#IFOUND[@]} -gt 0 ]] || fail "WhiteSur icons were not installed."
    ICON_NAME="$(basename "${IFOUND[0]}")"
fi
[[ -d "${ICONS}/${ICON_NAME}" ]] || fail "Icon verification failed: ${ICONS}/${ICON_NAME}"
ok "WhiteSur icons verified: $ICON_NAME"

# ---------- Cursors ----------
# WhiteSur-cursors/install.sh uses the relative path "dist", so it MUST run
# with the repository as the current working directory. build.sh has the same
# requirement because it sets ROOT=$(pwd). We therefore build/verify/copy from
# inside the repo and never trust its "Finished..." message as proof of success.
info "Installing WhiteSur cursors..."

CURSOR_REPO="${SRC}/WhiteSur-cursors"
CURSOR_INSTALL="${CURSOR_REPO}/install.sh"
CURSOR_BUILD="${CURSOR_REPO}/build.sh"
CURSOR_TARGET="${ICONS}/WhiteSur-cursors"

[[ -f "$CURSOR_INSTALL" ]] || fail "WhiteSur-cursors install.sh is missing."
[[ -f "$CURSOR_BUILD" ]] || fail "WhiteSur-cursors build.sh is missing."
chmod +x "$CURSOR_INSTALL" "$CURSOR_BUILD"

# Install the exact tools used by the upstream build script when necessary.
if [[ ! -d "${CURSOR_REPO}/dist" ]]; then
    info "Compiled cursor dist/ is absent; building WhiteSur cursors from source."
    sudo apt-get install -y xorg-xcursorgen librsvg2-bin python3
    command -v xcursorgen >/dev/null 2>&1 || fail "xcursorgen is unavailable after installation."
    command -v rsvg-convert >/dev/null 2>&1 || fail "rsvg-convert is unavailable after installation."
    command -v python3 >/dev/null 2>&1 || fail "python3 is unavailable after installation."
    (
        cd "$CURSOR_REPO"
        bash ./build.sh
    )
fi

# Verify build output before touching the user's icon directory.
[[ -d "${CURSOR_REPO}/dist" ]] || fail "WhiteSur-cursors build did not create dist/."
[[ -d "${CURSOR_REPO}/dist/cursors" ]] || fail "WhiteSur-cursors dist/cursors is missing."
[[ -f "${CURSOR_REPO}/dist/index.theme" ]] || fail "WhiteSur-cursors dist/index.theme is missing."
CURSOR_FILE_COUNT="$(find "${CURSOR_REPO}/dist/cursors" -type f 2>/dev/null | wc -l)"
(( CURSOR_FILE_COUNT > 0 )) || fail "WhiteSur-cursors dist/cursors is empty."
ok "Compiled WhiteSur cursor payload verified: ${CURSOR_FILE_COUNT} files."

# Reproduce the upstream installer operation, but from the correct CWD.
# The upstream install.sh itself executes: cp -pr dist ...
rm -rf "$CURSOR_TARGET"
(
    cd "$CURSOR_REPO"
    bash ./install.sh
) || warn "Upstream cursor installer returned non-zero; final filesystem verification is authoritative."

# Hard verification of the actual installed payload.
if [[ ! -d "$CURSOR_TARGET/cursors" || ! -f "$CURSOR_TARGET/index.theme" ]]; then
    # Fallback: copy the already-verified dist payload directly.
    warn "Upstream installer did not leave a valid target; copying verified dist directly."
    rm -rf "$CURSOR_TARGET"
    cp -a "${CURSOR_REPO}/dist" "$CURSOR_TARGET"
fi

[[ -d "$CURSOR_TARGET/cursors" ]] || fail "WhiteSur cursor target missing cursors/."
[[ -f "$CURSOR_TARGET/index.theme" ]] || fail "WhiteSur cursor target missing index.theme."
INSTALLED_CURSOR_COUNT="$(find "$CURSOR_TARGET/cursors" -type f 2>/dev/null | wc -l)"
(( INSTALLED_CURSOR_COUNT > 0 )) || fail "WhiteSur cursor target contains no cursor files."

CURSOR_NAME="WhiteSur-cursors"
ok "WhiteSur cursors verified: $CURSOR_TARGET ($INSTALLED_CURSOR_COUNT cursor files)"

# ---------- Wallpapers ----------
WALL="${HOME}/Pictures/SmallSur"
mkdir -p "$WALL"
if [[ -d "${SRC}/SmallSur/wallpaper" ]]; then
    cp -a "${SRC}/SmallSur/wallpaper/." "$WALL/"
fi
WCOUNT="$(find "$WALL" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | wc -l)"
if (( WCOUNT > 0 )); then ok "Wallpapers verified: $WCOUNT"; else warn "No SmallSur wallpaper files detected."; fi

# ---------- Plank theme ----------
PLANK_THEMES="${HOME}/.local/share/plank/themes"
mkdir -p "$PLANK_THEMES"
if [[ -d "${SRC}/WhiteSur-gtk-theme/src/other/plank" ]]; then
    cp -a "${SRC}/WhiteSur-gtk-theme/src/other/plank/." "$PLANK_THEMES/"
fi
if [[ -d "${SRC}/SmallSur/plank" ]]; then
    cp -a "${SRC}/SmallSur/plank/." "$PLANK_THEMES/" || true
fi
find "$PLANK_THEMES" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q . \
  && ok "Plank themes verified." \
  || warn "No Plank theme directory detected; Plank itself is installed."

# ---------- Back up XFCE panel ----------
PANEL_DIR="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
PANEL="${PANEL_DIR}/xfce4-panel.xml"
mkdir -p "$PANEL_DIR"
if [[ -f "$PANEL" ]]; then
    B="${BACKUP}/xfce4-panel.xml.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$PANEL" "$B"
    ok "XFCE panel backup: $B"
fi

# ---------- Apply XFCE theme ----------
info "Applying detected WhiteSur theme: $THEME_NAME"
xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "$THEME_NAME" 2>/dev/null \
 || xfconf-query -c xsettings -p /Net/ThemeName -s "$THEME_NAME"

xfconf-query -c xsettings -p /Net/IconThemeName -n -t string -s "$ICON_NAME" 2>/dev/null \
 || xfconf-query -c xsettings -p /Net/IconThemeName -s "$ICON_NAME"

xfconf-query -c xsettings -p /Gtk/CursorThemeName -n -t string -s "$CURSOR_NAME" 2>/dev/null \
 || xfconf-query -c xsettings -p /Gtk/CursorThemeName -s "$CURSOR_NAME"

# Verify immediately.
[[ "$(xfconf-query -c xsettings -p /Net/ThemeName)" == "$THEME_NAME" ]] \
  || fail "GTK theme verification failed."
[[ "$(xfconf-query -c xsettings -p /Net/IconThemeName)" == "$ICON_NAME" ]] \
  || fail "Icon theme verification failed."
[[ "$(xfconf-query -c xsettings -p /Gtk/CursorThemeName)" == "$CURSOR_NAME" ]] \
  || fail "Cursor theme verification failed."
ok "XFConf GTK/icon/cursor configuration verified."

# XFWM uses the same detected theme directory name.
xfconf-query -c xfwm4 -p /general/theme -n -t string -s "$THEME_NAME" 2>/dev/null \
 || xfconf-query -c xfwm4 -p /general/theme -s "$THEME_NAME"

if [[ "$(xfconf-query -c xfwm4 -p /general/theme)" != "$THEME_NAME" ]]; then
    fail "XFWM theme verification failed."
fi

# Enable compositor.
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true 2>/dev/null \
 || xfconf-query -c xfwm4 -p /general/use_compositing -s true
ok "XFWM configuration verified."

# ---------- SmallSur panel XML ----------
UP="${SRC}/SmallSur/xfce4-panel/xfce4-panel.xml"
if [[ -f "$UP" ]]; then
    info "Applying SmallSur panel layout."
    killall xfce4-panel >/dev/null 2>&1 || true
    cp -a "$UP" "$PANEL"
    [[ -s "$PANEL" ]] || fail "SmallSur panel XML copy failed."

    xfce4-panel >/tmp/smallsur-panel.log 2>&1 &
    sleep 2
    pgrep -x xfce4-panel >/dev/null || {
        echo "---- xfce4-panel error ----"
        cat /tmp/smallsur-panel.log || true
        fail "XFCE panel failed to start with the SmallSur layout."
    }
    ok "SmallSur panel layout verified by successful panel startup."
else
    warn "SmallSur panel XML not found; existing panel left untouched."
fi

# ---------- Plank autostart ----------
AUTOSTART="${HOME}/.config/autostart"
mkdir -p "$AUTOSTART"
cat > "${AUTOSTART}/plank.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Comment=macOS-style dock
Exec=plank
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF
grep -q '^Exec=plank$' "${AUTOSTART}/plank.desktop" || fail "Plank autostart verification failed."
ok "Plank autostart verified."

# ---------- Start Plank now ----------
killall plank >/dev/null 2>&1 || true
plank >/dev/null 2>&1 &
sleep 2
pgrep -x plank >/dev/null || warn "Plank did not start in the current session; autostart remains configured."

# ---------- Final independent verification ----------
echo
echo "========== FINAL VERIFICATION =========="
printf 'Desktop:      %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
printf 'GTK theme:    %s\n' "$(xfconf-query -c xsettings -p /Net/ThemeName)"
printf 'Icons:        %s\n' "$(xfconf-query -c xsettings -p /Net/IconThemeName)"
printf 'Cursor:       %s\n' "$(xfconf-query -c xsettings -p /Gtk/CursorThemeName)"
printf 'XFWM:         %s\n' "$(xfconf-query -c xfwm4 -p /general/theme)"
printf 'Theme path:   %s\n' "${THEMES}/${THEME_NAME}"
printf 'Icon path:    %s\n' "${ICONS}/${ICON_NAME}"
printf 'Cursor path:  %s\n' "${ICONS}/${CURSOR_NAME}"
printf 'Plank:        %s\n' "$(pgrep -x plank >/dev/null && echo RUNNING || echo AUTOSTART-CONFIGURED)"
printf 'Log:          %s\n' "$LOG"
echo "========================================"

# These are the hard requirements.
[[ -d "${THEMES}/${THEME_NAME}" ]] || fail "FINAL CHECK: GTK theme directory missing."
[[ -d "${ICONS}/${ICON_NAME}" ]] || fail "FINAL CHECK: icon directory missing."
[[ -d "${ICONS}/${CURSOR_NAME}/cursors" ]] || fail "FINAL CHECK: cursor directory missing."
[[ "$(xfconf-query -c xsettings -p /Net/ThemeName)" == "$THEME_NAME" ]] || fail "FINAL CHECK: GTK selection mismatch."
[[ "$(xfconf-query -c xsettings -p /Net/IconThemeName)" == "$ICON_NAME" ]] || fail "FINAL CHECK: icon selection mismatch."
[[ "$(xfconf-query -c xsettings -p /Gtk/CursorThemeName)" == "$CURSOR_NAME" ]] || fail "FINAL CHECK: cursor selection mismatch."
[[ "$(xfconf-query -c xfwm4 -p /general/theme)" == "$THEME_NAME" ]] || fail "FINAL CHECK: XFWM selection mismatch."

ok "ALL HARD CHECKS PASSED."
echo
echo "Logout and login once to reload the complete XFCE/GTK session."
echo "If anything is wrong, the complete log is:"
echo "$LOG"
