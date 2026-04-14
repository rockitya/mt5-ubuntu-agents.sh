#!/bin/bash

# Read inputs directly from the command line arguments
CORES=$1
PASSWORD=$2
MQL5_LOGIN=$3

if [ -z "$CORES" ] || [ -z "$PASSWORD" ]; then
    echo "Error: Missing required arguments."
    echo "Usage: curl -sSL <github_raw_url> | bash -s <CORES> <PASSWORD> [MQL5_LOGIN]"
    exit 1
fi

echo "========================================================="
echo "      MetaTester 5 Setup (Native Service Architecture)   "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Notice tmux is removed entirely from dependencies
echo "Installing required packages (wine, xvfb, winbind, net-tools)..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools > /dev/null 2>&1

echo "Downloading official metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe"

echo "Clearing old configurations..."
killall -9 wineserver metatester64.exe wine Xvfb 2>/dev/null
sleep 2

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    export WINEPREFIX="$DIR"
    export WINEDEBUG=-all
    
    echo "Configuring and starting Agent on port $PORT..."
    
    rm -rf "$DIR"
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    # 1. Create a dedicated virtual display for this specific agent to prevent crashes
    nohup Xvfb :$PORT -screen 0 1024x768x16 > /dev/null 2>&1 &
    export DISPLAY=:$PORT
    sleep 1
    
    # 2. Pre-boot the Wine environment
    wineboot -u > /dev/null 2>&1
    sleep 2
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        # Inject Cloud Network Registry
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    # 3. INSTALL the application as a background Windows Service
    wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1
    
    # 4. Force-kill the temporary installation daemon
    wineserver -k > /dev/null 2>&1
    sleep 2
    
    # 5. START the persistent daemon. '-p' keeps the wine background alive forever.
    nohup wineserver -p > /dev/null 2>&1 &
    sleep 2
    
    # 6. Boot the services. This natively turns ON the MetaTester service in the background!
    nohup wineboot > /dev/null 2>&1 &
    
    echo "✅ Agent successfully started in background on port $PORT"
    sleep 2
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete!"
echo "Check your active listening ports using:"
echo "sudo netstat -tulnp | grep wineserver"
echo "========================================================="
