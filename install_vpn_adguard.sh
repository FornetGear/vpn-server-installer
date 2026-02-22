#!/bin/bash

# =====================================================================================
#
#        FILE: install_vpn.sh
#
#       USAGE: curl -fsSL [URL_TO_THIS_SCRIPT] | bash
#         or: bash install_vpn.sh --domain my.domain.com --email me@example.com
#
# DESCRIPTION: Автоматическая установка и настройка VPN-сервера.
#
#      AUTHOR: Написано Gemini на основе предоставленных требований.
#     VERSION: 4.0.3 (Исправлен метод получения SSL на webroot, улучшен вызов 3x-ui)
#     CREATED: $(date)
#
# =====================================================================================

set -euo pipefail

# ===============================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И КОНСТАНТЫ
# ===============================================

readonly SCRIPT_VERSION="4.0.3"
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

AUTO_PASSWORD=false
AUTO_CONFIRM=false
DEBUG_MODE=false

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
log_debug() { if [[ "$DEBUG_MODE" == true ]]; then echo -e "${PURPLE}[DEBUG]${NC} $1"; fi; }

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
║        Enhanced VPN Server Auto Installer v4.0.3             ║
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
# РАЗБОР АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ===============================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -e|--email)
                EMAIL="$2"
                shift 2
                ;;
            --xui-user)
                XUI_USERNAME="$2"
                shift 2
                ;;
            --xui-pass)
                XUI_PASSWORD="$2"
                shift 2
                ;;
            --adguard-pass)
                ADGUARD_PASSWORD="$2"
                shift 2
                ;;
            --vless-port)
                VLESS_PORT="$2"
                shift 2
                ;;
            --xui-port)
                XUI_PORT="$2"
                shift 2
                ;;
            --adguard-port)
                ADGUARD_PORT="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_CONFIRM=true
                shift
                ;;
            --auto-password)
                AUTO_PASSWORD=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                set -x
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo
                echo "  -d, --domain DOMAIN          Домен для сертификата и панелей"
                echo "  -e, --email EMAIL            Email для Let's Encrypt"
                echo "      --xui-user USER          Логин для 3X-UI (по умолчанию: admin)"
                echo "      --xui-pass PASS          Пароль для 3X-UI"
                echo "      --adguard-pass PASS      Пароль для AdGuard Home"
                echo "      --vless-port PORT        Порт VLESS (по умолчанию: 2087)"
                echo "      --xui-port PORT          Порт панели 3X-UI (по умолчанию: 54321)"
                echo "      --adguard-port PORT      Порт панели AdGuard (по умолчанию: 3000)"
                echo "  -y, --yes                    Не задавать вопросов, всё подтверждать автоматически"
                echo "      --auto-password          Генерировать пароли автоматически"
                echo "      --debug                  Включить отладочный вывод"
                echo "  -h, --help                   Показать эту справку"
                exit 0
                ;;
            *)
                log_warn "Неизвестный аргумент: $1 (игнорируем)"
                shift
                ;;
        esac
    done
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
    # shellcheck source=/dev/null
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
# УСТАНОВКА И НАСТРОЙКА
# ===============================================

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
generate_password() { < /dev/urandom tr -dc 'A-Za-z0-9' | head -c${1:-16}; }

get_user_input() {
    print_header "НАСТРОЙКА ПАРАМЕТРОВ"
    if [[ -z "$DOMAIN" ]]; then
        while true; do read -p "Введите ваш домен: " DOMAIN; if validate_domain "$DOMAIN"; then break; else log_error "Неверный формат домена."; fi; done
    elif ! validate_domain "$DOMAIN"; then log_error "Неверный домен: $DOMAIN"; exit 1; fi
    log_info "Домен: $DOMAIN"
    if [[ -z "$EMAIL" ]]; then
        while true; do read -p "Введите ваш email для SSL: " EMAIL; if validate_email "$EMAIL"; then break; else log_error "Неверный формат email."; fi; done
    elif ! validate_email "$EMAIL"; then log_error "Неверный email: $EMAIL"; exit 1; fi
    log_info "Email: $EMAIL"
    if [[ -z "$XUI_PASSWORD" ]]; then
        if [[ "$AUTO_PASSWORD" == true ]]; then XUI_PASSWORD=$(generate_password); log_info "Пароль 3X-UI сгенерирован.";
        else read -p "Пароль 3X-UI [Enter для генерации]: " XUI_PASSWORD; [[ -z "$XUI_PASSWORD" ]] && XUI_PASSWORD=$(generate_password) && log_info "Пароль 3X-UI сгенерирован."; fi
    fi
    if [[ -z "$ADGUARD_PASSWORD" ]]; then
        if [[ "$AUTO_PASSWORD" == true ]]; then ADGUARD_PASSWORD=$(generate_password); log_info "Пароль AdGuard сгенерирован.";
        else read -p "Пароль AdGuard [Enter для генерации]: " ADGUARD_PASSWORD; [[ -z "$ADGUARD_PASSWORD" ]] && ADGUARD_PASSWORD=$(generate_password) && log_info "Пароль AdGuard сгенерирован."; fi
    fi
    if [[ "$AUTO_CONFIRM" != true ]]; then
        echo -e "\n${YELLOW}Проверьте параметры:${NC}\n  Домен: $DOMAIN\n  Email: $EMAIL\n  Порт VLESS: $VLESS_PORT"
        read -p "Продолжить установку? (y/n): " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then log_info "Установка отменена."; exit 0; fi
    fi
}

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
        log_warn "Не удалось разрешить DNS-имя $DOMAIN. Убедитесь, что A-запись указывает на $SERVER_IP."
        sleep 5
    elif [[ "$resolved_ip" != "$SERVER_IP" ]]; then
        log_error "DNS домена $DOMAIN указывает на $resolved_ip, а не на IP сервера $SERVER_IP. Исправьте A-запись."
        exit 1
    else
        log_info "DNS запись домена корректна ✅"
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

    log_info "Настройка временного Nginx для проверки Certbot..."
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

    log_info "Запрос сертификата для $DOMAIN через webroot..."
    certbot certonly \
        --webroot -w /var/www/html \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --quiet

    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        log_error "Certbot сообщил об успехе, но файл сертификата не найден!"
        log_error "Проверьте лог /var/log/letsencrypt/letsencrypt.log для деталей."
        exit 1
    fi

    log_info "SSL сертификат успешно получен ✅"
    systemctl stop nginx

    (crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
    log_info "Автообновление SSL настроено ✅"
}

