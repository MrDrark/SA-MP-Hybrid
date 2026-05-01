#!/bin/bash
set -Eeuo pipefail

APP_ROOT="/home/container"
STATE_ROOT="${APP_ROOT}/.samp-auto"
STATE_FILE="${STATE_ROOT}/state/runtime.env"
LOG_ROOT="${STATE_ROOT}/logs"
SERVER_CFG="${APP_ROOT}/server.cfg"
SESSION_ID="$(date +%Y%m%d-%H%M%S)"
SESSION_DIR="${LOG_ROOT}/${SESSION_ID}"
STDIN_PIPE="${STATE_ROOT}/stdin.pipe"

mkdir -p "${STATE_ROOT}/state" "${LOG_ROOT}" "${SESSION_DIR}"
export HOME="${APP_ROOT}"

WATCH_PIDS=()
STDIN_FORWARD_PID=""
SERVER_PID=""
LAUNCHER_PID=""
STOPPING="0"

log_line() {
    local level="$1"
    local message="$2"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}"
}

info() {
    log_line "INFO" "$1"
}

warn() {
    log_line "WARN" "$1"
}

error() {
    log_line "ERROR" "$1" >&2
}

die() {
    error "$1"
    exit 1
}

load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
    fi
}

save_state() {
    cat > "${STATE_FILE}" <<EOF
LAST_MODE=${SERVER_MODE:-unknown}
LAST_GAMEMODE=${CURRENT_GAMEMODE:-unknown}
LAST_RELEASE=${RELEASE_LABEL:-unknown}
LAST_STARTED_AT=${SESSION_ID}
EOF
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

ensure_server_cfg() {
    if [[ ! -f "${SERVER_CFG}" ]]; then
        warn "server.cfg nao encontrado. Criando um arquivo minimo."
        cat > "${SERVER_CFG}" <<'EOF'
echo Executing Server Config...
lanmode 0
rcon_password changemeplease
maxplayers 50
port 7777
hostname SA-MP Auto Hybrid
gamemode0 grandlarc 1
filterscripts
announce 0
query 1
weburl www.sa-mp.com
maxnpc 0
onfoot_rate 40
incar_rate 40
weapon_rate 40
stream_distance 300.0
stream_rate 1000
logtimeformat [%H:%M:%S]
output 1
EOF
    fi
}

read_cfg_value() {
    local key="$1"

    [[ -f "${SERVER_CFG}" ]] || return 0

    awk -v cfg_key="${key}" '
        $1 == cfg_key {
            $1 = ""
            sub(/^[ \t]+/, "", $0)
            print
            exit
        }
    ' "${SERVER_CFG}"
}

set_cfg_value() {
    local key="$1"
    local value="$2"
    local temp_file="${SERVER_CFG}.tmp"

    [[ -n "${value}" ]] || return 0

    awk -v cfg_key="${key}" -v cfg_value="${value}" '
        BEGIN { replaced = 0 }
        $1 == cfg_key && replaced == 0 {
            print cfg_key " " cfg_value
            replaced = 1
            next
        }
        $1 == cfg_key && replaced == 1 {
            next
        }
        { print }
        END {
            if (replaced == 0) {
                print cfg_key " " cfg_value
            }
        }
    ' "${SERVER_CFG}" > "${temp_file}"

    mv "${temp_file}" "${SERVER_CFG}"
}

remove_cfg_key() {
    local key="$1"
    local temp_file="${SERVER_CFG}.tmp"

    awk -v cfg_key="${key}" '$1 != cfg_key { print }' "${SERVER_CFG}" > "${temp_file}"
    mv "${temp_file}" "${SERVER_CFG}"
}

discover_first_gamemode() {
    local first_file

    if [[ ! -d "${APP_ROOT}/gamemodes" ]]; then
        return 1
    fi

    first_file="$(find "${APP_ROOT}/gamemodes" -maxdepth 1 -type f -name '*.amx' | sort | head -n 1 || true)"
    [[ -n "${first_file}" ]] || return 1

    basename "${first_file}" .amx
}

ensure_gamemode() {
    local configured_gamemode
    local desired_gamemode

    configured_gamemode="$(trim "$(read_cfg_value "gamemode0" | awk '{print $1}')")"
    desired_gamemode="${GAME_MODE:-${configured_gamemode}}"

    if [[ -z "${desired_gamemode}" ]]; then
        desired_gamemode="$(discover_first_gamemode || true)"
    fi

    [[ -n "${desired_gamemode}" ]] || die "Nenhum gamemode .amx foi encontrado em ${APP_ROOT}/gamemodes."
    [[ -f "${APP_ROOT}/gamemodes/${desired_gamemode}.amx" ]] || die "Gamemode ${desired_gamemode}.amx nao encontrado em ${APP_ROOT}/gamemodes."

    set_cfg_value "gamemode0" "${desired_gamemode} 1"
    CURRENT_GAMEMODE="${desired_gamemode}"
}

cfg_mode_hint() {
    local plugins_line

    plugins_line="$(read_cfg_value "plugins" | tr '[:upper:]' '[:lower:]')"

    if [[ "${plugins_line}" == *".dll"* ]]; then
        printf 'windows'
        return 0
    fi

    if [[ "${plugins_line}" == *".so"* ]]; then
        printf 'linux'
        return 0
    fi

    printf 'unknown'
}

resolve_release_targets() {
    local requested_release

    requested_release="$(printf '%s' "${SAMP_RELEASE:-stable}" | tr '[:lower:]' '[:upper:]')"
    requested_release="${requested_release// /}"
    requested_release="${requested_release//_/-}"
    requested_release="${requested_release//--/-}"

    case "${requested_release}" in
        ""|STABLE|LATEST|R2|R2-1)
            LINUX_RELEASE="R2-1"
            WINDOWS_RELEASE="R2-2-1"
            RELEASE_LABEL="stable (linux R2-1 / windows R2-2-1)"
        ;;
        R2-2-1)
            LINUX_RELEASE="R2-1"
            WINDOWS_RELEASE="R2-2-1"
            RELEASE_LABEL="custom (linux R2-1 / windows R2-2-1)"
            warn "Linux nao possui pacote espelhado equivalente a ${requested_release}. Usando Linux R2-1."
        ;;
        *)
            LINUX_RELEASE="R2-1"
            WINDOWS_RELEASE="R2-2-1"
            RELEASE_LABEL="fallback (linux R2-1 / windows R2-2-1)"
            warn "Release ${requested_release} nao possui pacote de servidor suportado neste egg. Aplicando fallback estavel."
        ;;
    esac
}

