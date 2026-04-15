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

echo "==> [1/7] NUCLEAR WIPE: Killing Locked Processes & Old Installs..."
# Erase all traces of background locked files so we have a clean slate
sudo killall -9 wine wineserver xvfb-run Xvfb metatester64.exe mt5setup.exe wget curl 2>/dev/null || true

for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done

sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true
sudo systemctl daemon-reload

echo "==> [2/7] Installing WineHQ & Xvfb..."
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

echo "==> [4/7] Downloading MetaTester directly from GitHub..."
MASTER_WP="/opt/mt5master"
sudo mkdir -p $MASTER_WP
sudo chown -R $USER:$USER $MASTER_WP

export WINEPREFIX=$MASTER_WP 
export WINEARCH=win64 
export WINEDLLOVERRIDES="mscoree,mshtml=" 

echo "    -> Initializing Windows Environment (This takes ~15 seconds)..."
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "    -> Pulling metatester64.exe directly from your GitHub..."
sudo mkdir -p "$MASTER_WP/drive_c/Program Files/MetaTrader 5/"
sudo chown -R $USER:$USER "$MASTER_WP"
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

# THE FIX: Bypassing MetaQuotes CDN and pulling your exact binary. 
# Using the /raw/ path perfectly handles both standard and LFS Git binaries.
wget --show-progress -q -O "$MASTER_EX" "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
chmod +x "$MASTER_EX"

# Safety Check - Ensure it downloaded the full file and not a tiny text file error
FILESIZE=$(stat -c%s "$MASTER_EX")
if [ "$FILESIZE" -lt 1000000 ]; then
    echo "WARNING: GitHub download was too small (Likely an LFS pointer block)."
    echo "Fallback: Tricking MetaQuotes CDN with a custom User-Agent..."
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --show-progress -q -O /tmp/mt5setup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
    xvfb-run -a wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 &
    sleep 90
fi

if [ ! -f "$MASTER_EX" ]; then
    echo "ERROR: metatester64.exe is completely missing. Exiting."
    exit 1
fi

echo "==> [5/7] Deploying Isolated Agents..."
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
        
        cat <<REG > "$AGENT_WP/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        WINEPREFIX="$AGENT_WP" WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wine regedit "$AGENT_WP/cloud.reg" >/dev/null 2>&1

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

    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
Environment=WINEDLLOVERRIDES="mscoree,mshtml="
LimitNOFILE=65536
ExecStartPre=-/usr/bin/xvfb-run -a /usr/bin/wine reg delete "HKEY_USERS\\S-1-5-18\\Software\\MetaQuotes Software\\Cloud.Ping" /f
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl restart mt5-agent-$P.service
done

echo "==> [6/7] Finalizing RAM Cleanup..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1
sleep 6

echo ""
echo "========================================="
echo "✓ SUCCESS! SystemD Agents are active!"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
if [ ! -z "$MQL5_LOGIN" ]; then
    echo "Cloud Selling: ENABLED for account '$MQL5_LOGIN'"
fi
echo "To check agent 3000 logs: sudo journalctl -u mt5-agent-3000 -f"
echo "========================================="
