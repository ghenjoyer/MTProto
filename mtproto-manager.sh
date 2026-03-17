#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DEFAULT_CONTAINER_NAME="mtproto-proxy"
DEFAULT_PORT="443"
DEFAULT_FAKE_DOMAIN="ya.ru"
CONFIG_DIR="$HOME/.mtproto_configs"
ACTIVE_CONFIG_FILE="$CONFIG_DIR/active.conf"

init_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

generate_secret() {
    local domain=$1
    local domain_hex=$(echo -n "$domain" | xxd -ps | tr -d '\n')
    local domain_len=${#domain_hex}
    local needed=$((30 - domain_len))
    local random_hex=$(openssl rand -hex 15 | cut -c1-$needed)
    echo "ee${domain_hex}${random_hex}"
}

check_port() {
    local port=$1
    ! ss -tuln | grep -q ":${port} "
}

find_free_port() {
    local base_port=$1
    local port=$base_port
    while ! check_port $port; do
        ((port++))
        if [ $port -gt $((base_port + 100)) ]; then
            return 1
        fi
    done
    echo $port
}

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
    echo -e "${GREEN}✅ Конфигурация '${name}' сохранена${NC}"
}

load_config() {
    local name=$1
    local config_file="$CONFIG_DIR/${name}.conf"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED} Конфигурация '${name}' не найдена${NC}"
        return 1
    fi
    source "$config_file"
}

list_configs() {
    echo -e "\n${CYAN}📋 Сохранённые конфигурации:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local count=0
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        ((count++))
        local name=$(basename "$conf" .conf)
        source "$conf" 2>/dev/null
        local status="остановлен"
        
        if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER:-}$"; then
            status="активен"
        fi
        
        printf "%2d. ${BLUE}%-20s${NC} | Порт: %-5s | Домен: %-15s | %s\n" \
            $count "$name" "${PORT:-?}" "${DOMAIN:-?}" "$status"
    done
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW} Нет сохранённых конфигураций${NC}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

delete_config() {
    local name=$1
    
    if [ ! -f "$CONFIG_DIR/${name}.conf" ]; then
        echo -e "${RED} Конфигурация '${name}' не найдена${NC}"
        return 1
    fi

    source "$CONFIG_DIR/${name}.conf" 2>/dev/null
    
    echo -n "🗑️  Остановка и удаление контейнера '${CONTAINER:-$name}'... "
    sudo docker stop "${CONTAINER:-$name}" >/dev/null 2>&1
    sudo docker rm "${CONTAINER:-$name}" >/dev/null 2>&1
    echo -e "${GREEN}готово${NC}"
    
    rm -f "$CONFIG_DIR/${name}.conf"
    echo -e "${GREEN} Конфигурация '${name}' удалена${NC}"
    
    [ -f "$ACTIVE_CONFIG_FILE" ] && grep -q "NAME=${name}" "$ACTIVE_CONFIG_FILE" && rm -f "$ACTIVE_CONFIG_FILE"
}

start_proxy() {
    local name=$1
    local port=${2:-$DEFAULT_PORT}
    local domain=${3:-$DEFAULT_FAKE_DOMAIN}
    local container_name=${4:-"${DEFAULT_CONTAINER_NAME}-${name}"}
    
    echo -n "🔑 Генерация секрета... "
    local secret=$(generate_secret "$domain")
    echo -e "${GREEN}готово${NC}"
     
    echo -n "🔍 Проверка порта ${port}... "
    if ! check_port $port; then
        echo -e "${YELLOW}занят${NC}"
        port=$(find_free_port $port)
        if [ -z "$port" ]; then
            echo -e "${RED} Не удалось найти свободный порт${NC}"
            return 1
        fi
        echo " Используем порт: ${port}"
    else
        echo -e "${GREEN}свободен${NC}"
    fi
    
    echo -n " Остановка старого контейнера... "
    sudo docker stop "$container_name" >/dev/null 2>&1
    sudo docker rm "$container_name" >/dev/null 2>&1
    echo -e "${GREEN}готово${NC}"

    echo -n " Запуск контейнера... "
    sudo docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        -p "${port}:443" \
        -e SECRET="$secret" \
        telegrammessenger/proxy >/dev/null 2>&1
    
    sleep 2
    
    if sudo docker ps | grep -q "$container_name"; then
        local server_ip=$(curl -s ifconfig.me)
        
        echo -e "${GREEN}✅ УСПЕШНО${NC}"
        echo ""
        echo " ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " Название: ${name}"
        echo " Сервер: ${server_ip}"
        echo " Порт: ${port}"
        echo " Секрет: ${YELLOW}${secret}${NC}"
        echo " Fake TLS: ${domain}"
        echo " Контейнер: ${container_name}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " Ссылка для Telegram:"
        echo -e "${GREEN}tg://proxy?server=${server_ip}&port=${port}&secret=${secret}${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        save_config "$name" "$server_ip" "$port" "$secret" "$domain" "$container_name"
        
        echo "NAME=${name}" > "$ACTIVE_CONFIG_FILE"
        echo "Установлено как активная конфигурация"

        echo ""
        echo " Последние логи:"
        sudo docker logs --tail 3 "$container_name" 2>/dev/null | sed 's/^/   /'
        
        return 0
    else
        echo -e "${RED} ОШИБКА запуска${NC}"
        sudo docker logs "$container_name" 2>/dev/null
        return 1
    fi
}

