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
echo "   MetaTester 5 Setup (Global Display Backend Mode)      "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

export WINEDLLOVERRIDES="mscoree=;mshtml="
export WINEDEBUG=-all

echo "Installing backend dependencies..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools > /dev/null 2>&1

echo "Downloading official metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe"

# Wipe the slate clean before starting
killall -9 wineserver metatester64.exe wine xvfb-run Xvfb 2>/dev/null
sleep 2

# THE FIX: Create ONE indestructible global virtual display.
# It will never close, so your agents will never crash.
nohup Xvfb :99 -screen 0 1024x768x24 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    
    # Isolate this specific agent's Windows environment
    export WINEPREFIX="$DIR"
    
    echo "Deploying stable backend Agent on port $PORT..."
    
    rm -rf "$DIR"
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    # 1. Boot the environment
    wineboot -u > /dev/null 2>&1
    sleep 2
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
        
        cat <<REG > "$DIR/cloud.reg"
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
        wine regedit "$DIR/cloud.reg" > /dev/null 2>&1
    fi
    
    # 2. Install the Windows Service (Timeout 15s to guarantee it doesn't pause the terminal)
    timeout 15 wine "$DIR/metatester64.exe" /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1
    
    # Clear any residual locks from the installer
    wineserver -k > /dev/null 2>&1
    sleep 2
    
    # 3. Start the persistent daemon
    nohup wineserver -p > /dev/null 2>&1 &
    sleep 1
    
    # 4. Boot the service. 
    # Because DISPLAY=:99 is permanently open, this service will run forever without crashing.
    wineboot > /dev/null 2>&1
    
    echo "✅ Agent is running permanently on port $PORT"
    sleep 2
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Master Setup Complete!"
echo "Verify your active backend agents are running here:"
echo "sudo netstat -tulnp | grep wineserver"
echo "========================================================="
