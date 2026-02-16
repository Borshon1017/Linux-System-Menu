# System Menu

An interactive terminal menu to control your system: WiFi, Bluetooth, audio volume, brightness, disk/memory usage, and logged users.

## 1. Install optional tools (recommended)

```bash
sudo apt update
sudo apt install -y fzf network-manager bluez alsa-utils
# Optional (brightness control):
sudo apt install -y brightnessctl
```

## 2. Run the script

```bash
cd ~/system_menu_project
chmod +x system_menu.sh
./system_menu.sh
```

## Features

- **System status** – Host, kernel, uptime, load, IP
- **Disk usage** – `df -h` overview
- **Memory usage** – `free -h` and top memory consumers
- **Logged users** – `who`
- **WiFi** – List networks, connect (interactive with fzf), disconnect, show connection
- **Bluetooth** – Toggle power, status, scan/connect, disconnect (fzf)
- **Audio** – Show/set volume, ±5%, mute toggle
- **Brightness** – Show/set, ±10% (needs `brightnessctl`)

Logs are written to `~/.system_menu/logs/` (output.log, error.log).