build_linux_urls() {
    local release="$1"
    printf '%s\n' "https://raw.githubusercontent.com/drylian/Eggs/main/Connect/SAMP/server/samp037svr_${release}.tar.gz"
    printf '%s\n' "https://github.com/drylian/Eggs/raw/main/Connect/SAMP/server/samp037svr_${release}.tar.gz"
}

build_windows_urls() {
    local release="$1"
    printf '%s\n' "https://gta-multiplayer.cz/downloads/samp037_svr_${release}_win32.zip"
}

download_with_fallback() {
    local output_file="$1"
    shift

    local url
    rm -f "${output_file}"

    for url in "$@"; do
        [[ -n "${url}" ]] || continue
        info "Baixando: ${url}"
        if curl -fsSL --retry 3 --connect-timeout 20 -o "${output_file}" "${url}"; then
            return 0
        fi
        warn "Falha ao baixar ${url}. Tentando o proximo espelho."
    done

    return 1
}

copy_first_match() {
    local search_root="$1"
    local pattern="$2"
    local destination="$3"
    local found_file

    found_file="$(find "${search_root}" -type f -name "${pattern}" | head -n 1 || true)"
    [[ -n "${found_file}" ]] || return 1

    cp -f "${found_file}" "${destination}"
    return 0
}

