#!/bin/bash
set -e

echo "==> [1/6] Preparing Ubuntu & Removing Firewall..."
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a || true
sudo apt-get remove --purge -y needrestart ufw firewalld >/dev/null 2>&1 || true
sudo apt-get autoremove -y >/dev/null 2>&1 || true

# Kill the old conflicting service that was hogging port 3000
sudo systemctl stop MetaTester-1.service 2>/dev/null || true
sudo systemctl disable MetaTester-1.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/MetaTester-1.service 2>/dev/null || true

echo "==> [2/6] Installing WineHQ & Xvfb (Virtual Display)..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb wget cabextract >/dev/null 2>&1

echo "==> [3/6] Initializing 64-bit Wine Prefix..."
WP="/opt/mt5agent"
export WINEPREFIX=$WP WINEARCH=win64 DISPLAY=:99
sudo rm -rf $WP
xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [4/6] Downloading & Extracting MetaTrader 5 silently..."
wget -O /tmp/mt5setup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

echo "    Launching installer in background..."
xvfb-run -a wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 &

echo "    Waiting 60 seconds for background extraction to finish..."
sleep 60

EX="$WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
if [ ! -f "$EX" ]; then
    echo "ERROR: metatester64.exe failed to extract. The silent installer crashed."
    exit 1
fi

echo "==> [5/6] Registering MetaTester Agents across all CPU cores..."
PW="MetaTester"
SP=3000
CORES=$(nproc)
EP=$((SP + CORES - 1))

echo "    Found $CORES CPU cores. Configuring ports $SP to $EP..."

for P in $(seq $SP $EP); do
    echo "    -> Configuring Agent on port $P..."
    
    # Stop existing service if it exists to avoid conflicts
    sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true
    
    # Register the agent in Wine
    xvfb-run -a wine "$EX" /install /address:0.0.0.0:$P /password:$PW >/dev/null 2>&1
    
    # Create persistent SystemD service with EXACT port and password arguments
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$WP
Environment=WINEARCH=win64
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$EX" /address:0.0.0.0:$P /password:$PW
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
sleep 5

echo ""
echo "========================================="
echo "✓ SUCCESS! Agents active on the following ports:"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
echo "VPS IP  : $(hostname -I | awk '{print $1}')"
echo "Password: $PW"
echo "Add these IPs and ports in your MT5 terminal: Tools -> Options -> Expert Advisors -> Add Agent"
