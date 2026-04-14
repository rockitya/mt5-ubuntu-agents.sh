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
echo "      MetaTester 5 Setup (Background Detach Fix)         "
echo "========================================================="
echo "Cores: $CORES | MQL5 Login: ${MQL5_LOGIN:-None}"

echo "---------------------------------------------------------"
echo "Disabling UFW Firewall..."
sudo ufw disable > /dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "Installing Wine and dependencies..."
sudo dpkg --add-architecture i386
sudo -E apt-get update -y > /dev/null 2>&1
sudo -E apt-get install -y wine wine64 wine32 xvfb wget winbind net-tools > /dev/null 2>&1

DIR="$HOME/mt5-agents"
mkdir -p "$DIR"
cd "$DIR"

echo "Downloading metatester64.exe..."
wget -q -nc -O metatester64.exe "https://raw.githubusercontent.com/rockitya/mt5-ubuntu-agents.sh/main/metatester64.exe"

export WINEPREFIX="$DIR/wine_env"
export WINEDEBUG=-all

# Stop any stuck old processes from the previous run
killall -9 Xvfb wineserver metatester64.exe 2>/dev/null
sleep 2

echo "Starting Virtual Display & Wine Services..."
nohup Xvfb :99 -screen 0 1024x768x16 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

nohup wineserver -p > /dev/null 2>&1 &
sleep 2

wineboot -u > /dev/null 2>&1
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
    
    echo "Installing and Detaching Agent on port $PORT..."
    
    # FIX: Added 'nohup' and '&' at the end. 
    # This pushes the active agent into the background so the script doesn't pause!
    nohup wine metatester64.exe /install /address:0.0.0.0:$PORT /password:$PASSWORD $ACCOUNT_FLAG > /dev/null 2>&1 &
    
    # Wait 5 seconds for the agent to fully boot before starting the next core
    sleep 5
    
    echo "✅ Agent is running in background on port $PORT"
done

echo "---------------------------------------------------------"
echo "Cleaning up RAM Cache..."
sudo sync; sudo sysctl -w vm.drop_caches=3 > /dev/null 2>&1

echo "========================================================="
echo "Setup Complete! Agents are actively running."
echo "To verify they are listening, run this command:"
echo "sudo netstat -tulnp | grep wineserver"
echo "========================================================="
