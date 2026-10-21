#!/usr/bin/env bash
#
# xcascade — port-forwarding cascades (DNAT) on nftables.
# xcascade — каскадные пробросы портов (DNAT) на nftables.
#
# Principles / Принципы:
#   * all rules live in a dedicated nft table «ip xcascade» — other firewall rules are never touched;
#   * source of truth is /etc/xcascade/rules.conf, the nft ruleset is generated from it;
#   * atomic apply: validate (nft -c) -> load -> save;
#   * a backup of the rule list is made before every change;
#   * autostart via the xcascade.service systemd unit;
#   * UI language: English / Русский (xcascade lang).
#
# Help / Справка: xcascade help
# Repository: https://github.com/Heawikk/xcascade
#
set -u
set -o pipefail

VERSION="1.1.0"
PROG="xcascade"
REPO_URL="https://github.com/Heawikk/xcascade"

CONF_DIR="${XCASCADE_CONF_DIR:-/etc/xcascade}"
RULES_FILE="$CONF_DIR/rules.conf"
NFT_FILE="$CONF_DIR/xcascade.nft"
LANG_FILE="$CONF_DIR/lang"
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
UI_LANG="en"      # en | ru; по умолчанию английский
S=""              # результат sel()

# ------------------------------------------------------------ язык / i18n ----
# sel "ru" "en" — выбирает строку по текущему языку и кладёт её в $S.
# Если передан один аргумент — он используется для обоих языков.
sel() {
    if [[ $UI_LANG == ru ]]; then S=$1; else S=${2-$1}; fi
}

load_lang() {
    local l
    if [[ ${XCASCADE_LANG:-} == ru || ${XCASCADE_LANG:-} == en ]]; then
        UI_LANG=$XCASCADE_LANG
        return 0
    fi
    if [[ -r $LANG_FILE ]]; then
        l=$(head -c 8 "$LANG_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ $l == ru || $l == en ]]; then UI_LANG=$l; fi
    fi
    return 0
}

lang_is_saved() { [[ -n ${XCASCADE_LANG:-} || -f $LANG_FILE ]]; }

# ---------------------------------------------------------------- вывод ----
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

say()  { sel "$@"; printf '%s\n' "$S"; }
info() { sel "$@"; printf '%s\n' "${C_CYN}[*]${C_OFF} $S"; }
ok()   { sel "$@"; printf '%s\n' "${C_GRN}[OK]${C_OFF} $S"; }
warn() { sel "$@"; printf '%s\n' "${C_YEL}[!]${C_OFF} $S" >&2; }
err()  { sel "$@"; local m=$S; sel "ОШИБКА" "ERROR"; printf '%s\n' "${C_RED}[${S}]${C_OFF} $m" >&2; }

# ------------------------------------------------------------ утилиты ------
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ $EUID -eq 0 ]] && return 0
    err "Нужны права root. Запустите: sudo $PROG ..." "Root privileges required. Run: sudo $PROG ..."
    return 1
}

need_nft() {
    have nft && return 0
    err "nftables не установлен. Выполните: sudo $PROG install" "nftables is not installed. Run: sudo $PROG install"
    return 1
}

# confirm "ru" "en"
confirm() {
    local a
    sel "$1" "${2-$1}"
    read -r -p "$S [y/N]: " a || return 1
    a=${a,,}
    [[ $a == y || $a == yes || ( $UI_LANG == ru && ( $a == д || $a == да ) ) ]]
}

pause() {
    sel "Enter — назад..." "Press Enter to go back..."
    read -r -p "$S" _ || true
}

lock() {
    have flock || return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    if ! exec 9>"$LOCK_FILE"; then
        err "Не удалось открыть lock-файл $LOCK_FILE" "Could not open lock file $LOCK_FILE"
        return 1
    fi
    if ! flock -w 10 9; then
        err "Другой экземпляр $PROG уже изменяет правила. Попробуйте позже." \
            "Another $PROG instance is already changing the rules. Try again later."
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

# ------------------------------------------------------- выбор языка --------
set_lang() {
    UI_LANG=$1
    if ensure_dirs 2>/dev/null && printf '%s\n' "$1" > "$LANG_FILE" 2>/dev/null; then
        chmod 600 "$LANG_FILE" 2>/dev/null
    else
        warn "Не удалось сохранить язык в $LANG_FILE (будет действовать до конца сеанса)." \
             "Could not save the language to $LANG_FILE (it applies until this session ends)."
    fi
}

ask_lang() {
    local c
    printf '\n%s\n  1) English\n  2) Русский\n' "Select language / Выберите язык:"
    while true; do
        read -r -p "[1/2] (Enter = 1): " c || c=1
        case ${c:-1} in
            1|en|EN) set_lang en; return 0 ;;
            2|ru|RU) set_lang ru; return 0 ;;
        esac
    done
}

