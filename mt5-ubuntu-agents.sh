#!/bin/bash
set -e

# Accept inline arguments: 1=Cores, 2=Password, 3=MQL5_Login
TOTAL_CORES=$(nproc)
if [ -z "$1" ]; then
    REQUESTED_CORES=$((TOTAL_CORES > 1 ? TOTAL_CORES - 1 : 1))
else
    REQUESTED_CORES=$1
    if [ "$REQUESTED_CORES" -ge "$TOTAL_CORES" ] && [ "$TOTAL_CORES" -gt 1 ]; then
        echo "WARNING: Reserving 1 core for OS stability to prevent Cloud disconnects."
        REQUESTED_CORES=$((TOTAL_CORES - 1))
    fi
fi

PW=${2:-"MetaTester"}
MQL5_LOGIN=$3

echo "==> [1/8] Stopping Auto-Updaters & Fixing DPKG Locks..."
export DEBIAN_FRONTEND=noninteractive

# Force-stop any background Ubuntu updates that cause the 'lock' error
sudo systemctl stop apt-daily.timer 2>/dev/null || true
sudo systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
sudo systemctl stop unattended-upgrades.service 2>/dev/null || true

# Wait safely if dpkg is still locked by a dying process
while sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "    Waiting for Ubuntu background updates to release the dpkg lock..."
    sleep 5
done

# Repair any broken packages from previous interrupted installations
sudo dpkg --configure -a || true

echo "==> [2/8] Preparing Ubuntu & Removing Firewall..."
sudo apt-get remove --purge -y needrestart ufw firewalld >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true

# Kill old conflicting services
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; done

echo "==> [3/8] Creating 16GB Swap File (OOM Crash Protection)..."
if [ $(swapon --show | wc -l) -eq 0 ]; then
    sudo fallocate -l 16G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=16384 || true
    sudo chmod 600 /swapfile || true
    sudo mkswap /swapfile || true
    sudo swapon /swapfile || true
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null || true
else
    echo "    Swap file already exists. Skipping."
fi

echo "==> [4/8] Optimizing TCP Keep-Alive & File Limits..."
cat <<EOF | sudo tee /etc/sysctl.d/99-mt5-network.conf >/dev/null
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=1024
fs.file-max=1000000
EOF
sudo sysctl -p /etc/sysctl.d/99-mt5-network.conf >/dev/null 2>&1 || true

echo "==> [5/8] Installing WineHQ & Xvfb..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract winbind net-tools >/dev/null 2>&1

echo "==> [6/8] Initializing Master 64-bit Wine Prefix..."
MASTER_WP="/opt/mt5master"
export WINEPREFIX=$MASTER_WP WINEARCH=win64 DISPLAY=:99
sudo rm -rf $MASTER_WP
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [7/8] Downloading & Extracting MetaTrader 5 silently..."
wget -q -O /tmp/mt5setup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
xvfb-run -a wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 &

echo "    Waiting 60 seconds for background extraction to finish..."
sleep 60

MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
if [ ! -f "$MASTER_EX" ]; then
    echo "ERROR: metatester64.exe failed to extract."
    exit 1
fi

echo "==> [8/8] Isolating MetaTester Agents for $REQUESTED_CORES stable cores..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Deploying Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    
    sudo rm -rf "$AGENT_WP"
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
        WINEPREFIX="$AGENT_WP" xvfb-run -a wine regedit "$AGENT_WP/cloud.reg" >/dev/null 2>&1
    fi

    WINEPREFIX=$AGENT_WP xvfb-run -a wine "$AGENT_EX" /install /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG >/dev/null 2>&1
    
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
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

echo "==> Finalizing & One-Time RAM Cleanup..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1
sleep 6

echo ""
echo "========================================="
echo "✓ SUCCESS! Stable Agents active on ports:"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
if [ ! -z "$MQL5_LOGIN" ]; then
    echo "Cloud Selling: ENABLED for account '$MQL5_LOGIN'"
fi