extract_zip_archive() {
    local archive_file="$1"
    local destination="$2"

    rm -rf "${destination}"
    mkdir -p "${destination}"

    if command -v unzip >/dev/null 2>&1; then
        unzip -qo "${archive_file}" -d "${destination}"
        return 0
    fi

    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "${archive_file}" -C "${destination}"
        return 0
    fi

    die "Nao foi encontrado unzip ou bsdtar no container para extrair o pacote Windows."
}

install_linux_runtime() {
    local release="$1"
    local archive_file="${STATE_ROOT}/cache-linux-${release}.tar.gz"
    local extract_dir="${STATE_ROOT}/extract-linux-${release}"
    local url_list=()

    mapfile -t url_list < <(build_linux_urls "${release}")
    download_with_fallback "${archive_file}" "${url_list[@]}" || die "Falha ao baixar os arquivos Linux do SA-MP release ${release}."

    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"
    tar -xzf "${archive_file}" -C "${extract_dir}"

    if [[ -d "${extract_dir}/samp03" ]]; then
        extract_dir="${extract_dir}/samp03"
    fi

    mkdir -p "${APP_ROOT}/plugins" "${APP_ROOT}/gamemodes" "${APP_ROOT}/filterscripts"
    copy_first_match "${extract_dir}" "samp03svr" "${APP_ROOT}/samp03svr" || die "Pacote Linux baixado sem o binario samp03svr."
    copy_first_match "${extract_dir}" "samp-npc" "${APP_ROOT}/samp-npc" || true
    copy_first_match "${extract_dir}" "announce" "${APP_ROOT}/announce" || true
    copy_first_match "${extract_dir}" "libstdc++.so.6" "${APP_ROOT}/libstdc++.so.6" || true

    if [[ ! -f "${SERVER_CFG}" ]]; then
        copy_first_match "${extract_dir}" "server.cfg" "${SERVER_CFG}" || true
    fi

    chmod +x "${APP_ROOT}/samp03svr" 2>/dev/null || true
    chmod +x "${APP_ROOT}/samp-npc" 2>/dev/null || true
    chmod +x "${APP_ROOT}/announce" 2>/dev/null || true
}

install_windows_runtime() {
    local release="$1"
    local archive_file="${STATE_ROOT}/cache-windows-${release}.zip"
    local extract_dir="${STATE_ROOT}/extract-windows-${release}"
    local url_list=()

    mapfile -t url_list < <(build_windows_urls "${release}")
    download_with_fallback "${archive_file}" "${url_list[@]}" || die "Falha ao baixar os arquivos Windows do SA-MP release ${release}."

    extract_zip_archive "${archive_file}" "${extract_dir}"

    mkdir -p "${APP_ROOT}/plugins" "${APP_ROOT}/gamemodes" "${APP_ROOT}/filterscripts"
    copy_first_match "${extract_dir}" "samp-server.exe" "${APP_ROOT}/samp-server.exe" || die "Pacote Windows baixado sem o binario samp-server.exe."
    copy_first_match "${extract_dir}" "samp-npc.exe" "${APP_ROOT}/samp-npc.exe" || true
    copy_first_match "${extract_dir}" "announce.exe" "${APP_ROOT}/announce.exe" || true

    if [[ ! -f "${SERVER_CFG}" ]]; then
        copy_first_match "${extract_dir}" "server.cfg" "${SERVER_CFG}" || true
    fi
}