# Спрашиваем язык при первом интерактивном запуске (меню или install).
maybe_ask_lang() {
    local cmd=$1; shift
    [[ $cmd == "" || $cmd == install ]] || return 0
    lang_is_saved && return 0
    [[ " $* " == *" --lang "* ]] && return 0
    [[ -t 0 && -t 1 && $EUID -eq 0 ]] || return 0
    ask_lang
}

cmd_lang() {
    local want=${1:-}
    need_root || return 1
    if [[ -z $want ]]; then
        if [[ -t 0 ]]; then
            ask_lang
        else
            say "Текущий язык: $UI_LANG (сменить: $PROG lang ru|en)" "Current language: $UI_LANG (change: $PROG lang ru|en)"
            return 0
        fi
    else
        case ${want,,} in
            ru|russian) set_lang ru ;;
            en|english) set_lang en ;;
            *) err "Неизвестный язык: $want (допустимо: ru, en)" "Unknown language: $want (use ru or en)"; return 1 ;;
        esac
    fi
    ok "Язык интерфейса: Русский" "Interface language: English"
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
        err "Недопустимый адрес назначения: $ip" "Invalid target address: $ip"
        return 1
    fi
    if local_ipv4s | grep -qxF "$ip"; then
        err "$ip — адрес этого же сервера, проброс зациклится." "$ip is this server's own address, the forwarding would loop."
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
            err "Порт $sp занят SSH: проброс отрежет вам доступ к серверу." \
                "Port $sp is used by SSH: forwarding it would cut off your access to the server."
            rc=1
        fi
    done < <(ssh_ports)

    for p in $(protos_of "$proto"); do
        while read -r q; do
            [[ $q =~ ^[0-9]+$ ]] || continue
            (( q >= lo && q <= hi )) || continue
            [[ $ssh_list == *" $q "* ]] && continue
            warn "На порту $q/$p уже слушает локальная служба — снаружи она станет недоступна." \
                 "A local service is already listening on $q/$p — it would become unreachable from outside."
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
            err "Повреждённая строка $ln в $file: $name ${proto:-} ${inp:-} ${ip:-} ${out:-}" \
                "Corrupted line $ln in $file: $name ${proto:-} ${inp:-} ${ip:-} ${out:-}"
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
        echo "# xcascade: name protocol in ip out"
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
# Generated by $PROG $VERSION. Do not edit: the rules are stored in $RULES_FILE
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
    tmp=$(mktemp "$CONF_DIR/.nft.XXXXXX") || {
        err "Не удалось создать временный файл в $CONF_DIR" "Could not create a temporary file in $CONF_DIR"
        return 1
    }
    gen_nft > "$tmp"
    if ! out=$(nft -c -f "$tmp" 2>&1); then
        err "nft отклонил конфигурацию, ничего не изменено:" "nft rejected the configuration, nothing was changed:"
        printf '%s\n' "$out" >&2
        rm -f "$tmp"
        return 1
    fi
    if ! out=$(nft -f "$tmp" 2>&1); then
        err "Не удалось загрузить правила в ядро:" "Could not load the rules into the kernel:"
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
    ensure_dirs || { err "Не удалось создать $CONF_DIR" "Could not create $CONF_DIR"; return 1; }
    make_backup
    apply_nft || return 1
    save_rules || { err "Не удалось сохранить $RULES_FILE" "Could not save $RULES_FILE"; return 1; }
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
            warn "UFW: не удалось добавить route-правило для ${R_NAME[i]} ($p). Проверьте: $PROG doctor" \
                 "UFW: could not add a route rule for ${R_NAME[i]} ($p). Check: $PROG doctor"
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
    echo "${ip:-<server-ip>}"
}

usage_add() {
    if [[ $UI_LANG == ru ]]; then
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
    else
        cat <<EOF
Usage: $PROG add <tcp|udp|both> <port|range> <ip[:port]> [name] [options]

  <port>     port on this server; range: 20000-20100
  <ip:port>  target server; if the port is omitted, it is the same as the incoming one
             (for ranges, ports are always preserved)
  [name]     a-z, 0-9, _ and -; default: proto-port

Options:
  --name N    same as [name]
  --force     create the rule despite warnings (SSH, busy ports)
  --dry-run   show the ruleset and validate it with nft -c without applying anything
  --no-ufw    do not add route rules to UFW
EOF
    fi
}

