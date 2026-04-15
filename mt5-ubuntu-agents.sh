#!/bin/bash
set -e

# Accept inline arguments: 1=Cores, 2=Password, 3=MQL5_Login
TOTAL_CORES=$(nproc)
REQUESTED_CORES=${1:-$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))}
PW=${2:-"MetaTester"}
MQL5_LOGIN=$3

export DEBIAN_FRONTEND=noninteractive

echo "==> [1/6] Wiping Old Installations..."
sudo killall -9 wine wineserver xvfb-run Xvfb metatester64.exe 2>/dev/null || true
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true
sudo systemctl daemon-reload

echo "==> [2/6] Verifying Dependencies..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract winbind net-tools >/dev/null 2>&1

echo "==> [3/6] Initializing Root Wine Environment..."
MASTER_WP="/opt/mt5master"
sudo mkdir -p "$MASTER_WP"
sudo env WINEPREFIX="$MASTER_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [4/6] Downloading metatester64.exe..."
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
sudo mkdir -p "$(dirname "$MASTER_EX")"
sudo wget --show-progress -q -O "$MASTER_EX" "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
sudo chmod +x "$MASTER_EX"

echo "==> [5/6] Deploying SystemD Agent on Port 3000..."
AGENT_WP="/opt/mt5agent-3000"
sudo cp -r "$MASTER_WP" "$AGENT_WP"
AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
ACCOUNT_FLAG=$([ ! -z "$MQL5_LOGIN" ] && echo "/account:$MQL5_LOGIN" || echo "")

cat << EOF | sudo tee /etc/systemd/system/mt5-agent-3000.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent
After=network.target

[Service]
User=root
Group=root
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
Environment=WINEDLLOVERRIDES="mscoree,mshtml="
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /address:0.0.0.0:3000 /password:$PW $ACCOUNT_FLAG
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mt5-agent-3000.service >/dev/null 2>&1
sudo systemctl restart mt5-agent-3000.service

echo "==> [6/6] Verifying Agent Status..."
sleep 10

if ss -tuln | grep -q ":3000"; then
    echo ""
    echo "========================================="
    echo "✓ SUCCESS! Agent 3000 is ACTIVE AND RUNNING!"
    echo "========================================="
    exit 0
else
    echo ""
    echo "========================================="
    echo "❌ CRITICAL ERROR: The Agent crashed immediately."
    echo "Extracting exact crash logs from SystemD..."
    echo "========================================="
    sudo journalctl -u mt5-agent-3000 --no-pager -n 30
    
    echo ""
    echo "========================================="
    echo "Running direct diagnostic test (Bypassing SystemD)..."
    echo "========================================="
    # Run directly in the terminal so we can see the raw Wine output
    sudo env WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wine "$AGENT_EX" /address:0.0.0.0:3000 /password:$PW $ACCOUNT_FLAG
fi
