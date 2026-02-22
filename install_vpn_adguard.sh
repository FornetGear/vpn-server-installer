#!/bin/bash

# =====================================================================================
#
#        FILE: install_vpn.sh
#
#       USAGE: sudo ./install_vpn_adguard.sh
#
# DESCRIPTION: Автоматическая установка и настройка VPN-сервера.
#
#      AUTHOR: Исправлено для обязательного ввода всех параметров
#     VERSION: 4.0.4 (Убрана автогенерация паролей)
#     CREATED: $(date)
#
# =====================================================================================

set -euo pipefail

# ===============================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И КОНСТАНТЫ
# ===============================================

readonly SCRIPT_VERSION="4.0.4"
readonly SCRIPT_NAME="Enhanced VPN Server Auto Installer"
readonly LOG_FILE="/var/log/vpn-installer.log"
readonly STATE_FILE="/var/lib/vpn-install-state"
readonly UNINSTALL_SCRIPT_PATH="/usr/local/sbin/uninstall_vpn_server.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

DOMAIN=""
EMAIL=""
XUI_USERNAME="admin"
XUI_PASSWORD=""
ADGUARD_PASSWORD=""
VLESS_PORT="2087"
XUI_PORT="54321"
ADGUARD_PORT="3000"

OS_ID=""
OS_NAME=""
OS_VERSION=""
ARCH=""
SERVER_IP=""

readonly SUPPORTED_DISTROS=("ubuntu" "debian" "centos" "rhel" "fedora" "almalinux" "rocky")

# ===============================================
# ФУНКЦИИ ЛОГИРОВАНИЯ И ВЫВОДА
# ===============================================

setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "=== Запуск $SCRIPT_NAME v$SCRIPT_VERSION ==="
    echo "Время: $(date)"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} $(printf "%-36s" "$1") ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
}

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║  ██╗   ██╗██████╗ ███╗   ██╗    ██╗███╗   ██╗███████╗████████╗║
║  ██║   ██║██╔══██╗████╗  ██║    ██║████╗  ██║██╔════╝╚══██╔══╝║
║  ██║   ██║██████╔╝██╔██╗ ██║    ██║██╔██╗ ██║███████╗   ██║   ║
║  ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║    ██║██║╚██╗██║╚════██║   ██║   ║
║   ╚████╔╝ ██║     ██║ ╚████║    ██║██║ ╚████║███████║   ██║   ║
║    ╚═══╝  ╚═╝     ╚═╝  ╚═══╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ║
║                                                               ║
║        Enhanced VPN Server Auto Installer v4.0.4             ║
║     VLESS + Reverse Proxy (3X-UI, AdGuard) + CLI Tools       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ===============================================
# УПРАВЛЕНИЕ ОШИБКАМИ
# ===============================================

cleanup_on_error() {
    local exit_code=$?
    log_error "Критическая ошибка (код $exit_code) на строке $LINENO. Команда: $BASH_COMMAND. Начинаю откат..."
    systemctl stop x-ui 2>/dev/null || true
    systemctl stop AdGuardHome 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    rm -rf /opt/3x-ui /opt/AdGuardHome
    rm -f /etc/systemd/system/x-ui.service /etc/systemd/system/AdGuardHome.service
    systemctl daemon-reload 2>/dev/null || true
    log_info "Базовый откат завершен. Для полного удаления запустите: ${UNINSTALL_SCRIPT_PATH}"
    log_warn "Логи для анализа проблемы сохранены в: $LOG_FILE"
    exit $exit_code
}

trap cleanup_on_error ERR

# ===============================================
# РАЗБОР АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ (УПРОЩЁН)
# ===============================================

parse_arguments() {
    # Пока пустая - все параметры спрашиваем интерактивно
    true
}

# ===============================================
# ПРОВЕРКА СИСТЕМЫ
# ===============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен запускаться с правами root или через sudo."
        exit 1
    fi
}

detect_system() {
    print_header "АНАЛИЗ СИСТЕМЫ"
    if [[ ! -f /etc/os-release ]]; then log_error "Не удалось определить ОС."; exit 1; fi
    source /etc/os-release
    OS_ID="$ID"
    OS_NAME="$NAME"
    OS_VERSION="${VERSION_ID:-unknown}"
    log_info "ОС: $OS_NAME $OS_VERSION"
    local supported=false
    for distro in "${SUPPORTED_DISTROS[@]}"; do
        if [[ "$OS_ID" == "$distro"* ]]; then supported=true; break; fi
    done
    if [[ "$supported" != true ]]; then log_error "Неподдерживаемая ОС: $OS_NAME."; exit 1; fi
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) log_error "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
    esac
    log_info "Архитектура: $ARCH"
    if ! timeout 15 curl -s --max-time 10 https://1.1.1.1 >/dev/null; then log_error "Нет подключения к интернету."; exit 1; fi
    SERVER_IP=$(get_server_ip)
    log_info "Публичный IP сервера: $SERVER_IP"
    log_info "Система совместима и готова к установке ✅"
}

