#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR"
ENV_FILE="$APP_DIR/.env"
REQ_FILE="$APP_DIR/requierments.txt"

if [[ ! -f "$APP_DIR/manage.py" ]]; then
    echo "manage.py not found in $APP_DIR"
    exit 1
fi

if [[ ! -f "$REQ_FILE" ]]; then
    echo "Requirements file not found: $REQ_FILE"
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

CURRENT_USER_NAME="$(id -un)"
CURRENT_GROUP_NAME="$(id -gn)"
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
DEFAULT_VENV_DIR="$APP_DIR/env"
DEFAULT_LOG_DIR="$APP_DIR/logs"

ask() {
    local prompt="$1"
    local default_value="${2-}"
    local answer

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " answer
        printf '%s\n' "${answer:-$default_value}"
    else
        read -r -p "$prompt: " answer
        printf '%s\n' "$answer"
    fi
}

confirm() {
    local prompt="$1"
    local default_value="${2:-Y}"
    local suffix="[Y/n]"

    if [[ "${default_value^^}" == "N" ]]; then
        suffix="[y/N]"
    fi

    local answer
    read -r -p "$prompt $suffix: " answer
    answer="${answer:-$default_value}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

escape_env() {
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

echo "XuiSubTemplate installer"
echo "Project directory: $APP_DIR"
echo

if confirm "Install base apt packages (python3, venv, pip)?" "Y"; then
    $SUDO apt update
    $SUDO apt install -y python3 python3-venv python3-pip
fi

SERVICE_NAME="$(ask "Systemd service name" "$DEFAULT_SERVICE_NAME")"
RUN_USER="$(ask "Run service as user" "$CURRENT_USER_NAME")"
RUN_GROUP="$(ask "Run service as group" "$CURRENT_GROUP_NAME")"
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

GENERATED_SECRET_KEY="$(random_secret_key)"
SECRET_KEY="$(ask "SECRET_KEY" "$GENERATED_SECRET_KEY")"
DEBUG_VALUE="False"
if confirm "Enable DEBUG mode?" "N"; then
    DEBUG_VALUE="True"
fi

if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
fi

$SUDO mkdir -p "$CRON_LOG_DIR"

VENV_PARENT_DIR="$(dirname "$VENV_DIR")"
mkdir -p "$VENV_PARENT_DIR"

cat > "$ENV_FILE" <<EOF
SECRET_KEY="$(escape_env "$SECRET_KEY")"
DEBUG=$DEBUG_VALUE
ALLOWED_HOSTS=$(escape_env "$ALLOWED_HOSTS")
ADMIN_PATH=$(escape_env "$ADMIN_PATH")
GUNICORN_BIND=$(escape_env "$GUNICORN_BIND")
GUNICORN_WORKERS=$(escape_env "$GUNICORN_WORKERS")
GUNICORN_THREADS=$(escape_env "$GUNICORN_THREADS")
GUNICORN_TIMEOUT=$(escape_env "$GUNICORN_TIMEOUT")
GUNICORN_GRACEFUL_TIMEOUT=$(escape_env "$GUNICORN_GRACEFUL_TIMEOUT")
GUNICORN_KEEPALIVE=$(escape_env "$GUNICORN_KEEPALIVE")
GUNICORN_LOG_LEVEL=$(escape_env "$GUNICORN_LOG_LEVEL")

XUI_DB_ADDRESS="$(escape_env "$XUI_DB_ADDRESS")"
XUI_SUBSERVICE_DOAMIN="$(escape_env "$XUI_SUBSERVICE_DOMAIN")"
XUI_SUBSERVICE_PORT=$(escape_env "$XUI_SUBSERVICE_PORT")
XUI_SUBSERVICE_PROTOCOL=$(escape_env "$XUI_SUBSERVICE_PROTOCOL")
USAGE_CRON_SCHEDULE="$(escape_env "$USAGE_CRON_SCHEDULE")"
USAGE_CLEANUP_CRON_SCHEDULE="$(escape_env "$USAGE_CLEANUP_CRON_SCHEDULE")"
CRON_LOG_DIR="$(escape_env "$CRON_LOG_DIR")"
USAGE_CHART_LIMIT=$(escape_env "$USAGE_CHART_LIMIT")
EOF

echo ".env created at $ENV_FILE"
$SUDO chown "$RUN_USER:$RUN_GROUP" "$ENV_FILE"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$REQ_FILE"
"$VENV_DIR/bin/pip" install gunicorn

$SUDO chown -R "$RUN_USER:$RUN_GROUP" "$CRON_LOG_DIR" "$VENV_DIR"

pushd "$APP_DIR" >/dev/null
"$VENV_DIR/bin/python" manage.py migrate
"$VENV_DIR/bin/python" manage.py collectstatic --noinput

if "$VENV_DIR/bin/python" manage.py help crontab >/dev/null 2>&1; then
    "$VENV_DIR/bin/python" manage.py crontab remove >/dev/null 2>&1 || true
    "$VENV_DIR/bin/python" manage.py crontab add
fi

if confirm "Create a Django superuser now?" "N"; then
    "$VENV_DIR/bin/python" manage.py createsuperuser
fi
popd >/dev/null

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

SERVICE_CONTENT="[Unit]
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
"

printf '%s\n' "$SERVICE_CONTENT" | $SUDO tee "$SERVICE_FILE" >/dev/null
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE_NAME"
$SUDO systemctl restart "$SERVICE_NAME"

echo
echo "Installation completed."
echo "Service: $SERVICE_NAME"
echo "Project: $APP_DIR"
echo "Virtualenv: $VENV_DIR"
echo "Environment: $ENV_FILE"
echo
echo "Useful commands:"
echo "  sudo systemctl status $SERVICE_NAME --no-pager -l"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  $VENV_DIR/bin/python $APP_DIR/manage.py crontab show"
echo "  Open: http://<server>:${GUNICORN_BIND##*:}/sub/<subid>/"
