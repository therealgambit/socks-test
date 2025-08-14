#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Пути
MANAGER_DIR="/etc/socks5-manager"
PROFILES_FILE="$MANAGER_DIR/profiles.json"
SCRIPT_PATH="/usr/local/bin/socks"
DANTE_CONFIG="/etc/danted.conf"
INSTALL_PATH="/opt/socks5-manager/install.sh"

# Вывод
print_status(){ echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error(){ echo -e "${RED}[ERROR]${NC} $1"; }
print_header(){ echo -e "${BLUE}================================${NC}\n${BLUE}$1${NC}\n${BLUE}================================${NC}"; }
print_success(){ echo -e "${GREEN}✓${NC} $1"; }

# -------------------- Инициализация --------------------
init_manager() {
    mkdir -p "$MANAGER_DIR" /opt/socks5-manager
    [ ! -f "$PROFILES_FILE" ] && echo "[]" > "$PROFILES_FILE" && print_status "Создана директория управления: $MANAGER_DIR"

    cp -f "$(realpath "$0")" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$SCRIPT_PATH"
    print_status "Создана команда быстрого доступа: socks"

    if [ -x "$SCRIPT_PATH" ]; then
        print_success "Команда 'socks' готова к использованию"
    else
        print_warning "Не удалось создать рабочую команду 'socks'"
    fi
}

install_dependencies() {
    print_status "Обновление пакетов и установка зависимостей..."
    apt update && apt install -y dante-server apache2-utils jq || {
        print_error "Ошибка при установке пакетов."
        exit 1
    }
}

# -------------------- Хелперы --------------------
generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        ! ss -tulnp | awk '{print $4}' | grep -q ":$port" && ! is_port_used_by_profiles "$port" && { echo $port; return; }
    done
}

is_port_used_by_profiles() { [ -f "$PROFILES_FILE" ] && jq -r '.[].port' "$PROFILES_FILE" | grep -q "^$1$"; }
get_next_profile_number() { local max=0; jq -r '.[].name' "$PROFILES_FILE" 2>/dev/null | while read n; do [[ "$n" =~ ^socks5-([0-9]+)$ ]] && (( ${BASH_REMATCH[1]} > max )) && max=${BASH_REMATCH[1]}; done; echo $((max+1)); }

generate_dante_config() {
    local IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -n1)
    {
        echo "logoutput: /var/log/danted.log"
        echo "user.privileged: root"
        echo "user.notprivileged: nobody"
        jq -r '.[].port' "$PROFILES_FILE" | while read port; do echo "internal: 0.0.0.0 port = $port"; done
        echo -e "\nexternal: $IFACE\nsocksmethod: username"
        echo -e "client pass {\n from: 0.0.0.0/0 to: 0.0.0.0/0\n log: error\n}\n"
        echo -e "socks pass {\n from: 0.0.0.0/0 to: 0.0.0.0/0\n method: username\n protocol: tcp udp\n log: error\n}"
    } > "$DANTE_CONFIG"
}

save_profile() {
    jq ". + [ {name:\"$1\", port:$2, username:\"$3\", password:\"$4\", created:\"$(date -Iseconds)\"} ]" \
       "$PROFILES_FILE" > "$PROFILES_FILE.tmp" && mv "$PROFILES_FILE.tmp" "$PROFILES_FILE"
}

profile_exists() { [ -f "$PROFILES_FILE" ] && jq -e ".[] | select(.name == \"$1\")" "$PROFILES_FILE" >/dev/null; }

# -------------------- Создание --------------------
create_profile() {
    print_header "СОЗДАНИЕ НОВОГО SOCKS5 ПРОФИЛЯ"
    read -p "Введите название профиля (Enter для автогенерации): " profile_name
    [ -z "$profile_name" ] && profile_name="socks5-$(get_next_profile_number)"
    profile_exists "$profile_name" && { print_error "Профиль уже существует!"; return; }

    read -p "Ввести логин и пароль вручную? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        read -p "Имя пользователя: " username
        id "$username" &>/dev/null && { print_error "Системный пользователь '$username' уже существует."; return; }
        read -s -p "Пароль: " password; echo
    else
        username=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
        password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)
    fi

    read -p "Указать порт вручную? [y/N]: " port_choice
    if [[ "$port_choice" =~ ^[Yy]$ ]]; then
        while :; do
            read -p "Введите порт (1024-65535): " port
            [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1024 && port<=65535)) && ! ss -tulnp | awk '{print $4}' | grep -q ":$port" && ! is_port_used_by_profiles "$port" && break
            print_warning "Порт недоступен, выберите другой."
        done
    else
        port=$(generate_random_port)
    fi

    useradd -r -s /bin/false "$username"
    (echo "$password"; echo "$password") | passwd "$username" >/dev/null 2>&1

    save_profile "$profile_name" "$port" "$username" "$password"
    generate_dante_config
    ufw allow "$port/tcp" >/dev/null 2>&1
    systemctl restart danted && systemctl enable danted

    print_success "Профиль '$profile_name' создан. IP: $(curl -s4 ifconfig.me), Порт: $port, Логин: $username, Пароль: $password"
}

