#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Настройки по умолчанию
DEFAULT_FAKE_DOMAIN="ya.ru"
DEFAULT_PORT="443"
DEFAULT_CONTAINER_PREFIX="mtproto-proxy"
CONFIG_DIR="$HOME/.mtproto_configs"
ACTIVE_CONFIG_FILE="$CONFIG_DIR/active.conf"

# Инициализация директории конфигураций
init_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

# Генерация случайного имени контейнера
generate_container_name() {
    local name_suffix=$1
    local random_suffix=$(openssl rand -hex 3)
    if [ -n "$name_suffix" ]; then
        echo "${DEFAULT_CONTAINER_PREFIX}-${name_suffix}-${random_suffix}"
    else
        echo "${DEFAULT_CONTAINER_PREFIX}-$(openssl rand -hex 4)"
    fi
}

# Генерация секрета для Fake TLS
generate_secret() {
    local domain=$1
    local domain_hex=$(echo -n "$domain" | xxd -ps | tr -d '\n')
    local domain_len=${#domain_hex}
    local needed=$((30 - domain_len))
    
    if [ $domain_len -ge 30 ]; then
        echo "ee${domain_hex:0:30}"
    else
        local random_hex=$(openssl rand -hex 15 | cut -c1-$needed)
        echo "ee${domain_hex}${random_hex}"
    fi
}

# Проверка доступности порта
check_port() {
    local port=$1
    ! ss -tuln 2>/dev/null | grep -qE ":[[:space:]]*${port}[[:space:]]"
}

# Поиск свободного порта
find_free_port() {
    local base_port=$1
    local port=$base_port
    local max_attempts=100
    local attempts=0
    
    while [ $attempts -lt $max_attempts ]; do
        if check_port $port; then
            echo $port
            return 0
        fi
        ((port++))
        ((attempts++))
    done
    
    return 1
}

# Сохранение конфигурации
save_config() {
    local name=$1
    local server=$2
    local port=$3
    local secret=$4
    local domain=$5
    local container=$6
    
    local config_file="$CONFIG_DIR/${name}.conf"
    cat > "$config_file" << EOF
NAME=${name}
SERVER=${server}
PORT=${port}
SECRET=${secret}
DOMAIN=${domain}
CONTAINER=${container}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$config_file"
    echo -e "${GREEN}[OK] Конфигурация '${name}' сохранена${NC}"
}

# Загрузка конфигурации
load_config() {
    local name=$1
    local config_file="$CONFIG_DIR/${name}.conf"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}[ERROR] Конфигурация '${name}' не найдена${NC}"
        return 1
    fi
    source "$config_file"
    return 0
}

# Список конфигураций
list_configs() {
    echo -e "\n${CYAN}Сохранённые конфигурации:${NC}"
    echo "================================================================"
    
    local count=0
    
    shopt -s nullglob
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ "$conf" == *"active.conf" ]] && continue
        ((count++))
        
        local name=$(basename "$conf" .conf)
        source "$conf" 2>/dev/null
        
        local status="остановлен"
        local container_status=$(sudo docker inspect -f '{{.State.Status}}' "${CONTAINER:-}" 2>/dev/null)
        
        if [ "$container_status" = "running" ]; then
            status="активен"
        elif [ "$container_status" = "exited" ]; then
            status="остановлен"
        fi
        
        printf "%2d. %-25s | Порт: %-5s | Домен: %-20s | %s\n" \
            $count "$name" "${PORT:-?}" "${DOMAIN:-?}" "$status"
    done
    shopt -u nullglob
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}[WARN] Нет сохранённых конфигураций${NC}"
    fi
    echo "================================================================"
    echo "Всего: ${count} конфигураций"
}

