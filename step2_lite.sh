#!/usr/bin/env bash
# SmallSur XFCE Step 2 Lite
# Debian/Ubuntu/Linux Mint XFCE only.
# Completes Step 1 by:
#   - replacing any stale/duplicate XFCE panels with exactly one SmallSur top panel
#   - applying and persisting a real wallpaper via xfconf
#   - installing/configuring Plank as the bottom dock
#   - configuring XFCE Terminal with an anime background image
#   - creating a persistent login/session repair helper
#   - keeping XFWM4 native compositing enabled; no external compositor
#
# IMPORTANT:
# This Lite variant intentionally does NOT install or run picom. XFWM4's native
# compositor remains enabled for lightweight compositing/transparency. Real
# background blur is intentionally reserved for the Full variant.

set -Eeuo pipefail
IFS=$'\n\t'

STATE="${HOME}/.local/state/smallsur-xfce"
SRC="${STATE}/src"
BACKUP="${STATE}/backups/step2-$(date +%Y%m%d-%H%M%S)"
LOG="${STATE}/step2-install.log"
CONF="${HOME}/.config"
AUTOSTART="${CONF}/autostart"
BIN="${HOME}/.local/bin"
SESSION_HELPER="${BIN}/smallsur-session.sh"
WALL_DIR="${HOME}/Pictures/SmallSur"
TERM_DIR="${HOME}/Pictures/SmallSur/terminal"
TERM_IMG="${TERM_DIR}/anime-terminal.png"
PANEL_XML="${CONF}/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"

mkdir -p "$STATE" "$SRC" "$BACKUP" "$AUTOSTART" "$BIN" "$TERM_DIR"
exec > >(tee -a "$LOG") 2>&1

trap 'echo "[FAIL] Unexpected error at line $LINENO. See: $LOG" >&2' ERR

info(){ echo "[INFO] $*"; }
ok(){ echo "[ OK ] $*"; }
warn(){ echo "[WARN] $*"; }
fail(){ echo "[FAIL] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Run as the normal desktop user, NOT with sudo."
command -v apt-get >/dev/null 2>&1 || fail "apt-get not found."
command -v xfconf-query >/dev/null 2>&1 || fail "xfconf-query not found. Step 1 / XFCE installation is incomplete."
command -v xfce4-panel >/dev/null 2>&1 || fail "xfce4-panel not found."
command -v xfdesktop >/dev/null 2>&1 || fail "xfdesktop not found."

if [[ ! "${XDG_CURRENT_DESKTOP:-}" =~ [Xx][Ff][Cc][Ee] ]]; then
    fail "This must be executed inside an XFCE desktop session. Current: ${XDG_CURRENT_DESKTOP:-unknown}"
fi
[[ -n "${DISPLAY:-}" ]] || fail "DISPLAY is not set. Step 2 requires a graphical XFCE session."

SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"

if [[ ! -d "$SRC/SmallSur" ]]; then
    warn "SmallSur source from Step 1 was not found at $SRC/SmallSur. Cloning it now."
    command -v git >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y git; }
    git clone --depth=1 https://github.com/jothi-prasath/SmallSur.git "$SRC/SmallSur"
fi

UP_PANEL="${SRC}/SmallSur/xfce4-panel/xfce4-panel.xml"
[[ -s "$UP_PANEL" ]] || fail "SmallSur panel XML missing: $UP_PANEL"

# ---------- dependencies ----------

info "Installing Step 2 dependencies..."
sudo apt-get update

PKGS=(
    curl
    file
    mesa-utils
    dbus-x11
)

AVAILABLE=()
for p in "${PKGS[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
        AVAILABLE+=("$p")
    else
        warn "APT package unavailable, skipping: $p"
    fi
