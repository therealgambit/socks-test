#!/bin/bash

# SOCKS5 Proxy Manager - Enhanced Version
# Управление множественными SOCKS5 прокси-серверами

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Конфигурация
MANAGER_DIR="/etc/socks5-manager"
PROFILES_FILE="$MANAGER_DIR/profiles.json"
SCRIPT_PATH="/usr/local/bin/socks"

# Функции для цветного вывода
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Инициализация менеджера
init_manager() {
    if [ ! -d "$MANAGER_DIR" ]; then
        mkdir -p "$MANAGER_DIR"
        echo "[]" > "$PROFILES_FILE"
        print_status "Создана директория управления: $MANAGER_DIR"
    fi
    
    # Создание symlink для быстрого доступа
    if [ ! -f "$SCRIPT_PATH" ] || [ ! -L "$SCRIPT_PATH" ]; then
        ln -sf "$(realpath "$0")" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        print_status "Создана команда быстрого доступа: socks"
    fi
}

# Проверка и установка зависимостей
install_dependencies() {
    print_status "Проверка и установка зависимостей..."
    
    if ! command -v jq &> /dev/null; then
        apt update > /dev/null 2>&1
        apt install -y jq > /dev/null 2>&1
    fi
    
    apt install -y dante-server apache2-utils > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        print_error "Ошибка при установке пакетов"
        exit 1
    fi
}

# Функция для генерации случайного порта
generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$port" && ! is_port_used_by_profiles "$port"; then
            echo $port
            return
        fi
    done
}

# Проверка использования порта в профилях
is_port_used_by_profiles() {
    local check_port=$1
    if [ -f "$PROFILES_FILE" ]; then
        jq -r '.[].port' "$PROFILES_FILE" 2>/dev/null | grep -q "^$check_port$"
    else
        return 1
    fi
}

# Генерация следующего номера профиля
get_next_profile_number() {
    if [ ! -f "$PROFILES_FILE" ]; then
        echo 1
        return
    fi
    
    local max_num=0
    while IFS= read -r name; do
        if [[ "$name" =~ ^socks5-([0-9]+)$ ]]; then
            local num=${BASH_REMATCH[1]}
            if [ "$num" -gt "$max_num" ]; then
                max_num=$num
            fi
        fi
    done < <(jq -r '.[].name' "$PROFILES_FILE" 2>/dev/null)
    
    echo $((max_num + 1))
}

# Создание нового профиля
create_profile() {
    print_header "СОЗДАНИЕ НОВОГО SOCKS5 ПРОФИЛЯ"
    
    # Запрос названия профиля
    echo ""
    read -p "Введите название профиля (Enter для автогенерации): " profile_name
    
    if [ -z "$profile_name" ]; then
        local next_num=$(get_next_profile_number)
        profile_name="socks5-$next_num"
        print_status "Создается профиль: $profile_name"
    fi
    
    # Проверка уникальности названия
    if profile_exists "$profile_name"; then
        print_error "Профиль '$profile_name' уже существует!"
        return 1
    fi
    
    # Определяем сетевой интерфейс
    INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
    print_status "Обнаружен сетевой интерфейс: $INTERFACE"
    
    # Настройка аутентификации
    echo ""
    print_header "НАСТРОЙКА АУТЕНТИФИКАЦИИ"
    read -p "Ввести логин и пароль вручную? [y/N]: " choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        read -p "Имя пользователя: " username
        read -s -p "Пароль: " password
        echo ""
    else
        username=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
        password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)
        print_status "Сгенерированы учетные данные:"
        echo "  Логин: $username"
        echo "  Пароль: $password"
    fi
    
    # Настройка порта
    echo ""
    print_header "НАСТРОЙКА ПОРТА"
    read -p "Указать порт вручную? [y/N]: " port_choice
    
    if [[ "$port_choice" =~ ^[Yy]$ ]]; then
        while :; do
            read -p "Введите порт (1024-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && ! ss -tulnp | awk '{print $4}' | grep -q ":$port" && ! is_port_used_by_profiles "$port"; then
                break
            else
                print_warning "Порт недоступен или некорректный. Попробуйте снова."
            fi
        done
    else
        port=$(generate_random_port)
        print_status "Назначен порт: $port"
    fi
    
    # Создание системного пользователя
    print_status "Создание системного пользователя..."
    local system_user="${profile_name//-/_}_user"
    useradd -r -s /bin/false "$system_user" 2>/dev/null
    (echo "$password"; echo "$password") | passwd "$system_user" > /dev/null 2>&1
    
    # Создание конфигурации Dante
    print_status "Создание конфигурации Dante..."
    local config_file="$MANAGER_DIR/${profile_name}.conf"
    
    cat > "$config_file" <<EOL
