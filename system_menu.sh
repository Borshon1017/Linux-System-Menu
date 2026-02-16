#!/usr/bin/env bash
# interactive menu to control wifi, bluetooth, volume, etc from the terminal
set -u

APP_NAME="system_menu"
LOG_DIR="${HOME}/.${APP_NAME}/logs"
OUT_LOG="${LOG_DIR}/output.log"
ERR_LOG="${LOG_DIR}/error.log"

mkdir -p "$LOG_DIR"

# save everything to log files but still show it in the terminal
exec > >(tee -a "$OUT_LOG")
exec 2> >(tee -a "$ERR_LOG" >&2)

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log()  { echo "[$(timestamp)] [INFO]  $*"; }
warn() { echo "[$(timestamp)] [WARN]  $*" >&2; }
err()  { echo "[$(timestamp)] [ERROR] $*" >&2; }

# when we exit, say bye
cleanup() {
  echo
  log "Exiting."
}
trap cleanup EXIT

pause() {
  echo
  read -r -p "Press Enter to continue... " _
}

# check if a command exists
have() { command -v "$1" >/dev/null 2>&1; }

# make sure we have the commands we need or tell user to install
require_cmds() {
  local missing=()
  for c in "$@"; do
    have "$c" || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    err "Missing commands: ${missing[*]}"
    echo "Install suggestions (Debian/Ubuntu):"
    echo "  sudo apt install -y ${missing[*]}"
    exit 1
  fi
}