cmd_add() {
    local name="" force=0 dry=0 noufw=0
    local -a pos=()
    while (( $# )); do
        case $1 in
            -n|--name)
                [[ $# -ge 2 ]] || { err "--name требует значение" "--name requires a value"; return 1; }
                name=$2; shift 2 ;;
            --force)   force=1; shift ;;
            --dry-run) dry=1; shift ;;
            --no-ufw)  noufw=1; shift ;;
            -h|--help) usage_add; return 0 ;;
            -*)        err "Неизвестная опция: $1" "Unknown option: $1"; return 1 ;;
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

    valid_proto "$proto" || { err "Протокол должен быть tcp, udp или both" "Protocol must be tcp, udp or both"; return 1; }
    is_portspec "$inspec" || { err "Некорректный входящий порт: $inspec" "Invalid incoming port: $inspec"; return 1; }
    if [[ $to == *:* ]]; then
        ip=${to%%:*}; outspec=${to#*:}
    else
        ip=$to; outspec=$inspec
    fi
    is_ipv4 "$ip" || { err "Некорректный IPv4-адрес: $ip" "Invalid IPv4 address: $ip"; return 1; }
    is_portspec "$outspec" || { err "Некорректный порт назначения: $outspec" "Invalid target port: $outspec"; return 1; }
    if [[ ( $inspec == *-* || $outspec == *-* ) && $inspec != "$outspec" ]]; then
        err "Диапазоны пробрасываются только с сохранением портов (вход и выход должны совпадать)." \
            "Port ranges are forwarded with ports preserved only (incoming and target ports must match)."
        return 1
    fi
    validate_target_ip "$ip" || return 1
    [[ -z $name ]] && name="${proto}-${inspec}"
    valid_name "$name" || {
        err "Недопустимое имя «$name»: разрешены a-z, 0-9, _ и - (до 32 символов)" \
            "Invalid name '$name': only a-z, 0-9, _ and - are allowed (up to 32 characters)"
        return 1
    }

    with_lock _add_locked "$proto" "$inspec" "$ip" "$outspec" "$name" "$force" "$dry" "$noufw"
}