# Удаление конфигурации
delete_config() {
    local name=$1
    
    if [ ! -f "$CONFIG_DIR/${name}.conf" ]; then
        echo -e "${RED}[ERROR] Конфигурация '${name}' не найдена${NC}"
        return 1
    fi
    
    source "$CONFIG_DIR/${name}.conf" 2>/dev/null
    
    echo -n "[INFO] Остановка и удаление контейнера '${CONTAINER:-$name}'... "
    sudo docker stop "${CONTAINER:-$name}" >/dev/null 2>&1
    sudo docker rm "${CONTAINER:-$name}" >/dev/null 2>&1
    echo -e "${GREEN}готово${NC}"
    
    rm -f "$CONFIG_DIR/${name}.conf"
    echo -e "${GREEN}[OK] Конфигурация '${name}' удалена${NC}"
    
    if [ -f "$ACTIVE_CONFIG_FILE" ]; then
        local active_name=$(grep "^NAME=" "$ACTIVE_CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        if [ "$active_name" = "$name" ]; then
            rm -f "$ACTIVE_CONFIG_FILE"
            echo "[INFO] Активная конфигурация сброшена"
        fi
    fi
}

# Запуск прокси
start_proxy() {
    local name=$1
    local port=${2:-}
    local domain=${3:-}
    local container_name=${4:-}
    
    # Fake TLS домен - значение по умолчанию
    if [ -z "$domain" ]; then
        domain="$DEFAULT_FAKE_DOMAIN"
        echo -e "   Fake TLS домен: ${BLUE}${domain}${NC} (по умолчанию)"
    else
        echo -e "   Fake TLS домен: ${BLUE}${domain}${NC}"
    fi
    
    # Порт - проверка и авто-подбор
    if [ -z "$port" ]; then
        port="$DEFAULT_PORT"
    fi
    
    echo -n "[INFO] Проверка порта ${port}... "
    if ! check_port $port; then
        echo -e "${YELLOW}занят${NC}"
        echo -n "   Поиск свободного порта... "
        local new_port=$(find_free_port $port)
        if [ -n "$new_port" ]; then
            port=$new_port
            echo -e "${GREEN}найдено: ${port}${NC}"
        else
            echo -e "${RED}[ERROR] Не удалось найти свободный порт${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}свободен${NC}"
    fi
    
    # Имя контейнера - авто-генерация
    if [ -z "$container_name" ]; then
        container_name=$(generate_container_name "$name")
        echo -e "   Имя контейнера: ${BLUE}${container_name}${NC} (авто-генерация)"
    else
        echo -e "   Имя контейнера: ${BLUE}${container_name}${NC}"
    fi
    
    # Генерация секрета
    echo -n "[INFO] Генерация секрета... "
    local secret=$(generate_secret "$domain")
    echo -e "${GREEN}готово${NC}"
    echo -e "   Секрет: ${YELLOW}${secret}${NC}"
    
    # Проверка существующего контейнера
    echo -n "[INFO] Проверка существующих контейнеров... "
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${YELLOW}существует${NC}"
        echo -n "   Остановка и удаление... "
        sudo docker stop "$container_name" >/dev/null 2>&1
        sudo docker rm "$container_name" >/dev/null 2>&1
        echo -e "${GREEN}готово${NC}"
    else
        echo -e "${GREEN}чисто${NC}"
    fi
    
    # Запуск контейнера
    echo -n "[INFO] Запуск контейнера... "
    sudo docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        -p "${port}:443" \
        -e SECRET="$secret" \
        telegrammessenger/proxy >/dev/null 2>&1
    
    sleep 3
    
    if sudo docker ps | grep -q "$container_name"; then
        local server_ip=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 icanhazip.com || echo "определить-не-удалось")
        
        echo -e "\n${GREEN}[SUCCESS] Запуск выполнен успешно${NC}"
        echo ""
        echo "ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
        echo "================================================================"
        echo -e "Название: ${CYAN}${name}${NC}"
        echo -e "Сервер: ${BLUE}${server_ip}${NC}"
        echo -e "Порт: ${port}"
        echo -e "Секрет: ${YELLOW}${secret}${NC}"
        echo -e "Fake TLS: ${BLUE}${domain}${NC}"
        echo -e "Контейнер: ${CYAN}${container_name}${NC}"
        echo "================================================================"
        echo "Ссылка для Telegram:"
        echo -e "${GREEN}tg://proxy?server=${server_ip}&port=${port}&secret=${secret}${NC}"
        echo "================================================================"
        
        save_config "$name" "$server_ip" "$port" "$secret" "$domain" "$container_name"
        
        echo "NAME=${name}" > "$ACTIVE_CONFIG_FILE"
        chmod 600 "$ACTIVE_CONFIG_FILE"
        echo -e "${GREEN}[OK] Установлено как активная конфигурация${NC}"
        
        echo ""
        echo "Последние логи:"
        sudo docker logs --tail 3 "$container_name" 2>/dev/null | sed 's/^/   /'
        
        return 0
    else
        echo -e "\n${RED}[ERROR] Ошибка запуска${NC}"
        echo "Логи контейнера:"
        sudo docker logs "$container_name" 2>/dev/null | tail -10 | sed 's/^/   /'
        return 1
    fi
}

