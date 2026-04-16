#!/bin/bash

echo "=========================================================================="
echo "🚨 INITIATING NUCLEAR CLEANUP & FULL AUTOMATED SETUP..."
echo "=========================================================================="

# 1. Kill any existing related processes
echo "Killing old processes..."
sudo pkill -9 vncserver 2>/dev/null
sudo pkill -9 Xtigervnc 2>/dev/null
sudo pkill -9 Xtightvnc 2>/dev/null
sudo pkill -9 Xvnc 2>/dev/null
sudo pkill -9 websockify 2>/dev/null
sudo pkill -9 wine 2>/dev/null

# 2. Remove previous broken packages
echo "Purging old packages..."
sudo apt-get purge -y tightvncserver tigervnc-standalone-server tigervnc-common xfce4 xfce4-goodies novnc websockify python3-websockify wine64 wine32 wine dbus-x11 xauth 2>/dev/null
sudo apt-get autoremove -y
sudo apt-get clean

# 3. Wipe old configuration and temporary files
echo "Deleting old lock files and directories..."
sudo rm -rf /tmp/.X11-unix /tmp/.X*-lock
rm -rf ~/.vnc ~/.wine ~/mt5_experiment

# 4. Disable Firewall (As requested)
sudo ufw disable

echo "Cleanup complete. Starting fresh installation..."
echo "=========================================================================="

# 5. Add 32-bit architecture and install CORRECT dependencies
echo "Installing new desktop and Wine dependencies (This may take a minute)..."
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common dbus-x11 xauth novnc python3-websockify wine64 wine32 wget unzip curl

# 6. Setup VNC Server password (Password: mql5test)
echo "Configuring VNC Server..."
mkdir -p ~/.vnc
echo "mql5test" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# 7. Configure VNC to use the XFCE desktop environment
cat << 'EOF' > ~/.vnc/xstartup
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x ~/.vnc/xstartup

# 8. Start VNC server using TigerVNC
echo "Starting TigerVNC..."
vncserver :1 -geometry 1280x720 -depth 24

# 9. Start noVNC Web Bridge in the background
echo "Starting Web Bridge..."
websockify -D --web=/usr/share/novnc/ 6080 localhost:5901

# 10. Create working directory
mkdir -p ~/mt5_experiment
cd ~/mt5_experiment

# 11. Initialize Wine silently to the VNC display
export WINEARCH=win64
export DISPLAY=:1
echo "Initializing Wine environment..."
wineboot -u

# 12. Download the MetaTester Agent Setup
echo "Downloading MetaTester Agent Installer..."
wget -q -O mt5testersetup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5testersetup.exe"

# 13. Download and Extract Intel SDE
echo "Downloading Intel SDE Emulator..."
wget -q -O sde-win.zip "https://downloadmirror.intel.com/813591/sde-external-9.33.0-2024-01-07-win.zip"
unzip -q sde-win.zip
mv sde-external-9.33.0-2024-01-07-win sde

# 14. Launch the installer inside the VNC Desktop
echo "Launching Setup Wizard inside noVNC..."
nohup wine ~/mt5_experiment/sde/sde.exe -hsw -- ~/mt5_experiment/mt5testersetup.exe > /dev/null 2>&1 &

# 15. Print final connection instructions
VPS_IP=$(curl -s ifconfig.me)

echo ""
echo "=========================================================================="
echo "✅ FULLY AUTOMATED SETUP COMPLETE!"
echo "=========================================================================="
echo "1. Open a web browser on your personal computer."
echo "2. Navigate to: http://${VPS_IP}:6080/vnc.html"
echo "3. Click 'Connect' and enter the password: mql5test"
echo ""
echo "The MetaTester Agent Setup wizard should already be open and waiting"
echo "for you on the visual desktop. (It may be slow/laggy due to emulation)."
echo "=========================================================================="