# -------------------- Просмотр --------------------
show_connections() {
    while true; do
        clear
        print_header "СПИСОК SOCKS5 ПРОФИЛЕЙ"
        [ ! -s "$PROFILES_FILE" ] && { print_warning "Нет профилей"; return; }
        local i=1; while IFS= read -r n; do echo "$i) $n"; ((i++)); done < <(jq -r '.[].name' "$PROFILES_FILE")
        echo "0) Назад"
        read -p "Выберите номер: " sel
        [[ "$sel" == "0" ]] && break
        name=$(jq -r ".[$((sel-1))].name" "$PROFILES_FILE")
        [ "$name" == "null" ] && { print_error "Нет такого номера"; sleep 1; continue; }
        local ip=$(curl -s4 ifconfig.me)
        jq -r ".[] | select(.name==\"$name\") | \"Название: \(.name)\nIP: $ip\nПорт: \(.port)\nЛогин: \(.username)\nПароль: \(.password)\nСоздан: \(.created)\"" "$PROFILES_FILE"
        read -p "Enter для возврата..."
    done
}

# -------------------- Удаление --------------------
delete_profile() {
    read -p "Введите название профиля для удаления: " pname
    profile_exists "$pname" || { print_error "Не найдено"; return; }
    local u=$(jq -r ".[] | select(.name==\"$pname\").username" "$PROFILES_FILE")
    local p=$(jq -r ".[] | select(.name==\"$pname\").port" "$PROFILES_FILE")
    userdel "$u" 2>/dev/null
    ufw delete allow "$p/tcp" >/dev/null 2>&1
    jq "del(.[] | select(.name==\"$pname\"))" "$PROFILES_FILE" > "$PROFILES_FILE.tmp" && mv "$PROFILES_FILE.tmp" "$PROFILES_FILE"
    generate_dante_config
    [ "$(jq length "$PROFILES_FILE")" -gt 0 ] && systemctl restart danted || systemctl stop danted
    print_success "Профиль удалён"
}

uninstall_manager() {
    read -p "Подтвердите удаление всех профилей (YES): " confirm
    [ "$confirm" != "YES" ] && { print_warning "Отменено"; return; }
    systemctl stop danted; systemctl disable danted
    if [ -f "$PROFILES_FILE" ]; then
        jq -c '.[]' "$PROFILES_FILE" | while read pr; do
            userdel "$(echo "$pr" | jq -r '.username')" 2>/dev/null
            ufw delete allow "$(echo "$pr" | jq -r '.port')/tcp" >/dev/null 2>&1
        done
    fi
    rm -rf "$MANAGER_DIR" "$DANTE_CONFIG" "$SCRIPT_PATH" "$INSTALL_PATH"
    print_success "Менеджер удалён"
}

# -------------------- Меню --------------------
show_main_menu() {
    while true; do
        clear
        print_header "SOCKS5 MANAGER"
        echo "1) Показать подключения"
        echo "2) Создать подключение"
        echo "3) Удалить подключение"
        echo "4) Удалить менеджер"
        echo "5) Выход"
        read -p "Выбор: " ch
        case $ch in
            1) show_connections ;;
            2) create_profile ;;
            3) delete_profile ;;
            4) uninstall_manager; exit ;;
            5) exit ;;
            *) print_error "Неверно"; sleep 1 ;;
        esac
    done
}

# -------------------- Main --------------------
main() {
    [[ $EUID -ne 0 ]] && { print_error "Нужен root"; exit 1; }
    if [ ! -d "$MANAGER_DIR" ]; then
        print_header "ПЕРВАЯ УСТАНОВКА"
        install_dependencies
        init_manager
        generate_dante_config
        read -p "Создать первый профиль? [Y/n]: " ans
        [[ ! "$ans" =~ ^[Nn]$ ]] && create_profile
    else
        init_manager
    fi
    show_main_menu
}

# -------------------- CLI --------------------
[[ "$1" == "" || "$1" == "menu" ]] && main || {
    case "$1" in
        list) show_connections ;;
        create) create_profile ;;
        delete) delete_profile ;;
        *) echo "Использование: socks [menu|list|create|delete]" ;;
    esac
}