logoutput: stderr
internal: 0.0.0.0 port = $port
external: $INTERFACE
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error
}

socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        method: username
        protocol: tcp udp
        log: error
}
EOL
    
    # Создание systemd сервиса
    print_status "Создание systemd сервиса..."
    local service_name="dante-${profile_name}"
    
    cat > "/etc/systemd/system/${service_name}.service" <<EOL
[Unit]
Description=Dante SOCKS5 Proxy Server - $profile_name
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/danted -f $config_file
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/danted-${profile_name}.pid
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL
    
    # Обновление конфигурации Dante для использования PID файла
    echo "pidfile: /var/run/danted-${profile_name}.pid" >> "$config_file"
    
    # Настройка брандмауэра
    print_status "Настройка брандмауэра..."
    ufw allow "$port/tcp" > /dev/null 2>&1
    
    # Запуск службы
    print_status "Запуск службы..."
    systemctl daemon-reload
    systemctl restart "$service_name"
    systemctl enable "$service_name" > /dev/null 2>&1
    
    if ! systemctl is-active --quiet "$service_name"; then
        print_error "Не удалось запустить службу $service_name"
        return 1
    fi
    
    # Получение внешнего IP
    local external_ip=$(curl -4 -s ifconfig.me)
    
    # Сохранение профиля в JSON
    save_profile "$profile_name" "$external_ip" "$port" "$username" "$password" "$service_name" "$system_user"
    
    # Вывод результатов
    echo ""
    print_header "ПРОФИЛЬ СОЗДАН УСПЕШНО"
    print_success "SOCKS5 прокси-сервер '$profile_name' настроен!"
    echo ""
    echo -e "${BLUE}Параметры подключения:${NC}"
    echo "  Название: $profile_name"
    echo "  IP адрес: $external_ip"
    echo "  Порт: $port"
    echo "  Логин: $username"
    echo "  Пароль: $password"
    echo ""
    echo -e "${BLUE}Форматы для антидетект браузеров:${NC}"
    echo "  $external_ip:$port:$username:$password"
    echo "  $username:$password@$external_ip:$port"
    echo ""
}

# Сохранение профиля в JSON
save_profile() {
    local name=$1
    local ip=$2
    local port=$3
    local username=$4
    local password=$5
    local service_name=$6
    local system_user=$7
    
    local new_profile=$(jq -n \
        --arg name "$name" \
        --arg ip "$ip" \
        --arg port "$port" \
        --arg username "$username" \
        --arg password "$password" \
        --arg service "$service_name" \
        --arg user "$system_user" \
        --arg created "$(date -Iseconds)" \
        '{
            name: $name,
            ip: $ip,
            port: ($port | tonumber),
            username: $username,
            password: $password,
            service: $service,
            system_user: $user,
            created: $created
        }')
    
    jq ". + [$new_profile]" "$PROFILES_FILE" > "$PROFILES_FILE.tmp" && mv "$PROFILES_FILE.tmp" "$PROFILES_FILE"
}

