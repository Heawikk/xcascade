#!/usr/bin/env bash
#
# xcascade — каскадные пробросы портов (DNAT) на nftables.
#
# Принципы:
#   * все правила живут в отдельной таблице nft «ip xcascade» — чужой файрвол не трогаем;
#   * источник правды — /etc/xcascade/rules.conf, nft-конфиг генерируется из него;
#   * применение атомарное: сначала проверка (nft -c), потом загрузка, потом сохранение;
#   * перед каждым изменением делается бэкап списка правил;
#   * автозагрузка через systemd-юнит xcascade.service.
#
# Справка: xcascade help
# Репозиторий: https://github.com/Heawikk/xcascade
#
set -u
set -o pipefail

VERSION="1.0.0"
PROG="xcascade"
REPO_URL="https://github.com/Heawikk/xcascade"

CONF_DIR="${XCASCADE_CONF_DIR:-/etc/xcascade}"
RULES_FILE="$CONF_DIR/rules.conf"
NFT_FILE="$CONF_DIR/xcascade.nft"
BACKUP_DIR="$CONF_DIR/backups"
LOCK_FILE="${XCASCADE_LOCK_FILE:-/run/xcascade.lock}"
NFT_TABLE="xcascade"
TAG_PREFIX="xcascade:"
BIN_PATH="/usr/local/bin/xcascade"
UNIT_NAME="xcascade.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
SYSCTL_FWD="/etc/sysctl.d/99-xcascade.conf"
SYSCTL_BBR="/etc/sysctl.d/99-xcascade-bbr.conf"
MODULES_BBR="/etc/modules-load.d/xcascade-bbr.conf"
MAX_BACKUPS=20

INTERACTIVE=0
DOCTOR_BAD=0

# ---------------------------------------------------------------- вывод ----
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

info() { printf '%s\n' "${C_CYN}[*]${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GRN}[OK]${C_OFF} $*"; }
warn() { printf '%s\n' "${C_YEL}[!]${C_OFF} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[ОШИБКА]${C_OFF} $*" >&2; }

# ------------------------------------------------------------ утилиты ------
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ $EUID -eq 0 ]] && return 0
    err "Нужны права root. Запустите: sudo $PROG ..."
    return 1
}

need_nft() {
    have nft && return 0
    err "nftables не установлен. Выполните: sudo $PROG install"
    return 1
}

confirm() {
    local a
    read -r -p "$1 [y/N]: " a || return 1
    a=${a,,}
    [[ $a == y || $a == yes ]]
}

pause() { read -r -p "Enter — назад..." _ || true; }

lock() {
    have flock || return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    if ! exec 9>"$LOCK_FILE"; then
        err "Не удалось открыть lock-файл $LOCK_FILE"
        return 1
    fi
    if ! flock -w 10 9; then
        err "Другой экземпляр $PROG уже изменяет правила. Попробуйте позже."
        exec 9>&-
        return 1
    fi
}

# Важно: у exec перенаправления постоянны, поэтому здесь только закрытие fd 9.
unlock() { exec 9>&-; }

with_lock() {
    lock || return 1
    "$@"
    local rc=$?
    unlock
    return $rc
}

ensure_dirs() {
    mkdir -p "$CONF_DIR" "$BACKUP_DIR" && chmod 700 "$CONF_DIR"
}

# --------------------------------------------------------- валидация -------
OCT='(0|[1-9][0-9]{0,2})'

is_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^$OCT\.$OCT\.$OCT\.$OCT$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( o <= 255 )) || return 1
    done
    return 0
}

is_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

