#!/bin/bash

# SOCKS5 Proxy Manager - Enhanced Version Based on Working Script
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
DANTE_CONFIG="/etc/danted.conf"

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

# Инициализация менеджера (исправленная версия)
init_manager() {
    if [ ! -d "$MANAGER_DIR" ]; then
        mkdir -p "$MANAGER_DIR"
        echo "[]" > "$PROFILES_FILE"
        print_status "Создана директория управления: $MANAGER_DIR"
    fi

    # Всегда обеспечиваем правильную работу команды socks
    setup_socks_command
}

# Новая функция для настройки команды socks
setup_socks_command() {
    # Удаляем старый symlink если он существует
    if [ -L "$SCRIPT_PATH" ] || [ -f "$SCRIPT_PATH" ]; then
        rm -f "$SCRIPT_PATH"
    fi

    # Определяем путь к скрипту более надежно
    local script_location
    if [ -n "$BASH_SOURCE" ]; then
        script_location="$(readlink -f "$BASH_SOURCE")"
    else
        script_location="$(readlink -f "$0")"
    fi

    # Если скрипт был скачан временно, копируем его в постоянное место
    if [[ "$script_location" == */tmp/* ]] || [[ "$script_location" == *install.sh ]]; then
        local permanent_location="/usr/local/bin/socks5-manager.sh"
        cp "$script_location" "$permanent_location"
        chmod +x "$permanent_location"
        script_location="$permanent_location"
        print_status "Скрипт скопирован в: $permanent_location"
    fi

    # Создаем symlink
    if [ -f "$script_location" ]; then
        ln -sf "$script_location" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        
        # Проверяем что symlink работает
        if [ -x "$SCRIPT_PATH" ]; then
            print_success "Команда 'socks' создана и готова к использованию"
        else
            print_warning "Проблема с созданием команды 'socks'"
        fi
    else
        print_warning "Не удалось создать команду быстрого доступа"
    fi
}

# Проверка и установка зависимостей (ТОЧНО КАК В ИСХОДНОМ СКРИПТЕ)
install_dependencies() {
    print_status "Обновление пакетов и установка зависимостей..."
    apt update > /dev/null 2>&1 && apt install -y dante-server apache2-utils jq > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        print_error "Ошибка при установке пакетов"
        exit 1
    fi
}

# Функция для генерации случайного порта (ИЗ ИСХОДНОГО СКРИПТА)
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

# Генерация конфигурации Dante для всех профилей
generate_dante_config() {
    local INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
    
    cat > "$DANTE_CONFIG" <<EOL
logoutput: /var/log/danted.log
user.privileged: root
user.notprivileged: nobody

EOL

    # Добавляем internal интерфейсы для каждого порта
    if [ -f "$PROFILES_FILE" ] && [ "$(jq length "$PROFILES_FILE")" -gt 0 ]; then
        while IFS= read -r profile; do
            local port=$(echo "$profile" | jq -r '.port')
            echo "internal: 0.0.0.0 port = $port" >> "$DANTE_CONFIG"
        done < <(jq -c '.[]' "$PROFILES_FILE")
    fi
    
    cat >> "$DANTE_CONFIG" <<EOL

external: $INTERFACE
socksmethod: username

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
}

# Создание нового профиля (ОСНОВАН НА ИСХОДНОМ СКРИПТЕ)
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
    
    # Определяем сетевой интерфейс (ИЗ ИСХОДНОГО СКРИПТА)
    INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
    print_status "Обнаружен сетевой интерфейс: $INTERFACE"
    
    # Настройка аутентификации (ИЗ ИСХОДНОГО СКРИПТА)
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
    
    # Настройка порта (ИЗ ИСХОДНОГО СКРИПТА)
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
    
    # Создание системного пользователя (ИЗ ИСХОДНОГО СКРИПТА)
    print_status "Создание системного пользователя..."
    useradd -r -s /bin/false "$username" 2>/dev/null
    (echo "$password"; echo "$password") | passwd "$username" > /dev/null 2>&1
    
    # Сохранение профиля
    save_profile "$profile_name" "$port" "$username" "$password"
    
    # Обновление конфигурации Dante
    print_status "Обновление конфигурации Dante..."
    generate_dante_config
    
    # Настройка брандмауэра (ИЗ ИСХОДНОГО СКРИПТА)
    print_status "Настройка брандмауэра..."
    ufw allow "$port/tcp" > /dev/null 2>&1
    
    # Перезапуск службы (ИЗ ИСХОДНОГО СКРИПТА)
    print_status "Перезапуск службы..."
    systemctl restart danted
    systemctl enable danted > /dev/null 2>&1
    
    if ! systemctl is-active --quiet danted; then
        print_error "Не удалось запустить службу Dante"
        return 1
    fi
    
    # Получение внешнего IP (ИЗ ИСХОДНОГО СКРИПТА)
    local external_ip=$(curl -4 -s ifconfig.me)
    
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
    local port=$2
    local username=$3
    local password=$4
    
    local new_profile=$(jq -n \
        --arg name "$name" \
        --arg port "$port" \
        --arg username "$username" \
        --arg password "$password" \
        --arg created "$(date -Iseconds)" \
        '{
            name: $name,
            port: ($port | tonumber),
            username: $username,
            password: $password,
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
# Показать все подключения (улучшенная версия)
show_connections() {
    print_header "АКТИВНЫЕ SOCKS5 ПОДКЛЮЧЕНИЯ"
    
    if [ ! -f "$PROFILES_FILE" ] || [ "$(jq length "$PROFILES_FILE")" -eq 0 ]; then
        print_warning "Нет созданных профилей"
        return
    fi
    
    local external_ip=$(curl -4 -s ifconfig.me 2>/dev/null || echo "N/A")
    local service_status=""
    if systemctl is-active --quiet danted; then
        service_status="${GREEN}АКТИВЕН${NC}"
    else
        service_status="${RED}ОСТАНОВЛЕН${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}Список профилей:${NC}"
    echo ""
    
    local counter=1
    declare -a profile_names=()
    
    while IFS= read -r profile; do
        local name=$(echo "$profile" | jq -r '.name')
        local port=$(echo "$profile" | jq -r '.port')
        profile_names+=("$name")
        echo -e "${CYAN}$counter.${NC} $name (порт: $port)"
        ((counter++))
    done < <(jq -c '.[]' "$PROFILES_FILE")
    
    echo ""
    echo -e "${CYAN}0.${NC} Назад в главное меню"
    echo ""
    read -p "Выберите профиль для просмотра (0-$((counter-1))): " selection
    
    if [[ "$selection" == "0" ]]; then
        return
    fi
    
    if ! [[ "$selection" =~ ^[1-9][0-9]*$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -ge $counter ]; then
        print_error "Неверный выбор"
        sleep 1
        return
    fi
    
    local selected_profile=$(echo "${profile_names[$((selection-1))]}")
    local profile_data=$(jq ".[] | select(.name == \"$selected_profile\")" "$PROFILES_FILE")
    
    local name=$(echo "$profile_data" | jq -r '.name')
    local port=$(echo "$profile_data" | jq -r '.port')
    local username=$(echo "$profile_data" | jq -r '.username')
    local password=$(echo "$profile_data" | jq -r '.password')
    local created=$(echo "$profile_data" | jq -r '.created')
    
    clear
    print_header "ИНФОРМАЦИЯ О ПРОФИЛЕ: $name"
    echo ""
    echo -e "${BLUE}Параметры подключения:${NC}"
    echo "  Название: $name"
    echo "  IP адрес: $external_ip"
    echo "  Порт: $port"
    echo "  Логин: $username"
    echo "  Пароль: $password"
    echo "  Статус: $service_status"
    echo "  Создан: $created"
    echo ""
    echo -e "${BLUE}Форматы для антидетект браузеров:${NC}"
    echo "  $external_ip:$port:$username:$password"
    echo "  $username:$password@$external_ip:$port"
    echo ""
    
    read -p "Нажмите Enter для возврата к списку..."
    clear
    show_connections  # Рекурсивный вызов для возврата к списку
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
    jq -r '.[] | "  - \(.name) (порт: \(.port))"' "$PROFILES_FILE"
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
    local username=$(echo "$profile_data" | jq -r '.username')
    local port=$(echo "$profile_data" | jq -r '.port')
    
    echo ""
    read -p "Вы уверены, что хотите удалить профиль '$profile_name'? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Удаление отменено"
        return
    fi
    
    print_status "Удаление профиля '$profile_name'..."
    
    # Удаление системного пользователя
    userdel "$username" 2>/dev/null
    
    # Удаление правила firewall
    ufw delete allow "$port/tcp" > /dev/null 2>&1
    
    # Удаление профиля из JSON
    jq "del(.[] | select(.name == \"$profile_name\"))" "$PROFILES_FILE" > "$PROFILES_FILE.tmp" && mv "$PROFILES_FILE.tmp" "$PROFILES_FILE"
    
    # Обновление конфигурации Dante
    print_status "Обновление конфигурации Dante..."
    generate_dante_config
    
    # Перезапуск службы
    if [ "$(jq length "$PROFILES_FILE")" -gt 0 ]; then
        systemctl restart danted
    else
        print_warning "Это был последний профиль. Остановка службы Dante."
        systemctl stop danted
    fi
    
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
    
    # Остановка службы
    systemctl stop danted 2>/dev/null
    systemctl disable danted 2>/dev/null
    
    # Удаление всех системных пользователей
    if [ -f "$PROFILES_FILE" ]; then
        while IFS= read -r profile; do
            local username=$(echo "$profile" | jq -r '.username')
            local port=$(echo "$profile" | jq -r '.port')
            userdel "$username" 2>/dev/null
            ufw delete allow "$port/tcp" > /dev/null 2>&1
        done < <(jq -c '.[]' "$PROFILES_FILE")
    fi
    
    # Удаление файлов
    rm -rf "$MANAGER_DIR"
    rm -f "$DANTE_CONFIG"
    rm -f "$SCRIPT_PATH"
    
    print_success "SOCKS5 менеджер полностью удален"
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
        
        # Создаем пустую конфигурацию dante
        generate_dante_config
        
        echo ""
        print_success "Менеджер SOCKS5 прокси успешно установлен!"
        echo ""
        
        read -p "Создать первый профиль сейчас? [Y/n]: " create_first
        if [[ ! "$create_first" =~ ^[Nn]$ ]]; then
            clear
            create_profile
            echo ""
            read -p "Нажмите Enter для продолжения..."
        fi
    else
        # При повторных запусках - проверяем и обновляем команду socks
        setup_socks_command
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
