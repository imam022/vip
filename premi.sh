#!/bin/bash
# ========================================================
# Quick Setup VPN Server (Full Modernized Release)
# Support: Ubuntu 20.04 / 22.04 / 24.04 & Debian 10 / 11 / 12
# ========================================================

export DEBIAN_FRONTEND=noninteractive
Green="\e[92;1m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
FONT="\033[0m"
OK="${Green}--->${FONT}"
ERROR="${RED}[ERROR]${FONT}"
NC='\e[0m'

clear
if [ "${EUID}" -ne 0 ]; then
    echo -e "${ERROR} Anda harus menjalankan script ini sebagai root!"
    exit 1
fi

if [ "$(systemd-detect-virt)" == "openvz" ]; then
    echo -e "${ERROR} OpenVZ tidak didukung!"
    exit 1
fi

# Cek Arsitektur Mesin
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    echo -e "${ERROR} Arsitektur $ARCH tidak didukung! Harus x86_64."
    exit 1
fi

# Deteksi IP Publik Server
MYIP=$(curl -sS ipv4.icanhazip.com || curl -sS ifconfig.me || curl -sS ipinfo.io/ip)
if [[ -z "$MYIP" ]]; then
    echo -e "${ERROR} IP Publik tidak terdeteksi!"
    exit 1
fi

REPO="https://raw.githubusercontent.com/imam022/vip/main/"
start=$(date +%s)

function print_ok() { echo -e "${OK} ${BLUE}$1${FONT}"; }
function print_install() {
    echo -e "${Green}=========================================${FONT}"
    echo -e "${YELLOW}# $1 ${FONT}"
    echo -e "${Green}=========================================${FONT}"
}
function print_success() {
    echo -e "${Green}---> $1 berhasil dipasang.${FONT}"
    sleep 1
}

# 1. Persiapan Direktori & Basis Sistem
function first_setup(){
    print_install "Menyiapkan Direktori & Dependensi Sistem"
    timedatectl set-timezone Asia/Jakarta
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

    mkdir -p /etc/xray /var/log/xray /var/lib/kyt /var/www/html /run/xray /usr/local/kyt /usr/local/share/xray /usr/local/bin
    chown -R www-data:www-data /var/log/xray /run/xray
    touch /var/log/xray/access.log /var/log/xray/error.log
    chmod +x /var/log/xray

    mkdir -p /etc/kyt/limit/vmess/ip /etc/kyt/limit/vless/ip /etc/kyt/limit/trojan/ip /etc/kyt/limit/ssh/ip
    mkdir -p /etc/limit/vmess /etc/limit/vless /etc/limit/trojan /etc/limit/ssh
    mkdir -p /etc/vmess /etc/vless /etc/trojan /etc/shadowsocks /etc/ssh /etc/bot

    touch /etc/vmess/.vmess.db /etc/vless/.vless.db /etc/trojan/.trojan.db /etc/shadowsocks/.shadowsocks.db /etc/ssh/.ssh.db /etc/bot/.bot.db

    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

    apt update -y
    apt install -y software-properties-common haproxy nginx
    print_success "Dependensi Dasar"
}

# 2. Pemasangan Paket Lengkap
function base_package() {
    print_install "Memasang Paket Sistem, Python 3 & Utilitas Jaringan"
    apt install -y zip unzip tar curl wget git jq socat cron bash-completion \
        iptables iptables-persistent netfilter-persistent net-tools \
        openssl ca-certificates gnupg lsof htop bc rsyslog dos2unix \
        python3 python3-pip openvpn easy-rsa vnstat dropbear chrony

    systemctl enable chrony >/dev/null 2>&1
    systemctl restart chrony >/dev/null 2>&1
    print_success "Paket Pendukung Selesai Dipasang"
}

# 3. Input & Konfigurasi Domain
function pasang_domain() {
    clear
    echo -e "   .----------------------------------."
    echo -e "   |     PILIH SUMBER DOMAIN SERVER   |"
    echo -e "   '----------------------------------'"
    echo -e "     1) Domain Sendiri (Subdomain sudah di-pointing ke IP)"
    echo -e "     2) Domain Acak (Script Cloudflare)"
    echo -e "   ------------------------------------"
    read -p "   Pilih angka (1 atau 2): " host
    if [[ $host == "2" ]]; then
        wget -q -O cf.sh "${REPO}limit/cf.sh" && chmod +x cf.sh && ./cf.sh
        rm -f cf.sh
    else
        read -p "   Masukkan Subdomain Anda: " host1
        echo "$host1" > /etc/xray/domain
        echo "$host1" > /root/domain
    fi
    domain=$(cat /etc/xray/domain)
    print_success "Domain Terdaftar: $domain"
}

