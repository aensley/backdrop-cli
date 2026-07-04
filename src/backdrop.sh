#!/usr/bin/env bash

# backdrop - set a new desktop wallpaper every day from various sources

# A personal script to set the desktop wallpaper to a new image every day from various sources.
# See the "Sources" section in the usage() function below for the available sources.
# The script is designed to be run daily from cron or a systemd timer,
# but can also be invoked manually to switch sources or get status info.

# Sources:
# apod:   https://apod.nasa.gov/apod/
# bing:   https://www.bing.com/
# earth:  https://www.earth.com/gallery/images-of-the-day/
# eo:     https://science.nasa.gov/earth/earth-observatory/image-of-the-day/
# iotd:   https://www.nasa.gov/image-of-the-day/
# natgeo: https://www.nationalgeographic.com/photo-of-the-day/
# wmc:    https://commons.wikimedia.org/wiki/Commons:Picture_of_the_day

VERSION="1.7.0"

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/backdrop"
BASE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$BASE_CONFIG_DIR/backdrop"
CONFIG_FILE="$CONFIG_DIR/config"
VALID_SOURCES=(apod bing earth iotd natgeo eo wmc)

# Metadata for the most recently resolved image; set by apply_wallpaper after
# parsing META_* lines from resolver output.
META_TITLE=""
META_DESC=""
META_URL=""

# Built-in defaults, can be overriden in the config file.
# All live in the config file ($CONFIG_FILE) and can be edited there:
#   source              active wallpaper source(s); space-separated list or "all"
#                       (also set via: backdrop set <src> [src...])
#   rotate_interval     minutes between source rotations; 0 = disabled
#                       (also set via: backdrop set-rotate-interval <minutes>)
#   screen_aspect_ratio screen aspect ratio used if auto-detect fails
#                       (16:9=1.7778  16:10=1.6  21:9=2.3333  4:3=1.3333)
#   zoom_min_coverage   crop tolerance; if "zoom" would show less than this
#                       fraction of the image, use "scaled" instead (0.55 ~= allow up to ~45% crop)
#   user_agent          HTTP User-Agent sent with all requests
SOURCE="iotd"
ROTATE_INTERVAL=0
SCREEN_ASPECT_RATIO="1.7778"
ZOOM_MIN_COVERAGE="0.55"
USER_AGENT="backdrop/${VERSION%.*} (personal daily wallpaper script)"
TIMER_TIME="08:00"

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

die() {
  echo "backdrop: $*" >&2
  exit 1
}

# --- Config file ------------------------------------------------------------

# Read a key ("key = value") from the config file; prints the value or nothing.
cfg_get() {
  local key="$1" v=""
  [ -r "$CONFIG_FILE" ] || return 0
  v="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$CONFIG_FILE" | tail -n1)"
  v="${v%"${v##*[![:space:]]}"}" # trim trailing whitespace
  case "$v" in                   # strip surrounding quotes
    \"*\")
      v="${v#\"}"
      v="${v%\"}"
      ;;
    \'*\')
      v="${v#\'}"
      v="${v%\'}"
      ;;
  esac
  printf '%s' "$v"
}

# Set a key in the config file in place (preserving comments / other keys).
cfg_set() {
  local key="$1" val="$2" tmp
  ensure_config
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
    tmp="$(mktemp)"
    sed -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\\1${val}|" "$CONFIG_FILE" >"$tmp"
    mv "$tmp" "$CONFIG_FILE"
  else
    printf '%s = %s\n' "$key" "$val" >>"$CONFIG_FILE"
  fi
}

# Create the config file on first run with built-in defaults.
ensure_config() {
  [ -f "$CONFIG_FILE" ] && return 0
  local seed="$SOURCE"
  cat >"$CONFIG_FILE" <<EOF
# backdrop configuration  (key = value; lines starting with # are ignored)

# Active wallpaper source(s): iotd | apod | bing | wmc | eo | earth | natgeo
# Single source:    source = iotd
# Multiple sources: source = iotd apod bing
# All sources:      source = all
# Also settable with: backdrop set <source> [source...]
source = $seed

# How often to rotate between sources, in minutes (0 = disabled).
# Only applies when multiple sources are configured.
# When rotation is enabled, the timer fires at this interval instead of timer_time.
# Also settable with: backdrop set-rotate-interval <minutes>
rotate_interval = $ROTATE_INTERVAL

# Screen aspect ratio used only if auto-detection (/sys/class/drm) fails.
# 16:9 = 1.7778   16:10 = 1.6   21:9 = 2.3333   4:3 = 1.3333
screen_aspect_ratio = $SCREEN_ASPECT_RATIO

# Crop tolerance for choosing zoom vs scaled. If filling the screen ("zoom")
# would keep less than this fraction of the image, "scaled" is used instead.
# Higher = switch to scaled more eagerly; lower = tolerate more cropping.
zoom_min_coverage = $ZOOM_MIN_COVERAGE

# HTTP User-Agent string sent with all requests. Override if a source blocks the default.
# user_agent = backdrop/${VERSION%.*} (personal daily wallpaper script)

# Time of day to run the daily wallpaper update (HH:MM, 24-hour format).
# Only applies when rotation is disabled (rotate_interval = 0).
# Also settable with: backdrop set-time HH:MM
timer_time = $TIMER_TIME
EOF
}

# Load config values into the globals (called once before dispatch).
load_config() {
  ensure_config
  local v
  v="$(cfg_get screen_aspect_ratio)"
  [ -n "$v" ] && SCREEN_ASPECT_RATIO="$v"
  v="$(cfg_get zoom_min_coverage)"
  [ -n "$v" ] && ZOOM_MIN_COVERAGE="$v"
  v="$(cfg_get user_agent)"
  [ -n "$v" ] && USER_AGENT="$v"
  v="$(cfg_get timer_time)"
  [ -n "$v" ] && TIMER_TIME="$v"
  v="$(cfg_get rotate_interval)"
  [[ "$v" =~ ^[0-9]+$ ]] && ROTATE_INTERVAL="$v"
  return 0
}

# --- Source resolvers -------------------------------------------------------
# Each prints one or more candidate image URLs (best first), one per line.
# Empty output  = no image today (e.g. APOD video day) -> skip, keep current.
# Return code 1 = the fetch itself failed (network etc.).