resolve_mode() {
    local flavor="${SERVER_FLAVOR:-auto}"
    local hint

    hint="$(cfg_mode_hint)"

    case "${flavor}" in
        windows|linux)
            SERVER_MODE="${flavor}"
            info "Modo forcado por SERVER_FLAVOR=${flavor}."
            return 0
        ;;
        auto|"")
            :
        ;;
        *)
            die "Valor invalido para SERVER_FLAVOR=${flavor}. Use auto, linux ou windows."
        ;;
    esac

    if [[ -f "${APP_ROOT}/samp-server.exe" && -f "${APP_ROOT}/samp03svr" ]]; then
        SERVER_MODE="windows"
        info "Os binarios Linux e Windows foram encontrados. Por padrao o egg vai iniciar pelo samp-server.exe."
        return 0
    fi

    if [[ "${hint}" == "windows" && ! -f "${APP_ROOT}/samp-server.exe" ]]; then
        SERVER_MODE="windows"
        info "server.cfg aponta plugins .dll. O egg vai preparar o modo Windows/Wine."
        return 0
    fi

    if [[ "${hint}" == "linux" && ! -f "${APP_ROOT}/samp03svr" ]]; then
        SERVER_MODE="linux"
        info "server.cfg aponta plugins .so. O egg vai preparar o modo Linux."
        return 0
    fi

    if [[ -f "${APP_ROOT}/samp-server.exe" ]]; then
        SERVER_MODE="windows"
        info "Binario Windows detectado."
        return 0
    fi

    if [[ -f "${APP_ROOT}/samp03svr" ]]; then
        SERVER_MODE="linux"
        info "Binario Linux detectado."
        return 0
    fi

    if [[ "${hint}" == "windows" || "${hint}" == "linux" ]]; then
        SERVER_MODE="${hint}"
        info "Nenhum binario local encontrado. Usando a dica do server.cfg: ${hint}."
        return 0
    fi

    SERVER_MODE="linux"
    info "Nenhum binario ou dica especifica foi encontrado. O egg vai baixar Linux por padrao."
}

ensure_runtime_files() {
    case "${SERVER_MODE}" in
        linux)
            if [[ ! -f "${APP_ROOT}/samp03svr" ]]; then
                info "Binario Linux ausente. Baixando runtime Linux ${LINUX_RELEASE}."
                install_linux_runtime "${LINUX_RELEASE}"
            fi
        ;;
        windows)
            if [[ ! -f "${APP_ROOT}/samp-server.exe" ]]; then
                if [[ "${AUTO_DOWNLOAD_WINDOWS:-1}" != "1" ]]; then
                    die "Modo Windows selecionado, mas AUTO_DOWNLOAD_WINDOWS esta desativado e o binario samp-server.exe nao existe."
                fi
                info "Binario Windows ausente. Baixando runtime Windows ${WINDOWS_RELEASE}."
                install_windows_runtime "${WINDOWS_RELEASE}"
            fi
        ;;
        *)
            die "Modo de execucao desconhecido: ${SERVER_MODE}."
        ;;
    esac
}

normalize_plugins_line() {
    local line_source
    local extension
    local token
    local base_name
    local normalized_list=()
    local final_list

    line_source="${PLUGIN_LIST:-$(read_cfg_value "plugins")}"
    extension=".so"
    [[ "${SERVER_MODE}" == "windows" ]] && extension=".dll"

    if [[ -z "${line_source}" ]]; then
        warn "Linha de plugins vazia. Nenhuma alteracao de extensao foi necessaria."
        return 0
    fi

    for token in ${line_source}; do
        token="${token%\"}"
        token="${token#\"}"
        base_name="${token%.dll}"
        base_name="${base_name%.DLL}"
        base_name="${base_name%.so}"
        base_name="${base_name%.SO}"
        base_name="$(trim "${base_name}")"
        [[ -n "${base_name}" ]] || continue
        normalized_list+=("${base_name}${extension}")
    done

    if [[ "${#normalized_list[@]}" -eq 0 ]]; then
        warn "Nao foi possivel normalizar a lista de plugins."
        return 0
    fi

    final_list="$(printf '%s\n' "${normalized_list[@]}" | awk '!seen[$0]++' | paste -sd' ' -)"
    set_cfg_value "plugins" "${final_list}"
}

