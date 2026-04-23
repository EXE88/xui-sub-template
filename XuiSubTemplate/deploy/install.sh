#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR"
ENV_FILE="$APP_DIR/.env"
REQ_FILE="$APP_DIR/requierments.txt"
STATE_FILE="$APP_DIR/deploy/.installer-state"
BACKUP_DIR="$APP_DIR/deploy/.installer-backups"

mkdir -p "$BACKUP_DIR"

if [[ ! -f "$APP_DIR/manage.py" ]]; then
    echo "manage.py not found in $APP_DIR"
    exit 1
fi

if [[ ! -f "$REQ_FILE" ]]; then
    echo "Requirements file not found: $REQ_FILE"
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    SUDO_BIN=""
else
    SUDO_BIN="sudo"
fi

DEFAULT_ALLOWED_HOSTS="localhost,127.0.0.1"
DEFAULT_ADMIN_PATH="admin"
DEFAULT_BIND="0.0.0.0:8000"
DEFAULT_WORKERS="3"
DEFAULT_THREADS="2"
DEFAULT_TIMEOUT="120"
DEFAULT_GRACEFUL_TIMEOUT="30"
DEFAULT_KEEPALIVE="5"
DEFAULT_LOG_LEVEL="info"
DEFAULT_XUI_DB="/etc/x-ui/x-ui.db"
DEFAULT_FALLBACK_DOMAIN="$(hostname -f 2>/dev/null || hostname)"
DEFAULT_FALLBACK_PROTOCOL="http"
DEFAULT_FALLBACK_PORT="2096"
DEFAULT_USAGE_CRON="0 * * * *"
DEFAULT_CLEANUP_CRON="15 3 * * *"
DEFAULT_CHART_LIMIT="240"
DEFAULT_SERVICE_NAME="xui-sub-template"
DEFAULT_RUN_USER="$(id -un)"
DEFAULT_RUN_GROUP="$(id -gn)"
DEFAULT_VENV_DIR="$APP_DIR/env"
DEFAULT_LOG_DIR="$APP_DIR/logs"

INSTALL_IN_PROGRESS=0
INSTALL_FAILED=0
ROLLBACK_RUNNING=0

ENV_CREATED=0
ENV_BACKUP_PATH=""
VENV_CREATED=0
SERVICE_CREATED=0
SERVICE_BACKUP_PATH=""
CRON_ADDED=0
CRON_LOG_DIR_CREATED=0
PROXY_ENABLED=0
HTTP_PROXY_VALUE=""
HTTPS_PROXY_VALUE=""
ALL_PROXY_VALUE=""
NO_PROXY_VALUE=""

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_BLUE=$'\033[38;5;39m'
    C_GREEN=$'\033[38;5;46m'
    C_YELLOW=$'\033[38;5;220m'
    C_RED=$'\033[38;5;196m'
    C_CYAN=$'\033[38;5;51m'
    C_MAGENTA=$'\033[38;5;207m'
    C_DIM=$'\033[2m'
else
    C_RESET=""
    C_BOLD=""
    C_BLUE=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
    C_MAGENTA=""
    C_DIM=""
fi

print_line() {
    printf '%b\n' "$1"
}

section() {
    print_line ""
    print_line "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$1${C_RESET}"
}

info() {
    print_line "${C_CYAN}>${C_RESET} $1"
}

success() {
    print_line "${C_GREEN}+${C_RESET} $1"
}

warn() {
    print_line "${C_YELLOW}!${C_RESET} $1"
}

error() {
    print_line "${C_RED}x${C_RESET} $1" >&2
}

banner() {
    print_line "${C_MAGENTA}${C_BOLD}XuiSubTemplate Installer${C_RESET}"
    print_line "${C_DIM}$APP_DIR${C_RESET}"
}

ask() {
    local prompt="$1"
    local default_value="${2-}"
    local answer

    if [[ -n "$default_value" ]]; then
        read -r -p "$(printf '%b' "${C_BLUE}?${C_RESET} $prompt [${default_value}]: ")" answer
        printf '%s\n' "${answer:-$default_value}"
    else
        read -r -p "$(printf '%b' "${C_BLUE}?${C_RESET} $prompt: ")" answer
        printf '%s\n' "$answer"
    fi
}

