#!/usr/bin/env bash

set +e;
set -uo pipefail;

# ---------------------------------------------
# --> VARS Definitions
# ---------------------------------------------
LOCK_FILE="/tmp/$(basename $0).lock"

#NGINX_ACCESS_LOG="/var/log/nginx/access.log";
NGINX_ACCESS_LOG="./access.log";

DATETIME_SNAPSHOT_CURRENT="$(tail -n 1 ${NGINX_ACCESS_LOG} | awk '{print $4,$5}')"
DATETIME_SNAPSHOT=""
LAST_ACCESS_DATA_FILE="$0.ladf"
TEMP_LOG_FILE=$(mktemp /tmp/nginx_log.XXXXXX)
TEMP_REPORT_FILE=$(mktemp /tmp/nginx_report.XXXXXX)
# ---------------------------------------------
# <-- VARS Definitions
# ---------------------------------------------

# ---------------------------------------------
# --> FUNCTIONS
# ---------------------------------------------
function dt_log {
  local __MSG="$(date +'%d.%m.%Y %H:%M:%S %Z(UTC%z)'): $1"
  # to stdout
  echo "${__MSG}"
  ## Add message also to `/var/log/syslog`
  # logger "${__MSG}"
}

function OnExitTrap() {
  echo -e "\nRemove [${LOCK_FILE}] file on exit"
  rm -rf "${LOCK_FILE}"

  echo -e "\nRemove temp report file [${TEMP_REPORT_FILE}] on exit"
  rm -rf "${TEMP_REPORT_FILE}"

  echo -e "\nRemove snapshot of log [${TEMP_LOG_FILE}] on exit"
  rm -rf "${TEMP_LOG_FILE}"
}

function GetDT() {
    if [[ -s "${LAST_ACCESS_DATA_FILE}" && -r "${LAST_ACCESS_DATA_FILE}" ]]; then
        source "${LAST_ACCESS_DATA_FILE}"
        echo "Last access DT exists: ${DATETIME_SNAPSHOT}"
    else
        echo "No previous access to log"
    fi    
}

function FreezeDT() {
    echo "DATETIME_SNAPSHOT='${DATETIME_SNAPSHOT_CURRENT}'" > "${LAST_ACCESS_DATA_FILE}"
}

function TakeLogSnapshotForReport() {
    if [ ! -n "${DATETIME_SNAPSHOT}" ]; then
        # Если не найдена точка предыдущего просмотра, то делаем снапшот всего лога
        cat "${NGINX_ACCESS_LOG}" > "${TEMP_LOG_FILE}"
    else
        # если есть - только то, что новое
        # Экранируем спецсимволы для работе в паттерне sed
        local __tmp=$(echo "${DATETIME_SNAPSHOT}" | sed 's!/!\\/!g' | sed 's!\[!\\[!g' | sed  's!\]!\\]!g' );
        sed -n "/${__tmp}/,\$p" ./access.log > "${TEMP_LOG_FILE}"
    fi
}

function PrepareReport() {
    if [ ! -s "${TEMP_LOG_FILE}" ]; then
        echo "Файл лога для отчета пустой. Нет данных для отправки."
        return
    fi

    echo "IP-адреса с наибольшим числом запросов (с момента последнего запуска)" >> "${TEMP_REPORT_FILE}"
    awk '{print $1}' "${TEMP_LOG_FILE}" | sort | uniq -c | sort -rn | head -n 5 >> "${TEMP_REPORT_FILE}"

    echo "Запрашиваемые URL с наибольшим числом запросов (с момента последнего запуска)" >> "${TEMP_REPORT_FILE}"
    awk '{print $7}' "${TEMP_LOG_FILE}" | sort | uniq -c | sort -rn | head -n 5 >> "${TEMP_REPORT_FILE}"

    echo "Ошибки веб-сервера/приложения (с момента последнего запуска)" >> "${TEMP_REPORT_FILE}"
    awk '$9 ~ /^[45][0-9][0-9]/ {print $9}' "${TEMP_LOG_FILE}" | sort | uniq -c | sort -rn | head -n 5 >> "${TEMP_REPORT_FILE}"

    echo "HTTP-коды ответов с указанием их количества (с момента последнего запуска)" >> "${TEMP_REPORT_FILE}"
    awk '$9 ~ /^[0-9][0-9][0-9]/ {print $9}' "${TEMP_LOG_FILE}" | sort | uniq -c | sort -rn | head -n 15 >> "${TEMP_REPORT_FILE}"

    # Отправка отчета на почту
    send_yandex_email_with_attachment \
        "blackmind79@gmail.com" \
        "Отчет с вложением" \
        "Во вложении находится файл отчета" \
        "${TEMP_REPORT_FILE}"
}

# Отправка через SMTP Яндекса
function send_yandex_email_with_attachment() {
    # Считываем данные для отправки почты
    source ./.env
    
    if [ ! -n "${SEND_FROM}" ]; then
      echo "Не заполнен e-mail отправителя!"
      exit 2
    fi

    if [ ! -n "${SEND_PASSWORD}" ]; then
      echo "Не заполнен пароль отправителя!"
      exit 3
    fi

    local to="$1"
    local subject=$(echo -n "$2" | base64) # Проблема с кириллицей
    local body="$3"
    local attachment="$4"  # путь к файлу
    local attachment_filename="$(basename $attachment)"
    local from="${SEND_FROM}"
    local password="${SEND_PASSWORD}"  # Пароль приложения!

    # Проверка существования файла
    if [ ! -f "$attachment" ]; then
      echo "Ошибка: Файл '$attachment' не найден" >&2
      return 1
    fi

    swaks --server smtp.yandex.ru:587 \
          --auth LOGIN \
          --auth-user "$from" \
          --auth-password "$password" \
          --tls \
          --to "$to" \
          --from "$from" \
          --header "Subject: =?UTF-8?B?$subject?=" \
          --body "$body" \
          --attach-name "$attachment_filename" \
          --attach-type "text/plain" \
          --attach @"$attachment"
}

# ---------------------------------------------
# <-- FUNCTIONS
# ---------------------------------------------
# -s: файл существует и не пустой
# -r: файл существует и доступен для чтения
if [[ -s "${LOCK_FILE}" && -r "${LOCK_FILE}" ]]; then
  source "${LOCK_FILE}"
  echo "Another instance of script $0 is running"
  echo "Current PID is $$"
  echo "PID in lock-file is ${PID}"
  exit 1;
fi

# Create lock-file
echo "Create lock-file [${LOCK_FILE}]"
echo "PID=$$" > "${LOCK_FILE}"

trap OnExitTrap EXIT
trap '' INT

# Получаем дату последней записи предыдущего обращения к логу
GetDT

# Создаем снапшот файла лога (от последнего прочтения) для работы с ним при построении отчета
TakeLogSnapshotForReport

# Собираем отчет во временный файл
PrepareReport

# Сохраняем дату последней записи лога для того, чтобы потом читать с нее
# Сохраняем последним шагом, чтобы в случае ошибки не было перезаписано
FreezeDT

# Для отладки
if [ ! -n "${DATETIME_SNAPSHOT}" ]; then
  echo "DATETIME_SNAPSHOT is <no value>"
else
  echo "DATETIME_SNAPSHOT is ${DATETIME_SNAPSHOT}"
fi
echo "DATETIME_SNAPSHOT_CURRENT is ${DATETIME_SNAPSHOT_CURRENT}"

## Раскомментируйте, если требуется отключить трапы дальше
# trap - EXIT
# trap - INT