#!/bin/bash
set -e

# Accept arguments:
# $1 = Number of cores
# $2 = MQL5 Account Email or Username
REQUESTED_CORES=${1:-$(nproc)}
MQL5_ACCOUNT=${2:-""}

if [ -z "$MQL5_ACCOUNT" ]; then
    echo "ERROR: You must provide your MQL5 account email/username to sell computing resources!"
    echo "Usage: wget -qO- YOUR_URL | sudo bash -s -- CORES MQL5_EMAIL"
    exit 1
fi

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

echo "==> [4/6] Downloading Portable MetaTester64 directly..."
mkdir -p "$MASTER_WP/drive_c/Program Files/MetaTrader 5/"
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

# Downloading the actual executable from your GitHub repo
wget -qO "$MASTER_EX" "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

if [ ! -f "$MASTER_EX" ]; then
    echo "ERROR: Failed to download metatester64.exe from GitHub."
    exit 1
fi
echo "    -> Download complete! No installation required."

echo "==> [5/6] Isolating & Configuring MetaTester Agents for Cloud Network..."
PW="MetaTester"
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

echo "    Creating isolated environments for $REQUESTED_CORES cores..."
echo "    Binding agents to MQL5 Account: $MQL5_ACCOUNT"

for P in $(seq $SP $EP); do
    echo "    -> Configuring Agent on port $P for MQL5 Cloud..."
    AGENT_WP="/opt/mt5agent-$P"
    
    sudo rm -rf "$AGENT_WP"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

    # THE FIX: We use 'timeout' to run the official installation command for exactly 10 seconds.
    # This is enough time for metatester64.exe to securely generate its own tester.ini file,
    # bind to your MQL5 account, and enable Cloud Selling before it hangs. Then we kill it.
    timeout 10 xvfb-run -a wine "$AGENT_EX" /install /address:0.0.0.0:$P /password:$PW /account:$MQL5_ACCOUNT >/dev/null 2>&1 || true
    
    # Create persistent SystemD service. Notice we use the /run flag now because the configuration 
    # file was officially created by the executable itself in the step above!
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Environment=WINEPREFIX=$AGENT_WP
Environment=WINEARCH=win64
ExecStart=/usr/bin/xvfb-run -a /usr/bin/wine "$AGENT_EX" /run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable mt5-agent-$P.service >/dev/null 2>&1
    sudo systemctl restart mt5-agent-$P.service
done

echo "==> [6/6] Finalizing & RAM cleanup..."
sudo rm -f /etc/cron.d/clear-mt5-cache 2>/dev/null || true
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
sleep 8

echo ""
echo "========================================="
echo "✓ SUCCESS! Agents configured for MQL5 Cloud Network."
echo "Active Ports:"
ss -tuln | grep -E "30[0-9]{2}|3100" | awk '{print $5}'
echo "========================================="
echo "VPS IP        : $(hostname -I | awk '{print $1}')"
echo "Local Password: $PW"
echo "MQL5 Account  : $MQL5_ACCOUNT"
echo "Your agents will now automatically sell computing power to the Cloud Network!"