# NASA Image of the Day
resolve_iotd() {
  local feed url item title desc link
  feed="$(curl -fsSL --max-time 30 -A "$USER_AGENT" "https://www.nasa.gov/feeds/iotd-feed/")" || return 1
  item="$(awk '/<item>/{f=1} f{print} /<\/item>/{if(f)exit}' <<<"$feed")"
  url="$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' <<<"$item" | head -1)" || true
  title="$(grep -m1 '<title' <<<"$item" | sed 's/.*<title[^>]*>//;s/<\/title>//;s/<!\[CDATA\[//;s/\]\]>//' || true)"
  desc="$(grep -m1 '<description>' <<<"$item" | sed 's/.*<description>//;s/<\/description>//' || true)"
  link="$(grep -m1 '<link>' <<<"$item" | sed 's/.*<link>//;s/<\/link>//' || true)"
  printf 'META_TITLE:%s\n' "$(_strip_html "$title")"
  [ -n "$desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$desc")"
  printf 'META_URL:%s\n' "${link:-https://www.nasa.gov/image-of-the-day/}"
  [ -n "$url" ] && printf '%s\n' "$url"
  return 0
}

# NASA Astronomy Picture of the Day
resolve_apod() {
  local page rel _out title desc
  page="$(curl -fsSL --max-time 30 -A "$USER_AGENT" "https://apod.nasa.gov/apod/astropix.html")" || return 1
  rel="$(grep -ioE 'href="image/[^"]+\.(jpg|jpeg|png|gif)"' <<<"$page" |
    head -1 | sed -E 's/.*href="([^"]+)".*/\1/I')" || true
  _out="$(python3 -c '
import re, sys
page = sys.stdin.read()
tm = re.search(r"<center>\s*<b>([^<]+)</b>\s*<br", page, re.IGNORECASE)
title = tm.group(1).strip() if tm else ""
em = re.search(r"<b>\s*Explanation:\s*</b>(.*?)(?=<p>|<hr|</body>)", page, re.DOTALL | re.IGNORECASE)
if em:
    desc = re.sub(r"<[^>]+>", "", em.group(1))
    desc = " ".join(desc.split())[:400]
else:
    desc = ""
print(title)
print(desc)
' <<<"$page" 2>/dev/null)" || true
  title="$(sed -n '1p' <<<"$_out")"
  desc="$(sed -n '2p' <<<"$_out")"
  [ -n "$title" ] && printf 'META_TITLE:%s\n' "$(_strip_html "$title")"
  [ -n "$desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$desc")"
  printf 'META_URL:%s\n' "https://apod.nasa.gov/apod/astropix.html"
  [ -n "$rel" ] && printf '%s\n' "https://apod.nasa.gov/apod/$rel"
  return 0
}

# Bing image of the day
resolve_bing() {
  local json _out urlbase url
  json="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US")" || return 1
  _out="$(python3 -c 'import json,sys; d=json.load(sys.stdin)["images"][0]; [print(d.get(k,"")) for k in ("urlbase","url","title","copyright")]' <<<"$json" 2>/dev/null)"
  urlbase="$(sed -n '1p' <<<"$_out")"
  url="$(sed -n '2p' <<<"$_out")"
  [ -n "$(sed -n '3p' <<<"$_out")" ] && printf 'META_TITLE:%s\n' "$(sed -n '3p' <<<"$_out")"
  [ -n "$(sed -n '4p' <<<"$_out")" ] && printf 'META_DESC:%s\n' "$(sed -n '4p' <<<"$_out")"
  printf 'META_URL:%s\n' "https://www.bing.com/"
  [ -n "$urlbase" ] && printf '%s\n' "https://www.bing.com${urlbase}_UHD.jpg" # 4K
  [ -n "$url" ] && printf '%s\n' "https://www.bing.com${url}"                 # 1920x1080 fallback
  return 0
}

# Wikimedia Commons Picture of the Day
# (The global $USER_AGENT is a descriptive string, as Wikimedia's API policy asks for.)
resolve_wmc() {
  local date resp file enc title desc
  date="$(date +%Y-%m-%d)"
  resp="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    "https://commons.wikimedia.org/w/api.php?action=expandtemplates&format=json&prop=wikitext&text=%7B%7BPotd/$date%7D%7D")" || return 1
  file="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["expandtemplates"]["wikitext"])' <<<"$resp" 2>/dev/null)" || return 1
  [ -n "$file" ] || return 0
  title="$(printf '%s' "$file" | sed 's/^File://;s/\.[^.]*$//;s/_/ /g')"
  printf 'META_TITLE:%s\n' "$title"
  resp="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    "https://commons.wikimedia.org/w/api.php?action=expandtemplates&format=json&prop=wikitext&text=%7B%7BPotd/${date}%20(en)%7D%7D")" || true
  desc="$(python3 -c '
import re, json, sys
text = json.load(sys.stdin)["expandtemplates"]["wikitext"].strip()
text = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", text)
text = re.sub(r"\{\{[^}]*\}\}", "", text)
print(" ".join(text.split())[:300])
' <<<"$resp" 2>/dev/null)" || true
  [ -n "$desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$desc")"
  printf 'META_URL:%s\n' "https://commons.wikimedia.org/wiki/File:$(printf '%s' "${file#File:}" | tr ' ' '_')"
  enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$file")"
  resp="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url&iiurlwidth=3840&titles=File:$enc")" || return 1
  python3 -c 'import json,sys
p=list(json.load(sys.stdin)["query"]["pages"].values())[0]["imageinfo"][0]
if p.get("thumburl"): print(p["thumburl"])
print(p["url"])' <<<"$resp" 2>/dev/null || return 1
  return 0
}