sync_server_cfg() {
    local before_checksum
    local after_checksum

    ensure_server_cfg
    cp -f "${SERVER_CFG}" "${SESSION_DIR}/server.cfg.before" 2>/dev/null || true
    before_checksum="$(cksum < "${SERVER_CFG}")"

    set_cfg_value "hostname" "${HOST_NAME:-SA-MP Auto Hybrid}"
    set_cfg_value "maxplayers" "${MAX_PLAYERS:-50}"
    set_cfg_value "rcon_password" "${RCON_PASSWORD:-changemeplease}"
    set_cfg_value "weburl" "${WEB_URL:-www.sa-mp.com}"
    set_cfg_value "maxnpc" "${MAX_NPC:-0}"
    set_cfg_value "logtimeformat" "${LOG_TIME_FORMAT:-[%H:%M:%S]}"
    set_cfg_value "output" "1"

    if [[ -n "${VOICE_PORT:-}" ]]; then
        set_cfg_value "sv_port" "${VOICE_PORT}"
    fi

    ensure_gamemode
    normalize_plugins_line

    after_checksum="$(cksum < "${SERVER_CFG}")"
    if [[ "${before_checksum}" != "${after_checksum}" ]]; then
        cp -f "${SERVER_CFG}" "${SESSION_DIR}/server.cfg.synced"
        info "server.cfg sincronizado automaticamente para o modo ${SERVER_MODE}."
    else
        info "server.cfg ja estava sincronizado."
    fi
}

start_log_watch() {
    local file_path="$1"
    local tag="$2"

    touch "${file_path}" 2>/dev/null || true
    tail -n 0 -F "${file_path}" 2>/dev/null | while IFS= read -r line; do
        log_line "${tag}" "${line}"
    done &
    WATCH_PIDS+=("$!")
}

archive_known_logs() {
    local file_path

    for file_path in \
        "${APP_ROOT}/server_log.txt" \
        "${APP_ROOT}/svlog.txt" \
        "${APP_ROOT}/crashinfo.txt" \
        "${APP_ROOT}/samp.log" \
        "${APP_ROOT}/samp.log.txt" \
        "${APP_ROOT}/samp.erro.log.txt" \
        "${SESSION_DIR}/process.stdout.log" \
        "${SESSION_DIR}/process.stderr.log" \
        "${SERVER_CFG}"; do
        if [[ -f "${file_path}" ]]; then
            cp -f "${file_path}" "${SESSION_DIR}/$(basename "${file_path}")" 2>/dev/null || true
        fi
    done
}

request_server_quit() {
    if [[ -p "${STDIN_PIPE}" ]]; then
        printf '%s\n' "quit" > "${STDIN_PIPE}" 2>/dev/null || true
    fi
}

proc_cmdline() {
    local pid="$1"
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true
}

proc_comm() {
    local pid="$1"
    cat "/proc/${pid}/comm" 2>/dev/null || true
}

match_server_process() {
    local pid="$1"
    local cmdline
    local comm

    [[ -d "/proc/${pid}" ]] || return 1

    cmdline="$(proc_cmdline "${pid}")"
    comm="$(proc_comm "${pid}")"

    case "${SERVER_MODE:-linux}" in
        windows)
            [[ "${cmdline}" == *"samp-server.exe"* ]] && return 0
            [[ "${cmdline}" == *"wine"* && "${cmdline}" == *"samp-server"* ]] && return 0
        ;;
        linux|*)
            [[ "${comm}" == "samp03svr" ]] && return 0
            [[ "${cmdline}" == *"/samp03svr"* ]] && return 0
            [[ "${cmdline}" == *"./samp03svr"* ]] && return 0
        ;;
    esac

    return 1
}

