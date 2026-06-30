#!/usr/bin/env bash

set -Eeuo pipefail

APP_ID=3792580
STEAMCMD_DIR=/opt/steamcmd
SCUM_DIR=/opt/scumserver
SERVER_EXE="${SCUM_DIR}/SCUM/Binaries/Win64/SCUMServer.exe"
GRACEFUL_STOP_TIMEOUT=60

GAMEPORT="${GAMEPORT:-7777}"
QUERYPORT="${QUERYPORT:-27015}"
MAXPLAYERS="${MAXPLAYERS:-32}"
ADDITIONALFLAGS="${ADDITIONALFLAGS:-}"
GAME_UPDATE="${GAME_UPDATE:-true}"
RESTART_SCHEDULE="${RESTART_SCHEDULE:-4,10,16,22}"
MEMORY_THRESHOLD_PERCENT="${MEMORY_THRESHOLD_PERCENT:-95}"
MEMORY_CHECK_INTERVAL="${MEMORY_CHECK_INTERVAL:-60}"
MEMORY_WATCHDOG_DEBUG="${MEMORY_WATCHDOG_DEBUG:-false}"
UPDATE_MIN_INTERVAL_MINUTES="${UPDATE_MIN_INTERVAL_MINUTES:-30}"
UPDATE_MARKER_FILE="${SCUM_DIR}/.last_successful_update"
AUTO_RESTART_ON_CRASH="${AUTO_RESTART_ON_CRASH:-true}"
CRASH_RESTART_DELAY_SECONDS="${CRASH_RESTART_DELAY_SECONDS:-15}"
MAX_CRASH_RESTARTS="${MAX_CRASH_RESTARTS:-0}"
WINE_HEALTHCHECK_TIMEOUT_SECONDS="${WINE_HEALTHCHECK_TIMEOUT_SECONDS:-25}"
WINE_INIT_TIMEOUT_SECONDS="${WINE_INIT_TIMEOUT_SECONDS:-240}"

WRAPPER_PID=""
SCUM_PID=""
WATCHDOG_PID=""
SCHEDULER_PID=""
RESTART_REQUESTED=0
EXIT_REQUESTED=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

print_banner() {
    cat <<'EOF'
                      _/_/_/    _/_/_/  _/    _/  _/      _/
                   _/        _/        _/    _/  _/_/  _/_/
                    _/_/    _/        _/    _/  _/  _/  _/
                       _/  _/        _/    _/  _/      _/
                _/_/_/      _/_/_/    _/_/    _/      _/

                           DEDICATED SERVER
EOF
}