# Показать все запущенные конфигурации
show_active() {
    echo -e "\n${CYAN}Запущенные конфигурации:${NC}"
    echo "================================================================"
    
    local count=0
    shopt -s nullglob
    
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ "$conf" == *"active.conf" ]] && continue
        
        local name=$(basename "$conf" .conf)
        source "$conf" 2>/dev/null
        
        local container_status=$(sudo docker inspect -f '{{.State.Status}}' "${CONTAINER:-}" 2>/dev/null)
        
        if [ "$container_status" = "running" ]; then
            ((count++))
            echo -e "\n[${count}] ${CYAN}${name}${NC}"
            echo "----------------------------------------------------------------"
            echo -e "Сервер: ${BLUE}${SERVER}${NC}"
            echo -e "Порт: ${PORT}"
            echo -e "Секрет: ${YELLOW}${SECRET}${NC}"
            echo -e "Fake TLS: ${BLUE}${DOMAIN}${NC}"
            echo -e "Контейнер: ${CYAN}${CONTAINER}${NC}"
            echo -e "Статус: ${GREEN}запущен${NC}"
            echo "----------------------------------------------------------------"
            echo -e "${GREEN}tg://proxy?server=${SERVER}&port=${PORT}&secret=${SECRET}${NC}"
        fi
    done
    
    shopt -u nullglob
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}[WARN] Нет запущенных конфигураций${NC}"
    fi
    
    echo "================================================================"
    echo "Всего запущено: ${count} конфигураций"
}

# Остановка контейнера
stop_container() {
    local name=$1
    load_config "$name" 2>/dev/null || return 1
    
    echo -n "[INFO] Остановка контейнера '${CONTAINER}'... "
    sudo docker stop "$CONTAINER" >/dev/null 2>&1
    echo -e "${GREEN}готово${NC}"
}