# NASA Earth Observatory Image of the Day
resolve_eo() {
  local feed item base title desc link
  feed="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    "https://earthobservatory.nasa.gov/feeds/image-of-the-day.rss")" || return 1
  item="$(awk '/<item>/{f=1} f{print} /<\/item>/{if(f)exit}' <<<"$feed")"
  base="$(grep -oiE 'https://assets\.science\.nasa\.gov/dynamicimage/[^"?]+\.(jpg|jpeg|png)' <<<"$item" | head -1)" || true
  title="$(grep -m1 '<title' <<<"$item" | sed 's/.*<title[^>]*>//;s/<\/title>//;s/<!\[CDATA\[//;s/\]\]>//' || true)"
  desc="$(grep -m1 '<description>' <<<"$item" | sed 's/.*<!\[CDATA\[//;s/<[^>]*>//g;s/\]\]>.*//' || true)"
  link="$(grep -m1 '<link>' <<<"$item" | sed 's/.*<link>//;s/<\/link>//' || true)"
  [ -z "$link" ] && link="$(grep -oiE 'https://earthobservatory\.nasa\.gov/images/[0-9]+[^"< ]*' <<<"$item" | head -1 || true)"
  printf 'META_TITLE:%s\n' "$(_strip_html "$title")"
  [ -n "$desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$desc")"
  printf 'META_URL:%s\n' "${link:-https://earthobservatory.nasa.gov/}"
  [ -n "$base" ] || return 0
  printf '%s\n' "${base}?w=3840" # ~4K-wide rendering
  printf '%s\n' "$base"          # CDN-default size as fallback
  return 0
}

# National Geographic Photo of the Day
resolve_natgeo() {
  local page url og_title og_desc og_url
  page="$(curl -fsSL --max-time 30 -A "$USER_AGENT" "https://www.nationalgeographic.com/photo-of-the-day/")" || return 1
  url="$(grep -oiE 'property="og:image" content="https://i\.natgeofe\.com/[^"]+"' <<<"$page" |
    sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  og_title="$(grep -oiE 'property="og:title" content="[^"]+"' <<<"$page" | sed -E 's/.*content="([^"]+)".*/\1/;s/ \|.*//' | head -1)" || true
  og_desc="$(grep -oiE 'property="og:description" content="[^"]+"' <<<"$page" | sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  og_url="$(grep -oiE 'property="og:url" content="[^"]+"' <<<"$page" | sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  [ -n "$og_title" ] && printf 'META_TITLE:%s\n' "$(_strip_html "$og_title")"
  [ -n "$og_desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$og_desc")"
  printf 'META_URL:%s\n' "${og_url:-https://www.nationalgeographic.com/photo-of-the-day/}"
  [ -n "$url" ] || return 0
  printf '%s\n' "${url}?w=5120" # max CDN resolution (~4600px wide)
  printf '%s\n' "$url"          # original as fallback
  return 0
}

# Earth.com Image of the Day
resolve_earth() {
  local page article_url article og_title og_desc og_url url
  page="$(curl -fsSL --max-time 30 -A "$USER_AGENT" "https://www.earth.com/gallery/images-of-the-day/")" || return 1
  article_url="$(grep -oiE 'href="https://www\.earth\.com/image/[^"]+"' <<<"$page" |
    sed -E 's/href="([^"]+)".*/\1/' | head -1)" || true
  [ -n "$article_url" ] || return 0
  article="$(curl -fsSL --max-time 30 -A "$USER_AGENT" "$article_url")" || return 1
  og_title="$(grep -oiE 'property="og:title" content="[^"]+"' <<<"$article" | sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  og_desc="$(grep -oiE 'property="og:description" content="[^"]+"' <<<"$article" | sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  og_url="$(grep -oiE 'property="og:url" content="[^"]+"' <<<"$article" | sed -E 's/.*content="([^"]+)".*/\1/' | head -1)" || true
  url="$(grep -oiE 'https://cff2\.earth\.com/uploads/[^"]+\.(jpg|jpeg|png)' <<<"$article" | head -1)" || true
  [ -n "$og_title" ] && printf 'META_TITLE:%s\n' "$(_strip_html "$og_title")"
  [ -n "$og_desc" ] && printf 'META_DESC:%s\n' "$(_strip_html "$og_desc")"
  printf 'META_URL:%s\n' "${og_url:-$article_url}"
  [ -n "$url" ] && printf '%s\n' "$url"
  return 0
}

# --- Geometry helpers -------------------------------------------------------

# Print "WIDTH HEIGHT" of an image (JPEG/PNG/GIF) using only the Python stdlib.
image_dims() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, struct
def dims(path):
    with open(path, 'rb') as f:
        head = f.read(26)
        if len(head) >= 24 and head[:8] == b'\x89PNG\r\n\x1a\n' and head[12:16] == b'IHDR':
            return struct.unpack('>II', head[16:24])
        if head[:6] in (b'GIF87a', b'GIF89a'):
            return struct.unpack('<HH', head[6:10])
        if head[:2] == b'\xff\xd8':                      # JPEG: walk to the SOF marker
            f.seek(2)
            while True:
                b = f.read(1)
                if not b: return None
                if b != b'\xff': continue
                m = f.read(1)
                while m == b'\xff': m = f.read(1)        # skip fill bytes
                if not m: return None
                mv = m[0]
                if 0xC0 <= mv <= 0xCF and mv not in (0xC4, 0xC8, 0xCC):
                    f.read(3)                            # segment length (2) + precision (1)
                    h, w = struct.unpack('>HH', f.read(4))
                    return (w, h)
                seg = f.read(2)
                if len(seg) < 2: return None
                f.seek(struct.unpack('>H', seg)[0] - 2, 1)
    return None
d = dims(sys.argv[1])
if d: print(d[0], d[1])
PY
}