_add_locked() {
    local proto=$1 inspec=$2 ip=$3 outspec=$4 name=$5 force=$6 dry=$7 noufw=$8
    local i rc n sip
    load_rules || return 1

    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        if [[ ${R_NAME[i]} == "$name" ]]; then
            err "Правило с именем «$name» уже есть. Выберите другое имя или удалите старое: $PROG del $name" \
                "A rule named '$name' already exists. Pick another name or delete the old one: $PROG del $name"
            return 1
        fi
        if protos_overlap "$proto" "${R_PROTO[i]}" && ranges_overlap "$inspec" "${R_IN[i]}"; then
            err "Порт ${R_PROTO[i]}/${R_IN[i]} уже занят правилом «${R_NAME[i]}»." \
                "Port ${R_PROTO[i]}/${R_IN[i]} is already used by rule '${R_NAME[i]}'."
            return 1
        fi
    done

    safety_check "$proto" "$inspec"
    rc=$?
    if (( rc != 0 )); then
        if (( force )); then
            warn "Продолжаю из-за --force." "Continuing because of --force."
        elif (( INTERACTIVE )) && confirm "Всё равно создать правило?" "Create the rule anyway?"; then
            :
        else
            err "Отменено. Исправьте причину или добавьте --force (на свой риск)." \
                "Cancelled. Fix the cause or add --force (at your own risk)."
            return 1
        fi
    fi

    R_NAME+=("$name"); R_PROTO+=("$proto"); R_IN+=("$inspec"); R_IP+=("$ip"); R_OUT+=("$outspec")
    n=$((${#R_NAME[@]} - 1))

    if (( dry )); then
        gen_nft
        if gen_nft | nft -c -f - 2>&1; then
            ok "Конфигурация корректна (dry-run, ничего не применено)." "Configuration is valid (dry-run, nothing applied)."
            return 0
        fi
        return 1
    fi

    commit || return 1
    (( noufw )) || ufw_add_rule "$n"

    sip=$(server_ip)
    ok "Правило «$name» создано: $proto $inspec -> $ip:$outspec" "Rule '$name' created: $proto $inspec -> $ip:$outspec"
    sel "   Клиентам указывайте адрес ${C_GRN}${sip}${C_OFF} и порт ${C_GRN}${inspec}${C_OFF} вместо зарубежного сервера." \
        "   In your client, use address ${C_GRN}${sip}${C_OFF} and port ${C_GRN}${inspec}${C_OFF} instead of the target server's."
    printf '%s\n' "$S"
}

# ------------------------------------------------------------ list/del -----
cmd_list() {
    load_rules || return 1
    local n=${#R_NAME[@]} i
    if (( n == 0 )); then
        info "Правил нет. Добавьте: $PROG add udp 51820 203.0.113.10" "No rules yet. Add one: $PROG add udp 51820 203.0.113.10"
        return 0
    fi
    sel "Адрес этого сервера:" "This server's address:"
    echo "$S ${C_GRN}$(server_ip)${C_OFF}"
    echo
    printf '%-3s %-20s %-6s %-13s %s\n' "#" "NAME" "PROTO" "IN" "TARGET"
    for ((i = 0; i < n; i++)); do
        printf '%-3s %-20s %-6s %-13s %s\n' \
            "$((i + 1))" "${R_NAME[i]}" "${R_PROTO[i]}" "${R_IN[i]}" "${R_IP[i]}:${R_OUT[i]}"
    done
}

cmd_del() {
    [[ $# -eq 1 ]] || { err "Использование: $PROG del <имя|номер>" "Usage: $PROG del <name|number>"; return 1; }
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
        err "Правило не найдено: $key" "Rule not found: $key"
        return 1
    fi
    name=${R_NAME[idx]}
    remove_rule_at "$idx"
    commit || return 1
    ufw_purge "$name"
    ok "Правило «$name» удалено." "Rule '$name' deleted."
    info "Уже установленные соединения живут до своего завершения (conntrack)." \
         "Established connections keep working until they end (conntrack)."
}

# ------------------------------------------------------------- stats -------
cmd_stats() {
    need_root || return 1
    need_nft || return 1
    if ! nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
        err "Таблица $NFT_TABLE не загружена. Выполните: $PROG apply" "Table $NFT_TABLE is not loaded. Run: $PROG apply"
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
    info "Считается трафик клиент → цель; счётчики обнуляются при каждом изменении правил." \
         "Counts client → target traffic; counters reset whenever the rules change."
}

# ------------------------------------------------------------- check -------
cmd_check() {
    local only=${1:-} i found=0 ip port p bad=0
    load_rules || return 1
    if (( ${#R_NAME[@]} == 0 )); then info "Правил нет." "No rules."; return 0; fi
    for ((i = 0; i < ${#R_NAME[@]}; i++)); do
        [[ -n $only && ${R_NAME[i]} != "$only" ]] && continue
        found=1
        ip=${R_IP[i]}
        port=$(port_lo "${R_OUT[i]}")
        echo "${C_BLD}${R_NAME[i]}${C_OFF}  (${R_PROTO[i]} ${R_IN[i]} -> $ip:${R_OUT[i]})"
        if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
            ok "ping $ip отвечает" "ping $ip replies"
        else
            warn "ping $ip не проходит (ICMP может быть закрыт — это не всегда ошибка)" \
                 "ping $ip fails (ICMP may be blocked — not necessarily a problem)"
        fi
        for p in $(protos_of "${R_PROTO[i]}"); do
            if [[ $p == tcp ]]; then
                if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$ip" "$port" 2>/dev/null; then
                    ok "TCP $ip:$port — порт открыт" "TCP $ip:$port — port is open"
                else
                    err "TCP $ip:$port недоступен" "TCP $ip:$port is unreachable"
                    bad=1
                fi
            else
                info "UDP $ip:$port: без ответа службы надёжно не проверить — проверьте подключением клиента" \
                     "UDP $ip:$port: cannot be verified reliably without a service reply — test with a real client connection"
            fi
        done
    done
    if (( ! found )); then err "Правило не найдено: $only" "Rule not found: $only"; return 1; fi
    return $bad
}

# ------------------------------------------------------------ doctor -------
d_ok()   { sel "$@"; printf '  %s %s\n' "${C_GRN}✔${C_OFF}" "$S"; }
d_warn() { sel "$@"; printf '  %s %s\n' "${C_YEL}!${C_OFF}" "$S"; }
d_bad()  { sel "$@"; printf '  %s %s\n' "${C_RED}✘${C_OFF}" "$S"; DOCTOR_BAD=1; }

cmd_doctor() {
    need_root || return 1
    DOCTOR_BAD=0
    local i fwd cc pol

    say "${C_BLD}Диагностика $PROG $VERSION${C_OFF}" "${C_BLD}$PROG $VERSION diagnostics${C_OFF}"

    if have nft; then
        d_ok "nftables: $(nft --version 2>/dev/null)"
    else
        d_bad "nftables не установлен ($PROG install)" "nftables is not installed ($PROG install)"
    fi

    if load_rules; then
        d_ok "Конфигурация $RULES_FILE читается, правил: ${#R_NAME[@]}" "Config $RULES_FILE is readable, rules: ${#R_NAME[@]}"
    else
        d_bad "Конфигурация повреждена" "Config is corrupted"
    fi

    if have nft; then
        if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
            d_ok "Таблица nft «$NFT_TABLE» загружена" "nft table '$NFT_TABLE' is loaded"
        elif (( ${#R_NAME[@]} > 0 )); then
            d_bad "Таблица nft «$NFT_TABLE» не загружена, хотя правила есть — выполните: $PROG apply" \
                  "nft table '$NFT_TABLE' is not loaded although rules exist — run: $PROG apply"
        else
            d_warn "Таблица nft «$NFT_TABLE» не загружена (правил нет)" "nft table '$NFT_TABLE' is not loaded (no rules)"
        fi
    fi

    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ $fwd == 1 ]]; then
        d_ok "net.ipv4.ip_forward = 1"
    else
        d_bad "net.ipv4.ip_forward = ${fwd:-?} — пересылка выключена ($PROG install)" \
              "net.ipv4.ip_forward = ${fwd:-?} — forwarding is disabled ($PROG install)"
    fi
    if [[ -f $SYSCTL_FWD ]]; then
        d_ok "Пересылка сохранена в $SYSCTL_FWD" "Forwarding is persisted in $SYSCTL_FWD"
    else
        d_warn "Нет $SYSCTL_FWD: после перезагрузки пересылка может выключиться" \
               "$SYSCTL_FWD is missing: forwarding may be disabled after a reboot"
    fi

    if have systemctl && [[ -d /run/systemd/system ]]; then
        if systemctl is-enabled "$UNIT_NAME" >/dev/null 2>&1; then
            d_ok "Автозагрузка $UNIT_NAME включена" "Autostart of $UNIT_NAME is enabled"
        else
            d_bad "Автозагрузка $UNIT_NAME не включена ($PROG install)" "Autostart of $UNIT_NAME is not enabled ($PROG install)"
        fi
    else
        d_warn "systemd не найден: добавьте «$PROG apply» в автозагрузку вручную" \
               "systemd not found: add '$PROG apply' to your boot scripts manually"
    fi

    if ufw_active; then
        d_ok "UFW активен" "UFW is active"
        for ((i = 0; i < ${#R_NAME[@]}; i++)); do
            if ufwc show added 2>/dev/null | grep -qF "comment '${TAG_PREFIX}${R_NAME[i]}'"; then
                d_ok "UFW: есть route-правило для «${R_NAME[i]}»" "UFW: route rule for '${R_NAME[i]}' exists"
            else
                d_bad "UFW: нет route-правила для «${R_NAME[i]}» — трафик будет блокироваться. Выполните: $PROG apply" \
                      "UFW: no route rule for '${R_NAME[i]}' — traffic will be blocked. Run: $PROG apply"
            fi
        done
    elif have iptables; then
        pol=$(iptables -S FORWARD 2>/dev/null | head -n1)
        if [[ $pol == "-P FORWARD DROP" ]]; then
            d_warn "iptables: политика FORWARD = DROP (Docker?). Проброс не пройдёт, пока вы не разрешите форвардинг к целям в своём файрволе." \
                   "iptables: FORWARD policy is DROP (Docker?). Forwarding will not work until you allow it to the targets in your own firewall."
        else
            d_ok "iptables FORWARD не блокирует проброс" "iptables FORWARD does not block forwarding"
        fi
    fi

    if [[ -f /etc/nftables.conf ]] && grep -q 'flush ruleset' /etc/nftables.conf \
        && systemctl is-enabled nftables.service >/dev/null 2>&1; then
        d_warn "nftables.service делает «flush ruleset»: его reload сотрёт и таблицу $NFT_TABLE. Восстановление: $PROG apply (при restart сервиса $PROG перезапускается сам)" \
               "nftables.service does 'flush ruleset': its reload also wipes the $NFT_TABLE table. Restore it with: $PROG apply (a restart of the service restarts $PROG automatically)"
    fi

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    d_ok "TCP congestion control: ${cc:-?} (BBR на роутере почти не влияет на проброс, см. README)" \
         "TCP congestion control: ${cc:-?} (BBR on the relay hardly affects forwarded traffic, see README)"

    echo
    if (( DOCTOR_BAD )); then
        err "Есть проблемы — см. пункты ✘ выше." "Problems found — see the ✘ items above."
        return 1
    fi
    ok "Проблем не найдено." "No problems found."
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
    ok "Правила применены (${#R_NAME[@]} шт.)." "Rules applied (${#R_NAME[@]})."
}

# ------------------------------------------------------ backup/restore -----
cmd_backup() {
    need_root || return 1
    if [[ ! -s $RULES_FILE ]]; then info "Нечего сохранять: правил нет." "Nothing to back up: no rules."; return 0; fi
    ensure_dirs || return 1
    make_backup
    local last
    last=$(ls -1t "$BACKUP_DIR"/rules-*.conf 2>/dev/null | head -n1)
    ok "Бэкап сохранён в $BACKUP_DIR (последний: $last)" "Backup saved to $BACKUP_DIR (latest: $last)"
}

cmd_restore() {
    need_root || return 1
    need_nft || return 1
    local f=${1:-}
    if [[ -z $f ]]; then
        local -a bk=()
        mapfile -t bk < <(ls -1t "$BACKUP_DIR"/rules-*.conf 2>/dev/null)
        if (( ${#bk[@]} == 0 )); then info "Бэкапов нет." "No backups."; return 0; fi
        say "Доступные бэкапы:" "Available backups:"
        printf '  %s\n' "${bk[@]}"
        say "Восстановить: $PROG restore <файл>" "Restore with: $PROG restore <file>"
        return 0
    fi
    [[ -f $f ]] || f="$BACKUP_DIR/$f"
    [[ -f $f ]] || { err "Файл не найден: $1" "File not found: $1"; return 1; }
    with_lock _restore_locked "$f"
}

_restore_locked() {
    local f=$1
    ensure_dirs || return 1
    load_rules "$f" || {
        err "Файл бэкапа повреждён, ничего не изменено." "The backup file is corrupted, nothing was changed."
        return 1
    }
    ufw_purge
    commit || return 1
    ufw_add_all
    ok "Восстановлено из $f (правил: ${#R_NAME[@]})." "Restored from $f (rules: ${#R_NAME[@]})."
}

# --------------------------------------------------------------- bbr -------
cmd_bbr() {
    need_root || return 1
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cur == bbr ]]; then ok "BBR уже включён." "BBR is already enabled."; return 0; fi
    modprobe tcp_bbr 2>/dev/null
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
        err "Ядро не поддерживает BBR (нужно Linux >= 4.9 с модулем tcp_bbr)." \
            "The kernel does not support BBR (Linux >= 4.9 with the tcp_bbr module is required)."
        return 1
    fi
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_BBR"
    echo tcp_bbr > "$MODULES_BBR" 2>/dev/null
    if sysctl -q -p "$SYSCTL_BBR" >/dev/null 2>&1; then
        ok "BBR включён и сохранён в $SYSCTL_BBR." "BBR enabled and saved to $SYSCTL_BBR."
        info "Важно: BBR ускоряет только TCP-сессии самого сервера. Проброшенный трафик идёт сквозь сервер между клиентом и целью и от BBR здесь не ускоряется." \
             "Note: BBR only speeds up TCP sessions of the server itself. Forwarded traffic passes through the server between the client and the target and does not get faster from BBR here."
    else
        err "Не удалось применить sysctl из $SYSCTL_BBR" "Could not apply sysctl from $SYSCTL_BBR"
        return 1
    fi
}

# ----------------------------------------------------- install/uninstall ---
install_deps() {
    have nft && return 0
    if ! have apt-get; then
        err "nftables не найден, а apt-get недоступен. Установите nftables вручную и повторите." \
            "nftables not found and apt-get is unavailable. Install nftables manually and retry."
        return 1
    fi
    info "Устанавливаю nftables..." "Installing nftables..."
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null; }; then
        err "Не удалось установить nftables." "Failed to install nftables."
        return 1
    fi
}

write_unit() {
    local nftbin
    nftbin=$(command -v nft)
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=xcascade: port forwarding rules (nftables)
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
    local want_bbr=0 self lang_opt=""
    while (( $# )); do
        case $1 in
            --bbr) want_bbr=1 ;;
            --lang)
                if [[ ${2:-} != ru && ${2:-} != en ]]; then
                    err "--lang принимает ru или en" "--lang accepts ru or en"
                    return 1
                fi
                lang_opt=$2; shift ;;
            *) err "Неизвестная опция: $1" "Unknown option: $1"; return 1 ;;
        esac
        shift
    done
    need_root || return 1

    if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        err "Нужен bash >= 4.4" "bash >= 4.4 is required"
        return 1
    fi
    install_deps || return 1
    ensure_dirs || return 1
    [[ -n $lang_opt ]] && set_lang "$lang_opt"

    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    if [[ -f $self && $self != "$BIN_PATH" ]]; then
        install -m 755 "$self" "$BIN_PATH" || {
            err "Не удалось скопировать скрипт в $BIN_PATH" "Could not copy the script to $BIN_PATH"
            return 1
        }
    elif [[ ! -f $BIN_PATH ]]; then
        err "Скачайте скрипт в файл и запустите из него (запуск через pipe не поддерживается)." \
            "Download the script to a file and run it from there (running through a pipe is not supported)."
        return 1
    fi

    printf 'net.ipv4.ip_forward = 1\n' > "$SYSCTL_FWD"
    sysctl -q -p "$SYSCTL_FWD" >/dev/null 2>&1 || \
        warn "Не удалось включить ip_forward сейчас — проверьте: $PROG doctor" \
             "Could not enable ip_forward right now — check: $PROG doctor"

    with_lock _install_rules || return 1

    if have systemctl && [[ -d /run/systemd/system ]]; then
        write_unit
        systemctl start "$UNIT_NAME" >/dev/null 2>&1
    else
        warn "systemd не найден: автозагрузку правил настройте вручную (команда: $PROG apply)." \
             "systemd not found: set up autostart of the rules manually (command: $PROG apply)."
    fi

    (( want_bbr )) && cmd_bbr
    # Итоговое сообщение установки — всегда на английском.
    ok "Installed. Run: $PROG (menu) or $PROG help. Change the language: $PROG lang"
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
            *) err "Неизвестная опция: $1" "Unknown option: $1"; return 1 ;;
        esac
        shift
    done
    need_root || return 1

    say "Будет удалено: таблица nft «$NFT_TABLE», route-правила $PROG в UFW, systemd-юнит," \
        "Will be removed: nft table '$NFT_TABLE', $PROG route rules in UFW, the systemd unit,"
    say "$SYSCTL_FWD, $SYSCTL_BBR, команда $BIN_PATH. Чужие правила файрвола НЕ затрагиваются." \
        "$SYSCTL_FWD, $SYSCTL_BBR and the $BIN_PATH command. Other firewall rules are NOT touched."
    if (( purge )); then
        say "Также будет удалён каталог $CONF_DIR (правила, бэкапы, язык)." \
            "The $CONF_DIR directory (rules, backups, language) will be removed as well."
    else
        say "Каталог $CONF_DIR (правила и бэкапы) останется." "The $CONF_DIR directory (rules and backups) will be kept."
    fi
    if (( ! yes )); then
        confirm "Продолжить?" "Continue?" || { info "Отменено." "Cancelled."; return 0; }
    fi

    with_lock _uninstall_locked
    (( purge )) && rm -rf "$CONF_DIR"
    rm -f "$BIN_PATH"
    ok "$PROG удалён. net.ipv4.ip_forward в работающей системе не менялся." \
       "$PROG removed. The running net.ipv4.ip_forward value was not changed."
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
# ask VAR валидатор "ru" "en" [по умолчанию]; пустой ввод без умолчания = отмена
ask() {
    local __var=$1 validator=$2 def=${5:-} ans prompt hint
    sel "$3" "$4"; prompt=$S
    sel " (пусто — отмена)" " (empty to cancel)"; hint=$S
    while true; do
        if [[ -n $def ]]; then
            read -r -p "$prompt [$def]: " ans || return 1
            ans=${ans:-$def}
        else
            read -r -p "$prompt$hint: " ans || return 1
        fi
        ans=${ans//[[:space:]]/}
        [[ -n $ans ]] || return 1
        if "$validator" "$ans"; then
            printf -v "$__var" '%s' "$ans"
            return 0
        fi
        err "Некорректное значение, попробуйте ещё раз." "Invalid value, please try again."
    done
}

menu_item() { sel "$2" "$3"; printf ' %s) %s\n' "$1" "$S"; }

menu_add() {
    local choice proto="" label ip inport outport name
    echo
    menu_item 1 "AmneziaWG / WireGuard  (UDP)" "AmneziaWG / WireGuard  (UDP)"
    menu_item 2 "VLESS / XRay           (TCP)" "VLESS / XRay           (TCP)"
    menu_item 3 "MTProto / TProxy       (TCP)" "MTProto / TProxy       (TCP)"
    menu_item 4 "Другое (tcp / udp / оба, порт или диапазон)" "Other (tcp / udp / both, port or range)"
    sel "Что пробрасываем: " "What to forward: "
    read -r -p "$S" choice || return 0
    case $choice in
        1) proto=udp;  label=awg ;;
        2) proto=tcp;  label=vless ;;
        3) proto=tcp;  label=mtproto ;;
        4) ask proto valid_proto "Протокол tcp / udp / both" "Protocol tcp / udp / both" \
               || { info "Отменено." "Cancelled."; return 0; }
           label=$proto ;;
        *) return 0 ;;
    esac
    ask ip is_ipv4 "IP целевого (зарубежного) сервера" "Target (foreign) server IP" \
        || { info "Отменено." "Cancelled."; return 0; }
    ask inport is_portspec "Порт на ЭТОМ сервере (можно диапазон, напр. 20000-20100)" \
        "Port on THIS server (a range like 20000-20100 is allowed)" \
        || { info "Отменено." "Cancelled."; return 0; }
    if [[ $inport == *-* ]]; then
        outport=$inport
        info "Для диапазона порт назначения совпадает с входящим." "For a range, the target port equals the incoming port."
    else
        ask outport is_portspec "Порт на целевом сервере" "Port on the target server" "$inport" \
            || { info "Отменено." "Cancelled."; return 0; }
    fi
    ask name valid_name "Имя правила" "Rule name" "${label}-${inport}" \
        || { info "Отменено." "Cancelled."; return 0; }
    add_rule "$proto" "$inport" "$ip:$outport" "$name" 0 0 0
}

menu_del() {
    local key
    cmd_list || return 0
    echo
    sel "Номер или имя правила для удаления (пусто — отмена): " "Rule number or name to delete (empty to cancel): "
    read -r -p "$S" key || return 0
    [[ -n $key ]] || return 0
    cmd_del "$key"
}

menu_backup() {
    local c f
    menu_item 1 "Создать бэкап" "Create a backup"
    menu_item 2 "Восстановить из бэкапа" "Restore from a backup"
    sel "Выбор: " "Choice: "
    read -r -p "$S" c || return 0
    case $c in
        1) cmd_backup ;;
        2) cmd_restore
           sel "Имя файла для восстановления (пусто — отмена): " "File name to restore (empty to cancel): "
           read -r -p "$S" f || return 0
           [[ -n $f ]] && cmd_restore "$f" ;;
    esac
}

menu_bbr() {
    say "BBR улучшает TCP-сессии самого сервера (SSH, загрузки с VPS)." \
        "BBR improves TCP sessions of the server itself (SSH, downloads on the VPS)."
    say "Проброшенный трафик идёт сквозь сервер и от BBR здесь не ускоряется." \
        "Forwarded traffic passes through the server and does not get faster from BBR here."
    confirm "Включить BBR?" "Enable BBR?" && cmd_bbr
}

menu_first_run() {
    [[ -f $UNIT_PATH ]] && return 0
    have systemctl && [[ -d /run/systemd/system ]] || return 0
    say "Первый запуск: нужно установить зависимости и автозагрузку правил." \
        "First run: dependencies and autostart of the rules need to be installed."
    if confirm "Выполнить установку сейчас?" "Run the installation now?"; then
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
        menu_item 1 "Добавить правило" "Add a rule"
        menu_item 2 "Список правил" "List rules"
        menu_item 3 "Удалить правило" "Delete a rule"
        menu_item 4 "Статистика трафика" "Traffic stats"
        menu_item 5 "Проверить доступность целей" "Check target reachability"
        menu_item 6 "Диагностика (doctor)" "Diagnostics (doctor)"
        menu_item 7 "Бэкап / восстановление" "Backup / restore"
        menu_item 8 "Включить BBR (необязательно)" "Enable BBR (optional)"
        menu_item 9 "Удалить $PROG" "Uninstall $PROG"
        menu_item l "Language / Язык" "Language / Язык"
        menu_item 0 "Выход" "Exit"
        sel "Выбор: " "Choice: "
        read -r -p "$S" ch || { echo; return 0; }
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
            l|L) ask_lang ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# -------------------------------------------------------------- main -------
usage() {
    if [[ $UI_LANG == ru ]]; then
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
  $PROG lang [ru|en]                    язык интерфейса
  $PROG install [--bbr] [--lang ru|en]  установка (nftables, systemd, sysctl)
  $PROG uninstall [--purge] [--yes]     удаление (только своих правил)
  $PROG version

Примеры:
  $PROG add udp 51820 203.0.113.10                 # WireGuard / AmneziaWG
  $PROG add tcp 443 203.0.113.10:8443 vless        # другой порт на цели
  $PROG add both 20000-20100 203.0.113.10          # диапазон, порты сохраняются

Репозиторий: $REPO_URL
EOF
    else
        cat <<EOF
$PROG $VERSION — port-forwarding cascades (DNAT) on nftables

Usage:
  $PROG                                 interactive menu
  $PROG add <tcp|udp|both> <port> <ip[:port]> [name] [--force] [--dry-run] [--no-ufw]
  $PROG list                            list rules
  $PROG del <name|number>               delete a rule
  $PROG stats                           packets and traffic per rule
  $PROG check [name]                    check target reachability
  $PROG doctor                          system diagnostics
  $PROG apply                           recreate the rules from the config
  $PROG backup | restore [file]         backups of the rule list
  $PROG bbr                             enable BBR (optional)
  $PROG lang [ru|en]                    interface language
  $PROG install [--bbr] [--lang ru|en]  install (nftables, systemd, sysctl)
  $PROG uninstall [--purge] [--yes]     uninstall (own objects only)
  $PROG version

Examples:
  $PROG add udp 51820 203.0.113.10                 # WireGuard / AmneziaWG
  $PROG add tcp 443 203.0.113.10:8443 vless        # different target port
  $PROG add both 20000-20100 203.0.113.10          # port range, ports preserved

Repository: $REPO_URL
EOF
    fi
}

main() {
    load_lang
    if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        err "Нужен bash >= 4.4" "bash >= 4.4 is required"
        return 1
    fi
    local cmd=${1:-}
    [[ $# -gt 0 ]] && shift
    maybe_ask_lang "$cmd" "$@"
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
        lang|language)     cmd_lang "$@" ;;
        install)           cmd_install "$@" ;;
        uninstall)         cmd_uninstall "$@" ;;
        version|--version|-v) echo "$PROG $VERSION" ;;
        help|--help|-h)    usage ;;
        *)                 err "Неизвестная команда: $cmd" "Unknown command: $cmd"; usage >&2; return 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
    exit $?
fi