done
(( ${#AVAILABLE[@]} > 0 )) && sudo apt-get install -y "${AVAILABLE[@]}"

command -v curl >/dev/null 2>&1 || fail "curl installation failed."
command -v file >/dev/null 2>&1 || fail "file utility installation failed."

# ---------- backup ----------

info "Backing up current XFCE state..."
PANEL_FILE_BACKUP="${BACKUP}/xfce4-panel.xml"
DESKTOP_FILE_BACKUP="${BACKUP}/xfce4-desktop.xml"
TERMINAL_FILE_BACKUP="${BACKUP}/terminalrc"

if [[ -f "$PANEL_XML" ]]; then cp -a "$PANEL_XML" "$PANEL_FILE_BACKUP"; fi
if [[ -f "${CONF}/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" ]]; then
    cp -a "${CONF}/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" "$DESKTOP_FILE_BACKUP"
fi
if [[ -f "${CONF}/xfce4/terminal/terminalrc" ]]; then
    cp -a "${CONF}/xfce4/terminal/terminalrc" "$TERMINAL_FILE_BACKUP"
fi
ok "Backups stored in $BACKUP"

# ---------- wallpaper ----------

info "Selecting and applying SmallSur wallpaper..."
mkdir -p "$WALL_DIR"

mapfile -t WALLPAPERS < <(
    find "$WALL_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        ! -path "$TERM_DIR/*" -printf '%s\t%p\n' 2>/dev/null | sort -nr | cut -f2-
)

if (( ${#WALLPAPERS[@]} == 0 )); then
    fail "No SmallSur wallpaper found under $WALL_DIR. Step 1 did not install a usable wallpaper payload."
fi

WALLPAPER="${WALLPAPERS[0]}"
[[ -f "$WALLPAPER" ]] || fail "Selected wallpaper does not exist: $WALLPAPER"
ok "Selected wallpaper: $WALLPAPER"

apply_wallpaper(){
    local image="$1"
    local props=()
    mapfile -t props < <(
        xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?(last-image|image-path)$' \
        || true
    )

    if (( ${#props[@]} == 0 )); then
        # Common Xfce fallback path; create it if necessary.
        local p="/backdrop/screen0/monitor0/workspace0/last-image"
        xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$image" 2>/dev/null \
            || xfconf-query -c xfce4-desktop -p "$p" -s "$image" 2>/dev/null \
            || true
        xfconf-query -c xfce4-desktop -p "/backdrop/screen0/monitor0/workspace0/image-style" -n -t int -s 5 2>/dev/null || true
    else
        local p
        for p in "${props[@]}"; do
            xfconf-query -c xfce4-desktop -p "$p" -s "$image" 2>/dev/null || true
        done
        # Xfce uses image-style 5 for Zoomed. Set every existing style property.
        mapfile -t STYLE_PROPS < <(
            xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
            | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?image-style$' \
            || true
        )
        for p in "${STYLE_PROPS[@]}"; do
            xfconf-query -c xfce4-desktop -p "$p" -s 5 2>/dev/null || true
        done
    fi

    # Disable slideshow/cycling where properties exist.
    mapfile -t CYCLE_PROPS < <(
        xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -E 'backdrop-cycle-enable$' || true
    )
    local c
    for c in "${CYCLE_PROPS[@]}"; do
        xfconf-query -c xfce4-desktop -p "$c" -s false 2>/dev/null || true
    done
}

apply_wallpaper "$WALLPAPER"
sleep 1

WALL_OK=false
if xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep -E '(last-image|image-path)$' | while IFS= read -r p; do xfconf-query -c xfce4-desktop -p "$p" 2>/dev/null; done | grep -Fxq "$WALLPAPER"; then
    WALL_OK=true
fi
$WALL_OK || warn "Could not independently read back every wallpaper path; session helper will re-apply it at login."

# ---------- exact one-panel SmallSur layout ----------

info "Replacing duplicate/stale XFCE panels with exactly one SmallSur top panel..."

# The upstream SmallSur XML is explicitly a single panel (panel-0). The important
# failure mode in Step 1 is that xfconf can keep an in-memory/previous panel tree,
# while copying the XML alone does not guarantee that old panel IDs disappear.
# We therefore stop the running panel, replace the XML, restart xfconfd, then force
# the active panel list to exactly [0].
xfce4-panel --quit >/dev/null 2>&1 || true
killall xfce4-panel >/dev/null 2>&1 || true
sleep 1

cp -a "$UP_PANEL" "$PANEL_XML"
[[ -s "$PANEL_XML" ]] || fail "Could not install SmallSur panel XML."

# Ask xfconfd to forget the current xfce4-panel cache; the next client activation
# will re-read the file on disk. If the daemon respawns immediately, that is fine.
pkill -x xfconfd >/dev/null 2>&1 || true
sleep 1

xfce4-panel >/tmp/smallsur-step2-panel.log 2>&1 &
PANEL_PID=$!
sleep 2

if ! kill -0 "$PANEL_PID" 2>/dev/null && ! pgrep -x xfce4-panel >/dev/null 2>&1; then
    cat /tmp/smallsur-step2-panel.log || true
    fail "XFCE panel failed to start."
fi

# Force the active panel array to exactly one ID: 0.
xfconf-query -c xfce4-panel -p /panels -n -t int -s 0 -a 2>/dev/null \
    || xfconf-query -c xfce4-panel -p /panels -t int -s 0 -a

# Explicitly make panel-0 the top, glass-like bar and ensure the panel occupies
# the top edge.  These properties are safe to create if the upstream XML did not
# contain them.
set_panel_prop(){
    local prop="$1" type="$2" value="$3"
    xfconf-query -c xfce4-panel -p "/panels/panel-0/${prop}" -n -t "$type" -s "$value" 2>/dev/null \
        || xfconf-query -c xfce4-panel -p "/panels/panel-0/${prop}" -s "$value" 2>/dev/null \
        || warn "Could not set panel property: $prop"
}

set_panel_prop position string 'p=6;x=0;y=0'
set_panel_prop position-locked bool true
set_panel_prop size int 30
set_panel_prop nrows uint 1
set_panel_prop length uint 100
set_panel_prop length-adjust bool true
set_panel_prop mode uint 0
set_panel_prop autohide-behavior uint 0
set_panel_prop disable-struts bool false
set_panel_prop background-style uint 1
set_panel_prop enter-opacity uint 94
set_panel_prop leave-opacity uint 84

# Xfconf arrays are easier to rewrite using -t/-s repeatedly.
xfconf-query -c xfce4-panel -p /panels -r -R >/dev/null 2>&1 || true
# Re-load panel configuration from disk once more, then force only panel-0.
xfce4-panel --quit >/dev/null 2>&1 || true
pkill -x xfconfd >/dev/null 2>&1 || true
sleep 1
xfce4-panel >/tmp/smallsur-step2-panel-final.log 2>&1 &
sleep 2
xfconf-query -c xfce4-panel -p /panels -n -t int -s 0 -a 2>/dev/null \
    || xfconf-query -c xfce4-panel -p /panels -t int -s 0 -a
xfce4-panel -r >/dev/null 2>&1 || true
sleep 2

# Apply the final glass-panel styling after the XML has been reloaded.
set_panel_prop position string 'p=6;x=0;y=0'
set_panel_prop position-locked bool true
set_panel_prop size int 30
set_panel_prop nrows uint 1
set_panel_prop length uint 100
set_panel_prop length-adjust bool true
set_panel_prop mode uint 0
set_panel_prop autohide-behavior uint 0
set_panel_prop disable-struts bool false
set_panel_prop background-style uint 1
xfconf-query -c xfce4-panel -p /panels/panel-0/background-rgba -n -t double -s 0.025 -t double -s 0.030 -t double -s 0.045 -t double -s 0.820 -a 2>/dev/null \
    || xfconf-query -c xfce4-panel -p /panels/panel-0/background-rgba -t double -s 0.025 -t double -s 0.030 -t double -s 0.045 -t double -s 0.820 -a 2>/dev/null \
    || warn "Could not set panel RGBA background; keeping upstream SmallSur color."
set_panel_prop enter-opacity uint 94
set_panel_prop leave-opacity uint 84
sleep 1

PANEL_IDS="$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null || true)"
if ! grep -Eq '^0$' <<< "$PANEL_IDS"; then
    echo "$PANEL_IDS"
    cat /tmp/smallsur-step2-panel-final.log || true
    fail "Active XFCE panel list is not exactly panel-0."
fi

ok "Exactly one active XFCE panel is configured: panel-0 (SmallSur top bar)."

# ---------- XFWM native compositor (Lite) ----------

info "Keeping XFWM4 native compositing enabled (Lite mode; no picom)..."
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true 2>/dev/null \
    || xfconf-query -c xfwm4 -p /general/use_compositing -s true
ok "XFWM4 native compositor enabled. Real background blur is intentionally disabled in Lite mode."

# Remove any Picom artifacts created by an earlier Full/previous Step 2 run.
# This is required so the Lite profile remains Lite after reboot.
killall picom >/dev/null 2>&1 || true
rm -f "${AUTOSTART}/smallsur-picom.desktop" \
      "${BIN}/smallsur-session-picom.sh" \
      "${AUTOSTART}/picom.desktop" \
      "${AUTOSTART}/picom.desktop.disabled"
rm -f "${CONF}/picom/smallsur.conf"
rmdir "${CONF}/picom" 2>/dev/null || true
if command -v picom >/dev/null 2>&1; then
    warn "picom is installed from a previous Full/Step 2 run; removing it for Lite mode."
    sudo apt-get purge -y picom || warn "Could not purge picom; it will remain installed but is not used/autostarted."
fi

# ---------- Terminal anime background ----------

info "Configuring XFCE Terminal with anime image background..."
mkdir -p "$TERM_DIR"

# Stable raw image hosted in a public Git repository. If unavailable, fall back to
# an installed SmallSur wallpaper so the terminal still gets an image background.
ANIME_URL="https://raw.githubusercontent.com/N1XA-CLI/walls/main/anime.png"
if ! curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$TERM_IMG.tmp" "$ANIME_URL"; then
    warn "Anime image download failed; falling back to SmallSur wallpaper for the terminal."
    rm -f "$TERM_IMG.tmp"
    cp -a "$WALLPAPER" "$TERM_IMG"
else
    mv -f "$TERM_IMG.tmp" "$TERM_IMG"
fi

MIME="$(file --mime-type -b "$TERM_IMG" 2>/dev/null || true)"
grep -q '^image/' <<< "$MIME" || fail "Terminal background is not a valid image: $TERM_IMG (detected: $MIME)"

# Xfce Terminal stores these values in xfconf. The upstream Terminal source exposes
# the same property names: background-mode, background-image-file, background-image-style,
# background-darkness and background-image-shading.
xfconf-query -c xfce4-terminal -p /background-mode -n -t string -s TERMINAL_BACKGROUND_IMAGE 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-mode -s TERMINAL_BACKGROUND_IMAGE
xfconf-query -c xfce4-terminal -p /background-image-file -n -t string -s "$TERM_IMG" 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-file -s "$TERM_IMG"
xfconf-query -c xfce4-terminal -p /background-image-style -n -t string -s TERMINAL_BACKGROUND_STYLE_SCALED 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-style -s TERMINAL_BACKGROUND_STYLE_SCALED
xfconf-query -c xfce4-terminal -p /background-darkness -n -t double -s 0.35 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-darkness -s 0.35
xfconf-query -c xfce4-terminal -p /background-image-shading -n -t double -s 0.18 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-shading -s 0.18

xfconf-query -c xfce4-terminal -p /font-name -n -t string -s 'JetBrains Mono 11' 2>/dev/null || true
xfconf-query -c xfce4-terminal -p /misc-menubar-default -n -t bool -s false 2>/dev/null || true
xfconf-query -c xfce4-terminal -p /misc-toolbar-default -n -t bool -s false 2>/dev/null || true
xfconf-query -c xfce4-terminal -p /misc-borders-default -n -t bool -s true 2>/dev/null || true

# Close existing terminals so all new windows re-open with the configured profile.
# This is intentionally opt-in only for currently-running XFCE Terminal instances.
killall xfce4-terminal >/dev/null 2>&1 || true

TERM_MODE="$(xfconf-query -c xfce4-terminal -p /background-mode 2>/dev/null || true)"
TERM_IMAGE="$(xfconf-query -c xfce4-terminal -p /background-image-file 2>/dev/null || true)"
[[ "$TERM_MODE" == "TERMINAL_BACKGROUND_IMAGE" ]] || fail "XFCE Terminal background mode verification failed."
[[ "$TERM_IMAGE" == "$TERM_IMG" ]] || fail "XFCE Terminal image verification failed."
ok "Anime terminal background verified: $TERM_IMG"

# ---------- Plank ----------

info "Configuring Plank as the only bottom dock..."

PLANK_THEME_DIR="${HOME}/.local/share/plank/themes"
mkdir -p "$PLANK_THEME_DIR"

if [[ -d "${SRC}/WhiteSur-gtk-theme/src/other/plank" ]]; then
    cp -a "${SRC}/WhiteSur-gtk-theme/src/other/plank/." "$PLANK_THEME_DIR/"
fi
if [[ -d "${SRC}/SmallSur/plank" ]]; then
    cp -a "${SRC}/SmallSur/plank/." "$PLANK_THEME_DIR/" 2>/dev/null || true
fi

dpkg-query -W -f='${Status}' plank 2>/dev/null | grep -q 'install ok installed' || {
    sudo apt-get install -y plank
}

killall plank >/dev/null 2>&1 || true
plank >/tmp/smallsur-step2-plank.log 2>&1 &
sleep 2

# Apply Plank preferences when the schema is available. Ignore only individual keys
# that differ between distro builds.
if command -v gsettings >/dev/null 2>&1; then
    PLANK_SCHEMA='net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/'
    gsettings set "$PLANK_SCHEMA" position 'bottom' 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" alignment 'center' 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" items-alignment 'center' 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" icon-size 48 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" zoom-enabled true 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" zoom-percent 140 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" hide-mode 'intelligent' 2>/dev/null || true
    gsettings set "$PLANK_SCHEMA" dock-items-monitor 'primary' 2>/dev/null || true

    # Prefer an installed WhiteSur/SmallSur plank theme.
    if [[ -d "${PLANK_THEME_DIR}/WhiteSur-dark" ]]; then
        gsettings set "$PLANK_SCHEMA" theme 'WhiteSur-dark' 2>/dev/null || true
    elif [[ -d "${PLANK_THEME_DIR}/McOS-BS-iMacM1-Black" ]]; then
        gsettings set "$PLANK_SCHEMA" theme 'McOS-BS-iMacM1-Black' 2>/dev/null || true
    fi
fi

pgrep -x plank >/dev/null 2>&1 || warn "Plank did not stay running; inspect /tmp/smallsur-step2-plank.log"

# ---------- persistent session helper ----------

info "Installing persistent login/session repair helper..."

cat > "$SESSION_HELPER" <<'EOF_SESSION'
#!/usr/bin/env bash
set -u

STATE="${HOME}/.local/state/smallsur-xfce"
WALL_DIR="${HOME}/Pictures/SmallSur"
TERM_IMG="${HOME}/Pictures/SmallSur/terminal/anime-terminal.png"
PANEL_XML="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
UP_PANEL="${STATE}/src/SmallSur/xfce4-panel/xfce4-panel.xml"

mkdir -p "$STATE"

apply_wallpaper(){
    local image=""
    image="$(find "$WALL_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) ! -path "$WALL_DIR/terminal/*" -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)"
    [[ -f "$image" ]] || return 0

    local p
    mapfile -t props < <(
        xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?(last-image|image-path)$' || true
    )
    for p in "${props[@]}"; do
        xfconf-query -c xfce4-desktop -p "$p" -s "$image" 2>/dev/null || true
    done
    mapfile -t styles < <(
        xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?image-style$' || true
    )
    for p in "${styles[@]}"; do
        xfconf-query -c xfce4-desktop -p "$p" -s 5 2>/dev/null || true
    done
}

# Give xfdesktop/panel a moment to finish loading before re-applying persistent state.
sleep 2
apply_wallpaper

# Ensure only panel-0 remains active.
if command -v xfconf-query >/dev/null 2>&1; then
    xfconf-query -c xfce4-panel -p /panels -n -t int -s 0 -a 2>/dev/null || true
    if [[ -f "$PANEL_XML" && -f "$UP_PANEL" ]]; then
        # Do not overwrite live Xfconf in every login. The active array is enough to
        # suppress stale Mint panels. The XML remains the backup/source for recovery.
        true
    fi
fi

# Restore Plank if it was not started by the normal autostart path.
if command -v plank >/dev/null 2>&1 && ! pgrep -x plank >/dev/null 2>&1; then
    plank >/dev/null 2>&1 &
fi

# Refresh panel after stale session state has had time to settle.
if command -v xfce4-panel >/dev/null 2>&1; then
    sleep 1
    xfce4-panel -r >/dev/null 2>&1 || true
fi
EOF_SESSION

chmod +x "$SESSION_HELPER"

cat > "${AUTOSTART}/smallsur-session.desktop" <<EOF_AUTOSESSION
[Desktop Entry]
Type=Application
Name=SmallSur Session Repair
Comment=Re-apply wallpaper, panel and dock state after login
Exec=${SESSION_HELPER}
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF_AUTOSESSION

cat > "${AUTOSTART}/smallsur-plank.desktop" <<'EOF_AUTOPLANK'
[Desktop Entry]
Type=Application
Name=Plank - SmallSur Dock
Comment=macOS-style bottom dock
Exec=plank
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF_AUTOPLANK

# Remove old generic Plank autostart created by Step 1 so we have one source of truth.
if [[ -f "${AUTOSTART}/plank.desktop" ]]; then
    rm -f "${AUTOSTART}/plank.desktop"
fi

# ---------- final verification ----------

info "Running independent final verification..."

ACTIVE_PANELS="$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null || true)"
PANEL_COUNT="$(grep -E '^[0-9]+$' <<< "$ACTI