# Print the primary display's aspect ratio (e.g. 1.77778), or the default.
screen_ar() {
  local f modes mode w h
  for f in /sys/class/drm/*/status; do
    [ -r "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "connected" ] || continue
    modes="${f%status}modes"
    mode="$(head -n1 "$modes" 2>/dev/null)" # preferred mode, e.g. 3840x2160
    if [[ "$mode" =~ ^([0-9]+)x([0-9]+)$ ]]; then
      w="${BASH_REMATCH[1]}"
      h="${BASH_REMATCH[2]}"
      if [ "$h" -gt 0 ]; then
        awk "BEGIN{printf \"%.5f\", $w/$h}"
        return 0
      fi
    fi
  done
  printf '%s' "$SCREEN_ASPECT_RATIO"
}

# Choose "zoom" or "scaled" for the given image file.
pick_picture_option() {
  local file="$1" dims iw ih
  dims="$(image_dims "$file")"
  [ -n "$dims" ] || {
    echo "zoom"
    return
  } # unknown -> safe default
  iw="${dims% *}"
  ih="${dims#* }"
  awk -v iw="$iw" -v ih="$ih" -v sar="$(screen_ar)" -v thr="$ZOOM_MIN_COVERAGE" 'BEGIN{
    if (iw<=0 || ih<=0) { print "zoom"; exit }
    iar = iw/ih
    cov = (iar < sar) ? iar/sar : sar/iar               # fraction of image kept when zoom-filling
    print (cov >= thr) ? "zoom" : "scaled"
  }'
}

# --- Core -------------------------------------------------------------------

# Returns a systemd OnCalendar spec aligned to epoch-based rotation boundaries
# for standard intervals, or nothing for non-standard ones.
#   sub-hourly (divides 60):     "*-*-* *:0/<N>:00"
#   multi-hour (multiple of 60): "*-*-* 0/<N/60>:00:00"
_rotation_oncalendar() {
  local interval="$1"
  if [ "$((60 % interval))" -eq 0 ] && [ "$interval" -le 60 ]; then
    echo "*-*-* *:0/${interval}:00"
  elif [ "$((interval % 60))" -eq 0 ] && [ "$interval" -le 1440 ]; then
    echo "*-*-* 0/$((interval / 60)):00:00"
  fi
}

# Write a systemd drop-in that configures the timer based on current settings.
# Rotation mode: OnCalendar at epoch-aligned clock boundaries for standard
# intervals; OnActiveSec snapped to the next boundary for non-standard ones.
# Daily mode: OnCalendar at TIMER_TIME.
# OnStartupSec=2min (from the base unit) is preserved in all modes so the
# wallpaper is applied at login before the next scheduled boundary.
apply_timer_config() {
  local dropin_dir="$BASE_CONFIG_DIR/systemd/user/backdrop.timer.d"
  mkdir -p "$dropin_dir"
  if [ "$ROTATE_INTERVAL" -gt 0 ]; then
    local oncal
    oncal="$(_rotation_oncalendar "$ROTATE_INTERVAL")"
    if [ -n "$oncal" ]; then
      cat >"$dropin_dir/time.conf" <<EOF
[Timer]
OnCalendar=
OnActiveSec=
OnUnitActiveSec=
OnCalendar=${oncal}
EOF
    else
      local now_sec interval_sec delay_sec
      now_sec="$(date +%s)"
      interval_sec="$((ROTATE_INTERVAL * 60))"
      delay_sec="$((interval_sec - now_sec % interval_sec))"
      cat >"$dropin_dir/time.conf" <<EOF
[Timer]
OnCalendar=
OnActiveSec=
OnUnitActiveSec=
OnActiveSec=${delay_sec}s
OnUnitActiveSec=${ROTATE_INTERVAL}min
EOF
    fi
  else
    cat >"$dropin_dir/time.conf" <<EOF
[Timer]
OnActiveSec=
OnUnitActiveSec=
OnCalendar=
OnCalendar=*-*-* ${TIMER_TIME}:00
EOF
  fi
  systemctl --user daemon-reload
}

apply_timer_time() {
  local time="$1"
  TIMER_TIME="$time"
  apply_timer_config
}

# --- Desktop environment / wallpaper setters --------------------------------

# Prints "gnome", "kde", or "unknown".
detect_de() {
  local combined
  combined="$(printf '%s:%s' "${XDG_CURRENT_DESKTOP:-}" "${DESKTOP_SESSION:-}" | tr '[:lower:]' '[:upper:]')"
  case "$combined" in
    *GNOME* | *CINNAMON*) echo "gnome" ;;
    *KDE*) echo "kde" ;;
    *XFCE*) echo "xfce" ;;
    *MATE*) echo "mate" ;;
    *COSMIC*) echo "cosmic" ;;
    *LXQT*) echo "lxqt" ;;
    *) echo "unknown" ;;
  esac
}

set_wallpaper_gnome() {
  local file="$1" opt="$2"
  gsettings set org.gnome.desktop.background picture-uri "file://$file"
  gsettings set org.gnome.desktop.background picture-uri-dark "file://$file"
  gsettings set org.gnome.desktop.background picture-options "$opt"
}

# Map pick_picture_option output to KDE FillMode (Qt Image.fillMode values):
#   zoom   -> 2  PreserveAspectCrop (fill screen, crop overflow)
#   scaled -> 1  PreserveAspectFit  (fit within screen, letterbox)
kde_fillmode() { case "$1" in zoom) echo 2 ;; scaled) echo 1 ;; *) echo 2 ;; esac }

set_wallpaper_kde() {
  local file="$1" opt="$2" qdbus_cmd="" fm script
  fm="$(kde_fillmode "$opt")"
  command -v qdbus6 &>/dev/null && qdbus_cmd="qdbus6"
  { [ -z "$qdbus_cmd" ] && command -v qdbus &>/dev/null; } && qdbus_cmd="qdbus"
  if [ -n "$qdbus_cmd" ]; then
    script="var a=desktops();for(var i=0;i<a.length;i++){var d=a[i];d.wallpaperPlugin='org.kde.image';d.currentConfigGroup=['Wallpaper','org.kde.image','General'];d.writeConfig('Image','file://$file');d.writeConfig('FillMode',$fm);}"
    "$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
      org.kde.PlasmaShell.evaluateScript "$script" >/dev/null && return 0
  fi
  # Fallback: plasma-apply-wallpaperimage (Plasma 5.21+, no FillMode control).
  if command -v plasma-apply-wallpaperimage &>/dev/null; then
    plasma-apply-wallpaperimage "$file"
    return 0
  fi
  die "KDE: qdbus and plasma-apply-wallpaperimage are both unavailable"
}

# Map pick_picture_option output to XFCE image-style values:
#   zoom   -> 5  Zoomed (fill screen, crop overflow)
#   scaled -> 4  Scaled (fit within screen, letterbox)
xfce_imagestyle() { case "$1" in zoom) echo 5 ;; scaled) echo 4 ;; *) echo 5 ;; esac }

_xfce_xml_set_wallpaper() {
  local file="$1" style="$2"
  local cfg="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
  [ -f "$cfg" ] || die "XFCE: xfconf-query not found and no config at $cfg; install xfconf: sudo apt install xfconf"
  python3 - "$cfg" "$file" "$style" <<'PY' ||
import sys
from xml.etree import ElementTree as ET
cfg, img, style = sys.argv[1], sys.argv[2], sys.argv[3]
tree = ET.parse(cfg)
root = tree.getroot()
# Update existing last-image/image-style nodes if any exist.
for prop in root.iter('property'):
    if prop.get('name') == 'last-image':
        prop.set('value', img)
    elif prop.get('name') == 'image-style':
        prop.set('value', style)
# If no last-image nodes were found, add them under every workspace node.
if not any(p.get('name') == 'last-image' for p in root.iter('property')):
    backdrop = root.find("property[@name='backdrop']")
    if backdrop is None:
        sys.stderr.write("XFCE: no backdrop property in config; open Desktop settings once to initialise it\n")
        sys.exit(1)
    added = False
    for screen in backdrop:
        for monitor in screen:
            for workspace in monitor:
                ET.SubElement(workspace, 'property', name='last-image', type='string', value=img)
                ET.SubElement(workspace, 'property', name='image-style', type='int', value=style)
                added = True
    if not added:
        sys.stderr.write("XFCE: no workspace entries in config; open Desktop settings once to initialise it\n")
        sys.exit(1)
tree.write(cfg, xml_declaration=True, encoding='UTF-8')
PY
    die "XFCE: failed to update wallpaper config; install xfconf: sudo apt install xfconf"
  xfdesktop --reload 2>/dev/null || true
}

set_wallpaper_xfce() {
  local file="$1" opt="$2" style props prop all_props
  style="$(xfce_imagestyle "$opt")"
  if ! command -v xfconf-query >/dev/null 2>&1; then
    _xfce_xml_set_wallpaper "$file" "$style"
    return
  fi
  all_props="$(xfconf-query -c xfce4-desktop -l 2>/dev/null)" ||
    die "XFCE: xfconf-query failed"
  props="$(grep '/last-image$' <<<"$all_props" || true)"
  [ -z "$props" ] && die "XFCE: no backdrop properties found; launch the Desktop app once to initialise the wallpaper properties"
  while IFS= read -r prop; do
    xfconf-query -c xfce4-desktop -p "$prop" --create -t string -s "$file"
    xfconf-query -c xfce4-desktop -p "${prop%last-image}image-style" --create -t int -s "$style"
  done <<<"$props"
}

set_wallpaper_mate() {
  local file="$1" opt="$2"
  gsettings set org.mate.background picture-filename "$file"
  gsettings set org.mate.background picture-options "$opt"
}

# Map pick_picture_option output to pcmanfm-qt --wallpaper-mode values:
#   zoom   -> zoom  (fill screen, crop overflow)
#   scaled -> fit   (fit within screen, letterbox)
lxqt_wallpapermode() { case "$1" in zoom) echo "zoom" ;; scaled) echo "fit" ;; *) echo "zoom" ;; esac }

set_wallpaper_lxqt() {
  local file="$1" opt="$2"
  command -v pcmanfm-qt &>/dev/null || die "LXQt: pcmanfm-qt is not installed"
  pcmanfm-qt --set-wallpaper "$file" --wallpaper-mode "$(lxqt_wallpapermode "$opt")"
}

# Map pick_picture_option output to COSMIC ScalingMode (RON enum variant):
#   zoom   -> Zoom                 (fill screen, crop overflow)
#   scaled -> Fit([0.0, 0.0, 0.0]) (fit within screen, black letterbox)
cosmic_scalingmode() { case "$1" in zoom) echo "Zoom" ;; scaled) echo "Fit([0.0, 0.0, 0.0])" ;; *) echo "Zoom" ;; esac }

set_wallpaper_cosmic() {
  local file="$1" opt="$2" cfg_dir mode tmp
  cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicBackground/v1"
  mode="$(cosmic_scalingmode "$opt")"
  mkdir -p "$cfg_dir"
  tmp="$(mktemp "$cfg_dir/all.XXXXXX")"
  printf '(\n    output: "all",\n    source: Path("%s"),\n    filter_by_theme: false,\n    rotation_frequency: 900,\n    filter_method: Lanczos,\n    scaling_mode: %s,\n    sampling_method: Alphanumeric,\n)\n' \
    "$file" "$mode" >"$tmp"
  mv "$tmp" "$cfg_dir/all"
  printf 'true\n' >"$cfg_dir/same-on-all"
}

set_wallpaper() {
  local file="$1" opt="$2"
  case "$(detect_de)" in
    gnome) set_wallpaper_gnome "$file" "$opt" ;;
    kde) set_wallpaper_kde "$file" "$opt" ;;
    xfce) set_wallpaper_xfce "$file" "$opt" ;;
    mate) set_wallpaper_mate "$file" "$opt" ;;
    cosmic) set_wallpaper_cosmic "$file" "$opt" ;;
    lxqt) set_wallpaper_lxqt "$file" "$opt" ;;
    *)
      if command -v gsettings &>/dev/null; then
        set_wallpaper_gnome "$file" "$opt"
      elif command -v qdbus6 &>/dev/null || command -v qdbus &>/dev/null ||
        command -v plasma-apply-wallpaperimage &>/dev/null; then
        set_wallpaper_kde "$file" "$opt"
      else
        die "unsupported desktop environment; set XDG_CURRENT_DESKTOP"
      fi
      ;;
  esac
}

# Returns all configured source names (space-separated); expands "all" to every valid source.
get_sources() {
  local s
  s="$(cfg_get source)"
  if [ -n "$s" ]; then
    [ "$s" = "all" ] && {
      printf '%s' "${VALID_SOURCES[*]}"
      return
    }
    printf '%s' "$s"
    return
  fi
  printf '%s' "$SOURCE"
}

# Returns the first configured source name (single-source accessor).
# Returns the 0-based index into a source list for a given unix timestamp (seconds).
_rotation_index() {
  local now_sec="$1" interval="$2" count="$3"
  echo $(((now_sec / 60 / interval) % count))
}

# Returns the source to use right now, applying time-based rotation if configured.
get_active_source() {
  local -a srcs
  IFS=' ' read -ra srcs <<<"$(get_sources)"
  local n="${#srcs[@]}"
  if [ "$n" -le 1 ] || [ "$ROTATE_INTERVAL" -le 0 ]; then
    printf '%s' "${srcs[0]:-$SOURCE}"
    return
  fi
  local idx
  idx="$(_rotation_index "$(date +%s)" "$ROTATE_INTERVAL" "$n")"
  printf '%s' "${srcs[$idx]}"
}

is_valid() {
  local s="$1" v
  for v in "${VALID_SOURCES[@]}"; do [ "$s" = "$v" ] && return 0; done
  return 1
}

# Strip HTML tags and decode common entities from $1.
_strip_html() {
  local s="$1"
  s="$(printf '%s' "$s" | sed 's/<[^>]*>//g')"
  s="$(python3 -c 'import html,sys; print(html.unescape(sys.stdin.read()), end="")' <<<"$s")"
  printf '%s' "$s" | tr -s ' \t\n' ' ' | sed 's/^ //;s/ $//'
}

# Returns 0 (true) if version $1 is strictly newer than $2 (MAJOR.MINOR.PATCH).
_version_gt() {
  local i av bv
  local -a a b
  IFS='.' read -ra a <<<"$1"
  IFS='.' read -ra b <<<"$2"
  for ((i = 0; i < 3; i++)); do
    av="${a[$i]:-0}"
    bv="${b[$i]:-0}"
    if ((av > bv)); then return 0; fi
    if ((av < bv)); then return 1; fi
  done
  return 1
}

# Write title/desc/url metadata alongside a downloaded image (as a .meta file).
_write_meta() {
  local dest="$1" meta t d
  meta="${dest%.jpg}.meta"
  t="$(printf '%s' "$META_TITLE" | tr -s '\n\t' '  ' | sed 's/  */ /g;s/^ //;s/ $//')"
  d="$(printf '%s' "$META_DESC" | tr -s '\n\t' '  ' | sed 's/  */ /g;s/^ //;s/ $//' | cut -c1-200)"
  {
    [ -n "$t" ] && printf 'title = %s\n' "$t"
    [ -n "$d" ] && printf 'desc = %s\n' "$d"
    [ -n "$META_URL" ] && printf 'url = %s\n' "$META_URL"
  } >"$meta"
}