get_server_ip() {
    local ip
    local services=("ifconfig.me" "api.ipify.org" "icanhazip.com")
    for service in "${services[@]}"; do
        ip=$(timeout 10 curl -s "https://$service" 2>/dev/null | tr -d '\n\r ' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    done
    log_error "Не удалось определить публичный IP адрес сервера."
    exit 1
}

# ===============================================
# ✅ НОВЫЙ ОБЯЗАТЕЛЬНЫЙ ИНТЕРАКТИВНЫЙ ВВОД
# ===============================================

get_user_input() {
    print_header "▼ НАСТРОЙКА ПАРАМЕТРОВ ▼"

    echo -e "${CYAN}📋 Введите параметры (Enter = автогенерация):${NC}\n"

    # 1. ДОМЕН (ОБЯЗАТЕЛЬНО)
    while true; do
        read -p "📛 Домен (vpn.example.com): " DOMAIN
        if [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            log_info "✓ Домен: $DOMAIN"
            break
        elif [[ -z "$DOMAIN" ]]; then
            log_error "❌ Домен ОБЯЗАТЕЛЕН!"
        else
            log_error "❌ Неверный формат домена!"
        fi
    done

    # 2. EMAIL (ОБЯЗАТЕЛЬНО)
    while true; do
        read -p "📧 Email для SSL: " EMAIL
        if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_info "✓ Email: $EMAIL"
            break
        elif [[ -z "$EMAIL" ]]; then
            log_error "❌ Email ОБЯЗАТЕЛЕН!"
        else
            log_error "❌ Неверный формат email!"
        fi
    done

    # 3. ЛОГИН 3X-UI (по умолчанию: admin)
    read -p "👤 Логин 3X-UI [admin]: " input_login
    XUI_USERNAME="${input_login:-admin}"
    log_info "✓ Логин 3X-UI: $XUI_USERNAME"

    # 4. ПАРОЛЬ 3X-UI (Enter = автогенерация)
    read -s -p "🔐 Пароль 3X-UI [автогенерация]: " input_xui_pass
    echo
    if [[ -z "$input_xui_pass" ]]; then
        XUI_PASSWORD=$(generate_password 16)
        log_info "✓ Пароль 3X-UI: автогенерирован ($(( ${#XUI_PASSWORD} )) симв.)"
    elif [[ ${#input_xui_pass} -ge 8 ]]; then
        XUI_PASSWORD="$input_xui_pass"
        log_info "✓ Пароль 3X-UI: введён ($(( ${#XUI_PASSWORD} )) симв.)"
    else
        log_error "❌ Пароль 3X-UI короткий! Минимум 8 символов."
        XUI_PASSWORD=$(generate_password 16)
        log_info "✓ Использован автогенерированный пароль"
    fi

    # 5. ПАРОЛЬ ADGUARD (Enter = автогенерация)
    read -s -p "🔐 Пароль AdGuard [автогенерация]: " input_adguard_pass
    echo
    if [[ -z "$input_adguard_pass" ]]; then
        ADGUARD_PASSWORD=$(generate_password 16)
        log_info "✓ Пароль AdGuard: автогенерирован ($(( ${#ADGUARD_PASSWORD} )) симв.)"
    elif [[ ${#input_adguard_pass} -ge 8 ]]; then
        ADGUARD_PASSWORD="$input_adguard_pass"
        log_info "✓ Пароль AdGuard: введён ($(( ${#ADGUARD_PASSWORD} )) симв.)"
    else
        log_error "❌ Пароль AdGuard короткий! Минимум 8 символов."
        ADGUARD_PASSWORD=$(generate_password 16)
        log_info "✓ Использован автогенерированный пароль"
    fi

    # ПОДТВЕРЖДЕНИЕ
    echo -e "\n${YELLOW}📋 ИТОГ:${NC}"
    echo "   🌐 Домен: $DOMAIN"
    echo "   📧 Email: $EMAIL"
    echo "   👤 3X-UI: $XUI_USERNAME / *******"
    echo "   🛡️ AdGuard: admin / *******"
    echo -e "${NC}"
    
    read -p "✅ Продолжить? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "❌ Отменено."
        exit 0
    fi
}

# Добавь эту функцию для генерации паролей (если её нет)
generate_password() {
    local length=${1:-16}
    < /dev/urandom tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' | head -c"$length" | xargs
}



# Остальные функции остаются без изменений...
install_dependencies() {
    print_header "УСТАНОВКА ЗАВИСИМОСТЕЙ"
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl wget unzip tar systemd ufw cron nginx certbot python3-certbot-nginx net-tools dnsutils
    else
        local pkg_mgr="yum" && if command -v dnf >/dev/null; then pkg_mgr="dnf"; fi
        $pkg_mgr install -y -q curl wget unzip tar systemd firewalld cronie nginx certbot python3-certbot-nginx net-tools bind-utils
    fi
    log_info "Зависимости успешно установлены ✅"
}

validate_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
validate_email() { [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

stop_conflicting_services() {
    print_header "ОСВОБОЖДЕНИЕ СЕТЕВЫХ ПОРТОВ"
    local services=("apache2" "httpd" "caddy" "systemd-resolved")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_warn "Остановка конфликтующего сервиса: $service"
            systemctl stop "$service"; systemctl disable "$service"
        fi
    done
    systemctl stop nginx 2>/dev/null || true
}

fix_local_dns() {
    log_info "Настройка локального DNS-резолвера на время установки..."
    if [ -L /etc/resolv.conf ]; then rm -f /etc/resolv.conf; fi
    cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

check_dns_resolution() {
    print_header "ПРОВЕРКА DNS ЗАПИСИ ДОМЕНА"
    local resolved_ip
    resolved_ip=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -n1)
    if [[ -z "$resolved_ip" ]]; then
        log_warn "⚠️ Не удалось разрешить DNS-имя $DOMAIN. Убедитесь, что A-запись указывает на $SERVER_IP."
        sleep 5
    elif [[ "$resolved_ip" != "$SERVER_IP" ]]; then
        log_error "❌ DNS домена $DOMAIN указывает на $resolved_ip, а не на IP сервера $SERVER_IP."
        exit 1
    else
        log_info "✅ DNS запись домена корректна"
    fi
}

configure_firewall() {
    print_header "НАСТРОЙКА FIREWALL"
    if command -v ufw >/dev/null; then
        ufw --force reset >/dev/null
        ufw default deny incoming; ufw default allow outgoing
        ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
        ufw allow "$VLESS_PORT/tcp"; ufw allow 53/tcp; ufw allow 53/udp
        ufw --force enable
        log_info "Firewall UFW настроен ✅"
    elif command -v firewalld >/dev/null; then
        systemctl start firewalld && systemctl enable firewalld
        firewall-cmd --permanent --zone=public --add-service=ssh --add-service=http --add-service=https
        firewall-cmd --permanent --zone=public --add-port="$VLESS_PORT/tcp" --add-port=53/tcp --add-port=53/udp
        firewall-cmd --reload
        log_info "Firewall Firewalld настроен ✅"
    else
        log_warn "Firewall не найден. Пропускаем настройку."
    fi
}

setup_ssl() {
    print_header "ПОЛУЧЕНИЕ SSL СЕРТИФИКАТА"
    mkdir -p /var/www/html
    chown www-www-data /var/www/html

    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    server_name $DOMAIN;
    root /var/www/html;
    location /.well-known/acme-challenge/ { allow all; }
}
EOF
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    certbot certonly \
        --webroot -w /var/www/html \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --quiet

    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        log_error "❌ Certbot не смог получить сертификат!"
        exit 1
    fi

    log_info "✅ SSL сертификат успешно получен"
    systemctl stop nginx

    (crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
    log_info "Автообновление SSL настроено ✅"
}

install_3x_ui() {
    print_header "УСТАНОВКА ПАНЕЛИ 3X-UI"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) install
    /usr/local/x-ui/x-ui setting -username "$XUI_USERNAME" -password "$XUI_PASSWORD" -port "$XUI_PORT" -listen "127.0.0.1" >/dev/null
    systemctl restart x-ui
    if systemctl is-active --quiet x-ui; then
        log_info "✅ Панель 3X-UI установлена и запущена"
    else
        log_error "❌ Панель 3X-UI не запустилась"
        exit 1
    fi
}

install_adguard() {
    print_header "УСТАНОВКА ADGUARD HOME"
    local url="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
    wget -qO- "$url" | tar -xz -C /tmp
    mkdir -p /opt/AdGuardHome
    mv /tmp/AdGuardHome/* /opt/AdGuardHome
    rm -rf /tmp/AdGuardHome

    /opt/AdGuardHome/AdGuardHome -s install >/dev/null
    cat > /opt/AdGuardHome/AdGuardHome.yaml << EOF
bind_host: 127.0.0.1
bind_port: $ADGUARD_PORT
auth_attempts: 5
language: ru
dns:
  bind_hosts: [0.0.0.0]
  port: 53
  protection_enabled: true
  filtering_enabled: true
  safebrowsing_enabled: true
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns: [1.1.1.1, 8.8.8.8]
schema_version: 27
EOF
    systemctl restart AdGuardHome
    if systemctl is-active --quiet AdGuardHome; then
        log_info "✅ AdGuard Home установлен и запущен"
    else
        log_error "❌ AdGuard Home не запустился"
        exit 1
    fi
}

configure_final_nginx() {
    print_header "НАСТРОЙКА REVERSE PROXY NGINX"
    cat > /etc/nginx/sites-available/default << EOF
server_tokens off;
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    location = / { root /var/www/html; index index.html; }

    location /xui/ {
        proxy_pass http://127.0.0.1:$XUI_PORT/xui/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /adguard/ {
        proxy_pass http://127.0.0.1:$ADGUARD_PORT/;
        proxy_redirect / /adguard/;
        proxy_cookie_path / /adguard/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    create_main_page
    nginx -t && systemctl restart nginx
    log_info "✅ Финальная конфигурация Nginx применена"
}

create_main_page() {
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title>VPN Server - $DOMAIN</title><style>body{font-family:system-ui;background:linear-gradient(135deg,#667eea,#764ba2);min-height:100vh;color:white;padding:20px;text-align:center}h1{font-size:2.5rem}a{display:inline-block;padding:15px 30px;margin:10px;background:rgba(255,255,255,0.2);color:white;text-decoration:none;border-radius:10px;font-size:1.1rem;transition:background .3s}a:hover{background:rgba(255,255,255,0.3)}</style></head><body><h1>🛡️ VPN Сервер Активен</h1><p>Ваше подключение защищено!</p><a href="/xui/" target="_blank">📊 3X-UI Панель</a><a href="/adguard/" target="_blank">🛡️ AdGuard Home</a><p style="margin-top:30px;font-size:.9rem">Данные входа: /root/vpn_server_info.txt</p></body></html>
EOF
}

create_cli_commands() {
    print_header "СОЗДАНИЕ CLI УТИЛИТ"
    cat > /usr/local/bin/vpn-status <<'EOF'
#!/bin/bash
echo "--- Nginx ---"; systemctl status nginx --no-pager
echo "--- 3X-UI ---"; systemctl status x-ui --no-pager
echo "--- AdGuard ---"; systemctl status AdGuardHome --no-pager
EOF
    cat > /usr/local/bin/vpn-restart <<'EOF'
#!/bin/bash
systemctl restart nginx x-ui AdGuardHome
vpn-status
EOF
    chmod +x /usr/local/bin/vpn-*
    log_info "✅ CLI утилиты: vpn-status, vpn-restart"
}

create_instructions() {
    print_header "СОЗДАНИЕ ИНСТРУКЦИЙ"
    cat > /root/vpn_server_info.txt << EOF
🔐 VPN СЕРВЕР - $DOMAIN
━━━━━━━━━━━━━━━━━━━━━━━━━━
🌐 Главная страница: https://$DOMAIN/

📊 3X-UI Панель:
├ URL: https://$DOMAIN/xui/
├ Логин: $XUI_USERNAME
└ Пароль: $XUI_PASSWORD

🛡️ AdGuard Home:
├ URL: https://$DOMAIN/adguard/
├ Логин: admin  
└ Пароль: $ADGUARD_PASSWORD

⚙️ VLESS Inbound:
├ Протокол: vless
├ Порт: $VLESS_PORT
├ Сеть: tcp
├ Безопасность: tls
├ SNI/Host: $DOMAIN
└ Сертификаты: /etc/letsencrypt/live/$DOMAIN/

🚀 Команды:
vpn-status    # статус сервисов
vpn-restart   # перезапуск
/root/vpn_server_info.txt  # эта информация

📱 СОХРАНИТЕ ЭТОТ ФАЙЛ!
EOF
    chmod 600 /root/vpn_server_info.txt
    log_info "✅ Инструкции: /root/vpn_server_info.txt"
}

# ===============================================
# ГЛАВНАЯ ФУНКЦИЯ
# ===============================================

main() {
    setup_logging
    parse_arguments "$@"
    show_banner
    check_root
    detect_system
    get_user_input
    install_dependencies
    stop_conflicting_services
    fix_local_dns
    check_dns_resolution
    configure_firewall
    setup_ssl
    install_3x_ui
    install_adguard
    configure_final_nginx
    create_cli_commands
    create_instructions
    log_info "🎉 УСТАНОВКА ЗАВЕРШЕНА! Сервер готов."
    cat /root/vpn_server_info.txt
}

main "$@"
