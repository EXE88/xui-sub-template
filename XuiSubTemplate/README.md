# XuiSubTemplate

Template dashboard for 3x-ui subscription links, with periodic usage snapshots and a `/sub/{subid}` page.

This guide is for **production** deployment with:
- `gunicorn`
- `systemd` (`systemctl`)
- **without Nginx**

## 1) Prerequisites

- Ubuntu/Debian server
- Python 3.11+
- `systemd`
- Access to your 3x-ui SQLite DB path (for `XUI_DB_ADDRESS`)

Install base packages:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip
```

## 2) Project setup

Assume deployment path is `/opt/xui-sub-template`:

```bash
sudo mkdir -p /opt/xui-sub-template
sudo chown -R $USER:$USER /opt/xui-sub-template
cd /opt/xui-sub-template
git clone <YOUR_REPO_URL> .
cd XuiSubTemplate
python3 -m venv /opt/xui-sub-template/venv
source /opt/xui-sub-template/venv/bin/activate
pip install --upgrade pip
pip install -r requierments.txt
pip install gunicorn
```

## 3) Environment config

Create `.env` from sample:

```bash
cp .env.sample .env
```

Important variables in `.env`:

- `SECRET_KEY`: set a strong secret
- `DEBUG=False`
- `ALLOWED_HOSTS`: your domain or server IP
- `ADMIN_PATH`: custom admin URL path (example: `my-private-admin-92x`)
- `XUI_DB_ADDRESS`: absolute path to your 3x-ui sqlite DB
- `USAGE_CRON_SCHEDULE`: cron expression for usage collector
- `USAGE_CHART_LIMIT`: max chart points returned in view
- `GUNICORN_*`: gunicorn runtime options

## 4) Database and static files

```bash
source /opt/xui-sub-template/venv/bin/activate
cd /opt/xui-sub-template/XuiSubTemplate
python manage.py migrate
python manage.py collectstatic --noinput
python manage.py createsuperuser
```

If you use `django-crontab`:

```bash
python manage.py crontab add
python manage.py crontab show
```

## 5) Gunicorn + systemd (no Nginx)

Service template already exists in:

- `deploy/systemd/xui-sub-template.service`
- `deploy/gunicorn/gunicorn.conf.py`

Copy service file:

```bash
sudo cp /opt/xui-sub-template/XuiSubTemplate/deploy/systemd/xui-sub-template.service /etc/systemd/system/xui-sub-template.service
```

If your paths differ, edit service file:

```bash
sudo nano /etc/systemd/system/xui-sub-template.service
```

Load and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable xui-sub-template
sudo systemctl start xui-sub-template
sudo systemctl status xui-sub-template
```

Logs:

```bash
sudo journalctl -u xui-sub-template -f
```

## 6) Run result

Default bind is from `.env`:

- `GUNICORN_BIND=0.0.0.0:8000`

So app is reachable on:

- `http://SERVER_IP:8000/sub/<subid>/`
- `http://SERVER_IP:8000/<ADMIN_PATH>/`

## 7) Update workflow

```bash
cd /opt/xui-sub-template
git pull
source /opt/xui-sub-template/venv/bin/activate
cd /opt/xui-sub-template/XuiSubTemplate
pip install -r requierments.txt
pip install gunicorn
python manage.py migrate
python manage.py collectstatic --noinput
python manage.py crontab add
sudo systemctl restart xui-sub-template
```

## 8) Security notes (without Nginx)

- Keep `DEBUG=False`
- Set a strong `SECRET_KEY`
- Use a non-default `ADMIN_PATH`
- Restrict port `8000` with firewall (allow only trusted sources if possible)
- For public internet, place TLS termination in front (for example Cloudflare tunnel or a TLS reverse proxy)