# Read one key from a .meta file (same key = value format as cfg_get).
_meta_get() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 0
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$file" | tail -n1
}

apply_wallpaper() {
  local src="$1" full_output candidates dest url ok=0 opt
  is_valid "$src" || die "unknown source '$src' (valid: ${VALID_SOURCES[*]})"
  META_TITLE=""
  META_DESC=""
  META_URL=""

  dest="$STATE_DIR/$src-$(date +%F).jpg"
  if [ -f "$dest" ] && [ "$FORCE" = false ]; then
    opt="$(pick_picture_option "$dest")"
    set_wallpaper "$dest" "$opt"
    printf '%s\n' "$dest" >"$STATE_DIR/current"
    echo "backdrop: set from $src [$(image_dims "$dest" | tr ' ' 'x'), $opt] -> $dest (cached)"
    return 0
  fi

  if ! full_output="$(resolve_"$src")"; then
    die "failed to reach $src source"
  fi
  candidates="$(grep -v '^META_' <<<"$full_output" || true)"
  META_TITLE="$(grep '^META_TITLE:' <<<"$full_output" | sed 's/^META_TITLE://' | tail -1 || true)"
  META_DESC="$(grep '^META_DESC:' <<<"$full_output" | sed 's/^META_DESC://' | tail -1 || true)"
  META_URL="$(grep '^META_URL:' <<<"$full_output" | sed 's/^META_URL://' | tail -1 || true)"
  if [ -z "$candidates" ]; then
    echo "backdrop: $src has no image today (e.g. APOD video day); wallpaper unchanged."
    return 0
  fi

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    if curl -fsSL --max-time 120 -A "$USER_AGENT" "$url" -o "$dest"; then
      ok=1
      break
    fi
  done <<<"$candidates"
  [ "$ok" -eq 1 ] || die "could not download any image for $src"

  opt="$(pick_picture_option "$dest")"
  set_wallpaper "$dest" "$opt"
  printf '%s\n' "$dest" >"$STATE_DIR/current"
  _write_meta "$dest"

  find "$STATE_DIR" -maxdepth 1 -name '*.jpg' -type f -mtime +14 -delete
  find "$STATE_DIR" -maxdepth 1 -name '*.meta' -type f -mtime +14 -delete
  echo "backdrop: set from $src [$(image_dims "$dest" | tr ' ' 'x'), $opt] -> $dest"
}

