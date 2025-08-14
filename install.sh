#!/bin/bash

# SOCKS5 Proxy Server Installation Script
# Автоматическая установка и настройка Dante SOCKS5 прокси-сервера

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для цветного вывода
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

# Проверка прав администратора
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен быть запущен с правами root"
   exit 1
fi

print_header "SOCKS5 PROXY SERVER INSTALLER"

print_status "Обновление пакетов и установка зависимостей..."
apt update > /dev/null 2>&1 && apt install -y dante-server apache2-utils > /dev/null 2>&1

if [ $? -ne 0 ]; then
    print_error "Ошибка при установке пакетов"
    exit 1
fi

# Определяем правильный сетевой интерфейс
INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
print_status "Обнаружен сетевой интерфейс: $INTERFACE"

# Функция для генерации случайного порта
generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            echo $port
            return
        fi
    done
}

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
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            break
        else
            print_warning "Порт недоступен или некорректный. Попробуйте снова."
        fi
    done
else
    port=$(generate_random_port)
    print_status "Назначен порт: $port"
fi

print_status "Создание системного пользователя..."
useradd -r -s /bin/false $username 2>/dev/null
(echo "$password"; echo "$password") | passwd $username > /dev/null 2>&1

print_status "Создание конфигурации Dante..."
cat > /etc/danted.conf <<EOL
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

print_status "Настройка брандмауэра..."
ufw allow $port/tcp > /dev/null 2>&1

print_status "Запуск службы..."
systemctl restart danted
systemctl enable danted > /dev/null 2>&1

if ! systemctl is-active --quiet danted; then
    print_error "Не удалось запустить службу Dante"
    exit 1
fi

# Получение внешнего IP
ip=$(curl -4 -s ifconfig.me)

echo ""
print_header "УСТАНОВКА ЗАВЕРШЕНА"
print_status "SOCKS5 прокси-сервер успешно настроен!"
echo ""
echo -e "${BLUE}Параметры подключения:${NC}"
echo "  IP адрес: $ip"
echo "  Порт: $port"
echo "  Логин: $username"
echo "  Пароль: $password"
echo ""
echo -e "${BLUE}Форматы для антидетект браузеров:${NC}"
echo "  $ip:$port:$username:$password"
echo "  $username:$password@$ip:$port"
echo ""
print_status "Служба добавлена в автозагрузку"
echo -e "${BLUE}================================${NC}"