# Проверка существования профиля
profile_exists() {
    local name=$1
    if [ -f "$PROFILES_FILE" ]; then
        jq -e ".[] | select(.name == \"$name\")" "$PROFILES_FILE" > /dev/null 2>&1
    else
        return 1
    fi
}

# Показать все подключения
show_connections() {
    print_header "АКТИВНЫЕ SOCKS5 ПОДКЛЮЧЕНИЯ"
    
    if [ ! -f "$PROFILES_FILE" ] || [ "$(jq length "$PROFILES_FILE")" -eq 0 ]; then
        print_warning "Нет созданных профилей"
        return
    fi
    
    echo ""
    printf "%-15s %-15s %-8s %-12s %-15s %-10s\n" "НАЗВАНИЕ" "IP АДРЕС" "ПОРТ" "ЛОГИН" "ПАРОЛЬ" "СТАТУС"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    while IFS= read -r profile; do
        local name=$(echo "$profile" | jq -r '.name')
        local ip=$(echo "$profile" | jq -r '.ip')
        local port=$(echo "$profile" | jq -r '.port')
        local username=$(echo "$profile" | jq -r '.username')
        local password=$(echo "$profile" | jq -r '.password')
        local service=$(echo "$profile" | jq -r '.service')
        
        local status=""
        if systemctl is-active --quiet "$service"; then
            status="${GREEN}АКТИВЕН${NC}"
        else
            status="${RED}ОСТАНОВЛЕН${NC}"
        fi
        
        printf "%-15s %-15s %-8s %-12s %-15s %-20s\n" "$name" "$ip" "$port" "$username" "$password" "$status"
    done < <(jq -c '.[]' "$PROFILES_FILE")
    
    echo ""
    echo -e "${CYAN}Для управления используйте команду: socks${NC}"
}

# Удаление профиля
delete_profile() {
    print_header "УДАЛЕНИЕ SOCKS5 ПРОФИЛЯ"
    
    if [ ! -f "$PROFILES_FILE" ] || [ "$(jq length "$PROFILES_FILE")" -eq 0 ]; then
        print_warning "Нет профилей для удаления"
        return
    fi
    
    echo ""
    echo "Доступные профили:"
    jq -r '.[] | "  - \(.name)"' "$PROFILES_FILE"
    echo ""
    
    read -p "Введите название профиля для удаления: " profile_name
    
    if [ -z "$profile_name" ]; then
        print_warning "Название профиля не указано"
        return
    fi
    
    if ! profile_exists "$profile_name"; then
        print_error "Профиль '$profile_name' не найден"
        return
    fi
    
    # Получение данных профиля
    local profile_data=$(jq ".[] | select(.name == \"$profile_name\")" "$PROFILES_FILE")
    local service_name=$(echo "$profile_data" | jq -r '.service')
    local system_user=$(echo "$profile_data" | jq -r '.system_user')
    local port=$(echo "$profile_data" | jq -r '.port')
    
    echo ""
    read -p "Вы уверены, что хотите удалить профиль '$profile_name'? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Удаление отменено"
        return
    fi
    
    print_status "Удаление профиля '$profile_name'..."
    
    # Остановка и удаление службы
    systemctl stop "$service_name" 2>/dev/null
    systemctl disable "$service_name" 2>/dev/null
    rm -f "/etc/systemd/system/${service_name}.service"
    systemctl daemon-reload
    
    # Удаление системного пользователя
    userdel "$system_user" 2>/dev/null
    
    # Удаление конфигурационного файла
    rm -f "$MANAGER_DIR/${profile_name}.conf"
    
    # Удаление правила firewall
    ufw delete allow "$port/tcp" > /dev/null 2>&1
    
    # Удаление профиля из JSON
    jq "del(.[] | select(.name == \"$profile_name\"))" "$PROFILES_FILE" > "$PROFILES_FILE.tmp" && mv "$PROFILES_FILE.tmp" "$PROFILES_FILE"
    
    print_success "Профиль '$profile_name' успешно удален"
}