# 4. Pemasangan SSL Let's Encrypt
function pasang_ssl() {
    print_install "Menerbitkan Sertifikat SSL Let's Encrypt"
    domain=$(cat /etc/xray/domain)
    
    systemctl stop nginx >/dev/null 2>&1
    systemctl stop haproxy >/dev/null 2>&1
    
    rm -rf /root/.acme.sh
    curl -s https://get.acme.sh | sh -s email=admin@$domain
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --force
    
    /root/.acme.sh/acme.sh --installcert -d "$domain" \
        --fullchainpath /etc/xray/xray.crt \
        --keypath /etc/xray/xray.key --ecc
        
    chmod 644 /etc/xray/xray.crt
    chmod 600 /etc/xray/xray.key
    
    cat /etc/xray/xray.crt /etc/xray/xray.key > /etc/haproxy/hap.pem
    chmod 600 /etc/haproxy/hap.pem
    print_success "Sertifikat SSL"
}

# 5. Core Xray Terbaru & Konfigurasi Multiplexing
function install_xray() {
    print_install "Memasang Core Xray & Konfigurasi Multiplexer"
    
    mkdir -p /usr/local/share/xray /usr/local/bin /etc/xray
    
    # Ambil Core Xray Resmi Release Terbaru Langsung (Aman dari bug script install.sh lama)
    latest_xray=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f 4)
    if [[ -z "$latest_xray" ]]; then
        latest_xray="v1.8.24"
    fi
    wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${latest_xray}/Xray-linux-64.zip"
    unzip -q -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    rm -rf /tmp/xray /tmp/xray.zip

    # Unduh database geosite & geoip resmi
    wget -q -O /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    wget -q -O /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

    # Daftarkan Xray Service Systemd
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    # Unduh file config hasil revisi
    wget -q -O /etc/xray/config.json "${REPO}config.json"
    wget -q -O /etc/haproxy/haproxy.cfg "${REPO}haproxy.cfg"
    wget -q -O /etc/nginx/conf.d/xray.conf "${REPO}xray.conf"
    
    domain=$(cat /etc/xray/domain)
    sed -i "s/xxx/${domain}/g" /etc/haproxy/haproxy.cfg
    sed -i "s/xxx/${domain}/g" /etc/nginx/conf.d/xray.conf
    
    print_success "Core Xray & Konfigurasi Multiplexing"
}

# 6. Service SSH & WebSocket Proxy (Python 3 Native)
function ins_ssh_ws(){
    print_install "Menyiapkan SSH, Dropbear & WebSocket Proxy"
    
    sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config
    sed -i 's/AcceptEnv/#AcceptEnv/g' /etc/ssh/sshd_config
    
    cat <<EOF > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=143
DROPBEAR_EXTRA_ARGS="-p 109"
DROPBEAR_BANNER="/etc/kyt.txt"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
    echo "Banner /etc/kyt.txt" >> /etc/ssh/sshd_config
    echo "Welcome to Premium VPN Server" > /etc/kyt.txt

    wget -q -O /usr/bin/ws "${REPO}ws.py"
    chmod +x /usr/bin/ws
    
    cat <<EOF > /etc/systemd/system/ws.service
[Unit]
Description=WebSocket SSH Python3 Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/bin/ws 10015
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ws >/dev/null 2>&1
    systemctl restart ws >/dev/null 2>&1
    systemctl restart dropbear >/dev/null 2>&1
    systemctl restart ssh >/dev/null 2>&1
    print_success "Layanan SSH & Dropbear WebSocket"
}

# 7. Modul Limitasi & Monitoring
function setup_limits(){
    print_install "Menyiapkan Service Limit IP & Limit Quota"
    
    wget -q -O /usr/bin/limit-ip "${REPO}limit-ip"
    wget -q -O /usr/bin/quota "${REPO}quota"
    chmod +x /usr/bin/limit-ip /usr/bin/quota

    cat <<EOF > /etc/systemd/system/quota.service
[Unit]
Description=Xray Quota Auto Check Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/quota
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    for proto in vmip vlip trip; do
        cat <<EOF > /etc/systemd/system/${proto}.service
[Unit]
Description=Limit IP Service for ${proto}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/limit-ip ${proto}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable ${proto} >/dev/null 2>&1
        systemctl restart ${proto} >/dev/null 2>&1
    done

    systemctl daemon-reload
    systemctl enable quota >/dev/null 2>&1
    systemctl restart quota >/dev/null 2>&1
    print_success "Modul Limitasi"
}