# одиночный порт или диапазон a-b
is_portspec() {
    local s=$1 a b
    if [[ $s =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        is_port "$a" && is_port "$b" && (( a < b ))
    else
        is_port "$s"
    fi
}

valid_proto() { [[ $1 == tcp || $1 == udp || $1 == both ]]; }
valid_name()  { [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

port_lo() { echo "${1%-*}"; }
port_hi() { echo "${1#*-}"; }

protos_of() {
    case $1 in
        both) echo "tcp udp" ;;
        *)    echo "$1" ;;
    esac
}

protos_overlap() { [[ $1 == both || $2 == both || $1 == "$2" ]]; }

ranges_overlap() {
    local alo ahi blo bhi
    alo=$(port_lo "$1"); ahi=$(port_hi "$1")
    blo=$(port_lo "$2"); bhi=$(port_hi "$2")
    (( alo <= bhi && blo <= ahi ))
}

local_ipv4s() {
    ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'
}

# Недопустимые цели: служебные адреса и адреса самого сервера (зацикливание).
validate_target_ip() {
    local ip=$1 a
    a=${ip%%.*}
    if (( a == 0 || a == 127 || a >= 224 )); then
        err "Недопустимый адрес назначения: $ip"
        return 1
    fi
    if local_ipv4s | grep -qxF "$ip"; then
        err "$ip — адрес этого же сервера, проброс зациклится."
        return 1
    fi
    return 0
}

# Порты, на которых слушают локальные службы (tcp|udp).
listening_ports() {
    local flag=-tln
    [[ $1 == udp ]] && flag=-uln
    ss -H "$flag" 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | sort -un
}

ssh_ports() {
    local p
    p=$(ss -H -tlnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}' | sort -un)
    if [[ -n $p ]]; then echo "$p"; else echo 22; fi
}

# 0 — всё хорошо; 1 — критично (SSH); 2 — предупреждения (занятые порты).
safety_check() {
    local proto=$1 inspec=$2 rc=0 lo hi sp q p ssh_list
    lo=$(port_lo "$inspec"); hi=$(port_hi "$inspec")
    ssh_list=" $(ssh_ports | tr '\n' ' ')"

    while read -r sp; do
        [[ -n $sp ]] || continue
        if (( sp >= lo && sp <= hi )); then
            err "Порт $sp занят SSH: проброс отрежет вам доступ к серверу."
            rc=1
        fi
    done < <(ssh_ports)

    for p in $(protos_of "$proto"); do
        while read -r q; do
            [[ $q =~ ^[0-9]+$ ]] || continue
            (( q >= lo && q <= hi )) || continue
            [[ $ssh_list == *" $q "* ]] && continue
            warn "На порту $q/$p уже слушает локальная служба — снаружи она станет недоступна."
            (( rc == 0 )) && rc=2
        done < <(listening_ports "$p")
    done
    return $rc
}

# --------------------------------------------------------- правила ---------
R_NAME=(); R_PROTO=(); R_IN=(); R_IP=(); R_OUT=()

load_rules() {
    local file=${1:-$RULES_FILE}
    R_NAME=(); R_PROTO=(); R_IN=(); R_IP=(); R_OUT=()
    [[ -f $file ]] || return 0
    local name="" proto inp ip out extra ln=0
    while read -r name proto inp ip out extra || [[ -n ${name:-} ]]; do
        ln=$((ln + 1))
        [[ -z ${name:-} || $name == \#* ]] && continue
        if [[ -n ${extra:-} ]] || ! valid_name "$name" || ! valid_proto "${proto:-}" \
            || ! is_portspec "${inp:-}" || ! is_ipv4 "${ip:-}" || ! is_portspec "${out:-}"; then
            err "Повреждённая строка $ln в $file: $name ${proto:-} ${inp:-} ${ip:-} ${out:-}"
            return 1
        fi
        R_NAME+=("$name"); R_PROTO+=("$proto"); R_IN+=("$inp"); R_IP+=("$ip"); R_OUT+=("$out")
    done < "$file"
    return 0
}

save_rules() {
    local tmp i
    tmp=$(mktemp "$CONF_DIR/.rules.XXXXXX") || return 1
    {
        echo "# xcascade: имя протокол вход ip выход"
        for ((i = 0; i < ${#R_NAME[@]}; i++)); do
            echo "${R_NAME[i]} ${R_PROTO[i]} ${R_IN[i]} ${R_IP[i]} ${R_OUT[i]}"
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$RULES_FILE"
}

remove_rule_at() {
    local idx=$1 i
    local -a n=() p=() a=() ip=() o=()
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        (( i == idx )) && continue
        n+=("${R_NAME[i]}"); p+=("${R_PROTO[i]}"); a+=("${R_IN[i]}")
        ip+=("${R_IP[i]}"); o+=("${R_OUT[i]}")
    done
    R_NAME=("${n[@]}"); R_PROTO=("${p[@]}"); R_IN=("${a[@]}")
    R_IP=("${ip[@]}"); R_OUT=("${o[@]}")
}

# Печатает nft-конфиг для текущих R_* массивов.
gen_nft() {
    local i p dest
    cat <<EOF
# Сгенерировано $PROG $VERSION. Не редактируйте вручную: правила хранятся в $RULES_FILE
add table ip $NFT_TABLE
delete table ip $NFT_TABLE
table ip $NFT_TABLE {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
EOF
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        if [[ ${R_IN[i]} == *-* ]]; then
            dest="${R_IP[i]}"                 # диапазон: порты сохраняются
        else
            dest="${R_IP[i]}:${R_OUT[i]}"
        fi
        for p in $(protos_of "${R_PROTO[i]}"); do
            printf '    %s dport %s counter dnat to %s comment "%s%s"\n' \
                "$p" "${R_IN[i]}" "$dest" "$TAG_PREFIX" "${R_NAME[i]}"
        done
    done
    cat <<EOF
  }

  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
EOF
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        for p in $(protos_of "${R_PROTO[i]}"); do
            printf '    ct status dnat ip daddr %s %s dport %s masquerade comment "%s%s"\n' \
                "${R_IP[i]}" "$p" "${R_OUT[i]}" "$TAG_PREFIX" "${R_NAME[i]}"
        done
    done
    cat <<EOF
  }
}
EOF
}

# Проверка + загрузка в ядро + сохранение файла для автозагрузки.
apply_nft() {
    local tmp out
    tmp=$(mktemp "$CONF_DIR/.nft.XXXXXX") || { err "Не удалось создать временный файл в $CONF_DIR"; return 1; }
    gen_nft > "$tmp"
    if ! out=$(nft -c -f "$tmp" 2>&1); then
        err "nft отклонил конфигурацию, ничего не изменено:"
        printf '%s\n' "$out" >&2
        rm -f "$tmp"
        return 1
    fi
    if ! out=$(nft -f "$tmp" 2>&1); then
        err "Не удалось загрузить правила в ядро:"
        printf '%s\n' "$out" >&2
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$NFT_FILE"
}

make_backup() {
    [[ -s $RULES_FILE ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local f
    f="$BACKUP_DIR/rules-$(date +%Y%m%d-%H%M%S).conf"
    cp -f "$RULES_FILE" "$f" && chmod 600 "$f"
    ls -1t "$BACKUP_DIR"/rules-*.conf 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f --
}

commit() {
    ensure_dirs || { err "Не удалось создать $CONF_DIR"; return 1; }
    make_backup
    apply_nft || return 1
    save_rules || { err "Не удалось сохранить $RULES_FILE"; return 1; }
}

# ------------------------------------------------------------- UFW ---------
ufwc() { LC_ALL=C ufw "$@"; }

ufw_active() { have ufw && ufwc status 2>/dev/null | grep -q '^Status: active'; }

ufw_add_rule() {
    ufw_active || return 0
    local i=$1 p spec
    spec=${R_OUT[i]/-/:}
    for p in $(protos_of "${R_PROTO[i]}"); do
        if ! ufwc route allow proto "$p" from any to "${R_IP[i]}" port "$spec" \
            comment "${TAG_PREFIX}${R_NAME[i]}" >/dev/null 2>&1; then
            warn "UFW: не удалось добавить route-правило для ${R_NAME[i]} ($p). Проверьте: $PROG doctor"
            return 1
        fi
    done
}

ufw_add_all() {
    local i
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do ufw_add_rule "$i"; done
}

# Удаляет route-правила, созданные xcascade (все или только с именем $1).
ufw_purge() {
    ufw_active || return 0
    local filter="comment '${TAG_PREFIX}" line
    [[ -n ${1:-} ]] && filter="comment '${TAG_PREFIX}$1'"
    ufwc show added 2>/dev/null | grep -F -- "$filter" | while IFS= read -r line; do
        line=${line#ufw }
        line=${line%% comment *}
        local -a a
        read -ra a <<<"$line"
        # a = (route allow proto tcp from any to IP port N)
        [[ ${a[0]:-} == route && ${a[1]:-} == allow ]] || continue
        ufwc --force route delete allow "${a[@]:2}" >/dev/null 2>&1
    done
    return 0
}

# ------------------------------------------------------------ add ----------
server_ip() {
    local ip pub
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    if [[ $ip =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]] && have curl; then
        pub=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null)
        is_ipv4 "${pub:-}" && ip=$pub
    fi
    echo "${ip:-<IP-этого-сервера>}"
}

usage_add() {
    cat <<EOF
Использование: $PROG add <tcp|udp|both> <порт|диапазон> <ip[:порт]> [имя] [опции]

  <порт>    порт на этом сервере; диапазон: 20000-20100
  <ip:порт> целевой сервер; если порт не указан — тот же, что на входе
            (для диапазонов порты всегда сохраняются)
  [имя]     a-z, 0-9, _ и -; по умолчанию proto-порт

Опции:
  --name N    то же, что [имя]
  --force     создать правило несмотря на предупреждения (SSH, занятые порты)
  --dry-run   показать конфиг и проверить его через nft -c, ничего не применяя
  --no-ufw    не добавлять route-правила в UFW
EOF
}

cmd_add() {
    local name="" force=0 dry=0 noufw=0
    local -a pos=()
    while (( $# )); do
        case $1 in
            -n|--name)
                [[ $# -ge 2 ]] || { err "--name требует значение"; return 1; }
                name=$2; shift 2 ;;
            --force)   force=1; shift ;;
            --dry-run) dry=1; shift ;;
            --no-ufw)  noufw=1; shift ;;
            -h|--help) usage_add; return 0 ;;
            -*)        err "Неизвестная опция: $1"; return 1 ;;
            *)         pos+=("$1"); shift ;;
        esac
    done
    if (( ${#pos[@]} < 3 || ${#pos[@]} > 4 )); then
        usage_add >&2
        return 1
    fi
    [[ -z $name && ${#pos[@]} -eq 4 ]] && name=${pos[3]}
    add_rule "${pos[0]}" "${pos[1]}" "${pos[2]}" "$name" "$force" "$dry" "$noufw"
}

add_rule() {
    local proto=${1,,} inspec=$2 to=$3 name=$4 force=$5 dry=$6 noufw=$7
    local ip outspec
    need_root || return 1
    need_nft || return 1

    valid_proto "$proto" || { err "Протокол должен быть tcp, udp или both"; return 1; }
    is_portspec "$inspec" || { err "Некорректный входящий порт: $inspec"; return 1; }
    if [[ $to == *:* ]]; then
        ip=${to%%:*}; outspec=${to#*:}
    else
        ip=$to; outspec=$inspec
    fi
    is_ipv4 "$ip" || { err "Некорректный IPv4-адрес: $ip"; return 1; }
    is_portspec "$outspec" || { err "Некорректный порт назначения: $outspec"; return 1; }
    if [[ ( $inspec == *-* || $outspec == *-* ) && $inspec != "$outspec" ]]; then
        err "Диапазоны пробрасываются только с сохранением портов (вход и выход должны совпадать)."
        return 1
    fi
    validate_target_ip "$ip" || return 1
    [[ -z $name ]] && name="${proto}-${inspec}"
    valid_name "$name" || { err "Недопустимое имя «$name»: разрешены a-z, 0-9, _ и - (до 32 символов)"; return 1; }

    with_lock _add_locked "$proto" "$inspec" "$ip" "$outspec" "$name" "$force" "$dry" "$noufw"
}

_add_locked() {
    local proto=$1 inspec=$2 ip=$3 outspec=$4 name=$5 force=$6 dry=$7 noufw=$8
    local i rc n sip
    load_rules || return 1

    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        if [[ ${R_NAME[i]} == "$name" ]]; then
            err "Правило с именем «$name» уже есть. Выберите другое имя или удалите старое: $PROG del $name"
            return 1
        fi
        if protos_overlap "$proto" "${R_PROTO[i]}" && ranges_overlap "$inspec" "${R_IN[i]}"; then
            err "Порт ${R_PROTO[i]}/${R_IN[i]} уже занят правилом «${R_NAME[i]}»."
            return 1
        fi
    done

    safety_check "$proto" "$inspec"
    rc=$?
    if (( rc != 0 )); then
        if (( force )); then
            warn "Продолжаю из-за --force."
        elif (( INTERACTIVE )) && confirm "Всё равно создать правило?"; then
            :
        else
            err "Отменено. Исправьте причину или добавьте --force (на свой риск)."
            return 1
        fi
    fi

    R_NAME+=("$name"); R_PROTO+=("$proto"); R_IN+=("$inspec"); R_IP+=("$ip"); R_OUT+=("$outspec")
    n=$((${#R_NAME[@]} - 1))

    if (( dry )); then
        gen_nft
        if gen_nft | nft -c -f - 2>&1; then
            ok "Конфигурация корректна (dry-run, ничего не применено)."
            return 0
        fi
        return 1
    fi

    commit || return 1
    (( noufw )) || ufw_add_rule "$n"

    sip=$(server_ip)
    ok "Правило «$name» создано: $proto $inspec -> $ip:$outspec"
    echo "   Клиентам указывайте адрес ${C_GRN}${sip}${C_OFF} и порт ${C_GRN}${inspec}${C_OFF} вместо зарубежного сервера."
}

# ------------------------------------------------------------ list/del -----
cmd_list() {
    load_rules || return 1
    local n=${#R_NAME[@]} i
    if (( n == 0 )); then
        info "Правил нет. Добавьте: $PROG add udp 51820 203.0.113.10"
        return 0
    fi
    echo "Адрес этого сервера: ${C_GRN}$(server_ip)${C_OFF}"
    echo
    printf '%-3s %-20s %-6s %-13s %s\n' "#" "NAME" "PROTO" "IN" "TARGET"
    for ((i = 0; i < n; i++)); do
        printf '%-3s %-20s %-6s %-13s %s\n' \
            "$((i + 1))" "${R_NAME[i]}" "${R_PROTO[i]}" "${R_IN[i]}" "${R_IP[i]}:${R_OUT[i]}"
    done
}

cmd_del() {
    [[ $# -eq 1 ]] || { err "Использование: $PROG del <имя|номер>"; return 1; }
    need_root || return 1
    need_nft || return 1
    with_lock _del_locked "$1"
}

_del_locked() {
    local key=$1 idx=-1 i name
    load_rules || return 1
    if [[ $key =~ ^[0-9]+$ ]]; then
        idx=$((10#$key - 1))
        (( idx >= 0 && idx < ${#R_NAME[@]} )) || idx=-1
    else
        for ((i = 0; i < ${#R_NAME[@]}; i++)); do
            [[ ${R_NAME[i]} == "$key" ]] && idx=$i
        done
    fi
    if (( idx < 0 )); then
        err "Правило не найдено: $key"
        return 1
    fi
    name=${R_NAME[idx]}
    remove_rule_at "$idx"
    commit || return 1
    ufw_purge "$name"
    ok "Правило «$name» удалено."
    info "Уже установленные соединения живут до своего завершения (conntrack)."
}

# ------------------------------------------------------------- stats -------
cmd_stats() {
    need_root || return 1
    need_nft || return 1
    if ! nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
        err "Таблица $NFT_TABLE не загружена. Выполните: $PROG apply"
        return 1
    fi
    printf '%-20s %-6s %-13s %-10s %s\n' "NAME" "PROTO" "IN" "PACKETS" "TRAFFIC"
    local line name proto inport pk by traffic
    nft list chain ip "$NFT_TABLE" prerouting | while IFS= read -r line; do
        [[ $line == *"comment \"$TAG_PREFIX"* ]] || continue
        line=${line#"${line%%[![:space:]]*}"}
        name=$(sed -nE "s/.*comment \"${TAG_PREFIX}([^\"]+)\".*/\1/p" <<<"$line")
        read -r proto _ inport _ <<<"$line"
        read -r pk by < <(sed -nE 's/.*packets ([0-9]+) bytes ([0-9]+).*/\1 \2/p' <<<"$line")
        traffic=$(numfmt --to=iec --suffix=B "${by:-0}" 2>/dev/null || echo "${by:-0}B")
        printf '%-20s %-6s %-13s %-10s %s\n' "$name" "$proto" "$inport" "${pk:-0}" "$traffic"
    done
    echo
    info "Считается трафик клиент → цель; счётчики обнуляются при каждом изменении правил."
}

# ------------------------------------------------------------- check -------
cmd_check() {
    local only=${1:-} i found=0 ip port p bad=0
    load_rules || return 1
    if (( ${#R_NAME[@]} == 0 )); then info "Правил нет."; return 0; fi
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        [[ -n $only && ${R_NAME[i]} != "$only" ]] && continue
        found=1
        ip=${R_IP[i]}
        port=$(port_lo "${R_OUT[i]}")
        echo "${C_BLD}${R_NAME[i]}${C_OFF}  (${R_PROTO[i]} ${R_IN[i]} -> $ip:${R_OUT[i]})"
        if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
            ok "ping $ip отвечает"
        else
            warn "ping $ip не проходит (ICMP может быть закрыт — это не всегда ошибка)"
        fi
        for p in $(protos_of "${R_PROTO[i]}"); do
            if [[ $p == tcp ]]; then
                if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$ip" "$port" 2>/dev/null; then
                    ok "TCP $ip:$port — порт открыт"
                else
                    err "TCP $ip:$port недоступен"
                    bad=1
                fi
            else
                info "UDP $ip:$port: без ответа службы надёжно не проверить — проверьте подключением клиента"
            fi
        done
    done
    if (( ! found )); then err "Правило не найдено: $only"; return 1; fi
    return $bad
}

# ------------------------------------------------------------ doctor -------
d_ok()   { printf '  %s %s\n' "${C_GRN}✔${C_OFF}" "$*"; }
d_warn() { printf '  %s %s\n' "${C_YEL}!${C_OFF}" "$*"; }
d_bad()  { printf '  %s %s\n' "${C_RED}✘${C_OFF}" "$*"; DOCTOR_BAD=1; }

cmd_doctor() {
    need_root || return 1
    DOCTOR_BAD=0
    local i fwd cc pol

    echo "${C_BLD}Диагностика $PROG $VERSION${C_OFF}"

    if have nft; then d_ok "nftables: $(nft --version 2>/dev/null)"; else d_bad "nftables не установлен ($PROG install)"; fi

    if load_rules; then d_ok "Конфигурация $RULES_FILE читается, правил: ${#R_NAME[@]}"; else d_bad "Конфигурация повреждена"; fi

    if have nft; then
        if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
            d_ok "Таблица nft «$NFT_TABLE» загружена"
        elif (( ${#R_NAME[@]} > 0 )); then
            d_bad "Таблица nft «$NFT_TABLE» не загружена, хотя правила есть — выполните: $PROG apply"
        else
            d_warn "Таблица nft «$NFT_TABLE» не загружена (правил нет)"
        fi
    fi

    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ $fwd == 1 ]]; then d_ok "net.ipv4.ip_forward = 1"; else d_bad "net.ipv4.ip_forward = ${fwd:-?} — пересылка выключена ($PROG install)"; fi
    if [[ -f $SYSCTL_FWD ]]; then d_ok "Пересылка сохранена в $SYSCTL_FWD"; else d_warn "Нет $SYSCTL_FWD: после перезагрузки пересылка может выключиться"; fi

    if have systemctl && [[ -d /run/systemd/system ]]; then
        if systemctl is-enabled "$UNIT_NAME" >/dev/null 2>&1; then
            d_ok "Автозагрузка $UNIT_NAME включена"
        else
            d_bad "Автозагрузка $UNIT_NAME не включена ($PROG install)"
        fi
    else
        d_warn "systemd не найден: добавьте «$PROG apply» в автозагрузку вручную"
    fi

    if ufw_active; then
        d_ok "UFW активен"
        for ((i = 0; i < ${#R_NAME[@]}; i++)); do
            if ufwc show added 2>/dev/null | grep -qF "comment '${TAG_PREFIX}${R_NAME[i]}'"; then
                d_ok "UFW: есть route-правило для «${R_NAME[i]}»"
            else
                d_bad "UFW: нет route-правила для «${R_NAME[i]}» — трафик будет блокироваться. Выполните: $PROG apply"
            fi
        done
    elif have iptables; then
        pol=$(iptables -S FORWARD 2>/dev/null | head -n1)
        if [[ $pol == "-P FORWARD DROP" ]]; then
            d_warn "iptables: политика FORWARD = DROP (Docker?). Проброс не пройдёт, пока вы не разрешите форвардинг к целям в своём файрволе."
        else
            d_ok "iptables FORWARD не блокирует проброс"
        fi
    fi

    if [[ -f /etc/nftables.conf ]] && grep -q 'flush ruleset' /etc/nftables.conf \
        && systemctl is-enabled nftables.service >/dev/null 2>&1; then
        d_warn "nftables.service делает «flush ruleset»: его reload сотрёт и таблицу $NFT_TABLE. Восстановление: $PROG apply (при restart сервиса xcascade перезапускается сам)"
    fi

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    d_ok "TCP congestion control: ${cc:-?} (BBR на роутере почти не влияет на проброс, см. README)"

    echo
    if (( DOCTOR_BAD )); then err "Есть проблемы — см. пункты ✘ выше."; return 1; fi
    ok "Проблем не найдено."
}

# ------------------------------------------------------------- apply -------
cmd_apply() {
    need_root || return 1
    need_nft || return 1
    with_lock _apply_locked
}

_apply_locked() {
    ensure_dirs || return 1
    load_rules || return 1
    apply_nft || return 1
    ufw_purge
    ufw_add_all
    ok "Правила применены (${#R_NAME[@]} шт.)."
}

# ------------------------------------------------------ backup/restore -----
cmd_backup() {
    need_root || return 1
    if [[ ! -s $RULES_FILE ]]; then info "Нечего сохранять: правил нет."; return 0; fi
    ensure_dirs || return 1
    make_backup
    ok "Бэкап сохранён в $BACKUP_DIR (последний: $(ls -1t "$BACKUP_DIR"/rules-*.conf 2>/dev/null | head -n1))"
}

cmd_restore() {
    need_root || return 1
    need_nft || return 1
    local f=${1:-}
    if [[ -z $f ]]; then
        local -a bk=()
        mapfile -t bk < <(ls -1t "$BACKUP_DIR"/rules-*.conf 2>/dev/null)
        if (( ${#bk[@]} == 0 )); then info "Бэкапов нет."; return 0; fi
        echo "Доступные бэкапы:"
        printf '  %s\n' "${bk[@]}"
        echo "Восстановить: $PROG restore <файл>"
        return 0
    fi
    [[ -f $f ]] || f="$BACKUP_DIR/$f"
    [[ -f $f ]] || { err "Файл не найден: $1"; return 1; }
    with_lock _restore_locked "$f"
}

_restore_locked() {
    local f=$1
    ensure_dirs || return 1
    load_rules "$f" || { err "Файл бэкапа повреждён, ничего не изменено."; return 1; }
    ufw_purge
    commit || return 1
    ufw_add_all
    ok "Восстановлено из $f (правил: ${#R_NAME[@]})."
}

# --------------------------------------------------------------- bbr -------
cmd_bbr() {
    need_root || return 1
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cur == bbr ]]; then ok "BBR уже включён."; return 0; fi
    modprobe tcp_bbr 2>/dev/null
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
        err "Ядро не поддерживает BBR (нужно Linux >= 4.9 с модулем tcp_bbr)."
        return 1
    fi
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_BBR"
    echo tcp_bbr > "$MODULES_BBR" 2>/dev/null
    if sysctl -q -p "$SYSCTL_BBR" >/dev/null 2>&1; then
        ok "BBR включён и сохранён в $SYSCTL_BBR."
        info "Важно: BBR ускоряет только TCP-сессии самого сервера. Проброшенный трафик идёт сквозь сервер между клиентом и целью и от BBR здесь не ускоряется."
    else
        err "Не удалось применить sysctl из $SYSCTL_BBR"
        return 1
    fi
}

# ----------------------------------------------------- install/uninstall ---
install_deps() {
    have nft && return 0
    if ! have apt-get; then
        err "nftables не найден, а apt-get недоступен. Установите nftables вручную и повторите."
        return 1
    fi
    info "Устанавливаю nftables..."
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null; }; then
        err "Не удалось установить nftables."
        return 1
    fi
}

write_unit() {
    local nftbin
    nftbin=$(command -v nft)
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=XCascade: правила проброса портов (nftables)
After=network-pre.target nftables.service ufw.service
Wants=network-pre.target
PartOf=nftables.service
ConditionPathExists=$NFT_FILE

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nftbin -f $NFT_FILE
ExecReload=$nftbin -f $NFT_FILE
ExecStop=-$nftbin delete table ip $NFT_TABLE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1
}

cmd_install() {
    local want_bbr=0 self
    while (( $# )); do
        case $1 in
            --bbr) want_bbr=1 ;;
            *) err "Неизвестная опция: $1"; return 1 ;;
        esac
        shift
    done
    need_root || return 1

    if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        err "Нужен bash >= 4.4"
        return 1
    fi
    install_deps || return 1
    ensure_dirs || return 1

    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    if [[ -f $self && $self != "$BIN_PATH" ]]; then
        install -m 755 "$self" "$BIN_PATH" || { err "Не удалось скопировать скрипт в $BIN_PATH"; return 1; }
    elif [[ ! -f $BIN_PATH ]]; then
        err "Скачайте скрипт в файл и запустите из него (запуск через pipe не поддерживается)."
        return 1
    fi

    printf 'net.ipv4.ip_forward = 1\n' > "$SYSCTL_FWD"
    sysctl -q -p "$SYSCTL_FWD" >/dev/null 2>&1 || warn "Не удалось включить ip_forward сейчас — проверьте: $PROG doctor"

    with_lock _install_rules || return 1

    if have systemctl && [[ -d /run/systemd/system ]]; then
        write_unit
        systemctl start "$UNIT_NAME" >/dev/null 2>&1
    else
        warn "systemd не найден: автозагрузку правил настройте вручную (команда: $PROG apply)."
    fi

    (( want_bbr )) && cmd_bbr
    ok "Установлено. Команда: $PROG  (меню) или $PROG help"
}

_install_rules() {
    load_rules || return 1
    apply_nft
}

cmd_uninstall() {
    local purge=0 yes=0
    while (( $# )); do
        case $1 in
            --purge) purge=1 ;;
            --yes)   yes=1 ;;
            *) err "Неизвестная опция: $1"; return 1 ;;
        esac
        shift
    done
    need_root || return 1

    echo "Будет удалено: таблица nft «$NFT_TABLE», route-правила xcascade в UFW, systemd-юнит,"
    echo "$SYSCTL_FWD, $SYSCTL_BBR, команда $BIN_PATH. Чужие правила файрвола НЕ затрагиваются."
    (( purge )) && echo "Также будет удалён каталог $CONF_DIR (правила и бэкапы)." \
                || echo "Каталог $CONF_DIR (правила и бэкапы) останется."
    if (( ! yes )); then
        confirm "Продолжить?" || { info "Отменено."; return 0; }
    fi

    with_lock _uninstall_locked
    (( purge )) && rm -rf "$CONF_DIR"
    rm -f "$BIN_PATH"
    ok "xcascade удалён. net.ipv4.ip_forward в работающей системе не менялся."
}

_uninstall_locked() {
    load_rules >/dev/null 2>&1
    ufw_purge
    have nft && nft delete table ip "$NFT_TABLE" >/dev/null 2>&1
    if have systemctl && [[ -d /run/systemd/system ]]; then
        systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
        rm -f "$UNIT_PATH"
        systemctl daemon-reload
    fi
    rm -f "$SYSCTL_FWD" "$SYSCTL_BBR" "$MODULES_BBR"
}

# -------------------------------------------------------------- меню -------
# ask VAR "вопрос" валидатор [по умолчанию]; пустой ввод без умолчания = отмена
ask() {
    local __var=$1 prompt=$2 validator=$3 def=${4:-} ans
    while true; do
        if [[ -n $def ]]; then
            read -r -p "$prompt [$def]: " ans || return 1
            ans=${ans:-$def}
        else
            read -r -p "$prompt (пусто — отмена): " ans || return 1
        fi
        ans=${ans//[[:space:]]/}
        [[ -n $ans ]] || return 1
        if "$validator" "$ans"; then
            printf -v "$__var" '%s' "$ans"
            return 0
        fi
        err "Некорректное значение, попробуйте ещё раз."
    done
}

menu_add() {
    local choice proto="" label ip inport outport name
    echo
    echo " 1) AmneziaWG / WireGuard  (UDP)"
    echo " 2) VLESS / XRay           (TCP)"
    echo " 3) MTProto / TProxy       (TCP)"
    echo " 4) Другое (tcp / udp / оба, порт или диапазон)"
    read -r -p "Что пробрасываем: " choice || return 0
    case $choice in
        1) proto=udp;  label=awg ;;
        2) proto=tcp;  label=vless ;;
        3) proto=tcp;  label=mtproto ;;
        4) ask proto "Протокол tcp / udp / both" valid_proto || { info "Отменено."; return 0; }
           label=$proto ;;
        *) return 0 ;;
    esac
    ask ip "IP целевого (зарубежного) сервера" is_ipv4 || { info "Отменено."; return 0; }
    ask inport "Порт на ЭТОМ сервере (можно диапазон, напр. 20000-20100)" is_portspec || { info "Отменено."; return 0; }
    if [[ $inport == *-* ]]; then
        outport=$inport
        info "Для диапазона порт назначения совпадает с входящим."
    else
        ask outport "Порт на целевом сервере" is_portspec "$inport" || { info "Отменено."; return 0; }
    fi
    ask name "Имя правила" valid_name "${label}-${inport}" || { info "Отменено."; return 0; }
    add_rule "$proto" "$inport" "$ip:$outport" "$name" 0 0 0
}

menu_del() {
    local key
    cmd_list || return 0
    echo
    read -r -p "Номер или имя правила для удаления (пусто — отмена): " key || return 0
    [[ -n $key ]] || return 0
    cmd_del "$key"
}

menu_backup() {
    local c f
    echo " 1) Создать бэкап"
    echo " 2) Восстановить из бэкапа"
    read -r -p "Выбор: " c || return 0
    case $c in
        1) cmd_backup ;;
        2) cmd_restore
           read -r -p "Имя файла для восстановления (пусто — отмена): " f || return 0
           [[ -n $f ]] && cmd_restore "$f" ;;
    esac
}

menu_bbr() {
    echo "BBR улучшает TCP-сессии самого сервера (SSH, загрузки с VPS)."
    echo "Проброшенный трафик идёт сквозь сервер и от BBR здесь не ускоряется."
    confirm "Включить BBR?" && cmd_bbr
}

menu_first_run() {
    [[ -f $UNIT_PATH ]] && return 0
    have systemctl && [[ -d /run/systemd/system ]] || return 0
    echo "Первый запуск: нужно установить зависимости и автозагрузку правил."
    if confirm "Выполнить установку сейчас?"; then
        cmd_install || return 1
        pause
    fi
}

menu() {
    INTERACTIVE=1
    need_root || return 1
    menu_first_run || true
    local ch
    while true; do
        clear 2>/dev/null
        echo "${C_BLD}══════════ XCASCADE $VERSION ══════════${C_OFF}"
        echo " GitHub: ${C_CYN}${REPO_URL}${C_OFF}"
        echo "──────────────────────────────────────"
        echo " 1) Добавить правило"
        echo " 2) Список правил"
        echo " 3) Удалить правило"
        echo " 4) Статистика трафика"
        echo " 5) Проверить доступность целей"
        echo " 6) Диагностика (doctor)"
        echo " 7) Бэкап / восстановление"
        echo " 8) Включить BBR (необязательно)"
        echo " 9) Удалить xcascade"
        echo " 0) Выход"
        read -r -p "Выбор: " ch || { echo; return 0; }
        case $ch in
            1) menu_add; pause ;;
            2) cmd_list; pause ;;
            3) menu_del; pause ;;
            4) cmd_stats; pause ;;
            5) cmd_check; pause ;;
            6) cmd_doctor; pause ;;
            7) menu_backup; pause ;;
            8) menu_bbr; pause ;;
            9) cmd_uninstall && return 0; pause ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# -------------------------------------------------------------- main -------
usage() {
    cat <<EOF
$PROG $VERSION — каскадные пробросы портов (DNAT) на nftables

Использование:
  $PROG                                 интерактивное меню
  $PROG add <tcp|udp|both> <порт> <ip[:порт]> [имя] [--force] [--dry-run] [--no-ufw]
  $PROG list                            список правил
  $PROG del <имя|номер>                 удалить правило
  $PROG stats                           пакеты и трафик по правилам
  $PROG check [имя]                     проверить доступность целей
  $PROG doctor                          диагностика системы
  $PROG apply                           пересоздать правила из конфигурации
  $PROG backup | restore [файл]         резервные копии списка правил
  $PROG bbr                             включить BBR (необязательно)
  $PROG install [--bbr]                 установка (nftables, systemd, sysctl)
  $PROG uninstall [--purge] [--yes]     удаление (только своих правил)
  $PROG version

Примеры:
  $PROG add udp 51820 203.0.113.10                 # WireGuard / AmneziaWG
  $PROG add tcp 443 203.0.113.10:8443 vless        # другой порт на цели
  $PROG add both 20000-20100 203.0.113.10          # диапазон, порты сохраняются

Репозиторий: $REPO_URL
EOF
}

main() {
    if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        err "Нужен bash >= 4.4"
        return 1
    fi
    local cmd=${1:-}
    [[ $# -gt 0 ]] && shift
    case $cmd in
        "")
            if [[ -t 0 && -t 1 ]]; then menu; else usage; fi ;;
        add)               cmd_add "$@" ;;
        list|ls)           cmd_list ;;
        del|rm|delete)     cmd_del "$@" ;;
        stats)             cmd_stats ;;
        check)             cmd_check "$@" ;;
        doctor)            cmd_doctor ;;
        apply)             cmd_apply ;;
        backup)            cmd_backup ;;
        restore)           cmd_restore "$@" ;;
        bbr)               cmd_bbr ;;
        install)           cmd_install "$@" ;;
        uninstall)         cmd_uninstall "$@" ;;
        version|--version|-v) echo "$PROG $VERSION" ;;
        help|--help|-h)    usage ;;
        *)                 err "Неизвестная команда: $cmd"; usage >&2; return 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
    exit $?
fi