show_active() {
    if [ ! -f "$ACTIVE_CONFIG_FILE" ]; then
        echo -e "${YELLOW}  Активная конфигурация не установлена${NC}"
        return
    fi
    
    local name=$(grep "^NAME=" "$ACTIVE_CONFIG_FILE" | cut -d= -f2)
    load_config "$name" 2>/dev/null || return
    
    echo -e "\n${CYAN}🔷 Активная конфигурация:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Название: ${NAME}"
    echo " Сервер: ${SERVER}"
    echo " Порт: ${PORT}"
    echo " Секрет: ${SECRET}"
    echo " Fake TLS: ${DOMAIN}"
    echo " Контейнер: ${CONTAINER}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "tg://proxy?server=${SERVER}&port=${PORT}&secret=${SECRET}"
}

show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   🛠️  MTProto Proxy Manager    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════╝${NC}"
    echo ""
    echo "1. Добавить новую конфигурацию"
    echo "2. Список конфигураций"
    echo "3. Запустить конфигурацию"
    echo "4. Остановить конфигурацию"
    echo "5. Удалить конфигурацию"
    echo "6. Показать активную"
    echo "7. Перезапустить активную"
    echo "0. Выход"
    echo ""
    echo -n "Выберите действие [0-7]: "
}

stop_container() {
    local name=$1
    load_config "$name" 2>/dev/null || return 1
    
    echo -n "  Остановка контейнера '${CONTAINER}'... "
    sudo docker stop "$CONTAINER" >/dev/null 2>&1
    echo -e "${GREEN}готово${NC}"
}

restart_active() {
    if [ ! -f "$ACTIVE_CONFIG_FILE" ]; then
        echo -e "${RED} Нет активной конфигурации${NC}"
        return 1
    fi
    
    local name=$(grep "^NAME=" "$ACTIVE_CONFIG_FILE" | cut -d= -f2)
    load_config "$name" 2>/dev/null || return 1
    
    echo "🔄 Перезапуск '${name}'..."
    stop_container "$name"
    sleep 1
    start_proxy "$name" "$PORT" "$DOMAIN" "$CONTAINER"
}

interactive_mode() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                echo ""
                echo -e "${BLUE}➕ Добавление новой конфигурации${NC}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                read -p " Название конфигурации: " config_name
                [ -z "$config_name" ] && { echo -e "${RED} Название обязательно${NC}"; continue; }
                
                read -p "🌐 Fake TLS домен [${DEFAULT_FAKE_DOMAIN}]: " fake_domain
                fake_domain=${fake_domain:-$DEFAULT_FAKE_DOMAIN}
                
                read -p "🔌 Внешний порт [${DEFAULT_PORT}]: " ext_port
                ext_port=${ext_port:-$DEFAULT_PORT}
                
                read -p "🐳 Имя контейнера [${DEFAULT_CONTAINER_NAME}-${config_name}]: " container_name
                container_name=${container_name:-"${DEFAULT_CONTAINER_NAME}-${config_name}"}
                
                start_proxy "$config_name" "$ext_port" "$fake_domain" "$container_name"
                ;;
            2)
                list_configs
                ;;
            3)
                list_configs
                read -p "🔢 Номер конфигурации для запуска: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | sed -n "${num}p")
                if [ -n "$conf" ]; then
                    local name=$(basename "$conf" .conf)
                    load_config "$name" 2>/dev/null
                    start_proxy "$name" "${PORT:-443}" "${DOMAIN:-ya.ru}" "${CONTAINER:-${DEFAULT_CONTAINER_NAME}-${name}}"
                else
                    echo -e "${RED} Неверный номер${NC}"
                fi
                ;;
            4)
                list_configs
                read -p "🔢 Номер конфигурации для остановки: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | sed -n "${num}p")
                [ -n "$conf" ] && stop_container "$(basename "$conf" .conf)"
                ;;
            5)
                list_configs
                read -p "🔢 Номер конфигурации для удаления: " num
                local conf=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | sed -n "${num}p")
                [ -n "$conf" ] && delete_config "$(basename "$conf" .conf)"
                ;;
            6)
                show_active
                ;;
            7)
                restart_active
                ;;
            0)
                echo -e "${GREEN} До свидания!${NC}"
                exit 0
                ;;
            *)
                echo -e "${YELLOW} Неверный выбор${NC}"
                ;;
        esac
        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

cli_mode() {
    case "${1:-}" in
        add)
            shift
            start_proxy "${1:-default}" "${2:-443}" "${3:-ya.ru}" "${4:-mtproto-proxy-${1:-default}}"
            ;;
        list)
            list_configs
            ;;
        start)
            [ -z "$2" ] && { echo -e "${RED} Укажите название конфигурации${NC}"; exit 1; }
            load_config "$2" 2>/dev/null || exit 1
            start_proxy "$2" "${PORT:-443}" "${DOMAIN:-ya.ru}" "${CONTAINER:-mtproto-proxy-$2}"
            ;;
        stop)
            [ -z "$2" ] && { echo -e "${RED} Укажите название конфигурации${NC}"; exit 1; }
            stop_container "$2"
            ;;
        delete|rm)
            [ -z "$2" ] && { echo -e "${RED} Укажите название конфигурации${NC}"; exit 1; }
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
            echo "  active            - показать активную"
            echo "  restart           - перезапустить активную"
            ;;
        *)
            interactive_mode
            ;;
    esac
}

init_config_dir

if [ "$EUID" -ne 0 ] && ! sudo -v &>/dev/null; then
    echo -e "${YELLOW}⚠️  Для работы скрипта требуются права sudo${NC}"
fi

if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker не установлен${NC}"
    exit 1
fi

cli_mode "$@"