cleanup_children() {
    if [[ -n "${WATCHDOG_PID}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
        kill "${WATCHDOG_PID}" 2>/dev/null || true
        wait "${WATCHDOG_PID}" 2>/dev/null || true
    fi

    if [[ -n "${SCHEDULER_PID}" ]] && kill -0 "${SCHEDULER_PID}" 2>/dev/null; then
        kill "${SCHEDULER_PID}" 2>/dev/null || true
        wait "${SCHEDULER_PID}" 2>/dev/null || true
    fi

    WATCHDOG_PID=""
    SCHEDULER_PID=""
}

handle_exit_signal() {
    EXIT_REQUESTED=1
    log "Received shutdown signal."
    graceful_stop "container shutdown"
}

handle_restart_signal() {
    if [[ "${RESTART_REQUESTED}" -eq 1 ]]; then
        return
    fi

    RESTART_REQUESTED=1
    log "Restart requested."
    graceful_stop "scheduled or watchdog restart"
}

graceful_stop() {
    local reason="${1:-shutdown}"

    if [[ -n "${SCUM_PID}" ]] && kill -0 "${SCUM_PID}" 2>/dev/null; then
        log "Sending SIGINT to SCUMServer.exe (${SCUM_PID}) because of ${reason}."
        kill -INT "${SCUM_PID}" 2>/dev/null || true

        for ((i = 0; i < GRACEFUL_STOP_TIMEOUT; i++)); do
            if ! kill -0 "${SCUM_PID}" 2>/dev/null; then
                log "SCUMServer.exe stopped gracefully."
                break
            fi
            sleep 1
        done
    fi

    if [[ -n "${WRAPPER_PID}" ]] && kill -0 "${WRAPPER_PID}" 2>/dev/null; then
        kill -TERM "${WRAPPER_PID}" 2>/dev/null || true
        wait "${WRAPPER_PID}" 2>/dev/null || true
    fi

    if [[ -n "${SCUM_PID}" ]] && kill -0 "${SCUM_PID}" 2>/dev/null; then
        log "Graceful stop timed out; forcing SCUMServer.exe to exit."
        kill -KILL "${SCUM_PID}" 2>/dev/null || true
    fi
}

normalize_boolean() {
    local value="${1,,}"
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *)
            log "ERROR: invalid boolean value '${1}'."
            exit 1
            ;;
    esac
}

install_steamcmd() {
    if [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
        log "SteamCMD found."
        return
    fi

    log "SteamCMD not found. Installing..."
    install -d -m 0755 "${STEAMCMD_DIR}"
    wget --timeout=30 --tries=3 -O "${STEAMCMD_DIR}/steamcmd_linux.tar.gz" \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
    tar -xzf "${STEAMCMD_DIR}/steamcmd_linux.tar.gz" -C "${STEAMCMD_DIR}"
    rm -f "${STEAMCMD_DIR}/steamcmd_linux.tar.gz"
    log "SteamCMD installed."
}

run_steamcmd() {
    "${STEAMCMD_DIR}/steamcmd.sh" "$@"
}

wine_healthcheck() {
    timeout "${WINE_HEALTHCHECK_TIMEOUT_SECONDS}" \
        xvfb-run --auto-servernum wine cmd /c exit >/dev/null 2>&1
}

ensure_wine_prefix_healthy() {
    local init_status=0

    if wine_healthcheck; then
        return
    fi

    log "Wine prefix health check failed; rebuilding ${WINEPREFIX}."
    rm -rf "${WINEPREFIX}"
    install -d -m 0755 "${WINEPREFIX}"

    init_status=0
    timeout "${WINE_INIT_TIMEOUT_SECONDS}" \
        xvfb-run --auto-servernum wineboot --init >/dev/null 2>&1 || init_status=$?

    if [[ "${init_status}" -ne 0 ]] && [[ "${init_status}" -ne 124 ]]; then
        log "ERROR: wineboot failed while rebuilding prefix (exit ${init_status})."
        exit "${init_status}"
    fi

    if ! wine_healthcheck; then
        log "ERROR: Wine prefix is still unhealthy after rebuild (kernel32.dll issue persists)."
        exit 1
    fi

    log "Wine prefix rebuilt successfully."
}

update_server_files() {
    local update_enabled now last_update update_age_minutes
    update_enabled="$(normalize_boolean "${GAME_UPDATE}")"

    log "Updating SteamCMD..."
    run_steamcmd +quit

    if [[ "${update_enabled}" == "false" ]]; then
        if [[ ! -f "${SERVER_EXE}" ]]; then
            log "ERROR: GAME_UPDATE=false but no existing SCUM server installation was found at ${SERVER_EXE}."
            exit 1
        fi

        log "GAME_UPDATE=false. Reusing existing SCUM server files."
        return
    fi

    if [[ ! "${UPDATE_MIN_INTERVAL_MINUTES}" =~ ^[0-9]+$ ]]; then
        log "ERROR: UPDATE_MIN_INTERVAL_MINUTES must be an integer."
        exit 1
    fi

    if [[ -f "${UPDATE_MARKER_FILE}" ]] && (( UPDATE_MIN_INTERVAL_MINUTES > 0 )); then
        now="$(date +%s)"
        last_update="$(stat -c '%Y' "${UPDATE_MARKER_FILE}" 2>/dev/null || echo 0)"
        if (( last_update > 0 )); then
            update_age_minutes="$(((now - last_update) / 60))"
            if (( update_age_minutes < UPDATE_MIN_INTERVAL_MINUTES )); then
                log "Skipping SCUM update; last successful update was ${update_age_minutes} minute(s) ago (min interval: ${UPDATE_MIN_INTERVAL_MINUTES})."
                return
            fi
        fi
    fi

    log "Installing or updating SCUM dedicated server..."
    if run_steamcmd \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir "${SCUM_DIR}" \
        +login anonymous \
        +app_update "${APP_ID}" validate \
        +quit; then
        touch "${UPDATE_MARKER_FILE}"
        return
    fi

    if [[ -f "${SERVER_EXE}" ]]; then
        log "WARNING: SCUM update failed; continuing with existing server files."
        return
    fi

    log "ERROR: SCUM update failed and no existing server files were found."
    exit 1
}

discover_scum_pid() {
    local pid=""
    for ((i = 0; i < 30; i++)); do
        pid="$(pgrep -f 'SCUMServer\.exe' | head -n 1 || true)"
        if [[ -n "${pid}" ]]; then
            printf '%s\n' "${pid}"
            return
        fi
        sleep 1
    done

    return 1
}

next_restart_epoch() {
    local now candidate best=""
    local raw hour

    now="$(date +%s)"
    IFS=',' read -r -a schedule_items <<< "${RESTART_SCHEDULE}"

    for raw in "${schedule_items[@]}"; do
        hour="${raw//[[:space:]]/}"
        [[ -z "${hour}" ]] && continue

        if [[ ! "${hour}" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            log "ERROR: invalid hour '${hour}' in RESTART_SCHEDULE='${RESTART_SCHEDULE}'."
            exit 1
        fi

        candidate="$(date -d "today ${hour}:00:00" +%s)"
        if (( candidate <= now )); then
            candidate="$(date -d "tomorrow ${hour}:00:00" +%s)"
        fi

        if [[ -z "${best}" ]] || (( candidate < best )); then
            best="${candidate}"
        fi
    done

    if [[ -z "${best}" ]]; then
        return 1
    fi

    printf '%s\n' "${best}"
}

start_schedule_watcher() {
    if [[ -z "${RESTART_SCHEDULE//[[:space:]]/}" ]]; then
        log "Restart scheduler disabled."
        return
    fi

    (
        while true; do
            local next_epoch sleep_seconds
            next_epoch="$(next_restart_epoch)"
            sleep_seconds="$((next_epoch - $(date +%s)))"
            if (( sleep_seconds < 1 )); then
                sleep_seconds=1
            fi

            log "Next scheduled restart at $(date -d "@${next_epoch}" '+%Y-%m-%d %H:%M:%S')."
            sleep "${sleep_seconds}"
            log "Scheduled restart time reached."
            kill -USR1 $$
        done
    ) &

    SCHEDULER_PID=$!
}

start_memory_watchdog() {
    if [[ ! "${MEMORY_THRESHOLD_PERCENT}" =~ ^[0-9]+$ ]]; then
        log "ERROR: MEMORY_THRESHOLD_PERCENT must be an integer."
        exit 1
    fi

    if [[ ! "${MEMORY_CHECK_INTERVAL}" =~ ^[0-9]+$ ]] || (( MEMORY_CHECK_INTERVAL <= 0 )); then
        log "ERROR: MEMORY_CHECK_INTERVAL must be a positive integer."
        exit 1
    fi

    if (( MEMORY_THRESHOLD_PERCENT <= 0 )); then
        log "Memory watchdog disabled."
        return
    fi

    (
        while true; do
            local mem_usage
            mem_usage="$(LC_ALL=C free | awk '/Mem/ { printf("%.0f", ($2-$7)/$2*100) }')"

            if (( mem_usage >= MEMORY_THRESHOLD_PERCENT )); then
                log "Memory watchdog triggered at ${mem_usage}% usage."
                kill -USR1 $$
                exit 0
            fi

            if [[ "$(normalize_boolean "${MEMORY_WATCHDOG_DEBUG}")" == "true" ]]; then
                log "Memory watchdog debug: ${mem_usage}% used."
            fi

            sleep "${MEMORY_CHECK_INTERVAL}"
        done
    ) &

    WATCHDOG_PID=$!
    log "Memory watchdog enabled at ${MEMORY_THRESHOLD_PERCENT}% with ${MEMORY_CHECK_INTERVAL}s interval."
}

start_server() {
    if [[ ! -f "${SERVER_EXE}" ]]; then
        log "ERROR: SCUM server executable not found at ${SERVER_EXE}."
        exit 1
    fi

    log "Starting SCUM dedicated server..."

    # shellcheck disable=SC2086
    xvfb-run --auto-servernum --server-args="-screen 0 1024x768x24" \
        wine "${SERVER_EXE}" \
            -log \
            -port="${GAMEPORT}" \
            -QueryPort="${QUERYPORT}" \
            -MaxPlayers="${MAXPLAYERS}" \
            ${ADDITIONALFLAGS} &

    WRAPPER_PID=$!
    log "Server wrapper PID: ${WRAPPER_PID}"

    SCUM_PID="$(discover_scum_pid)" || {
        log "ERROR: SCUMServer.exe process was not detected."
        exit 1
    }

    log "SCUMServer.exe PID: ${SCUM_PID}"
}

main() {
    local auto_restart_on_crash crash_restart_count

    print_banner

    if [[ -n "${PORT:-}" ]]; then
        log "PORT is deprecated; copying its value into GAMEPORT."
        GAMEPORT="${PORT}"
    fi

    if [[ ! "${CRASH_RESTART_DELAY_SECONDS}" =~ ^[0-9]+$ ]]; then
        log "ERROR: CRASH_RESTART_DELAY_SECONDS must be an integer."
        exit 1
    fi

    if [[ ! "${MAX_CRASH_RESTARTS}" =~ ^[0-9]+$ ]]; then
        log "ERROR: MAX_CRASH_RESTARTS must be an integer."
        exit 1
    fi

    if [[ ! "${WINE_HEALTHCHECK_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( WINE_HEALTHCHECK_TIMEOUT_SECONDS <= 0 )); then
        log "ERROR: WINE_HEALTHCHECK_TIMEOUT_SECONDS must be a positive integer."
        exit 1
    fi

    if [[ ! "${WINE_INIT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( WINE_INIT_TIMEOUT_SECONDS <= 0 )); then
        log "ERROR: WINE_INIT_TIMEOUT_SECONDS must be a positive integer."
        exit 1
    fi

    auto_restart_on_crash="$(normalize_boolean "${AUTO_RESTART_ON_CRASH}")"
    crash_restart_count=0

    trap handle_exit_signal TERM INT
    trap handle_restart_signal USR1

    install_steamcmd
    ensure_wine_prefix_healthy
    update_server_files

    while true; do
        RESTART_REQUESTED=0
        EXIT_REQUESTED=0
        cleanup_children

        start_server
        start_memory_watchdog
        start_schedule_watcher

        local exit_code=0
        wait "${WRAPPER_PID}" || exit_code=$?
        cleanup_children

        if (( EXIT_REQUESTED == 1 )); then
            log "Server stopped because the container is shutting down."
            exit 0
        fi

        if (( RESTART_REQUESTED == 1 )); then
            log "Restarting SCUM dedicated server."
            crash_restart_count=0
            continue
        fi

        if [[ "${auto_restart_on_crash}" == "true" ]]; then
            crash_restart_count=$((crash_restart_count + 1))

            if (( MAX_CRASH_RESTARTS > 0 )) && (( crash_restart_count > MAX_CRASH_RESTARTS )); then
                log "SCUM dedicated server crashed too many times (${crash_restart_count}). Stopping container."
                exit "${exit_code}"
            fi

            log "SCUM dedicated server exited with code ${exit_code}; restarting in ${CRASH_RESTART_DELAY_SECONDS}s (attempt ${crash_restart_count})."
            sleep "${CRASH_RESTART_DELAY_SECONDS}"
            continue
        fi

        log "SCUM dedicated server exited with code ${exit_code}; auto restart disabled."
        exit "${exit_code}"
    done
}

main "$@"
