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
sleep 3

echo "==> [2/6] Installing WineHQ & Xvfb..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract >/dev/null 2>&1

echo "==> [3/6] Initializing Master 64-bit Wine Prefix..."
MASTER_WP="/opt/mt5master"
sudo rm -rf $MASTER_WP
export WINEPREFIX=$MASTER_WP WINEARCH=win64
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [4/6] Downloading & Installing MetaTester silently (InnoSetup)..."
INSTALLER="/tmp/mt5tester-installer.exe"
wget -qO "$INSTALLER" "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

FILESIZE=$(stat -c%s "$INSTALLER" 2>/dev/null || echo 0)
echo "    File size: $FILESIZE bytes"
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "ERROR: File too small — GitHub repo may be private."
    exit 1
fi

# Mark the time BEFORE installation so we can find newly created files after
touch /tmp/before_install

echo "    Running InnoSetup silent installer (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART)..."
xvfb-run -a wine "$INSTALLER" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART >/dev/null 2>&1 &
INSTALLER_PID=$!

# Actively scan for the NEWLY installed metatester64.exe (up to 3 minutes)
MASTER_EX=""
echo "    Scanning for real metatester64.exe (up to 3 minutes)..."
for i in {1..36}; do
    MASTER_EX=$(find "$MASTER_WP/drive_c" -name "metatester64.exe" -newer /tmp/before_install 2>/dev/null | head -n 1)
    if [ -n "$MASTER_EX" ]; then
        echo "    -> Real executable found at: $MASTER_EX"
        break
    fi
    echo "    ...scanning ($((i*5))s elapsed)"
    sleep 5
done

# Kill installer process regardless
kill $INSTALLER_PID 2>/dev/null || true
wait $INSTALLER_PID 2>/dev/null || true

if [ -z "$MASTER_EX" ]; then
    echo ""
    echo "ERROR: Could not find real metatester64.exe after installation."
    echo "All .exe files currently in drive_c:"
    find "$MASTER_WP/drive_c" -name "*.exe" 2>/dev/null
    exit 1
fi

RELATIVE_EX="${MASTER_EX#$MASTER_WP}"
echo "    Using executable at relative path: $RELATIVE_EX"

echo "==> [5/6] Creating $REQUESTED_CORES isolated agents..."
PW="MetaTester"
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Creating Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    sudo rm -rf "$AGENT_WP"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    AGENT_EX="$AGENT_WP$RELATIVE_EX"

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