# choose a line from stdin using fzf if available, otherwise fall back to
# a simple numbered prompt. Prints the selected line to stdout.
choose_line() {
  local prompt="${1:-Select> }"
  if have fzf; then
    fzf --prompt="$prompt" --height=15 --border
    return
  fi

  local lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done

  if ((${#lines[@]} == 0)); then
    return
  fi

  local i
  for i in "${!lines[@]}"; do
    printf '%3d) %s\n' $((i+1)) "${lines[i]}"
  done

  local sel
  read -r -p "$prompt (number): " sel
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#lines[@]} )); then
    printf '%s' "${lines[$((sel-1))]}"
  else
    return
  fi
}

# remove ANSI escape sequences from stdin (useful for bluetoothctl output)
sanitize() {
  sed -r $'s/\x1B\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'
}

# Brightness helpers (sysfs fallback when brightnessctl is unavailable)
detect_backlight() {
  BL_DIR=""
  for d in /sys/class/backlight/*; do
    [[ -d "$d" ]] || continue
    BL_DIR="$d"
    break
  done
  if [[ -z "$BL_DIR" ]]; then
    return 1
  fi
  BRIGHTNESS_FILE="$BL_DIR/brightness"
  MAX_FILE="$BL_DIR/max_brightness"
  return 0
}

brightness_get() {
  if have brightnessctl; then
    brightnessctl -m || true
    return
  fi
  if ! detect_backlight; then
    warn "No backlight interface found."
    return 1
  fi
  local cur max pct
  cur=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || echo 0)
  max=$(cat "$MAX_FILE" 2>/dev/null || echo 1)
  if [[ "$max" -eq 0 ]]; then max=1; fi
  pct=$(( (cur * 100) / max ))
  echo "Current: ${pct}% ($cur/$max)"
}

brightness_set() {
  local val="$1"
  if have brightnessctl; then
    brightnessctl set "$val" >/dev/null 2>&1 && return 0 || return 1
  fi
  if ! detect_backlight; then
    return 1
  fi
  val=${val//%/}
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local max target
  max=$(cat "$MAX_FILE" 2>/dev/null || echo 1)
  if [[ "$max" -eq 0 ]]; then max=1; fi
  target=$(( (val * max) / 100 ))
  if [[ -w "$BRIGHTNESS_FILE" ]]; then
    printf '%s' "$target" >"$BRIGHTNESS_FILE" 2>/dev/null && return 0 || return 1
  else
    printf '%s' "$target" | sudo tee "$BRIGHTNESS_FILE" >/dev/null 2>&1 && return 0 || return 1
  fi
}

brightness_change() {
  local delta="$1"
  if have brightnessctl; then
    brightnessctl set "$delta" >/dev/null 2>&1 && return 0 || return 1
  fi
  if ! detect_backlight; then
    return 1
  fi
  local cur max pct
  cur=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || echo 0)
  max=$(cat "$MAX_FILE" 2>/dev/null || echo 1)
  if [[ "$max" -eq 0 ]]; then max=1; fi
  pct=$(( (cur * 100) / max ))
  if [[ "$delta" == +* ]]; then
    pct=$((pct + ${delta#+}))
  else
    pct=$((pct - ${delta#-}))
  fi
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi
  brightness_set "${pct}%"
}

# detect audio backend/tool and preferred mixer control
detect_audio() {
  AU_BACKEND=""
  AU_CONTROL="Master"
  if have amixer; then
    AU_BACKEND=amixer
    # try to find a sensible control name (parse amixer scontrols output)
    local ctrl
    while IFS= read -r line; do
      ctrl=$(printf '%s' "$line" | awk -F"'" '{print $2}')
      if [[ -n "$ctrl" ]] && [[ "$ctrl" =~ Master|PCM|Speaker|Headphone|IEC958 ]]; then
        AU_CONTROL="$ctrl"
        break
      fi
    done < <(amixer scontrols 2>/dev/null || true)
  elif have pamixer; then
    AU_BACKEND=pamixer
  elif have pactl; then
    AU_BACKEND=pactl
  fi
}

# audio wrapper functions (use detected backend)
audio_get_volume() {
  detect_audio
  case "$AU_BACKEND" in
    amixer)
      amixer get "${AU_CONTROL}" 2>/dev/null | awk -F"[][]" '/%/ {print $2; exit}' || true
      ;;
    pamixer)
      pamixer --get-volume || true
      ;;
    pactl)
      pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk '/\//{print $5; exit}' || true
      ;;
    *)
      warn "No audio backend found."
      ;;
  esac
}
audio_set_volume() {
  local vol="$1"
  detect_audio
  case "$AU_BACKEND" in
    amixer)
      amixer set "${AU_CONTROL}" "${vol}%" >/dev/null 2>&1 && return 0 || return 1
      ;;
    pamixer)
      pamixer --set-volume "$vol" >/dev/null 2>&1 && return 0 || return 1
      ;;
    pactl)
      pactl set-sink-volume @DEFAULT_SINK@ "${vol}%" >/dev/null 2>&1 && return 0 || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

audio_change() {
  local delta="$1"
  detect_audio
  local sign amount
  if [[ "$delta" == +* ]]; then
    sign="+"
    amount="${delta#+}"
  else
    sign="-"
    amount="${delta#-}"
  fi
  case "$AU_BACKEND" in
    amixer)
      if [[ "$sign" == "+" ]]; then
        amixer set "${AU_CONTROL}" "${amount}%+" >/dev/null 2>&1 && return 0 || return 1
      else
        amixer set "${AU_CONTROL}" "${amount}%-" >/dev/null 2>&1 && return 0 || return 1
      fi
      ;;
    pamixer)
      if [[ "$sign" == "+" ]]; then
        pamixer --increase "${amount}" >/dev/null 2>&1 && return 0 || return 1
      else
        pamixer --decrease "${amount}" >/dev/null 2>&1 && return 0 || return 1
      fi
      ;;
    pactl)
      if [[ "$sign" == "+" ]]; then
        pactl set-sink-volume @DEFAULT_SINK@ +"${amount}%" >/dev/null 2>&1 && return 0 || return 1
      else
        pactl set-sink-volume @DEFAULT_SINK@ -"${amount}%" >/dev/null 2>&1 && return 0 || return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}
audio_toggle_mute() {
  detect_audio
  case "$AU_BACKEND" in
    amixer)
      amixer set "${AU_CONTROL}" toggle >/dev/null 2>&1 && return 0 || return 1
      ;;
    pamixer)
      pamixer --toggle-mute >/dev/null 2>&1 && return 0 || return 1
      ;;
    pactl)
      pactl set-sink-mute @DEFAULT_SINK@ toggle >/dev/null 2>&1 && return 0 || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# these are required or the script won't run (we check at start)
require_cmds awk sed grep df free uname who

# draw a horizontal line
hr() { printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '-'; }

# clear screen and show title
title() {
  clear
  echo "$APP_NAME"
  hr
}

# show basic system info on main menu
sys_status() {
  local host kernel up load ip
  host="$(hostname)"
  kernel="$(uname -r)"
  up="$(uptime -p 2>/dev/null || true)"
  load="$(uptime 2>/dev/null | awk -F'load average: ' '{print $2}' || true)"
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"

  echo "Host:   $host"
  echo "Kernel: $kernel"
  echo "Uptime: ${up:-N/A}"
  echo "Load:   ${load:-N/A}"
  echo "IP:     ${ip:-N/A}"
}

disk_usage() {
  title
  echo "Disk usage (df -h):"
  hr
  df -h
  pause
}

memory_usage() {
  title
  echo "Memory usage (free -h):"
  hr
  free -h || true
  echo
  echo "Top memory consumers:"
  hr
  ps -eo pid,comm,%mem --sort=-%mem | head -n 10 || true
  pause
}

users_logged() {
  title
  echo "Logged on users (who):"
  hr
  who || true
  pause
}

# -------- WiFi --------
wifi_menu() {
  if ! have nmcli; then
    warn "nmcli not installed. WiFi menu unavailable."
    pause
    return
  fi
  while true; do
    title
    echo "WiFi menu"
    hr
    echo "1) List networks"
    echo "2) Connect (interactive)"
    echo "3) Disconnect"
    echo "4) Show current connection"
    echo "0) Back"
    echo
    read -r -p "Select option: " opt

    case "${opt}" in
      1) wifi_list ;;
      2) wifi_connect_interactive ;;
      3) wifi_disconnect ;;
      4) wifi_status ;;
      0) break ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

wifi_list() {
  title
  echo "Scanning WiFi..."
  hr
  nmcli -f IN-USE,SSID,SECURITY,SIGNAL,BARS device wifi list || true
  pause
}

wifi_status() {
  title
  echo "Current connection:"
  hr
  nmcli -t -f NAME,TYPE,DEVICE connection show --active || true
  echo
  nmcli -f GENERAL.STATE,GENERAL.CONNECTION device show 2>/dev/null | sed -n '1,10p' || true
  pause
}

wifi_disconnect() {
  title
  local dev
  dev="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
  if [[ -z "${dev}" ]]; then
    warn "No WiFi device found."
    pause
    return
  fi
  nmcli device disconnect "$dev" && log "Disconnected $dev" || err "Failed to disconnect."
  pause
}

wifi_connect_interactive() {
  title
  echo "Select a network."
  hr
  local selection ssid secure
  selection="$(nmcli -f SSID,SECURITY,SIGNAL device wifi list | sed 1d | awk 'NF {print}' | choose_line "WiFi SSID> ")" || true

  if [[ -z "${selection}" ]]; then
    warn "No selection."
    pause
    return
  fi

  ssid="$(echo "$selection" | awk '{print $1}')"
  secure="$(echo "$selection" | awk '{print $2}')"

  # no password needed for open networks
  if [[ "$secure" == "--" ]]; then
    nmcli device wifi connect "$ssid" && log "Connected to $ssid" || err "Connect failed."
    pause
    return
  fi

  read -r -s -p "Enter password for ${ssid}: " pass
  echo
  nmcli device wifi connect "$ssid" password "$pass" && log "Connected to $ssid" || err "Connect failed."
  pause
}

# -------- Bluetooth --------
bluetooth_menu() {
  if ! have bluetoothctl; then
    warn "bluetoothctl not installed. Bluetooth menu unavailable."
    pause
    return
  fi
  while true; do
    title
    echo "Bluetooth menu"
    hr
    echo "1) Toggle power"
    echo "2) Show status"
    echo "3) Scan and connect (interactive)"
    echo "4) Disconnect device (interactive)"
    echo "0) Back"
    echo
    read -r -p "Select option: " opt

    case "${opt}" in
      1) bt_toggle ;;
      2) bt_status ;;
      3) bt_scan_connect ;;
      4) bt_disconnect ;;
      0) break ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

# get whether bluetooth is on or off
bt_power_state() {
  bluetoothctl show 2>/dev/null | awk -F': ' '/Powered/{print $2; exit}' || true
}

# return 0 if a bluetooth controller is present, non-zero otherwise
bt_has_controller() {
  local out
  out="$(timeout 2s bluetoothctl show 2>&1 | sanitize || true)"
  if [[ -z "$out" ]] || echo "$out" | grep -qi "no default controller\|no controllers"; then
    return 1
  fi
  return 0
}

bt_toggle() {
  title
  local state
  state="$(bt_power_state)"
  if [[ "$state" == "yes" ]]; then
    bluetoothctl power off && log "Bluetooth OFF" || err "Failed."
  else
    bluetoothctl power on && log "Bluetooth ON" || err "Failed."
  fi
  pause
}

bt_status() {
  title
  echo "Bluetooth status:"
  hr
  stty sane 2>/dev/null || true
  local out
  out="$(timeout 3s bluetoothctl show 2>&1 | sanitize || true)"
  if [[ -z "$out" ]] || echo "$out" | grep -qi "no default controller\|no controllers"; then
    warn "No Bluetooth controller available."
    pause
    return
  fi
  printf '%s\n' "$out"
  echo
  echo "Paired devices:"
  hr
  local pd
  pd="$(timeout 3s bluetoothctl paired-devices 2>&1 | sanitize || true)"
  if echo "$pd" | grep -qi "invalid command\|no default controller\|no controllers"; then
    pd="$(printf 'paired-devices\n' | timeout 3s bluetoothctl 2>&1 | sanitize || true)"
  fi
  printf '%s\n' "$pd"
  pause
}

bt_scan_connect() {
  title
  bluetoothctl power on >/dev/null 2>&1 || true
  bluetoothctl agent on >/dev/null 2>&1 || true
  bluetoothctl default-agent >/dev/null 2>&1 || true

  # scan for a few seconds so devices show up
  log "Starting scan (8 seconds)..."
  bluetoothctl scan on >/dev/null 2>&1 || true
  sleep 8
  bluetoothctl scan off >/dev/null 2>&1 || true

  local dev
  dev="$(bluetoothctl devices | choose_line "BT device> ")" || true
  if [[ -z "$dev" ]]; then
    warn "No selection."
    pause
    return
  fi

  local mac
  mac="$(echo "$dev" | awk '{print $2}')"
  log "Pairing $mac..."
  bluetoothctl pair "$mac" || warn "Pair may have failed (might already be paired)."
  log "Connecting $mac..."
  bluetoothctl connect "$mac" && log "Connected." || err "Connect failed."
  pause
}

bt_disconnect() {
  title
  local dev
  dev="$(bluetoothctl paired-devices | choose_line "Disconnect> ")" || true
  if [[ -z "$dev" ]]; then
    warn "No selection."
    pause
    return
  fi

  local mac
  mac="$(echo "$dev" | awk '{print $2}')"
  bluetoothctl disconnect "$mac" && log "Disconnected." || err "Disconnect failed."
  pause
}

# -------- Audio / volume --------
audio_menu() {
  if ! have amixer; then
    warn "amixer not installed. Audio menu unavailable."
    pause
    return
  fi
  while true; do
    title
    echo "Audio menu"
    hr
    echo "1) Show volume"
    echo "2) Set volume (0-100)"
    echo "3) Volume +5"
    echo "4) Volume -5"
    echo "5) Toggle mute"
    echo "0) Back"
    echo
    read -r -p "Select option: " opt

    case "${opt}" in
        1) audio_show ;;
        2) audio_set ;;
        3) audio_change +5 && log "Volume +5" || err "Failed"; pause ;;
        4) audio_change -5 && log "Volume -5" || err "Failed"; pause ;;
        5) audio_toggle_mute && log "Mute toggled" || err "Failed"; pause ;;
      0) break ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

audio_show() {
  title
  echo "Volume:"
  hr
  detect_audio
  if [[ "$AU_BACKEND" == "amixer" ]]; then
    amixer get "${AU_CONTROL}" | tail -n 5 || true
  else
    audio_get_volume || true
  fi
  pause
}

audio_set() {
  title
  local vol
  read -r -p "Enter volume (0-100): " vol
  if [[ "$vol" =~ ^[0-9]+$ ]] && (( vol >= 0 && vol <= 100 )); then
    if audio_set_volume "$vol"; then
      log "Volume set to ${vol}%"
    else
      err "Failed."
    fi
  else
    warn "Invalid number."
  fi
  pause
}

# -------- Brightness (optional - need brightnessctl) --------
brightness_menu() {
  while true; do
    title
    echo "Brightness menu"
    hr
    echo "1) Show brightness"
    echo "2) Set brightness (e.g., 30%)"
    echo "3) +10%"
    echo "4) -10%"
    echo "0) Back"
    echo
    read -r -p "Select option: " opt

    case "${opt}" in
      1) title; brightness_get || warn "Failed to read brightness"; pause ;;
      2) title; read -r -p "Value (like 30%): " b; brightness_set "$b" || err "Failed"; pause ;;
      3) brightness_change +10 && log "Brightness +10%" || err "Failed"; pause ;;
      4) brightness_change -10 && log "Brightness -10%" || err "Failed"; pause ;;
      0) break ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

# -------- Main menu --------
main_menu() {
  while true; do
    title
    echo "System status:"
    hr
    sys_status
    hr
    echo "1) Disk usage"
    echo "2) Memory usage"
    echo "3) Logged on users"
    echo "4) WiFi"
    echo "5) Bluetooth"
    echo "6) Audio"
    echo "7) Brightness (optional)"
    echo "0) Exit"
    echo
    read -r -p "Select option: " opt

    case "${opt}" in
      1) disk_usage ;;
      2) memory_usage ;;
      3) users_logged ;;
      4) wifi_menu ;;
      5) bluetooth_menu ;;
      6) audio_menu ;;
      7) brightness_menu ;;
      0) break ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

log "Starting $APP_NAME"
# allow skipping the interactive main menu when running tests or sourcing
if [[ "${SKIP_MAIN_MENU:-0}" != "1" ]]; then
  main_menu
fi
