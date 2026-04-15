#!/bin/bash
set -e

# Accept inline arguments: 1=Cores, 2=Password, 3=MQL5_Login
TOTAL_CORES=$(nproc)
if [ -z "$1" ]; then
    REQUESTED_CORES=$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))
else
    REQUESTED_CORES=$1
    if [ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ]; then
        echo "WARNING: Reserving 1 core for OS stability."
        REQUESTED_CORES=$((TOTAL_CORES - 1))
    fi
fi

PW=${2:-"MetaTester"}
MQL5_LOGIN=$3

export DEBIAN_FRONTEND=noninteractive

echo "==> [1/7] Wiping Old Installations..."
sudo killall -9 wine wineserver xvfb-run Xvfb metatester64.exe 2>/dev/null || true
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true
sudo systemctl daemon-reload

echo "==> [2/7] Verifying Dependencies..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract winbind net-tools >/dev/null 2>&1

echo "==> [3/7] Setting up 64GB Swap & Network..."
if ! swapon --show | grep -q "/swapfile"; then
    echo "    Allocating 64GB Swap..."
    sudo fallocate -l 64G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    sudo chmod 600 /swapfile || true
    sudo mkswap /swapfile || true
    sudo swapon /swapfile || true
fi

cat <<EOF | sudo tee /etc/sysctl.d/99-mt5-network.conf >/dev/null
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
vm.swappiness=60
EOF
sudo sysctl -p /etc/sysctl.d/99-mt5-network.conf >/dev/null 2>&1 || true

echo "==> [4/7] Initializing Root Wine Environment..."
MASTER_WP="/opt/mt5master"
sudo mkdir -p "$MASTER_WP"
sudo env WINEPREFIX="$MASTER_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [5/7] Downloading metatester64.exe..."
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
sudo mkdir -p "$(dirname "$MASTER_EX")"
sudo wget --show-progress -q -O "$MASTER_EX" "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
sudo chmod +x "$MASTER_EX"

echo "==> [6/7] Deploying SystemD Agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Configuring Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        cat <<REG | sudo tee "$AGENT_WP/cloud.reg" >/dev/null
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        
        sudo env WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wine regedit "$AGENT_WP/cloud.reg" >/dev/null 2>&1

        CONFIG_DIR="$AGENT_WP/drive_c/users/root/AppData/Roaming/MetaQuotes/Tester"
        sudo mkdir -p "$CONFIG_DIR"
        cat <<INI | sudo tee "$CONFIG_DIR/metatester.ini" >/dev/null
[Tester]
Port=$P
Password=$PW
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI
    fi

    # THE FIX: Added Type=simple, SendSIGKILL=no, and TimeoutStopSec to prevent SystemD from assassinating Wine
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Type=simple
User=root
Group=root
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
Environment=WINEDLLOVERRIDES="mscoree,mshtml="
LimitNOFILE=65536
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
Restart=always
RestartSec=10
SendSIGKILL=no
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl restart mt5-agent-$P.service
done

echo "==> [7/7] Verifying Agent Status (Waiting up to 60s for Cloud connection)..."
for i in {1..12}; do
    if ss -tuln | grep -q ":3000"; then
        echo ""
        echo "========================================="
        echo "✓ SUCCESS! SystemD Agents are active!"
        ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
        echo "========================================="
        if [ ! -z "$MQL5_LOGIN" ]; then
            echo "Cloud Selling: ENABLED for account '$MQL5_LOGIN'"
        fi
        echo "========================================="
        exit 0
    fi
    echo "    ...Waiting for Wine to initialize port 3000 ($((i*5))s)..."
    sleep 5
done

echo ""
echo "========================================="
echo "❌ TIMEOUT: Agent didn't open port 3000 in time."
echo "Here is the current live log:"
sudo journalctl -u mt5-agent-3000 --no-pager -n 20
