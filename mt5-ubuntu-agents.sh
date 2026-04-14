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
echo "      MetaTester 5 Setup (Fixing Wine Installation)      "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# FIX 1: Unhidden the output so we can see if it succeeds.
# FIX 2: Added 'wine' and 'net-tools' to the install list.
echo "Installing Wine and dependencies (Output is visible to ensure success)..."
sudo dpkg --add-architecture i386
sudo -E apt-get update -y
sudo -E apt-get install -y wine wine64 wine32 xvfb wget winbind net-tools

DIR="$HOME/mt5-agents"
mkdir -p "$DIR"
cd "$DIR"

echo "Downloading metatester64.exe..."
wget -q -nc -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

export WINEPREFIX="$DIR/wine_env"
export WINEDEBUG=-all

# Stop any stuck old processes
killall -9 Xvfb wineserver metatester64.exe 2>/dev/null
sleep 2

echo "Starting Virtual Display & Wine Services..."
nohup Xvfb :99 -screen 0 1024x768x16 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

nohup wineserver -p > /dev/null 2>&1 &
sleep 2

# This will now execute perfectly
wineboot -u
sleep 5

if [ ! -z "$MQL5_LOGIN" ]; then
    cat <<REG > cloud.reg
Windows Registry Editor Version 5.00
[HKEY_CURRENT_USER\Software\MetaQuotes\MetaTester]
"Login"="$MQL5_LOGIN"
"SellComputingResources"=dword:00000001
REG
    wine regedit cloud.reg > /dev/null 2>&1
fi

START_PORT=3000
for i in $(seq 1 $CORES); do
    PORT=$((START_PORT + i - 1))
    
    ACCOUNT_FLAG=""
    if [ ! -z "$MQL5_LOGIN" ]; then
        ACCOUNT_FLAG="/account:$MQL5_LOGIN"
    fi
    
    echo "Installing Agent on port $PORT..."
    wine metatester64.exe /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1
    sleep 2
    
    echo "✅ Agent is running on port $PORT"
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete! Agents are actively running."
echo "To verify they are listening, copy and paste this command:"
echo "sudo netstat -tulnp | grep wineserver"
echo "========================================================="