install_3x_ui() {
    print_header "УСТАНОВКА ПАНЕЛИ 3X-UI"
    log_info "Запуск неинтерактивного установщика 3X-UI..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) install

    log_info "Настройка 3X-UI для работы через reverse proxy..."
    /usr/local/x-ui/x-ui setting -username "$XUI_USERNAME" -password "$XUI_PASSWORD" -port "$XUI_PORT" -listen "127.0.0.1" >/dev/null

    systemctl restart x-ui
    if systemctl is-active --quiet x-ui; then
        log_info "Панель 3X-UI установлена и запущена ✅"
    else
        log_error "Панель 3X-UI не запустилась. Логи: journalctl -u x-ui"
        exit 1
    fi
}

install_adguard() {
    print_header "УСТАНОВКА ADGUARD HOME"
    log_info "Загрузка и установка AdGuard Home..."
    local url="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
    wget -qO- "$url" | tar -xz -C /tmp
    mkdir -p /opt/AdGuardHome
    mv /tmp/AdGuardHome/* /opt/AdGuardHome
    rm -rf /tmp/AdGuardHome

    log_info "Установка AdGuard Home как сервиса и первоначальная настройка..."
    /opt/AdGuardHome/AdGuardHome -s install >/dev/null

    log_info "Создание финальной конфигурации AdGuard Home..."
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
    - https://dns.google.com/dns-query
  bootstrap_dns: [1.1.1.1, 8.8.8.8]
schema_version: 27
EOF
    systemctl restart AdGuardHome
    if systemctl is-active --quiet AdGuardHome; then
        log_info "AdGuard Home установлен и запущен ✅"
    else
        log_error "AdGuard Home не запустился. Логи: journalctl -u AdGuardHome"
        exit 1
    fi
}

# ===============================================
# ФИНАЛЬНАЯ НАСТРОЙКА И ИНСТРУКЦИИ
# ===============================================

configure_final_nginx() {
    print_header "НАСТРОЙКА REVERSE PROXY NGINX"
    log_info "Создание финальной конфигурации Nginx..."
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
    log_info "Финальная конфигурация Nginx применена ✅"
}

create_main_page() {
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>🛡️ VPN Server - $DOMAIN</title><style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:20px;color:#fff;text-align:center}.container{max-width:800px;margin:40px auto;background:rgba(255,255,255,0.1);border-radius:20px;box-shadow:0 15px 35px rgba(0,0,0,0.2);backdrop-filter:blur(10px);border:1px solid rgba(255,255,255,0.2);padding:40px}h1{font-size:2.8rem;margin-bottom:10px}p{font-size:1.2rem;margin-bottom:30px}.button-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px}.button{display:block;padding:20px;background:rgba(255,255,255,0.2);color:white;text-decoration:none;border-radius:12px;font-weight:500;transition:background .3s;font-size:1.1rem}.button:hover{background:rgba(255,255,255,0.3)}.footer{margin-top:40px;font-size:.9rem;opacity:.7}</style></head><body><div class="container"><h1>🛡️ VPN Сервер Активен</h1><p>Ваше подключение к сети теперь под защитой.</p><div class="button-grid"><a href="/xui/" class="button" target="_blank">Панель управления 3X-UI</a><a href="/adguard/" class="button" target="_blank">Панель управления AdGuard</a></div><p style="margin-top:30px;font-size:1rem">Данные для входа в файле <code>/root/vpn_server_info.txt</code></p><div class="footer"><p>Сервер настроен с помощью $SCRIPT_NAME v$SCRIPT_VERSION</p></div></div></body></html>
EOF
}

create_cli_commands() {
    print_header "СОЗДАНИЕ CLI УТИЛИТ"
    cat > /usr/local/bin/vpn-status <<'EOF'
#!/bin/bash
echo "--- Nginx ---"; systemctl status nginx --no-pager; echo -e "\n--- 3X-UI ---"; systemctl status x-ui --no-pager; echo -e "\n--- AdGuard ---"; systemctl status AdGuardHome --no-pager
EOF
    cat > /usr/local/bin/vpn-restart <<'EOF'
#!/bin/bash
echo "Перезапуск сервисов..."; systemctl restart nginx x-ui AdGuardHome; echo "Готово."; vpn-status
EOF
    cat > /usr/local/bin/vpn-logs <<'EOF'
#!/bin/bash
if [[ -z "${1-}" ]]; then echo "Usage: vpn-logs [nginx|xui|adguard]"; exit 1; fi
journalctl -u "$1" -f
EOF
    cat > /usr/local/bin/vpn-ssl-renew <<'EOF'
#!/bin/bash
echo "Принудительное обновление SSL..."; certbot renew --force-renewal; echo "Готово."
EOF
    cat > /usr/local/bin/vpn-info <<'EOF'
#!/bin/bash
cat /root/vpn_server_info.txt
EOF
    create_uninstall_script
    chmod +x /usr/local/bin/vpn-*
    log_info "CLI утилиты созданы: vpn-status, vpn-restart, vpn-logs, vpn-ssl-renew, vpn-info ✅"
}

create_uninstall_script() {
    cat > "$UNINSTALL_SCRIPT_PATH" << EOF
#!/bin/bash
set -x
echo "Полное удаление VPN сервера..."
systemctl stop nginx x-ui AdGuardHome
/opt/AdGuardHome/AdGuardHome -s uninstall
rm -rf /opt/AdGuardHome /usr/local/x-ui /etc/nginx /var/www/html /usr/local/bin/vpn-* "$UNINSTALL_SCRIPT_PATH" "$LOG_FILE" "$STATE_FILE"
certbot delete --cert-name $DOMAIN --non-interactive
if command -v apt-get &>/dev/null; then apt-get purge --auto-remove -y nginx* certbot*;
else dnf remove -y nginx certbot; fi
if command -v ufw &>/dev/null; then ufw --force reset; fi
echo "Удаление завершено."
EOF
    chmod +x "$UNINSTALL_SCRIPT_PATH"
}

create_instructions() {
    print_header "СОЗДАНИЕ ФАЙЛА С ИНСТРУКЦИЯМИ"
    local info_file="/root/vpn_server_info.txt"
    cat > "$info_file" << EOF
╔═══════════════════════════════════════════════════════════════╗
║          ИНФОРМАЦИЯ О ВАШЕМ VPN-СЕРВЕРЕ (Created: $(date))      ║
╚═══════════════════════════════════════════════════════════════╝
Домен: $DOMAIN
IP-адрес: $SERVER_IP
╔═══════════════════════════════════════════════════════════════╗
║                      ДОСТУП К ПАНЕЛЯМ                      ║
╚═══════════════════════════════════════════════════════════════╝
🌐 Главная: https://$DOMAIN/
📊 3X-UI (VLESS):
   URL: https://$DOMAIN/xui/
   Логин: $XUI_USERNAME
   Пароль: $XUI_PASSWORD
🛡️ AdGuard Home (DNS):
   URL: https://$DOMAIN/adguard/
   Логин: admin
   Пароль: $ADGUARD_PASSWORD
╔═══════════════════════════════════════════════════════════════╗
║                  КЛЮЧЕВАЯ НАСТРОЙКА VLESS                    ║
╚═══════════════════════════════════════════════════════════════╝
1. Зайдите в панель 3X-UI и создайте 'Inbound'.
2. Протокол: vless
3. Порт: $VLESS_PORT (уже открыт в firewall)
4. Сеть (Network): tcp
5. Безопасность (Security): tls
6. SNI (Server Name) и Host: $DOMAIN
7. Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem
8. Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem
╔═══════════════════════════════════════════════════════════════╗
║                КОМАНДЫ ДЛЯ УПРАВЛЕНИЯ В ТЕРМИНАЛЕ            ║
╚═══════════════════════════════════════════════════════════════╝
 vpn-status         - Показать статус всех сервисов
 vpn-restart        - Перезапустить все сервисы
 vpn-logs [service] - Показать логи (nginx, xui, adguard)
 vpn-ssl-renew      - Принудительно обновить SSL-сертификат
 vpn-info           - Показать этот файл
 uninstall_vpn_server.sh - ПОЛНОСТЬЮ удалить все компоненты
ВАЖНО: СОХРАНИТЕ ЭТОТ ФАЙЛ В НАДЕЖНОМ МЕСТЕ!
EOF
    chmod 600 "$info_file"
    log_info "Файл с инструкциями и паролями создан: $info_file"
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
    log_info "🎉 Установка полностью завершена! Ваш сервер готов."
}

main "$@"