cmd_upgrade() {
  local api_response latest_tag latest_version raw_url tmp
  echo "backdrop: checking for updates (current: v${VERSION})..."
  api_response="$(curl -fsSL --max-time 15 -A "$USER_AGENT" \
    "https://api.github.com/repos/aensley/backdrop/releases/latest")" ||
    die "upgrade: could not reach GitHub API"
  latest_tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' \
    <<<"$api_response" 2>/dev/null)" ||
    die "upgrade: could not parse release info"
  latest_version="${latest_tag#v}"
  if ! _version_gt "$latest_version" "$VERSION"; then
    echo "backdrop: already up to date (v${VERSION})."
    return 0
  fi
  echo "backdrop: upgrading v${VERSION} -> v${latest_version}..."
  raw_url="https://raw.githubusercontent.com/aensley/backdrop/${latest_tag}/src/backdrop.sh"
  tmp="$(mktemp)"
  curl -fsSL --max-time 60 -A "$USER_AGENT" "$raw_url" -o "$tmp" ||
    {
      rm -f "$tmp"
      die "upgrade: failed to download v${latest_version}"
    }
  sudo install -m 755 "$tmp" /usr/local/bin/backdrop
  rm -f "$tmp"
  echo "backdrop: upgraded to v${latest_version}."
}

cmd_update() {
  [ "${1:-}" = "--force" ] && FORCE=true
  apply_wallpaper "$(get_active_source)"
}

cmd_random() {
  [ "${1:-}" = "--force" ] && FORCE=true
  apply_wallpaper "${VALID_SOURCES[$((RANDOM % ${#VALID_SOURCES[@]}))]}"
}

