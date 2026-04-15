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
sudo killall -9 wine wineserver xvfb-run Xvfb metatester64.exe fluxbox 2>/dev/null || true
for P in $(seq 3000 3100); do sudo systemctl stop mt5-agent-$P.service 2>/dev/null || true; sudo systemctl disable mt5-agent-$P.service 2>/dev/null || true; done
sudo rm -rf /opt/mt5* /tmp/mt5* ~/.wine /root/.wine /etc/systemd/system/mt5-agent* >/dev/null 2>&1 || true
sudo systemctl daemon-reload

echo "==> [2/7] Verifying Dependencies (Adding Headless Window Manager)..."
sudo dpkg --add-architecture i386
sudo apt-get update -y >/dev/null
sudo apt-get install -y wine32 wine64 xvfb fluxbox wget cabextract winbind net-tools >/dev/null 2>&1

echo "==> [3/7] Setting up 64GB Swap & Network..."
if ! swapon --show | grep -q "/swapfile"; then
    echo "    Allocating 64GB Swap..."
    sudo fallocate -l 64G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress || true
    sudo chmod 600 /swapfile || true
    sudo mkswap /swapfile || true
    sudo swapon /swapfile || true
fi

echo "==> [4/7] Creating Dedicated 'mt5user' & Initializing Wine Environment..."
if ! id "mt5user" &>/dev/null; then
    sudo useradd -m -s /bin/bash mt5user
fi

MASTER_WP="/opt/mt5master"
sudo mkdir -p "$MASTER_WP"
sudo chown -R mt5user:mt5user "$MASTER_WP"

sudo -u mt5user env WINEPREFIX="$MASTER_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wineboot -u >/dev/null 2>&1

echo "==> [5/7] Downloading metatester64.exe..."
MASTER_EX="$MASTER_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"
sudo -u mt5user mkdir -p "$(dirname "$MASTER_EX")"
sudo -u mt5user wget --show-progress -q -O "$MASTER_EX" "https://github.com/rockitya/mt5-ubuntu-agents.sh/raw/main/metatester64.exe"
sudo -u mt5user chmod +x "$MASTER_EX"

echo "==> [6/7] Deploying OLE-Compatible SystemD Agents..."
SP=3000
EP=$((SP + REQUESTED_CORES - 1))

for P in $(seq $SP $EP); do
    echo "    -> Configuring Agent on port $P..."
    AGENT_WP="/opt/mt5agent-$P"
    sudo cp -r "$MASTER_WP" "$AGENT_WP"
    sudo chown -R mt5user:mt5user "$AGENT_WP"
    AGENT_EX="$AGENT_WP/drive_c/Program Files/MetaTrader 5/metatester64.exe"

    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        cat <<REG | sudo -u mt5user tee "$AGENT_WP/cloud.reg" >/dev/null
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        
        sudo -u mt5user env WINEPREFIX="$AGENT_WP" WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" xvfb-run -a wine regedit "$AGENT_WP/cloud.reg" >/dev/null 2>&1

        CONFIG_DIR="$AGENT_WP/drive_c/users/mt5user/AppData/Roaming/MetaQuotes/Tester"
        sudo -u mt5user mkdir -p "$CONFIG_DIR"
        cat <<INI | sudo -u mt5user tee "$CONFIG_DIR/metatester.ini" >/dev/null
[Tester]
Port=$P
Password=$PW
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI
    fi

    # THE FIX: This wrapper script allows xvfb-run to seamlessly run both apps with perfect X11 Security Cookies
    LAUNCH_SCRIPT="/opt/mt5agent-$P/launch.sh"
    cat << EOF | sudo tee "$LAUNCH_SCRIPT" >/dev/null
#!/bin/bash
export WINEPREFIX="$AGENT_WP"
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="

# Start the micro window manager in the background
/usr/bin/fluxbox &
FLUX_PID=\$!
sleep 2

# Launch MetaTester natively in the foreground
/usr/bin/wine "$AGENT_EX" /address:0.0.0.0:$P /password:$PW $ACCOUNT_FLAG

kill \$FLUX_PID 2>/dev/null || true
EOF
    sudo chmod +x "$LAUNCH_SCRIPT"
    sudo chown mt5user:mt5user "$LAUNCH_SCRIPT"

    # THE FIX: Wrap the launch script completely inside the secure xvfb-run display generator
    cat << EOF | sudo tee /etc/systemd/system/mt5-agent-$P.service >/dev/null
[Unit]
Description=MT5 Strategy Tester Agent on Port $P
After=network.target

[Service]
Type=simple
User=mt5user
Group=mt5user
LimitNOFILE=65536
ExecStart=/usr/bin/xvfb-run -a $LAUNCH_SCRIPT
Restart=always
RestartSec=10
SendSIGKILL=no

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
