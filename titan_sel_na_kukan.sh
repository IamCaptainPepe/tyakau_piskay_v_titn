#!/bin/bash



# Прекращаем выполнение при ошибках
set -e

# Установка необходимых пакетов
echo "Установка необходимых пакетов..."
sudo apt-get update && sudo apt-get upgrade -y

# Добавляем репозиторий Docker и устанавливаем Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Установка Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Добавляем пользователя root в группу docker
usermod -aG docker root

# Префикс для контейнеров
CONTAINER_PREFIX="titan"

# Функция установки
installation_function() {
    # Прекращаем выполнение при ошибках в этой функции
    set -e

    # Имя Docker-образа
    IMAGE_NAME="titan_image"  # Новый образ, созданный на основе Ubuntu

    # Папка для хранения Machine ID
    MACHINE_ID_DIR="machine_ids"
    mkdir -p "$MACHINE_ID_DIR"

    # Создаём Dockerfile
    echo "Создаём Dockerfile..."

    cat <<EOF > Dockerfile
# Используем базовый образ Ubuntu
FROM ubuntu:22.04

# Установка необходимых пакетов
RUN apt-get update && apt-get install -y \\
    apt-transport-https \\
    ca-certificates \\
    curl \\
    software-properties-common \\
    uuid-runtime \\
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - \\
    && add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" \\
    && apt-get update \\
    && apt-get install -y docker-ce docker-ce-cli containerd.io \\
    && curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose \\
    && chmod +x /usr/local/bin/docker-compose \\
    && usermod -aG docker root

# Запуск демона Docker
CMD ["sh", "-c", "dockerd & tail -f /dev/null"]
EOF

    echo "Dockerfile создан."

    # Сборка Docker-образа
    echo "Сборка Docker-образа $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" .

    # Запрос количества контейнеров
    read -p "Введите количество контейнеров для создания: " CONTAINER_COUNT

    # Проверка на корректность ввода
    if [[ ! "$CONTAINER_COUNT" =~ ^[0-9]+$ ]]; then
        echo "Ошибка: введите число."
        return 1
    fi

    # Цикл для создания контейнеров
    for ((i=1; i<=CONTAINER_COUNT; i++)); do
        # Генерация уникального Machine ID для контейнера
        MACHINE_ID_FILE="$MACHINE_ID_DIR/machine_id_$i"
        uuidgen > "$MACHINE_ID_FILE"
        MACHINE_ID=$(cat "$MACHINE_ID_FILE")

        # Генерация уникального имени контейнера
        container_name="${CONTAINER_PREFIX}${i}"

        # Проверка на существование контейнера с таким именем
        while docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; do
            i=$((i + 1))  # Увеличиваем i для создания нового имени
            container_name="${CONTAINER_PREFIX}${i}"  # Обновляем имя контейнера
        done

        # Создание и запуск Docker-контейнеров с привилегиями
        if docker run -d --privileged --name "$container_name" --env MACHINE_ID="$MACHINE_ID" "$IMAGE_NAME"; then
            echo "Контейнер ${container_name} запущен с Machine ID $MACHINE_ID"
        else
            echo "Ошибка при запуске контейнера ${container_name}. Возможно, образ недоступен."
        fi
    done

    echo "Создано $CONTAINER_COUNT контейнеров."

    # Начинаем настройку контейнеров
    echo "Начинаем настройку контейнеров..."

    # Получаем список контейнеров с именем titan*
    containers=$(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}[0-9]*$")

    for container in $containers; do
        echo "Обработка контейнера $container"

        # Проверяем, запущен ли контейнер
        is_running=$(docker ps --format '{{.Names}}' | grep "^$container$")

        if [ -z "$is_running" ]; then
            echo "Контейнер $container не запущен. Запускаем..."
            docker start "$container"
        else
            echo "Контейнер $container уже запущен."
        fi

        # Проверяем, есть ли запущенные Docker-контейнеры внутри контейнера titan*
        running_containers=$(docker exec "$container" docker ps -q 2>/dev/null)

        if [ -z "$running_containers" ]; then
            echo "Внутри контейнера $container нет запущенных Docker-контейнеров. Выполняем настройки..."

            # Выполняем команды внутри контейнера titan*
            echo "Выполняем docker pull nezha123/titan-edge внутри $container"
            docker exec "$container" docker pull nezha123/titan-edge

            echo "Создаём директорию ~/.titanedge внутри $container"
            docker exec "$container" mkdir -p /root/.titanedge

            echo "Запускаем nezha123/titan-edge внутри $container"
            docker exec "$container" docker run --network=host -d -v /root/.titanedge:/root/.titanedge nezha123/titan-edge

            # Пауза 3 секунды для создания файла config.toml
            echo "Ожидание 3 секунд для создания config.toml"
            sleep 3

            # Извлекаем номер из имени контейнера
            port_number=$(echo "$container" | grep -o '[0-9]\+')
            port=$((1234 + port_number))

            # Заменяем порт в файле config.toml внутри контейнера
            echo "Изменяем порт на $port в файле config.toml внутри $container"
            docker exec "$container" sed -i "s/#ListenAddress = \"0.0.0.0:1234\"/ListenAddress = \"0.0.0.0:$port\"/" /root/.titanedge/config.toml

            # Запрашиваем Identity code у пользователя
            echo -n "Введите Identity code для контейнера $container: "
            read -r IDENTITY_CODE

            # Проверяем, что пользователь ввёл код
            if [ -z "$IDENTITY_CODE" ]; then
                echo "Ошибка: Identity code не может быть пустым. Пропускаем контейнер $container."
                continue
            fi

            # Выполняем команду bind внутри контейнера без опции -it
            echo "Выполняем команду bind внутри $container"
            docker exec "$container" docker run --rm -v /root/.titanedge:/root/.titanedge nezha123/titan-edge bind --hash="$IDENTITY_CODE" https://api-test1.container1.titannet.io/api/v2/device/binding

            echo "Настройка контейнера $container завершена."
        else
            echo "Внутри контейнера $container уже запущены Docker-контейнеры."
        fi

        echo "--------------------------------------------"
    done

    echo "Все контейнеры настроены."
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# Функция перезагрузки нод
restart_nodes_function() {
    echo "Перезагрузка нод..."

    # Получаем список контейнеров с именем titan*
    all_containers=$(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}[0-9]*$")

    if [ -z "$all_containers" ]; then
        echo "Нет доступных контейнеров для перезагрузки."
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    # Предлагаем выбрать контейнеры для перезагрузки
    echo "Вы хотите перезагрузить все ноды или выбрать конкретные?"
    echo "1) Все ноды"
    echo "2) Выбрать ноды"
    read -p "Выберите вариант [1-2]: " restart_choice

    if [ "$restart_choice" == "1" ]; then
        selected_containers=($all_containers)
    elif [ "$restart_choice" == "2" ]; then
        echo "Доступные контейнеры:"
        index=1
        declare -A container_map
        for container in $all_containers; do
            echo "$index) $container"
            container_map[$index]=$container
            index=$((index + 1))
        done
        read -p "Введите номера контейнеров через пробел: " -a selected_indices
        selected_containers=()
        for idx in "${selected_indices[@]}"; do
            selected_containers+=("${container_map[$idx]}")
        done
    else
        echo "Недопустимый вариант."
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    for container in "${selected_containers[@]}"; do
        echo "Обработка контейнера $container"

        # Проверяем, запущен ли контейнер
        is_running=$(docker ps --format '{{.Names}}' | grep "^$container$")

        if [ -z "$is_running" ]; then
            echo "Контейнер $container не запущен. Запускаем..."
            docker start "$container"
        else
            echo "Контейнер $container уже запущен."
        fi

        # Получаем ID запущенного Docker-контейнера внутри контейнера
        running_container_id=$(docker exec "$container" docker ps -q)

        if [ -n "$running_container_id" ]; then
            echo "Останавливаем контейнер внутри $container"
            docker exec "$container" docker stop "$running_container_id"
            echo "Запускаем контейнер внутри $container"
            docker exec "$container" docker start "$running_container_id"
            echo "Контейнер внутри $container перезапущен."
        else
            echo "Нет запущенных Docker-контейнеров внутри $container."
        fi

        echo "--------------------------------------------"
    done

    echo "Выбранные ноды перезагружены."
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# Функция просмотра логов
view_logs_function() {
    echo "Просмотр логов Docker..."

    # Запрашиваем количество строк логов
    read -p "Сколько последних строк логов вы хотите увидеть? " log_lines
    if [[ ! "$log_lines" =~ ^[0-9]+$ ]]; then
        echo "Ошибка: введите корректное число."
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    # Получаем список контейнеров с именем titan*
    all_containers=$(docker ps -a --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}[0-9]*$")

    if [ -z "$all_containers" ]; then
        echo "Нет доступных контейнеров для просмотра логов."
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    # Предлагаем выбрать контейнеры для просмотра логов
    echo "Вы хотите посмотреть логи всех нод или выбрать конкретные?"
    echo "1) Все ноды"
    echo "2) Выбрать ноды"
    read -p "Выберите вариант [1-2]: " log_choice

    if [ "$log_choice" == "1" ]; then
        selected_containers=($all_containers)
    elif [ "$log_choice" == "2" ]; then
        echo "Доступные контейнеры:"
        index=1
        declare -A container_map
        for container in $all_containers; do
            echo "$index) $container"
            container_map[$index]=$container
            index=$((index + 1))
        done
        read -p "Введите номера контейнеров через пробел: " -a selected_indices
        selected_containers=()
        for idx in "${selected_indices[@]}"; do
            selected_containers+=("${container_map[$idx]}")
        done
    else
        echo "Недопустимый вариант."
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    for container in "${selected_containers[@]}"; do
        echo "--------------------------------------------"
        echo "Логи Docker-контейнера внутри $container"

        # Проверяем, запущен ли контейнер
        is_running=$(docker ps --format '{{.Names}}' | grep "^$container$")

        if [ -z "$is_running" ]; then
            echo "Контейнер $container не запущен. Запускаем..."
            docker start "$container"
        fi

        # Получаем ID запущенного Docker-контейнера внутри контейнера
        running_container_id=$(docker exec "$container" docker ps -q)

        if [ -n "$running_container_id" ]; then
            # Отображаем последние N строк логов
            docker exec "$container" docker logs --tail "$log_lines" "$running_container_id" || echo "Ошибка при получении логов из контейнера внутри $container."
        else
            echo "Нет запущенных Docker-контейнеров внутри $container."
        fi

        echo "--------------------------------------------"
    done

    echo "Логи отображены."
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}


show_header() {
    echo -e "\033[97m# =------------------------------------==============+===---------------------------------------------\033[0m"
    echo -e "\033[97m# -----------------------------------=====--------------====------------------------------------------\033[0m"
    echo -e "\033[97m# --------------------------------=====--------------------===----=====-------------------------------\033[0m"
    echo -e "\033[97m# -------------------------------====--------=+**=-----------==--=----===-----------------------------\033[0m"
    echo -e "\033[97m# ------------------------------===---------+*###*------------==========-----------------=+=----------\033[0m"
    echo -e "\033[97m# -----------------------------===----------*##*+---------------==----------=====---==-=++==**--------\033[0m"
    echo -e "\033[97m# ----------------------------===--------------------------------=-------==-------+++**=-+#*++*=------\033[0m"
    echo -e "\033[97m# ----------------------------===-----=*+------------------------==---===-------+#*-:-+#+--*#====-----\033[0m"
    echo -e "\033[97m# ----------------------------===------+#+=----------------------==-===--------*##*+:::+#=--**:--=----\033[0m"
    echo -e "\033[97m# -----------=============----==--------+#*=-------=**##+--------====---------*####*=:::+#=-+=:::-==--\033[0m"
    echo -e "\033[97m# -------===---------------======--------=*#=-----=*####=--------===--------:+*#####*-:::+#=-:::::-=--\033[0m"
    echo -e "\033[97m# -----==--:::::::::::-------====---------=*#+-----=++=----------==----------*#######*-:::*#-::::::-=-\033[0m"
    echo -e "\033[97m# ---==--:::::::---:::--------===-----------*#*-----------------===----------*########+:::-**-=+=:::-=\033[0m"
    echo -e "\033[97m# --=--:::::::-*##**=----------===-----------+#*----------------==----------:+*########=:::-#+-=*+-=+=\033[0m"
    echo -e "\033[97m# -=-::::::::::=*###*----+*#+---===----------------------------=+=------------*########*=:::=#=-=#=-*= \033[0m"
    echo -e "\033[97m# =-:::::::::::::-------*###-----===--------------------------====-------------*########*-::-**-=*=-*= \033[0m"
    echo -e "\033[97m# =-:::::::::::::::----+###+-------===----------------------=======-------------+########*-::=#==*-=+=\033[0m"
    echo -e "\033[97m# -=-::::::::::::::::---=####---------=====----------------=====--===---------------=*######*--=#=--:-\033[0m"
    echo -e "\033[97m# -=-:::::::::::-::-:---+##%=----------=========------========-----===-----------------=+**#**+=-:::-=\033[0m"
    echo -e "\033[97m# -=-::::::::=*###**=---+##%-----------=--=================--------=+==-------------------::::::::--==-\033[0m"
    echo -e "\033[97m# -=-::::::::-*####+---*##%-----------==--============--------------=+==-------------------::::::--==--\033[0m"
    echo -e "\033[97m# =-::::::::::------=*#%+----------=====---------------------------==+==-----------------------==-----\033[0m"
    echo -e "\033[97m# =--:::::::::::----=*##------====----------------------------------======-------------------==-----=-\033[0m"
    echo -e "\033[97m# -=--::::::::::-----=#=---===----------==========------------------==--======------------====-------\033[0m"
    echo -e "\033[97m# --==--::::::::--------===----=========-=========------------============-----========----::==------\033[0m"
    echo -e "\033[97m# ----=----::::------===----=========-----==================----------------====------------:-==------\033[0m"
    echo -e "\033[97m# ------=----------==-----=======---======--------===-----------------------------------=+=-:-==-----\033[0m"
    echo -e "\033[97m# =-------===-----==-========---====---------===-----------------===-----------------======-:-==-----\033[0m"
    echo -e "\033[97m# -----------=-============--===------------=----------==========---==--=====--------=---+---:==-----\033[0m"
    echo -e "\033[97m# -----------=-:---======---=----------======----=---====--=====----==----------------=+=----:-=-----\033[0m"
    echo -e "\033[97m# -----------=-:-----===-----------=====----==--=====---------------==-------------------------=-----\033[0m"
    echo -e "\033[97m# -----------=-:-----------------==----==----=====------------------==-------------------------=---=-\033[0m"
    echo -e "\033[97m# -----------==::-----------------------==----====------------------==-------------------------=-----\033[0m"
    echo -e "\033[97m# -----------==-:-----------------------==-----===------------------==-------------------------=-----\033[0m"
    echo -e "\033[97m# ------------=-:------------------------=-----====------------------=------------------------==-=-=-\033[0m"
    echo -e "\033[97m# ------------==-------------------------==-----===------------------==-----------------------==-----\033[0m"
    echo -e "\033[97m# -------------=-:------------------------=-----===------------------==-----------------------===---=-\033[0m"
    echo -e "\033[97m# --------------=-------------------------==-----===-----------------==-----------------------=------\033[0m"
    echo -e "\033[97m# --------------==-------------------------============--------------==----------------------==-----=-\033[0m"
    echo -e "\033[97m# ---------------=----------------------====-------------------------==----------------------==----=-=\033[0m"
    echo -e "\033[97m# ----------------=------------------===-----===---------------------==---------------------==-------\033[0m"
    echo -e "\033[97m# -----------------=----------------==----============--------------===---------------------==-------\033[0m"
    echo -e "\033[97m# -----------------==--------------==---===--==----====================--------------------==--------\033[0m"
    echo -e "\033[97m# ------------------==-------------=----==----=--===-----===-----------====----------------===-------\033[0m"
    echo -e "\033[97m# -------------------==------------==---==---===-------=-----------------------------------==--=-----\033[0m"
    echo -e "\033[97m# ---------------------=-----------===--=====--------==-----=======-----------------------==-=-=-----\033[0m"
    echo -e "\033[97m# ----------------------=-----------===-==--------=====----==----=======-----------------===---------\033[0m"
    echo -e "\033[97m# -----------------------==-----========-==-----===--=----====---==-=======-------------==-----------\033[0m"
    echo -e "\033[97m# ------------------------==--=========---==---===---==---==-==--------=====-------====-=--==--------\033[0m"
    echo -e "\033[97m# -------------------------==---=======---==-=====---==---==-==-------==----======-----==---==-------\033[0m"
    echo -e "\033[97m# --------------------------===---------===---------===---==-==-----=======--===-------==--===-------\033[0m"
    echo -e "\033[97m# ----------------------------===------===---==---===--==--=--==---===--------------------=-----------\033[0m"
    echo -e "\033[97m# ------------------------------===----===---===-----====-------==----------------------------=------\033[0m"
    echo -e "\033[97m# --------------------------------===--===----=---===--------===--------------------------=-====---\033[0m"
    echo -e "\033[97m# -----------------------------------===------===------==-----=------------------------------------\033[0m"
    echo -e "\033[97m# ===================================----------===--------==------------------------------------\033[0m"
}




# Главное меню
while true; do
    clear
    show_header
    echo "==========================================="
    echo "Бегунки узлов vs TITAN"
    echo "==========================================="
    echo "1) Установка"
    echo "2) Перезагрузить ноды"
    echo "3) Посмотреть логи"
    echo "4) Выход"
    echo "==========================================="
    read -p "Пожалуйста, выберите пункт [1-4]: " choice

    case $choice in
        1)
            installation_function
            ;;
        2)
            restart_nodes_function
            ;;
        3)
            view_logs_function
            ;;
        4)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Недопустимый вариант!"
            read -p "Нажмите Enter, чтобы продолжить..."
            ;;
    esac
done