cmd_enable() {
  local systemd_user_dir="$BASE_CONFIG_DIR/systemd/user"
  mkdir -p "$systemd_user_dir"

  # Install unit files if missing (e.g. second user who only has the binary).
  local unit
  for unit in backdrop.service backdrop.timer; do
    if [ ! -f "$systemd_user_dir/$unit" ]; then
      echo "backdrop: $unit not found; downloading from GitHub release v${VERSION}..."
      curl -fsSL --max-time 30 -A "$USER_AGENT" \
        "https://raw.githubusercontent.com/aensley/backdrop/v${VERSION}/src/$unit" \
        -o "$systemd_user_dir/$unit" ||
        die "enable: failed to download $unit (v${VERSION}) from GitHub"
    fi
  done

  apply_timer_config
  systemctl --user enable --now backdrop.timer
  if [ "$ROTATE_INTERVAL" -gt 0 ]; then
    echo "backdrop: timer enabled (rotating every ${ROTATE_INTERVAL} min)."
  else
    echo "backdrop: daily timer enabled (runs at $TIMER_TIME)."
  fi
  cmd_update
}

cmd_disable() {
  systemctl --user disable --now backdrop.timer
  echo "backdrop: daily timer disabled."
}

cmd_set_time() {
  local t="${1:-}"
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "set-time: expected HH:MM (24-hour), e.g. 08:00"
  cfg_set timer_time "$t"
  apply_timer_time "$t"
  if [ "$ROTATE_INTERVAL" -gt 0 ]; then
    echo "backdrop: timer time saved to $t (rotation is active; daily time takes effect when rotation is disabled)."
  elif systemctl --user is-active --quiet backdrop.timer 2>/dev/null; then
    systemctl --user restart backdrop.timer
    echo "backdrop: timer time set to $t and timer restarted."
  else
    echo "backdrop: timer time set to $t (run 'backdrop enable' to start the timer)."
  fi
}

cmd_set_rotate_interval() {
  local t="${1:-}"
  [[ "$t" =~ ^[0-9]+$ ]] || die "set-rotate-interval: expected number of minutes (0 to disable), e.g. 60"
  cfg_set rotate_interval "$t"
  ROTATE_INTERVAL="$t"
  apply_timer_config
  if systemctl --user is-active --quiet backdrop.timer 2>/dev/null; then
    systemctl --user restart backdrop.timer
    if [ "$t" -gt 0 ]; then
      echo "backdrop: rotate interval set to ${t} min and timer restarted."
    else
      echo "backdrop: rotation disabled, timer reset to daily at ${TIMER_TIME}."
    fi
  else
    if [ "$t" -gt 0 ]; then
      echo "backdrop: rotate interval set to ${t} min (run 'backdrop enable' to start the timer)."
    else
      echo "backdrop: rotation disabled (run 'backdrop enable' to start the daily timer)."
    fi
  fi
}

cmd_uninstall() {
  local purge=false
  [ "${1:-}" = "--purge" ] && purge=true
  systemctl --user disable --now backdrop.timer 2>/dev/null || true
  systemctl --user daemon-reload
  local systemd_user_dir="$BASE_CONFIG_DIR/systemd/user"
  rm -f "$systemd_user_dir/backdrop.timer" "$systemd_user_dir/backdrop.service"
  rm -rf "$systemd_user_dir/backdrop.timer.d"
  sudo rm -f /usr/local/bin/backdrop
  if $purge; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    echo "backdrop: uninstalled. Config and cached wallpapers removed."
  else
    echo "backdrop: uninstalled."
    echo "Note: config and cached wallpapers were not removed. Run 'backdrop uninstall --purge' to delete them."
  fi
}

cmd_set() {
  local srcs=() arg s timer_changed=false
  for arg in "$@"; do
    [ "$arg" = "--force" ] && {
      FORCE=true
      continue
    }
    srcs+=("$arg")
  done
  [ "${#srcs[@]}" -eq 0 ] && die "set: choose one or more sources (${VALID_SOURCES[*]}) or 'all'"
  if [ "${#srcs[@]}" -eq 1 ] && [ "${srcs[0]}" = "all" ]; then
    srcs=("${VALID_SOURCES[@]}")
  fi
  for s in "${srcs[@]}"; do
    is_valid "$s" || die "set: unknown source '$s' (valid: ${VALID_SOURCES[*]})"
  done
  cfg_set source "${srcs[*]}"
  if [ "${#srcs[@]}" -gt 1 ]; then
    if [ "$ROTATE_INTERVAL" -le 0 ]; then
      ROTATE_INTERVAL=30
      cfg_set rotate_interval 30
      timer_changed=true
    fi
    echo "backdrop: active sources: ${srcs[*]} (rotating every ${ROTATE_INTERVAL} min)"
  else
    if [ "$ROTATE_INTERVAL" -gt 0 ]; then
      ROTATE_INTERVAL=0
      cfg_set rotate_interval 0
      timer_changed=true
    fi
    echo "backdrop: active source is now '${srcs[0]}'"
  fi
  if $timer_changed; then
    apply_timer_config
    if systemctl --user is-active --quiet backdrop.timer 2>/dev/null; then
      systemctl --user restart backdrop.timer
    fi
  fi
  apply_wallpaper "$(get_active_source)"
}

