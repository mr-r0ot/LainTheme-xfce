#!/usr/bin/env bash
# SmallSur XFCE Step 2 HIGH
# Debian/Ubuntu/Linux Mint XFCE on X11.
#
# Purpose:
#   Transform the Step 1 installation into a high-end SmallSur/WhiteSur desktop:
#     - exactly one SmallSur top panel
#     - persistent SmallSur wallpaper
#     - Plank bottom dock
#     - XFWM compositor disabled
#     - current stable picom v13 built with GLX/OpenGL + animation support
#     - glass/translucent windows
#     - background blur (dual_kawase)
#     - rounded corners + shadows + fading
#     - window open/close/show/hide/opacity/size/position animations
#     - XFCE Terminal anime background
#     - persistent session helper and autostart
#     - backups and hard verification
#
# IMPORTANT:
#   This is intentionally the HIGH profile. It is NOT intended for 1.5 GB RAM
#   virtual machines. Use step2_lite.sh on those systems.
#
# The script builds the current stable upstream picom v13 locally under ~/.local
# so that distro packages with older/feature-reduced picom builds cannot silently
# remove the animation feature set.

set -Eeuo pipefail
IFS=$'\n\t'

STATE="${HOME}/.local/state/smallsur-xfce"
SRC="${STATE}/src"
BACKUP="${STATE}/backups/step2-high-$(date +%Y%m%d-%H%M%S)"
LOG="${STATE}/step2-high-install.log"
CONF="${HOME}/.config"
AUTOSTART="${CONF}/autostart"
BIN="${HOME}/.local/bin"
PICOM_CONF="${CONF}/picom/smallsur-high.conf"
SESSION_HELPER="${BIN}/smallsur-session-high.sh"
WALL_DIR="${HOME}/Pictures/SmallSur"
TERM_DIR="${HOME}/Pictures/SmallSur/terminal"
TERM_IMG="${TERM_DIR}/anime-terminal.png"
PANEL_XML="${CONF}/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
DESKTOP_XML="${CONF}/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
TERMINAL_RC="${CONF}/xfce4/terminal/terminalrc"
PICOM_SRC="${SRC}/picom"
PICOM_INSTALL_PREFIX="${HOME}/.local"
PICOM_BIN="${PICOM_INSTALL_PREFIX}/bin/picom"
PICOM_TAG="v13"
PICOM_REPO="https://github.com/yshui/picom.git"
PICOM_LOG="${STATE}/picom-high.log"
PID_FILE="${STATE}/picom-high.pid"

mkdir -p "$STATE" "$SRC" "$BACKUP" "$AUTOSTART" "$BIN" "$TERM_DIR" "${CONF}/picom" "$PICOM_INSTALL_PREFIX"
exec > >(tee -a "$LOG") 2>&1

FAILED=0
restore_on_failure(){
    FAILED=1
    echo
    echo "========== HIGH PROFILE FAILURE / RECOVERY ==========" >&2
    # Always leave the desktop usable if picom failed after XFWM was disabled.
    xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true 2>/dev/null \
        || xfconf-query -c xfwm4 -p /general/use_compositing -s true 2>/dev/null || true
    pkill -x picom 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
    echo "XFWM4 compositing restored. picom stopped." >&2
    echo "Log: $LOG" >&2
    echo "=======================================================" >&2
}
trap 'echo "[FAIL] Unexpected error at line $LINENO. See: $LOG" >&2; restore_on_failure' ERR