# Полное удаление менеджера
uninstall_manager() {
    print_header "ПОЛНОЕ УДАЛЕНИЕ SOCKS5 МЕНЕДЖЕРА"
    
    echo ""
    echo -e "${RED}ВНИМАНИЕ: Это действие удалит ВСЕ профили и конфигурации!${NC}"
    echo ""
    read -p "Вы уверены? Введите 'YES' для подтверждения: " confirm
    
    if [ "$confirm" != "YES" ]; then
        print_warning "Удаление отменено"
        return
    fi
    
    print_status "Удаление всех профилей и конфигураций..."
    
    # Остановка и удаление всех служб
    if [ -f "$PROFILES_FILE" ]; then
        while IFS= read -r profile; do
            local service_name=$(echo "$profile" | jq -r '.service')
            local system_user=$(echo "$profile" | jq -r '.system_user')
            local port=$(echo "$profile" | jq -r '.port')
            
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "/etc/systemd/system/${service_name}.service"
            userdel "$system_user" 2>/dev/null
            ufw delete allow "$port/tcp" > /dev/null 2>&1
        done < <(jq -c '.[]' "$PROFILES_FILE")
    fi
    
    systemctl daemon-reload
    
    # Удаление директории менеджера
    rm -rf "$MANAGER_DIR"
    
    # Удаление симлинка
    rm -f "$SCRIPT_PATH"
    
    print_success "SOCKS5 менеджер полностью удален"
    print_status "Для повторной установки запустите скрипт заново"
}

# Главное меню
show_main_menu() {
    while true; do
        clear
        print_header "SOCKS5 PROXY MANAGER"
        echo ""
        echo -e "${CYAN}1.${NC} Показать все подключения"
        echo -e "${CYAN}2.${NC} Создать новое подключение"
        echo -e "${CYAN}3.${NC} Удалить подключение"
        echo -e "${CYAN}4.${NC} Удалить менеджер и все конфигурации"
        echo -e "${CYAN}5.${NC} Выход"
        echo ""
        read -p "Выберите пункт меню (1-5): " choice
        
        case $choice in
            1)
                clear
                show_connections
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                clear
                create_profile
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            3)
                clear
                delete_profile
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                clear
                uninstall_manager
                exit 0
                ;;
            5)
                echo ""
                print_status "До свидания!"
                exit 0
                ;;
            *)
                print_error "Неверный выбор. Попробуйте снова."
                sleep 1
                ;;
        esac
    done
}

# Основная логика
main() {
    # Проверка прав администратора
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    
    # Инициализация при первом запуске
    if [ ! -d "$MANAGER_DIR" ]; then
        print_header "ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА SOCKS5 МЕНЕДЖЕРА"
        install_dependencies
        init_manager
        
        echo ""
        print_success "Менеджер SOCKS5 прокси успешно установлен!"
        print_status "Теперь вы можете использовать команду 'socks' для быстрого доступа"
        echo ""
        read -p "Создать первый профиль сейчас? [Y/n]: " create_first
        
        if [[ ! "$create_first" =~ ^[Nn]$ ]]; then
            clear
            create_profile
            echo ""
            read -p "Нажмите Enter для входа в главное меню..."
        fi
    else
        init_manager
    fi
    
    # Показ главного меню
    show_main_menu
}

# Проверка аргументов командной строки
if [ "$1" = "menu" ] || [ "$1" = "" ]; then
    main
elif [ "$1" = "list" ]; then
    show_connections
elif [ "$1" = "create" ]; then
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    init_manager
    create_profile
elif [ "$1" = "delete" ]; then
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    init_manager
    delete_profile
else
    echo "Использование: $0 [menu|list|create|delete]"
    echo "  menu   - показать главное меню (по умолчанию)"
    echo "  list   - показать все подключения"
    echo "  create - создать новое подключение"
    echo "  delete - удалить подключение"
fi