find_server_pid() {
    local proc_dir
    local pid
    local newest_pid=""

    for proc_dir in /proc/[0-9]*; do
        [[ -d "${proc_dir}" ]] || continue
        pid="${proc_dir##*/}"
        [[ "${pid}" != "$$" ]] || continue
        [[ "${pid}" != "${BASHPID}" ]] || continue
        [[ "${pid}" != "${PPID}" ]] || continue

        if match_server_process "${pid}"; then
            newest_pid="${pid}"
        fi
    done

    printf '%s' "${newest_pid}"
}

is_server_running() {
    local pid

    pid="$(find_server_pid)"
    if [[ -n "${pid}" ]]; then
        SERVER_PID="${pid}"
        return 0
    fi

    if [[ -n "${LAUNCHER_PID}" ]] && kill -0 "${LAUNCHER_PID}" 2>/dev/null; then
        SERVER_PID="${LAUNCHER_PID}"
        return 0
    fi

    SERVER_PID=""
    return 1
}

await_server_stop() {
    local timeout_seconds="${1:-15}"
    local waited=0

    while [[ "${waited}" -lt "${timeout_seconds}" ]]; do
        if ! is_server_running; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

wait_for_server_boot() {
    local timeout_seconds="${1:-20}"
    local waited=0

    while [[ "${waited}" -lt "${timeout_seconds}" ]]; do
        if is_server_running; then
            return 0
        fi
        if [[ -n "${LAUNCHER_PID}" ]] && ! kill -0 "${LAUNCHER_PID}" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

shutdown_server() {
    if [[ "${STOPPING}" == "1" ]]; then
        return 0
    fi

    STOPPING="1"
    warn "Recebido sinal de parada. Encaminhando para o servidor."

    if is_server_running; then
        request_server_quit
        if await_server_stop 15; then
            return 0
        fi
        warn "O servidor nao respondeu ao quit dentro do tempo esperado. Enviando TERM."
        kill -TERM "${SERVER_PID}" 2>/dev/null || true
        if [[ -n "${LAUNCHER_PID}" ]] && [[ "${LAUNCHER_PID}" != "${SERVER_PID}" ]]; then
            kill -TERM "${LAUNCHER_PID}" 2>/dev/null || true
        fi
    fi
}

forward_stdin() {
    local line
    local normalized

    exec 3>"${STDIN_PIPE}"

    while IFS= read -r line; do
        normalized="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"

        case "${normalized}" in
            quit|exit|stop)
                warn "Comando de parada recebido via stdin do painel."
                printf '%s\n' "quit" >&3 || true

                if await_server_stop 15; then
                    break
                fi

                warn "O servidor ignorou o comando quit recebido via painel. Enviando TERM."
                if [[ -n "${SERVER_PID}" ]]; then
                    kill -TERM "${SERVER_PID}" 2>/dev/null || true
                fi
                if [[ -n "${LAUNCHER_PID}" ]] && [[ "${LAUNCHER_PID}" != "${SERVER_PID}" ]]; then
                    kill -TERM "${LAUNCHER_PID}" 2>/dev/null || true
                fi
                break
            ;;
            *)
                printf '%s\n' "${line}" >&3 || true
            ;;
        esac
    done

    exec 3>&-
}

cleanup() {
    local exit_code="$?"
    local watcher_pid

    set +e

    archive_known_logs

    for watcher_pid in "${WATCH_PIDS[@]}"; do
        kill "${watcher_pid}" 2>/dev/null || true
    done

    if [[ -n "${STDIN_FORWARD_PID}" ]]; then
        kill "${STDIN_FORWARD_PID}" 2>/dev/null || true
    fi

    rm -f "${STDIN_PIPE}"

    info "Logs da sessao arquivados em ${SESSION_DIR}."
    exit "${exit_code}"
}