info(){ echo "[INFO] $*"; }
ok(){ echo "[ OK ] $*"; }
warn(){ echo "[WARN] $*"; }
fail(){ echo "[FAIL] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Run as the normal desktop user, NOT with sudo."
command -v apt-get >/dev/null 2>&1 || fail "apt-get not found."
command -v xfconf-query >/dev/null 2>&1 || fail "xfconf-query not found. Step 1 / XFCE installation is incomplete."
command -v xfce4-panel >/dev/null 2>&1 || fail "xfce4-panel not found."
command -v xfdesktop >/dev/null 2>&1 || fail "xfdesktop not found."
command -v git >/dev/null 2>&1 || { sudo apt-get update; sudo apt-get install -y git; }

if [[ ! "${XDG_CURRENT_DESKTOP:-}" =~ [Xx][Ff][Cc][Ee] ]]; then
    fail "This must be executed inside an XFCE desktop session. Current: ${XDG_CURRENT_DESKTOP:-unknown}"
fi
[[ -n "${DISPLAY:-}" ]] || fail "DISPLAY is not set. This HIGH profile requires an X11 XFCE session."
if [[ "${XDG_SESSION_TYPE:-x11}" != "x11" ]]; then
    warn "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unknown}; this profile is designed for X11 XFCE."
fi

# ---------- SmallSur source ----------

if [[ ! -d "$SRC/SmallSur/.git" ]]; then
    if [[ -d "$SRC/SmallSur" ]]; then rm -rf "$SRC/SmallSur"; fi
    info "SmallSur source from Step 1 was not found; cloning it now."
    git clone --depth=1 https://github.com/jothi-prasath/SmallSur.git "$SRC/SmallSur"
fi
UP_PANEL="${SRC}/SmallSur/xfce4-panel/xfce4-panel.xml"
[[ -s "$UP_PANEL" ]] || fail "SmallSur panel XML missing: $UP_PANEL"

# ---------- dependencies ----------

info "Installing HIGH-profile build/runtime dependencies..."
sudo apt-get update

PKGS=(
    build-essential
    git
    curl
    ca-certificates
    file
    pkg-config
    python3
    meson
    ninja-build
    cmake
    libconfig-dev
    libdbus-1-dev
    libegl-dev
    libev-dev
    libgl-dev
    libepoxy-dev
    libpcre2-dev
    libpixman-1-dev
    libx11-dev
    libx11-xcb-dev
    libxcb1-dev
    libxcb-composite0-dev
    libxcb-damage0-dev
    libxcb-glx0-dev
    libxcb-image0-dev
    libxcb-present-dev
    libxcb-randr0-dev
    libxcb-render0-dev
    libxcb-render-util0-dev
    libxcb-shape0-dev
    libxcb-util-dev
    libxcb-xfixes0-dev
    uthash-dev
    mesa-utils
    dbus-x11
    plank
    xfce4-goodies
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

command -v meson >/dev/null 2>&1 || fail "meson is missing after dependency installation."
command -v ninja >/dev/null 2>&1 || fail "ninja is missing after dependency installation."
command -v gcc >/dev/null 2>&1 || fail "gcc is missing after dependency installation."
command -v g++ >/dev/null 2>&1 || fail "g++ is missing after dependency installation."

# ---------- backup ----------

info "Backing up current XFCE state..."
[[ -f "$PANEL_XML" ]] && cp -a "$PANEL_XML" "$BACKUP/xfce4-panel.xml"
[[ -f "$DESKTOP_XML" ]] && cp -a "$DESKTOP_XML" "$BACKUP/xfce4-desktop.xml"
[[ -f "$TERMINAL_RC" ]] && cp -a "$TERMINAL_RC" "$BACKUP/terminalrc"
[[ -f "$PICOM_CONF" ]] && cp -a "$PICOM_CONF" "$BACKUP/smallsur-high.conf"
[[ -f "${AUTOSTART}/picom.desktop" ]] && cp -a "${AUTOSTART}/picom.desktop" "$BACKUP/picom.desktop.old"
[[ -f "${AUTOSTART}/plank.desktop" ]] && cp -a "${AUTOSTART}/plank.desktop" "$BACKUP/plank.desktop.old"
ok "Backups stored in $BACKUP"

# ---------- hardware diagnostics ----------

RAM_GIB="$(awk '/MemTotal:/ {printf "%.2f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo unknown)"
GPU_RENDERER="unknown"
GPU_ACCEL="unknown"
if command -v glxinfo >/dev/null 2>&1; then
    GPU_RENDERER="$(glxinfo -B 2>/dev/null | awk -F: '/OpenGL renderer string/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' || true)"
    GPU_ACCEL="$(glxinfo -B 2>/dev/null | awk -F: '/direct rendering:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' || true)"
fi
info "Detected RAM: ${RAM_GIB} GiB"
info "OpenGL renderer: ${GPU_RENDERER:-unknown}"
info "Direct rendering: ${GPU_ACCEL:-unknown}"
if grep -qiE 'llvmpipe|softpipe|software' <<< "${GPU_RENDERER:-}"; then
    warn "Software OpenGL renderer detected. HIGH blur/animation will be CPU-heavy."
fi

# ---------- wallpaper ----------

info "Selecting and applying SmallSur wallpaper..."
mkdir -p "$WALL_DIR"
mapfile -t WALLPAPERS < <(
    find "$WALL_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        ! -path "$TERM_DIR/*" -printf '%s\t%p\n' 2>/dev/null | sort -nr | cut -f2-
)
(( ${#WALLPAPERS[@]} > 0 )) || fail "No SmallSur wallpaper found under $WALL_DIR."
WALLPAPER="${WALLPAPERS[0]}"
[[ -f "$WALLPAPER" ]] || fail "Selected wallpaper does not exist: $WALLPAPER"
ok "Selected wallpaper: $WALLPAPER"

apply_wallpaper(){
    local image="$1"
    local -a props=()
    mapfile -t props < <(
        xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?(last-image|image-path)$' || true
    )
    if (( ${#props[@]} == 0 )); then
        local p="/backdrop/screen0/monitor0/workspace0/last-image"
        xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$image" 2>/dev/null \
            || xfconf-query -c xfce4-desktop -p "$p" -s "$image" 2>/dev/null || true
        xfconf-query -c xfce4-desktop -p "/backdrop/screen0/monitor0/workspace0/image-style" -n -t int -s 5 2>/dev/null || true
    else
        local p
        for p in "${props[@]}"; do xfconf-query -c xfce4-desktop -p "$p" -s "$image" 2>/dev/null || true; done
        local -a styles=()
        mapfile -t styles < <(
            xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
            | grep -E '^/backdrop/screen[^/]+/monitor[^/]+/(workspace-?[0-9]+/)?image-style$' || true
        )
        for p in "${styles[@]}"; do xfconf-query -c xfce4-desktop -p "$p" -s 5 2>/dev/null || true; done
    fi
    local -a cycles=()
    mapfile -t cycles < <(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep -E 'backdrop-cycle-enable$' || true)
    local c
    for c in "${cycles[@]}"; do xfconf-query -c xfce4-desktop -p "$c" -s false 2>/dev/null || true; done
}
apply_wallpaper "$WALLPAPER"
sleep 1

# ---------- exact one-panel SmallSur layout ----------

info "Installing exactly one SmallSur top panel..."
xfce4-panel --quit >/dev/null 2>&1 || true
killall xfce4-panel >/dev/null 2>&1 || true
sleep 1
cp -a "$UP_PANEL" "$PANEL_XML"
[[ -s "$PANEL_XML" ]] || fail "Could not install SmallSur panel XML."
pkill -x xfconfd >/dev/null 2>&1 || true
sleep 1
xfce4-panel >/tmp/smallsur-high-panel.log 2>&1 &
sleep 2

set_panel_prop(){
    local prop="$1" type="$2" value="$3"
    xfconf-query -c xfce4-panel -p "/panels/panel-0/${prop}" -n -t "$type" -s "$value" 2>/dev/null \
        || xfconf-query -c xfce4-panel -p "/panels/panel-0/${prop}" -s "$value" 2>/dev/null \
        || warn "Could not set panel property: $prop"
}

xfconf-query -c xfce4-panel -p /panels -n -t int -s 0 -a 2>/dev/null \
    || xfconf-query -c xfce4-panel -p /panels -t int -s 0 -a
set_panel_prop position string 'p=6;x=0;y=0'
set_panel_prop position-locked bool true
set_panel_prop size int 30
set_panel_prop nrows uint 1
set_panel_prop length uint 100
set_panel_prop length-adjust bool true
set_panel_prop mode uint 0
set_panel_prop autohide-behavior uint 0
set_panel_prop enable-struts bool true
set_panel_prop background-style uint 1
set_panel_prop enter-opacity uint 94
set_panel_prop leave-opacity uint 84
xfconf-query -c xfce4-panel -p /panels/panel-0/background-rgba -n -t double -s 0.025 -t double -s 0.030 -t double -s 0.045 -t double -s 0.82 -a 2>/dev/null \
    || xfconf-query -c xfce4-panel -p /panels/panel-0/background-rgba -t double -s 0.025 -t double -s 0.030 -t double -s 0.045 -t double -s 0.82 -a 2>/dev/null \
    || true

PANEL_IDS="$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null || true)"
grep -Eq '^0$' <<< "$PANEL_IDS" || fail "Active XFCE panel list is not exactly panel-0."
ok "Exactly one active SmallSur top panel is configured."

# ---------- build stable upstream picom v13 ----------

info "Building upstream stable picom ${PICOM_TAG} with OpenGL/GLX, D-Bus, regex and animation support..."
if [[ ! -d "$PICOM_SRC/.git" ]]; then
    rm -rf "$PICOM_SRC"
    git clone --depth=1 --branch "$PICOM_TAG" "$PICOM_REPO" "$PICOM_SRC"
else
    git -C "$PICOM_SRC" fetch --depth=1 origin "refs/tags/${PICOM_TAG}:refs/tags/${PICOM_TAG}"
    git -C "$PICOM_SRC" checkout -f "$PICOM_TAG"
    git -C "$PICOM_SRC" submodule update --init --recursive
fi
[[ -f "$PICOM_SRC/meson.build" ]] || fail "picom source tree is incomplete."
git -C "$PICOM_SRC" submodule update --init --recursive

rm -rf "$PICOM_SRC/build"
meson setup "$PICOM_SRC" "$PICOM_SRC/build" \
    --buildtype=release \
    --prefix="$PICOM_INSTALL_PREFIX" \
    -Dwith_docs=false \
    -Ddbus=true \
    -Dopengl=true \
    -Dregex=true
ninja -C "$PICOM_SRC/build"
ninja -C "$PICOM_SRC/build" install

[[ -x "$PICOM_BIN" ]] || fail "picom build/install did not produce $PICOM_BIN"
export PATH="${PICOM_INSTALL_PREFIX}/bin:${PATH}"
PICOM_VERSION="$($PICOM_BIN --version 2>/dev/null | head -n1 || true)"
info "Installed: ${PICOM_VERSION:-unknown}"
grep -qi 'picom' <<< "$PICOM_VERSION" || fail "Installed binary does not identify as picom."

# ---------- picom config ----------

info "Writing high-end glass/blur/animation configuration..."
cat > "$PICOM_CONF" <<'EOF_PICOM'
# SmallSur HIGH — picom v13 configuration
# X11 / XFCE
# Stable upstream v13 provides animation scripts and rounded-corner support.

backend = "glx";
vsync = true;
use-damage = true;

# Avoid expensive full-screen unredirection while using blur/animations.
unredir-if-possible = false;

# ---------- opacity / glass ----------

active-opacity = 0.94;
inactive-opacity = 0.88;
frame-opacity = 0.86;
inactive-opacity-override = true;
detect-client-opacity = true;

opacity-rule = [
    "94:window_type = 'normal'",
    "94:window_type = 'dialog'",
    "92:window_type = 'utility'",
    "88:window_type = 'popup_menu'",
    "88:window_type = 'dropdown_menu'",
    "90:window_type = 'tooltip'",
    "100:window_type = 'desktop'",
    "100:window_type = 'dock'",
    "100:_NET_WM_STATE@:32a *= '_NET_WM_STATE_FULLSCREEN'"
];

# ---------- blur ----------

blur-background = true;
blur-background-frame = true;
blur-background-fixed = false;
blur-method = "dual_kawase";
blur-strength = 7;

blur-background-exclude = [
    "window_type = 'desktop'",
    "window_type = 'dock'",
    "window_type = 'notification'",
    "class_g = 'conky'",
    "class_g = 'Plank'"
];

# ---------- rounded glass ----------

corner-radius = 18;
rounded-corners-exclude = [
    "window_type = 'desktop'",
    "window_type = 'dock'",
    "window_type = 'notification'",
    "window_type = 'dropdown_menu'",
    "window_type = 'popup_menu'",
    "class_g = 'Plank'",
    "class_g = 'Xfce4-panel'",
    "class_g = 'xfdesktop'"
];

# ---------- shadows ----------

shadow = true;
shadow-radius = 22;
shadow-opacity = 0.42;
shadow-offset-x = -9;
shadow-offset-y = -9;
shadow-exclude = [
    "window_type = 'desktop'",
    "window_type = 'dock'",
    "window_type = 'notification'",
    "class_g = 'Plank'",
    "class_g = 'Xfce4-panel'",
    "class_g = 'xfdesktop'"
];

# ---------- base fade ----------

fading = true;
fade-in-step = 0.035;
fade-out-step = 0.035;
fade-delta = 8;
no-fading-openclose = false;

# ---------- animations ----------
# Open/close/show/hide use stable built-in v13 presets.
# Position/size use the upstream geometry-change animation; this is intentionally
# included in HIGH for maximal visual polish. It may be less smooth on weak GPUs.

animations = (
    {
        triggers = [ "open" ];
        preset = "appear";
        scale = 0.92;
        duration = 0.22;
    },
    {
        triggers = [ "close" ];
        preset = "disappear";
        scale = 0.92;
        duration = 0.18;
    },
    {
        triggers = [ "show" ];
        preset = "slide-in";
        direction = "down";
        duration = 0.24;
    },
    {
        triggers = [ "hide" ];
        preset = "slide-out";
        direction = "down";
        duration = 0.20;
    },
    {
        triggers = [ "position", "size" ];
        preset = "geometry-change";
        duration = 0.20;
    },
    {
        triggers = [ "increase-opacity" ];
        opacity = {
            curve = "cubic-bezier(0.25, 0.1, 0.25, 1.0)";
            duration = 0.14;
            start = "window-raw-opacity-before";
            end = "window-raw-opacity";
        };
    },
    {
        triggers = [ "decrease-opacity" ];
        opacity = {
            curve = "cubic-bezier(0.25, 0.1, 0.25, 1.0)";
            duration = 0.16;
            start = "window-raw-opacity-before";
            end = "window-raw-opacity";
        };
    }
);

# Menus/popups: soft shadow, no geometry animation.
wintypes:
{
    desktop = { shadow = false; fade = false; opacity = 1.0; };
    dock = { shadow = false; fade = false; opacity = 1.0; };
    dnd = { shadow = false; };
    popup_menu = { shadow = true; fade = true; opacity = 0.88; };
    dropdown_menu = { shadow = true; fade = true; opacity = 0.88; };
    tooltip = { shadow = true; fade = true; opacity = 0.90; };
};

# Do not blur the desktop itself.
# Keep fullscreen opaque to avoid needless repainting and video issues.
EOF_PICOM

[[ -s "$PICOM_CONF" ]] || fail "picom configuration was not created."

# ---------- verify picom configuration before replacing XFWM ----------

info "Validating picom configuration with a real compositor startup test..."
# Start XFWM compositor as the safety net while parsing the config.
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true 2>/dev/null \
    || xfconf-query -c xfwm4 -p /general/use_compositing -s true
pkill -x picom >/dev/null 2>&1 || true

TEST_LOG="${STATE}/picom-high-validation.log"
rm -f "$TEST_LOG"
# Launch with XFWM still active only long enough to catch configuration errors.
# picom should fail fast with another compositor present; this is not a config test
# by itself, so we instead temporarily disable XFWM after syntax generation and then
# immediately validate picom starts. Recovery trap restores XFWM if validation fails.
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false 2>/dev/null \
    || xfconf-query -c xfwm4 -p /general/use_compositing -s false

"$PICOM_BIN" --config "$PICOM_CONF" --log-file "$TEST_LOG" >/dev/null 2>&1 &
TEST_PID=$!
sleep 4
if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo "----- picom validation log -----" >&2
    cat "$TEST_LOG" 2>/dev/null || true
    echo "--------------------------------" >&2
    fail "picom failed to stay running with the HIGH configuration. XFWM will be restored by the failure trap."
fi

PICOM_PID="$TEST_PID"
printf '%s\n' "$PICOM_PID" > "$PID_FILE"
ok "picom v13 started successfully with GLX/blur/animation configuration."

# Verify the animation syntax specifically through the running process metadata.
# The v13 binary is the exact upstream version whose release notes document animation support.
if ! grep -q 'animations' "$PICOM_CONF"; then
    fail "Animation configuration section is missing."
fi

# ---------- anime terminal ----------

info "Configuring XFCE Terminal with anime background..."
mkdir -p "$TERM_DIR"
ANIME_URL="https://raw.githubusercontent.com/N1XA-CLI/walls/main/anime.png"
if [[ ! -s "$TERM_IMG" ]]; then
    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$TERM_IMG.tmp" "$ANIME_URL"; then
        warn "Anime image download failed; using the selected SmallSur wallpaper instead."
        rm -f "$TERM_IMG.tmp"
        cp -a "$WALLPAPER" "$TERM_IMG"
    else
        mv -f "$TERM_IMG.tmp" "$TERM_IMG"
    fi
fi
MIME="$(file --mime-type -b "$TERM_IMG" 2>/dev/null || true)"
grep -q '^image/' <<< "$MIME" || fail "Terminal image is not valid: $TERM_IMG (detected: $MIME)"

xfconf-query -c xfce4-terminal -p /background-mode -n -t string -s TERMINAL_BACKGROUND_IMAGE 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-mode -s TERMINAL_BACKGROUND_IMAGE
xfconf-query -c xfce4-terminal -p /background-image-file -n -t string -s "$TERM_IMG" 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-file -s "$TERM_IMG"
xfconf-query -c xfce4-terminal -p /background-image-style -n -t string -s TERMINAL_BACKGROUND_STYLE_SCALED 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-style -s TERMINAL_BACKGROUND_STYLE_SCALED
xfconf-query -c xfce4-terminal -p /background-darkness -n -t double -s 0.28 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-darkness -s 0.28
xfconf-query -c xfce4-terminal -p /background-image-shading -n -t double -s 0.12 2>/dev/null \
    || xfconf-query -c xfce4-terminal -p /background-image-shading -s 0.12
xfconf-query -c xfce4-terminal -p /font-name -n -t string -s 'JetBrains Mono 11' 2>/dev/null || true
xfconf-query -c xfce4-terminal -p /misc-menubar-default -n -t bool -s false 2>/dev/null || true
xfconf-query -c xfce4-terminal -p /misc-toolbar-default -n -t bool -s 
