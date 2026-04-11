#!/bin/bash
set -e

echo "==> [1/6] Preparing Ubuntu & Removing Firewall..."
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a || true
sudo apt-get remove --purge -y needrestart ufw firewalld >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true

# Kill old conflicting services
sudo systemctl stop MetaTester-1.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/MetaTester-1.service 2>/dev/null || true
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; done

echo "==> [2/6] Installing WineHQ & Xvfb (Virtual Display)..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract >/dev/null 2>&1

echo "==> [3/6] Initializing Master 64-bit Wine Prefix..."
MASTER_WP="/opt/mt5master"
export WINEPREFIX=$MASTER_WP WINEARCH=win64 DISPLAY=:99
sudo rm -rf $MASTER_WP
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [4/6] Downloading & Extracting Master MetaTrader 5 silently..."
wget -O /tmp/mt5setup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
xvfb-run -a wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 &

echo "    Waiting 60 seconds for background extraction to finish..."
sleep 60

MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
if [ ! -f "$MASTER_EX" ]; then
    echo "ERROR: metatester64.exe failed to extract."
    exit 1
fi

echo "==> [5/6] Isolating MetaTester Agents across all CPU cores..."
PW="MetaTester"
SP=3000
CORES=$(nproc)
EP=$((SP + CORES - 1))

echo "    Found $CORES CPU cores. Creating isolated environments for ports $SP to $EP..."

for P in $(seq $SP $EP); do
    echo "    -> Cloning environment for Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    
    # 1. Create a fully isolated copy of the Master Wine prefix for this specific port
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    
    # The path to the executable inside this specific isolated prefix
    AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

    # 2. Register the agent silently inside its own isolated environment
    WINEPREFIX=$AGENT_WP xvfb-run -a wine "$AGENT_EX" /install /address:0.0.0.0:$P /password:$PW >/dev/null 2>&1
    
    # 3. Create persistent SystemD service bound strictly to this isolated prefix
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /address:0.0.0.0:$P /password:$PW
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl restart mt5-agent-$P.service
done

echo "==> [6/6] Finalizing..."
sleep 6

echo ""
echo "========================================="
echo "✓ SUCCESS! Agents active on the following ports:"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
echo "Add these IPs and ports in your MT5 terminal: Tools -> Options -> Expert Advisors -> Add Agent"
