#!/bin/sh
# Welcome to my installation script!
# This script was made to containerize all the installation logic into a single
# file and run it with 0 interruptions (unless an error arises
#
# Any required configuration is defined in the `#Variables` section by the user
# that includes bit flags to enable/disable installation features.
#
# Im also assuming that the system running this script already had the following
# packages installed during the live-iso installation phase:
# - base
# - base-devel
# - git
# - networkmanager
# - iproute2  # in `base`
# - dnsmasq
# - wget
# - unzip

set -e

# only run with root permission
if [ "$EUID" -ne 0 ]; then Err "Install script must run with root privileges!"
    exit 1 fi

#==============================
# Variables
#==============================
# some fields will contain sensitive information, dont forget to hide these fields (marked with `# sensitive`)
# NOTE: 0: Ignore | 1: Apply
USER_NAME=""
USER_PASS=""  # sensitive
USER_HOME="/home/$USER_NAME"
HOSTNAME="MooseBox"
ZONE=""

USE_WIFI=0
WIFI_SSID=""
WIFI_PASS=""  # sensitive

NM_RANDOMIZE_MAC=0

ENABLE_NTP=1
ENABLE_DOCKER=0

PACKAGES=$(echo "
zsh
vim
neovim
ntp

# Dev tools
docker
docker-compose
python
npm

# Font support
noto-fonts-emoji
ttf-jetbrains-mono-nerd
noto-fonts-cjk
" | sed 's/\n/ /' | sed 's/,//g' | sed 's/#.*$//')

#==============================
# Util functions
#==============================
# logging
Err() {
    echo -e "[\033[0;31mERROR\033[0m $1"
}

Ok() {
    echo -e "[\033[0;32mOK   \033[0m $1"
}

Debug() {
    echo -e "[\033[0;33mDEBUG\033[0m $1"
}

Info() {
    echo -e "[\033[0;34mINFO \033[0m $1"
}

# additional util
uncomment() {
    sed -i "/^[[:space:]]*#[[:space:]]*$2$/s/^[[:space:]]*#[[:space:]]*//" "$1"
}

exec_in_user() {
    sudo -i -u $USER_NAME -- $@
}

exec_script_in_user() {
    chown $USER_NAME:$USER_NAME $1
    chmod a+x $1
    exec_in_user $@
}


#==============================
# Network
#==============================
Info "NetworkManager config"
tee /etc/NetworkManager/NetworkManager.conf <<EOF
[main]
auth-polkit=true
dhcp=internal
dns=dnsmasq
EOF

mkdir -p /etc/NetworkManager/conf.d

[[ $NM_RANDOMIZE_MAC -eq 1 ]] && tee /etc/NetworkManager/conf.d/00-macrandomize.conf <<EOF
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=preserve
EOF

# TODO: research networkmanager for more optional configuration options

Info "dnsmasq configuration"
tee /etc/NetworkManager/dnsmasq.d/custom.conf <<EOF
listen-address=127.0.0.1

bind-interfaces
interface=lo

domain-needed
bogus-priv
no-hosts
no-poll

# against DNS poisoning
dns-forward-max=150
cache-size=1000
EOF

Info "Ensure \`NetworkManager\` and \`dnsmasq\` are enabled and active"
systemctl enable --now NetworkManager.service
systemctl enable --now dnsmasq.service

if [[ $USE_WIFI -eq 1 ]]; then
    Info "Connecting to preset wifi host"
    nmcli dev wifi con $WIFI_SSID --pass $WIFI_PASS
fi

# TODO: add firewall configuration here

Info "Ensure network connection"
getent hosts archlinux.org
ping -c 5 archlinux.org

echo "$HOSTNAME" > /etc/hostname

#==============================
# Package manager
#==============================
Info "Generate updated mirrorlist"
pacman -Sy --noconfirm reflector
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
reflector --country "Israel" --protocol https --sort rate --save /etc/pacman.d/mirrorlist
tee -a /etc/pacman.d/mirrorlist <<EOF

## Fallback to global mirrors
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirror.nus.edu.sg/archlinux/\$repo/os/\$arch
Server = https://mirror.kernel.org/archlinux/\$repo/os/\$arch
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://ftpmirror.infania.net/mirror/archlinux/\$repo/os/\$arch
EOF

Info "Define pacman.conf"
tee /etc/pacman.conf <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
HoldPkg = pacman glibc

ParallelDownloads = 5
VerbosePkgLists
CheckSpace
Color
ILoveCandy  # :)

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

Info "Build yay from source"
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si
cd $HOME
rm -rf /tmp/yay

Info "Synchronize databases"
pacman -Syu --noconfirm

Info "Installing required system packages"
yay -S --noconfirm $PACKAGES

Ok "package manager config done!"

#==============================
# Locale
#==============================
uncomment /etc/locale.gen "en_US.UTF-8 UTF-8"
uncomment /etc/locale.gen "en_US USI-8559-1"
locale-gen

Info "Download my fav nerdfont :3"
FONT_DOWNLOAD_LINK="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/BigBlueTerminal.zip"
mkdir -p /usr/local/share/font
mkdir -p /tmp/font
 wget -o /tmp/font/FONT.zip $FONT_DOWNLOAD_LINK
unzip /tmp/font/FONT.zip
mv /tmp/font/BigBlueTermPlusNerdFontMono-Regular.ttf /usr/local/share/font
rm -rf /tmp/font  # cleanup
fc-cache -fv

#==============================
# Clock
#==============================
Info "Timezone"
if [[ -f "/usr/share/zoneinfo/$ZONE" ]]; then
    timedatectl set-timezone $ZONE
else
    Err "Zone \"$ZONE\" does not exist"

Info "NTP client setup"
hwclock --systohc
[[ $ENABLE_NTP -eq 1 ]] && systemctl enable --now ntpdate

#==============================
# User
#==============================
Info "Create user"
useradd -mG wheel,audio $USER_NAME
passwd $USER_NAME <<EOL
$USER_PASS
$USER_PASS
EOL

Info "Configure user shell"
sudo chsh $USER_NAME --shell /usr/bin/zsh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh > /tmp/oh-my-zsh.sh
exec_script_in_user /tmp/oh-my-zsh.sh --skip-chsh

tee $USER_HOME <<EOF
export ZSH="$HOME/.config/oh-my-zsh"
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
export EDITOR="nvim"
export XDG_CONFIG_HOME="$HOME/.config"

alias nv="nvim"
alias gs="git status"
alias pyenv="souce .venv/bin/activate"

ZSH_THEME="nicoulaj"
plugins=(git)
source $ZSH/oh-my-zsh.sh
EOF

Info "Give user sudo access"
uncomment /etc/sudoers "wheel ALL=(ALL:ALL) ALL"

#==============================
# Dev tools
#==============================
Info "Rust setup"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > /tmp/rustup.sh
exec_script_in_user /tmp/rustup.sh

Info "Docker setup"
usermod -aG docker $USER_NAME
[[ $ENABLE_DOCKER -eq 1 ]] && sudo systemctl enable --now docker