# Перезапуск активной конфигурации
restart_active() {
    if [ ! -f "$ACTIVE_CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] Нет активной конфигурации${NC}"
        return 1
    fi
    
    local name=$(grep "^NAME=" "$ACTIVE_CONFIG_FILE" | cut -d= -f2)
    load_config "$name" 2>/dev/null || return 1
    
    echo "[INFO] Перезапуск '${name}'..."
    stop_container "$name"
    sleep 1
    start_proxy "$name" "$PORT" "$DOMAIN" "$CONTAINER"
}

# Показать меню
show_menu() {
    echo ""
    echo "========================================"
    echo "   MTProto Proxy Manager"
    echo "========================================"
    echo ""
    echo "1. Добавить новую конфигурацию"
    echo "2. Список конфигураций"
    echo "3. Запустить конфигурацию"
    echo "4. Остановить конфигурацию"
    echo "5. Удалить конфигурацию"
    echo "6. Показать запущенные"
    echo "7. Перезапустить активную"
    echo "0. Выход"
    echo ""
    echo -n "Выберите действие [0-7]: "
}

# Интерактивный режим
interactive_mode() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                echo ""
                echo "Добавление новой конфигурации"
                echo "========================================"
                read -p "Название конфигурации: " config_name
                if [ -z "$config_name" ]; then
                    echo -e "${RED}[ERROR] Название обязательно${NC}"
                    continue
                fi
                
                read -p "Fake TLS домен [${DEFAULT_FAKE_DOMAIN}]: " fake_domain
                fake_domain=${fake_domain:-$DEFAULT_FAKE_DOMAIN}
                
                read -p "Внешний порт [${DEFAULT_PORT}]: " ext_port
                ext_port=${ext_port:-$DEFAULT_PORT}
                
                read -p "Имя контейнера [авто-генерация]: " container_name
                container_name=${container_name:-}
                
                start_proxy "$config_name" "$ext_port" "$fake_domain" "$container_name"
                ;;
            2)
                list_configs
                ;;
            3)
                list_configs
                read -p "Номер конфигурации для запуска: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "active.conf" | sed -n "${num}p")
                if [ -n "$conf" ]; then
                    local name=$(basename "$conf" .conf)
                    load_config "$name" 2>/dev/null
                    start_proxy "$name" "${PORT:-443}" "${DOMAIN:-ya.ru}" "${CONTAINER:-}"
                else
                    echo -e "${RED}[ERROR] Неверный номер${NC}"
                fi
                ;;
            4)
                list_configs
                read -p "Номер конфигурации для остановки: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "active.conf" | sed -n "${num}p")
                [ -n "$conf" ] && stop_container "$(basename "$conf" .conf)"
                ;;
            5)
                list_configs
                read -p "Номер конфигурации для удаления: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "active.conf" | sed -n "${num}p")
                [ -n "$conf" ] && delete_config "$(basename "$conf" .conf)"
                ;;
            6)
                show_active
                ;;
            7)
                restart_active
                ;;
            0)
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                echo -e "${YELLOW}[WARN] Неверный выбор${NC}"
                ;;
        esac
        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

# Режим командной строки
cli_mode() {
    case "${1:-}" in
        add)
            shift
            local name="${1:-default}"
            local port="${2:-}"
            local domain="${3:-}"
            local container="${4:-}"
            start_proxy "$name" "$port" "$domain" "$container"
            ;;
        list)
            list_configs
            ;;
        start)
            if [ -z "$2" ]; then
                echo -e "${RED}[ERROR] Укажите название конфигурации${NC}"
                exit 1
            fi
            load_config "$2" 2>/dev/null || exit 1
            start_proxy "$2" "${PORT:-443}" "${DOMAIN:-ya.ru}" "${CONTAINER:-}"
            ;;
        stop)
            if [ -z "$2" ]; then
                echo -e "${RED}[ERROR] Укажите название конфигурации${NC}"
                exit 1
            fi
            stop_container "$2"
            ;;
        delete|rm)
            if [ -z "$2" ]; then
                echo -e "${RED}[ERROR] Укажите название конфигурации${NC}"
                exit 1
            fi
            delete_config "$2"
            ;;
        active)
            show_active
            ;;
        restart)
            restart_active
            ;;
        help|--help|-h)
            echo "Использование: $0 [command] [args]"
            echo ""
            echo "Команды:"
            echo "  (без аргументов)  - интерактивное меню"
            echo "  add <name> [port] [domain] [container]  - добавить и запустить"
            echo "  list              - показать все конфигурации"
            echo "  start <name>      - запустить конфигурацию"
            echo "  stop <name>       - остановить конфигурацию"
            echo "  delete <name>     - удалить конфигурацию"
            echo "  active            - показать запущенные"
            echo "  restart           - перезапустить активную"
            ;;
        *)
            interactive_mode
            ;;
    esac
}

# Точка входа
init_config_dir

if [ "$EUID" -ne 0 ] && ! sudo -v &>/dev/null; then
    echo -e "${YELLOW}[WARN] Для работы скрипта требуются права sudo${NC}"
fi

if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERROR] Docker не установлен${NC}"
    exit 1
fi

cli_mode "$@"