confirm() {
    local prompt="$1"
    local default_value="${2:-Y}"
    local suffix="[Y/n]"
    local answer

    if [[ "${default_value^^}" == "N" ]]; then
        suffix="[y/N]"
    fi

    read -r -p "$(printf '%b' "${C_BLUE}?${C_RESET} $prompt $suffix: ")" answer
    answer="${answer:-$default_value}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

shell_quote() {
    printf '%q' "$1"
}

escape_env_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

random_secret_key() {
    python3 - <<'PY'
from secrets import token_urlsafe
print(token_urlsafe(50))
PY
}

save_state() {
    cat > "$STATE_FILE" <<EOF
SERVICE_NAME=$(shell_quote "${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}")
RUN_USER=$(shell_quote "${RUN_USER:-$DEFAULT_RUN_USER}")
RUN_GROUP=$(shell_quote "${RUN_GROUP:-$DEFAULT_RUN_GROUP}")
VENV_DIR=$(shell_quote "${VENV_DIR:-$DEFAULT_VENV_DIR}")
CRON_LOG_DIR=$(shell_quote "${CRON_LOG_DIR:-$DEFAULT_LOG_DIR}")
ENV_FILE=$(shell_quote "$ENV_FILE")
APP_DIR=$(shell_quote "$APP_DIR")
EOF
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    else
        SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
        RUN_USER="${RUN_USER:-$DEFAULT_RUN_USER}"
        RUN_GROUP="${RUN_GROUP:-$DEFAULT_RUN_GROUP}"
        VENV_DIR="${VENV_DIR:-$DEFAULT_VENV_DIR}"
        CRON_LOG_DIR="${CRON_LOG_DIR:-$DEFAULT_LOG_DIR}"
    fi
}

run_with_proxy() {
    local use_sudo="$1"
    shift
    local -a cmd=("$@")
    local -a env_args=()

    if [[ "$PROXY_ENABLED" == "1" ]]; then
        [[ -n "$HTTP_PROXY_VALUE" ]] && env_args+=("http_proxy=$HTTP_PROXY_VALUE" "HTTP_PROXY=$HTTP_PROXY_VALUE")
        [[ -n "$HTTPS_PROXY_VALUE" ]] && env_args+=("https_proxy=$HTTPS_PROXY_VALUE" "HTTPS_PROXY=$HTTPS_PROXY_VALUE")
        [[ -n "$ALL_PROXY_VALUE" ]] && env_args+=("all_proxy=$ALL_PROXY_VALUE" "ALL_PROXY=$ALL_PROXY_VALUE")
        [[ -n "$NO_PROXY_VALUE" ]] && env_args+=("no_proxy=$NO_PROXY_VALUE" "NO_PROXY=$NO_PROXY_VALUE")
    fi

    if [[ "$use_sudo" == "1" && -n "$SUDO_BIN" ]]; then
        if (( ${#env_args[@]} > 0 )); then
            "$SUDO_BIN" env "${env_args[@]}" "${cmd[@]}"
        else
            "$SUDO_BIN" "${cmd[@]}"
        fi
        return
    fi

    if (( ${#env_args[@]} > 0 )); then
        env "${env_args[@]}" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

backup_file_if_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local backup_path="$BACKUP_DIR/$(basename "$path").$(date +%Y%m%d%H%M%S).bak"
        cp "$path" "$backup_path"
        printf '%s\n' "$backup_path"
        return
    fi
    printf '\n'
}

restore_or_remove_env() {
    if [[ -n "$ENV_BACKUP_PATH" && -f "$ENV_BACKUP_PATH" ]]; then
        cp "$ENV_BACKUP_PATH" "$ENV_FILE"
        success "Restored previous .env"
    elif [[ "$ENV_CREATED" == "1" && -f "$ENV_FILE" ]]; then
        rm -f "$ENV_FILE"
        success "Removed generated .env"
    fi
}

restore_or_remove_service() {
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    if [[ -n "$SERVICE_BACKUP_PATH" && -f "$SERVICE_BACKUP_PATH" ]]; then
        run_with_proxy 1 cp "$SERVICE_BACKUP_PATH" "$service_file"
        success "Restored previous systemd service"
    elif [[ "$SERVICE_CREATED" == "1" ]]; then
        run_with_proxy 1 rm -f "$service_file"
        success "Removed generated systemd service"
    fi

    if command_exists systemctl; then
        run_with_proxy 1 systemctl daemon-reload || true
    fi
}

remove_generated_cron() {
    if [[ "$CRON_ADDED" == "1" && -x "${VENV_DIR}/bin/python" ]]; then
        pushd "$APP_DIR" >/dev/null
        "${VENV_DIR}/bin/python" manage.py crontab remove >/dev/null 2>&1 || true
        popd >/dev/null
        success "Removed generated Django crontab entries"
    fi
}

rollback_install() {
    if [[ "$ROLLBACK_RUNNING" == "1" ]]; then
        return
    fi
    ROLLBACK_RUNNING=1

    section "Rollback"
    warn "Installation did not finish. Reverting generated artifacts."

    if command_exists systemctl; then
        run_with_proxy 1 systemctl stop "${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}" >/dev/null 2>&1 || true
        run_with_proxy 1 systemctl disable "${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    remove_generated_cron
    restore_or_remove_service

    if [[ "$VENV_CREATED" == "1" && -d "${VENV_DIR:-}" ]]; then
        rm -rf "$VENV_DIR"
        success "Removed generated virtualenv"
    fi

    restore_or_remove_env

    if [[ "$CRON_LOG_DIR_CREATED" == "1" && -d "${CRON_LOG_DIR:-}" ]]; then
        run_with_proxy 1 rm -rf "$CRON_LOG_DIR" >/dev/null 2>&1 || true
        success "Removed generated log directory"
    fi

    rm -f "$STATE_FILE"
}

handle_error() {
    local exit_code=$?
    INSTALL_FAILED=1
    error "Installer failed with exit code $exit_code"
    rollback_install
    exit "$exit_code"
}

handle_interrupt() {
    INSTALL_FAILED=1
    warn "Installer interrupted by user"
    rollback_install
    exit 130
}

prompt_proxy_settings() {
    section "Proxy"
    if ! confirm "Use a proxy for apt/pip/system commands during installation?" "N"; then
        PROXY_ENABLED=0
        return
    fi

    PROXY_ENABLED=1
    local common_proxy
    common_proxy="$(ask "Proxy URL for HTTP/HTTPS (example: http://127.0.0.1:7890)")"
    HTTP_PROXY_VALUE="$(ask "HTTP proxy" "$common_proxy")"
    HTTPS_PROXY_VALUE="$(ask "HTTPS proxy" "$common_proxy")"
    ALL_PROXY_VALUE="$(ask "ALL_PROXY (optional)" "")"
    NO_PROXY_VALUE="$(ask "NO_PROXY (optional)" "localhost,127.0.0.1")"

    success "Proxy settings captured for installation commands"
}

create_env_file() {
    local debug_value="False"
    if confirm "Enable DEBUG mode?" "N"; then
        debug_value="True"
    fi

    local generated_secret_key
    generated_secret_key="$(random_secret_key)"
    SECRET_KEY="$(ask "SECRET_KEY" "$generated_secret_key")"

    ENV_BACKUP_PATH="$(backup_file_if_exists "$ENV_FILE")"
    cat > "$ENV_FILE" <<EOF
SECRET_KEY="$(escape_env_value "$SECRET_KEY")"
DEBUG=$debug_value
ALLOWED_HOSTS=$(escape_env_value "$ALLOWED_HOSTS")
ADMIN_PATH=$(escape_env_value "$ADMIN_PATH")
GUNICORN_BIND=$(escape_env_value "$GUNICORN_BIND")
GUNICORN_WORKERS=$(escape_env_value "$GUNICORN_WORKERS")
GUNICORN_THREADS=$(escape_env_value "$GUNICORN_THREADS")
GUNICORN_TIMEOUT=$(escape_env_value "$GUNICORN_TIMEOUT")
GUNICORN_GRACEFUL_TIMEOUT=$(escape_env_value "$GUNICORN_GRACEFUL_TIMEOUT")
GUNICORN_KEEPALIVE=$(escape_env_value "$GUNICORN_KEEPALIVE")
GUNICORN_LOG_LEVEL=$(escape_env_value "$GUNICORN_LOG_LEVEL")

XUI_DB_ADDRESS="$(escape_env_value "$XUI_DB_ADDRESS")"
XUI_SUBSERVICE_DOAMIN="$(escape_env_value "$XUI_SUBSERVICE_DOMAIN")"
XUI_SUBSERVICE_PORT=$(escape_env_value "$XUI_SUBSERVICE_PORT")
XUI_SUBSERVICE_PROTOCOL=$(escape_env_value "$XUI_SUBSERVICE_PROTOCOL")
USAGE_CRON_SCHEDULE="$(escape_env_value "$USAGE_CRON_SCHEDULE")"
USAGE_CLEANUP_CRON_SCHEDULE="$(escape_env_value "$USAGE_CLEANUP_CRON_SCHEDULE")"
CRON_LOG_DIR="$(escape_env_value "$CRON_LOG_DIR")"
USAGE_CHART_LIMIT=$(escape_env_value "$USAGE_CHART_LIMIT")
EOF

    ENV_CREATED=1
    if [[ -n "$SUDO_BIN" ]]; then
        run_with_proxy 1 chown "$RUN_USER:$RUN_GROUP" "$ENV_FILE"
    fi
    success "Created .env"
}

create_virtualenv_and_install() {
    local venv_parent_dir
    venv_parent_dir="$(dirname "$VENV_DIR")"
    mkdir -p "$venv_parent_dir"

    python3 -m venv "$VENV_DIR"
    VENV_CREATED=1
    run_with_proxy 0 "$VENV_DIR/bin/pip" install --upgrade pip
    run_with_proxy 0 "$VENV_DIR/bin/pip" install -r "$REQ_FILE"
    run_with_proxy 0 "$VENV_DIR/bin/pip" install gunicorn

    if [[ -n "$SUDO_BIN" ]]; then
        run_with_proxy 1 chown -R "$RUN_USER:$RUN_GROUP" "$VENV_DIR"
    fi
    success "Virtualenv and dependencies installed"
}

run_django_setup() {
    pushd "$APP_DIR" >/dev/null
    "$VENV_DIR/bin/python" manage.py migrate
    "$VENV_DIR/bin/python" manage.py collectstatic --noinput

    if "$VENV_DIR/bin/python" manage.py help crontab >/dev/null 2>&1; then
        "$VENV_DIR/bin/python" manage.py crontab remove >/dev/null 2>&1 || true
        "$VENV_DIR/bin/python" manage.py crontab add
        CRON_ADDED=1
    fi

    if confirm "Create a Django superuser now?" "N"; then
        "$VENV_DIR/bin/python" manage.py createsuperuser
    fi
    popd >/dev/null

    success "Django setup completed"
}

write_service_file() {
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local temp_file

    SERVICE_BACKUP_PATH="$(backup_file_if_exists "$service_file")"
    temp_file="$(mktemp)"

    cat > "$temp_file" <<EOF
[Unit]
Description=XuiSubTemplate Gunicorn Service
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python -m gunicorn --config $APP_DIR/deploy/gunicorn/gunicorn.conf.py XuiSubTemplate.wsgi:application
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

    run_with_proxy 1 cp "$temp_file" "$service_file"
    rm -f "$temp_file"
    SERVICE_CREATED=1
    success "Systemd service file written to $service_file"
}

enable_and_restart_service() {
    if ! command_exists systemctl; then
        warn "systemctl not found. Service file was generated but not enabled."
        return
    fi

    run_with_proxy 1 systemctl daemon-reload
    run_with_proxy 1 systemctl enable "$SERVICE_NAME"
    run_with_proxy 1 systemctl restart "$SERVICE_NAME"
    success "Service enabled and restarted"
}

collect_install_answers() {
    section "Install Settings"
    SERVICE_NAME="$(ask "Systemd service name" "$DEFAULT_SERVICE_NAME")"
    RUN_USER="$(ask "Run service as user" "$DEFAULT_RUN_USER")"
    RUN_GROUP="$(ask "Run service as group" "$DEFAULT_RUN_GROUP")"
    VENV_DIR="$(ask "Virtualenv path" "$DEFAULT_VENV_DIR")"
    ALLOWED_HOSTS="$(ask "ALLOWED_HOSTS (comma separated)" "$DEFAULT_ALLOWED_HOSTS")"
    ADMIN_PATH="$(ask "Admin path" "$DEFAULT_ADMIN_PATH")"
    XUI_DB_ADDRESS="$(ask "3x-ui SQLite DB absolute path" "$DEFAULT_XUI_DB")"
    XUI_SUBSERVICE_DOMAIN="$(ask "Fallback subscription domain" "$DEFAULT_FALLBACK_DOMAIN")"
    XUI_SUBSERVICE_PROTOCOL="$(ask "Fallback subscription protocol" "$DEFAULT_FALLBACK_PROTOCOL")"
    XUI_SUBSERVICE_PORT="$(ask "Fallback subscription port" "$DEFAULT_FALLBACK_PORT")"
    GUNICORN_BIND="$(ask "Gunicorn bind" "$DEFAULT_BIND")"
    GUNICORN_WORKERS="$(ask "Gunicorn workers" "$DEFAULT_WORKERS")"
    GUNICORN_THREADS="$(ask "Gunicorn threads" "$DEFAULT_THREADS")"
    GUNICORN_TIMEOUT="$(ask "Gunicorn timeout" "$DEFAULT_TIMEOUT")"
    GUNICORN_GRACEFUL_TIMEOUT="$(ask "Gunicorn graceful timeout" "$DEFAULT_GRACEFUL_TIMEOUT")"
    GUNICORN_KEEPALIVE="$(ask "Gunicorn keepalive" "$DEFAULT_KEEPALIVE")"
    GUNICORN_LOG_LEVEL="$(ask "Gunicorn log level" "$DEFAULT_LOG_LEVEL")"
    USAGE_CRON_SCHEDULE="$(ask "Usage cron schedule" "$DEFAULT_USAGE_CRON")"
    USAGE_CLEANUP_CRON_SCHEDULE="$(ask "Cleanup cron schedule" "$DEFAULT_CLEANUP_CRON")"
    USAGE_CHART_LIMIT="$(ask "Usage chart point limit" "$DEFAULT_CHART_LIMIT")"
    CRON_LOG_DIR="$(ask "Cron log directory" "$DEFAULT_LOG_DIR")"

    if [[ ! -d "$CRON_LOG_DIR" ]]; then
        CRON_LOG_DIR_CREATED=1
    fi

    if [[ -n "$SUDO_BIN" ]]; then
        run_with_proxy 1 mkdir -p "$CRON_LOG_DIR"
        run_with_proxy 1 chown -R "$RUN_USER:$RUN_GROUP" "$CRON_LOG_DIR"
    else
        mkdir -p "$CRON_LOG_DIR"
        chown -R "$RUN_USER:$RUN_GROUP" "$CRON_LOG_DIR" 2>/dev/null || true
    fi

    save_state
}

install_base_packages() {
    if ! command_exists apt; then
        warn "apt not found. Skipping package installation."
        return
    fi

    if confirm "Install base apt packages (python3, venv, pip)?" "Y"; then
        run_with_proxy 1 apt update
        run_with_proxy 1 apt install -y python3 python3-venv python3-pip
        success "Base packages installed"
    fi
}

show_status() {
    load_state
    section "Status"
    info "Project directory: $APP_DIR"
    info "Environment file: $ENV_FILE"
    info "Virtualenv: $VENV_DIR"
    info "Service name: $SERVICE_NAME"
    info "Cron log directory: $CRON_LOG_DIR"

    [[ -f "$ENV_FILE" ]] && success ".env exists" || warn ".env missing"
    [[ -d "$VENV_DIR" ]] && success "Virtualenv exists" || warn "Virtualenv missing"
    [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] && success "Systemd service file exists" || warn "Systemd service file missing"
    [[ -d "$CRON_LOG_DIR" ]] && success "Cron log directory exists" || warn "Cron log directory missing"

    if command_exists systemctl; then
        if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
            success "Service is enabled"
        else
            warn "Service is not enabled"
        fi

        if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
            success "Service is running"
        else
            warn "Service is not running"
        fi
    fi

    if [[ -x "${VENV_DIR}/bin/python" ]]; then
        pushd "$APP_DIR" >/dev/null
        if "${VENV_DIR}/bin/python" manage.py help crontab >/dev/null 2>&1; then
            info "Django crontab entries:"
            "${VENV_DIR}/bin/python" manage.py crontab show || true
        fi
        popd >/dev/null
    fi
}

uninstall_stack() {
    load_state
    section "Uninstall"
    warn "This removes service/venv/.env and can optionally remove logs, staticfiles and db.sqlite3."
    if ! confirm "Continue?" "N"; then
        info "Uninstall cancelled"
        return
    fi

    if [[ -x "${VENV_DIR}/bin/python" ]]; then
        pushd "$APP_DIR" >/dev/null
        "${VENV_DIR}/bin/python" manage.py crontab remove >/dev/null 2>&1 || true
        popd >/dev/null
        success "Removed Django crontab entries"
    fi

    if command_exists systemctl; then
        run_with_proxy 1 systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        run_with_proxy 1 systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    run_with_proxy 1 rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    if command_exists systemctl; then
        run_with_proxy 1 systemctl daemon-reload || true
    fi
    success "Removed systemd service"

    if [[ -d "$VENV_DIR" ]]; then
        rm -rf "$VENV_DIR"
        success "Removed virtualenv"
    fi

    if [[ -f "$ENV_FILE" ]]; then
        rm -f "$ENV_FILE"
        success "Removed .env"
    fi

    if [[ -d "$CRON_LOG_DIR" ]] && confirm "Remove cron log directory $CRON_LOG_DIR ?" "Y"; then
        run_with_proxy 1 rm -rf "$CRON_LOG_DIR"
        success "Removed cron log directory"
    fi

    if [[ -d "$APP_DIR/staticfiles" ]] && confirm "Remove collected staticfiles?" "N"; then
        run_with_proxy 1 rm -rf "$APP_DIR/staticfiles"
        success "Removed collected staticfiles"
    fi

    if [[ -f "$APP_DIR/db.sqlite3" ]] && confirm "Remove local Django db.sqlite3?" "N"; then
        rm -f "$APP_DIR/db.sqlite3"
        success "Removed local Django database"
    fi

    rm -f "$STATE_FILE"
    success "Uninstall completed"
}

show_help() {
    banner
    print_line ""
    print_line "Usage:"
    print_line "  bash deploy/install.sh install"
    print_line "  bash deploy/install.sh status"
    print_line "  bash deploy/install.sh uninstall"
    print_line "  bash deploy/install.sh help"
    print_line ""
    print_line "If no command is given, 'install' is used."
}

perform_install() {
    banner
    INSTALL_IN_PROGRESS=1
    trap handle_error ERR
    trap handle_interrupt INT TERM

    prompt_proxy_settings
    install_base_packages
    collect_install_answers
    create_env_file
    create_virtualenv_and_install
    run_django_setup
    write_service_file
    enable_and_restart_service

    INSTALL_IN_PROGRESS=0
    trap - ERR INT TERM
    save_state

    section "Done"
    success "Installation completed"
    info "Service: $SERVICE_NAME"
    info "Check status: sudo systemctl status $SERVICE_NAME --no-pager -l"
    info "Live logs: sudo journalctl -u $SERVICE_NAME -f"
    info "Crontab: ${VENV_DIR}/bin/python $APP_DIR/manage.py crontab show"
}

main() {
    local command="${1:-install}"

    case "$command" in
        install)
            perform_install
            ;;
        status)
            banner
            show_status
            ;;
        uninstall)
            banner
            uninstall_stack
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "${1:-install}"