# 8. Konfigurasi Jaringan, BBR, Swap & Anti-Torrent
function system_tuning(){
    print_install "Optimasi Kernel, TCP BBR & Firewall Anti-Torrent"
    
    if [ ! -f /swapfile ]; then
        dd if=/dev/zero of=/swapfile bs=1024 count=1048576 >/dev/null 2>&1
        mkswap /swapfile >/dev/null 2>&1
        chmod 0600 /swapfile
        swapon /swapfile >/dev/null 2>&1
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    iptables -F FORWARD
    iptables -A FORWARD -m string --algo bm --string "BitTorrent" -j DROP
    iptables -A FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP
    iptables -A FORWARD -m string --algo bm --string "peer_id=" -j DROP
    iptables -A FORWARD -m string --algo bm --string ".torrent" -j DROP
    iptables -A FORWARD -m string --algo bm --string "announce.php?passkey=" -j DROP
    iptables -A FORWARD -m string --algo bm --string "torrent" -j DROP
    iptables -A FORWARD -m string --algo bm --string "info_hash" -j DROP
    netfilter-persistent save >/dev/null 2>&1
    netfilter-persistent reload >/dev/null 2>&1

    cat <<EOF > /etc/rc.local
#!/bin/sh -e
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
exit 0
EOF
    chmod +x /etc/rc.local
    systemctl enable rc-local >/dev/null 2>&1
    systemctl start rc-local >/dev/null 2>&1
    print_success "Optimasi Sistem"
}

# 9. Pemasangan Menu CLI (Handle Nested Directory)
function install_menu(){
    print_install "Memasang Menu CLI Management"
    if wget -q --spider "${REPO}limit/menu.zip"; then
        rm -rf /tmp/menu /tmp/menu.zip
        wget -q -O /tmp/menu.zip "${REPO}limit/menu.zip"
        mkdir -p /tmp/menu
        unzip -q -o /tmp/menu.zip -d /tmp/menu/
        
        # Salin file eksekutor baik yang berada di root zip maupun di dalam subfolder menu
        if [ -d "/tmp/menu/menu" ]; then
            cp -r /tmp/menu/menu/* /usr/local/sbin/
        else
            cp -r /tmp/menu/* /usr/local/sbin/
        fi
        
        chmod +x /usr/local/sbin/*
        rm -rf /tmp/menu /tmp/menu.zip
    fi

    cat <<EOF > /root/.profile
if [ "\$BASH" ]; then
    if [ -f ~/.bashrc ]; then
        . ~/.bashrc
    fi
fi
mesg n || true
[ -f /usr/local/sbin/menu ] && menu
EOF
    chmod 644 /root/.profile
    print_success "Menu CLI"
}

# 10. Pengaktifan Seluruh Service
function start_all_services(){
    print_install "Menjalankan Ulang Seluruh Service"
    systemctl daemon-reload
    systemctl enable --now nginx haproxy xray cron dropbear ws
    systemctl restart nginx haproxy xray cron dropbear ws
    print_success "Semua Service Aktif Normal"
}

# Eksekusi Rangkaian
first_setup
base_package
pasang_domain
pasang_ssl
install_xray
ins_ssh_ws
setup_limits
system_tuning
install_menu
start_all_services

total_time=$(($(date +%s) - start))
clear
echo -e "${Green}=====================================================${NC}"
echo -e "${Green}   INSTALASI TUNNELING SERVER BERHASIL DISELESAIKAN   ${NC}"
echo -e "${Green}=====================================================${NC}"
echo -e " Domain Server : $(cat /etc/xray/domain)"
echo -e " IP Server     : $MYIP"
echo -e " Waktu Pasang  : $((total_time / 60)) menit $((total_time % 60)) detik"
echo -e "${Green}=====================================================${NC}"
echo -e " Ketik ${YELLOW}menu${NC} untuk membuka panel administrasi."
echo ""
read -p "Tekan [Enter] untuk me-reboot server..."
reboot