launch_server() {
    local wine_bin
    local -a launch_command

    rm -f "${STDIN_PIPE}"
    mkfifo "${STDIN_PIPE}"
    : > "${SESSION_DIR}/process.stdout.log"
    : > "${SESSION_DIR}/process.stderr.log"

    if [[ "${SERVER_MODE}" == "windows" ]]; then
        if command -v wine64 >/dev/null 2>&1; then
            wine_bin="wine64"
        elif command -v wine >/dev/null 2>&1; then
            wine_bin="wine"
        else
            die "Nenhum binario wine foi encontrado no container."
        fi

        launch_command=(env "WINEDEBUG=${WINE_DEBUG_LEVEL:--all}" "${wine_bin}" "./samp-server.exe")
    else
        chmod +x "${APP_ROOT}/samp03svr" 2>/dev/null || true
        launch_command=("./samp03svr")
    fi

    info "Iniciando SA-MP em modo ${SERVER_MODE}."
    info "Gamemode ativa: ${CURRENT_GAMEMODE}"
    info "Release selecionada: ${RELEASE_LABEL}"

    start_log_watch "${APP_ROOT}/server_log.txt" "SERVER"
    start_log_watch "${APP_ROOT}/svlog.txt" "VOICE"
    start_log_watch "${SESSION_DIR}/process.stderr.log" "STDERR"

    if [[ "${SERVER_MODE}" == "windows" ]]; then
        start_log_watch "${SESSION_DIR}/process.stdout.log" "WINE"
    else
        start_log_watch "${SESSION_DIR}/process.stdout.log" "APP"
    fi

    (
        cd "${APP_ROOT}"
        "${launch_command[@]}" < "${STDIN_PIPE}" >> "${SESSION_DIR}/process.stdout.log" 2>> "${SESSION_DIR}/process.stderr.log"
    ) &
    LAUNCHER_PID="$!"
    SERVER_PID="${LAUNCHER_PID}"

    forward_stdin &
    STDIN_FORWARD_PID="$!"

    if wait_for_server_boot 20; then
        info "Processo do SA-MP detectado com PID ${SERVER_PID}."
    else
        warn "Nao foi possivel confirmar o PID final do SA-MP logo apos a inicializacao. O monitoramento continuara ativo."
    fi

    echo "SA-MP AUTO READY"
}

monitor_server_lifecycle() {
    local misses=0

    while true; do
        if is_server_running; then
            misses=0
        else
            misses=$((misses + 1))
            if [[ "${misses}" -ge 3 ]]; then
                return 0
            fi
        fi
        sleep 1
    done
}

main() {
    local exit_code

    trap shutdown_server TERM INT
    trap cleanup EXIT

    SAMP_RELEASE="${SAMP_RELEASE:-stable}"

    info "Inicializando egg automatico SA-MP Hybrid."
    load_state
    resolve_release_targets
    resolve_mode
    ensure_runtime_files
    sync_server_cfg

    if [[ "${LAST_GAMEMODE:-unknown}" != "${CURRENT_GAMEMODE}" ]]; then
        info "Troca de gamemode detectada: ${LAST_GAMEMODE:-desconhecida} -> ${CURRENT_GAMEMODE}."
    fi

    if [[ "${LAST_MODE:-unknown}" != "${SERVER_MODE}" ]]; then
        info "Troca de plataforma detectada: ${LAST_MODE:-desconhecida} -> ${SERVER_MODE}."
    fi

    save_state
    launch_server

    monitor_server_lifecycle

    set +e
    if [[ -n "${LAUNCHER_PID}" ]]; then
        wait "${LAUNCHER_PID}" 2>/dev/null
    fi
    set -e

    if [[ "${STOPPING}" == "1" ]]; then
        exit_code=0
        info "Processo principal do SA-MP foi encerrado normalmente."
    else
        exit_code=1
        error "Processo principal do SA-MP terminou com codigo ${exit_code}."
    fi

    exit "${exit_code}"
}

main "$@"