cmd_status() {
  echo -e "backdrop v${VERSION}"
  echo
  local active_srcs active_src labeled s de method
  active_srcs="$(get_sources)"
  active_src="$(get_active_source)"

  local latest meta_val displayed_src
  latest=""
  if [ -f "$STATE_DIR/current" ]; then
    latest="$(<"$STATE_DIR/current")"
    [ -f "$latest" ] || latest=""
  fi
  if [ -z "$latest" ]; then
    latest="$(find "$STATE_DIR" -maxdepth 1 -name "${active_src}-*.jpg" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
  fi
  displayed_src="$active_src"
  if [ -n "$latest" ]; then
    local bn="${latest##*/}"
    local candidate="${bn%-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jpg}"
    is_valid "$candidate" && displayed_src="$candidate"
  fi

  if [[ "$active_srcs" == *" "* ]]; then
    labeled=""
    for s in $active_srcs; do
      [ "$s" = "$displayed_src" ] && labeled+="[$s] " || labeled+="$s "
    done
    echo "Active sources: ${labeled% }"
  else
    echo "Active source:  $active_src"
  fi
  if systemctl --user is-enabled --quiet backdrop.timer 2>/dev/null; then
    if [ "$ROTATE_INTERVAL" -gt 0 ]; then
      echo "Timer:          enabled (rotating every ${ROTATE_INTERVAL} min)"
    else
      echo "Timer:          enabled (runs at $TIMER_TIME)"
    fi
  else
    echo "Timer:          disabled"
  fi
  echo
  [ -n "$latest" ] && echo "Current image:  $latest"
  if [ -n "$latest" ]; then
    meta_val="$(_meta_get "${latest%.jpg}.meta" title)"
    if [ -n "$meta_val" ]; then
      [ "${#meta_val}" -gt 77 ] && meta_val="${meta_val:0:77}..."
      echo "Title:          $meta_val"
    fi
    meta_val="$(_meta_get "${latest%.jpg}.meta" desc)"
    if [ -n "$meta_val" ]; then
      [ "${#meta_val}" -gt 77 ] && meta_val="${meta_val:0:77}..."
      echo "Description:    $meta_val"
    fi
    meta_val="$(_meta_get "${latest%.jpg}.meta" url)"
    [ -n "$meta_val" ] && echo "URL:            $meta_val"
  fi
  de="$(detect_de)"
  method=""
  if [ "$de" = "kde" ]; then
    local qdbus_cmd fm
    qdbus_cmd=""
    command -v qdbus6 &>/dev/null && qdbus_cmd="qdbus6"
    { [ -z "$qdbus_cmd" ] && command -v qdbus &>/dev/null; } && qdbus_cmd="qdbus"
    if [ -n "$qdbus_cmd" ]; then
      fm="$("$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript \
        "var d=desktops()[0];d.currentConfigGroup=['Wallpaper','org.kde.image','General'];print(d.readConfig('FillMode'));" \
        2>/dev/null | tr -d '[:space:]')"
      case "$fm" in 2) method="zoom" ;; 1) method="scaled" ;; *) method="${fm:+fillmode=$fm}" ;; esac
    fi
  elif [ "$de" = "xfce" ]; then
    local prop style
    prop="$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$' | head -1)"
    if [ -n "$prop" ]; then
      style="$(xfconf-query -c xfce4-desktop -p "${prop%last-image}image-style" 2>/dev/null)"
      case "$style" in 5) method="zoom" ;; 4) method="scaled" ;; *) method="${style:+image-style=$style}" ;; esac
    fi
  elif [ "$de" = "mate" ]; then
    method="$(gsettings get org.mate.background picture-options 2>/dev/null | tr -d "'")"
  elif [ "$de" = "lxqt" ]; then
    local lxqt_cfg mode
    lxqt_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pcmanfm-qt/lxqt/settings.conf"
    mode="$(sed -n 's/^WallpaperMode=//p' "$lxqt_cfg" 2>/dev/null)"
    case "$mode" in zoom) method="zoom" ;; fit) method="scaled" ;; *) method="${mode:+wallpaper-mode=$mode}" ;; esac
  elif [ "$de" = "cosmic" ]; then
    local cfg_dir
    cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicBackground/v1"
    if [ -f "$cfg_dir/all" ]; then
      if grep -q 'scaling_mode:[[:space:]]*Zoom' "$cfg_dir/all" 2>/dev/null; then
        method="zoom"
      elif grep -q 'scaling_mode:[[:space:]]*Fit' "$cfg_dir/all" 2>/dev/null; then
        method="scaled"
      fi
    fi
  else
    method="$(gsettings get org.gnome.desktop.background picture-options 2>/dev/null | tr -d "'")"
  fi
  echo
  echo "Display method: $de, ${method:-unknown}"
  echo "Aspect ratio:   $(screen_ar), $ZOOM_MIN_COVERAGE min coverage"
  echo "Config file:    $CONFIG_FILE"
  echo
  echo "Use 'backdrop help' for usage information."
  echo
}

cmd_help() {
  cat <<EOF
backdrop v${VERSION}

Usage: backdrop <command>

Commands:
  status                          Show the active source and last image (default command)
  update [--force]                Refresh wallpaper from the active source
  set <source...> [--force]       Switch active source(s) and refresh now; use 'all' for all sources
  set-time <HH:MM>                Set the daily run time (24-hour); restarts timer if active
  set-rotate-interval <minutes>   Set rotation interval in minutes; 0 to disable rotation
  random [--force]                Refresh from a randomly chosen source (does not change active source)
  enable                          Enable the systemd --user timer (backdrop.timer)
  disable                         Disable the systemd --user timer
  upgrade                         Check for and install the latest version from GitHub
  uninstall [--purge]             Remove backdrop and (with --purge) delete config and cached wallpapers
  help                            Show this help

Sources:
  bing    Bing image of the day
  earth   Earth.com Image of the Day
  apod    NASA Astronomy Picture of the Day
  eo      NASA Earth Observatory Image of the Day
  iotd    NASA Image of the Day (default)
  natgeo  National Geographic Photo of the Day
  wmc     Wikimedia Commons Picture of the Day
EOF
}

# --- Dispatch ---------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  FORCE=false
  cmd="${1:-status}"
  [ "$cmd" != "uninstall" ] && load_config
  case "$cmd" in
    update | refresh)
      cmd_update "${2:-}"
      ;;
    set | use)
      cmd_set "${@:2}"
      ;;
    status)
      cmd_status
      ;;
    random)
      cmd_random "${2:-}"
      ;;
    enable)
      cmd_enable
      ;;
    disable)
      cmd_disable
      ;;
    set-time)
      cmd_set_time "${2:-}"
      ;;
    set-rotate-interval)
      cmd_set_rotate_interval "${2:-}"
      ;;
    upgrade)
      cmd_upgrade
      ;;
    uninstall)
      cmd_uninstall "${2:-}"
      ;;
    -h | --help | help)
      cmd_help
      ;;
    *)
      die "unknown command '$cmd' (try: backdrop help)"
      ;;
  esac
fi
