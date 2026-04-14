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
echo "   MetaTester 5 Setup (Direct Command-Line Execution)    "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Block GUI popups
export WINEDLLOVERRIDES="mscoree=;mshtml="
export WINEDEBUG=-all

echo "Installing Linux dependencies..."
sudo dpkg --add-architecture i386 > /dev/null 2>&1
sudo -E apt-get update -yqq > /dev/null 2>&1
sudo -E apt-get install -yqq wine wine64 wine32 xvfb wget winbind net-tools > /dev/null 2>&1

echo "Downloading official metatester64.exe..."
mkdir -p ~/mt5-agents
cd ~/mt5-agents
wget -q -nc -O metatester64.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/metatester64.exe"

# Stop everything
killall -9 wineserver metatester64.exe wine Xvfb xvfb-run 2>/dev/null
sleep 2

# Global Invisible Display
nohup Xvfb :99 -screen 0 1024x768x16 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

START_PORT=3000

for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    DIR="$HOME/mt5-agents/node_$PORT"
    export WINEPREFIX="$DIR"
    
    echo "Configuring Direct Agent on port $PORT..."
    
    rm -rf "$DIR"
    mkdir -p "$DIR"
    cp metatester64.exe "$DIR/"
    
    # Pre-boot environment
    wineboot -u > /dev/null 2>&1
    sleep 2
    
    # 1. CREATE DIRECT INI FILE
    # Instead of installing a Windows Service, we generate the exact configuration file MetaTester uses natively
    cat <<INI > "$DIR/config.ini"
[Tester]
Port=$PORT
Password=$PASSWORD
[Cloud]
Login=$MQL5_LOGIN
SellComputingResources=1
INI

    # 2. RUN DIRECTLY FROM COMMAND LINE
    # We pass the INI file straight into the executable. This physically forces the ports open.
    # The trailing '&' drops it into the Linux background safely.
    nohup wine "$DIR/metatester64.exe" /config:"Z:\\root\\mt5-agents\\node_$PORT\\config.ini" > /dev/null 2>&1 &
    
    echo "✅ Agent is running on port $PORT"
    sleep 2
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Direct Setup Complete!"
echo "Check your ports using: sudo netstat -tulnp | grep metatester"
echo "========================================================="
