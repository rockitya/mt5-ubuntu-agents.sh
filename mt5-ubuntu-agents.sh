#!/bin/bash
set -e

REQUESTED_CORES=${1:-$(nproc)}
MQL5_ACCOUNT=${2:-""}

if [ -z "$MQL5_ACCOUNT" ]; then
    echo "ERROR: Provide your MQL5 email!"
    echo "Usage: sudo bash mt5-setup.sh CORES MQL5_EMAIL"
    exit 1
fi

echo "==> [1/6] Preparing Ubuntu & Removing Firewall..."
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a || true
sudo apt-get remove --purge -y needrestart ufw firewalld >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true
sudo systemctl stop MetaTester-1.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/MetaTester-1.service 2>/dev/null || true
for P in $(seq 3000 3100); do
    sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/mt5-agent-$P.service 2>/dev/null || true
done
sudo systemctl daemon-reload || true
sudo pkill -f metatester64 2>/dev/null || true
sudo pkill -f wineserver 2>/dev/null || true
sleep 2

echo "==> [2/6] Installing Wine, Xvfb & p7zip..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget p7zip-full >/dev/null 2>&1

echo "==> [3/6] Initializing Master 64-bit Wine Prefix..."
MASTER_WP="/opt/mt5master"
sudo rm -rf $MASTER_WP
export WINEPREFIX=$MASTER_WP WINEARCH=win64
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [4/6] Downloading & Extracting MetaTester via 7zip (no Wine installer needed)..."
INSTALLER="/tmp/mt5tester-installer.exe"
wget -qO "$INSTALLER" "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

FILESIZE=$(stat -c%s "$INSTALLER" 2>/dev/null || echo 0)
echo "    File size: $FILESIZE bytes"
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "ERROR: File too small — GitHub repo may be private or file is missing."
    exit 1
fi

# Extract the InnoSetup package directly with 7zip - no Wine, no GUI, no hanging!
EXTRACT_DIR="/tmp/mt5extracted"
sudo rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
echo "    Extracting InnoSetup package with 7zip..."
7z e "$INSTALLER" -o"$EXTRACT_DIR" -y >/dev/null 2>&1 || true

# Find the real metatester64.exe inside extracted files
REAL_EX=$(find "$EXTRACT_DIR" -name "metatester64.exe" 2>/dev/null | head -n 1)

if [ -z "$REAL_EX" ]; then
    echo ""
    echo "ERROR: metatester64.exe not found inside the package."
    echo "All extracted files:"
    ls -lah "$EXTRACT_DIR/"
    exit 1
fi

echo "    -> Real metatester64.exe found! Copying to Wine prefix..."
DEST_DIR="$MASTER_WP/drive_c/Program Files/MetaTrader 5"
mkdir -p "$DEST_DIR"
cp "$REAL_EX" "$DEST_DIR/metatester64.exe"

# Also copy any supporting DLLs that were extracted alongside the exe
find "$EXTRACT_DIR" -name "*.dll" -exec cp {} "$DEST_DIR/" \; 2>/dev/null || true

echo "    -> Done! No installer, no hanging, no GUI dialogs."

echo "==> [5/6] Creating $REQUESTED_CORES isolated agents..."
PW="MetaTester"
SP=3000
EP=$((SP + REQUESTED_CORES - 1))
AGENT_EX_PATH="drive_c/Program Files/MetaTrader 5/metatester64.exe"

for P in $(seq $SP $EP); do
    echo "    -> Creating Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    sudo rm -rf "$AGENT_WP"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    AGENT_EX="$AGENT_WP/$AGENT_EX_PATH"

    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl restart mt5-agent-$P.service
    sleep 2
done

echo "==> [6/6] Finalizing & RAM cleanup..."
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
sleep 10

echo ""
echo "========================================="
echo "Active ports:"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
echo "MQL5    : $MQL5_ACCOUNT"
