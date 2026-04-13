from pathlib import Path
import os
import importlib.util
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

load_dotenv(os.path.join(BASE_DIR, '.env'))

SECRET_KEY = os.getenv('SECRET_KEY')

DEBUG = os.getenv('DEBUG', 'True') == 'True'

ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '')
if ALLOWED_HOSTS:
    ALLOWED_HOSTS = [h.strip() for h in ALLOWED_HOSTS.split(',') if h.strip()]
else:
    ALLOWED_HOSTS = []

ADMIN_PATH = os.getenv('ADMIN_PATH', 'admin').strip().strip('/')
if not ADMIN_PATH:
    ADMIN_PATH = 'admin'

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'sub',
]

if importlib.util.find_spec('django_crontab') is not None:
    INSTALLED_APPS.append('django_crontab')

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'XuiSubTemplate.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'XuiSubTemplate.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
    },
    'xui': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': os.getenv('XUI_DB_ADDRESS'),
        'OPTIONS': {
            'timeout': 20,
        }
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator',
    },
]

LANGUAGE_CODE = 'en-us'

TIME_ZONE = 'UTC'

USE_I18N = True

USE_TZ = True

STATIC_URL = '/static/'
STATICFILES_DIRS = [
    BASE_DIR / 'static',
    BASE_DIR / 'sub' / 'static',
]
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'

USAGE_CRON_SCHEDULE = os.getenv('USAGE_CRON_SCHEDULE', '0 * * * *')
USAGE_CLEANUP_CRON_SCHEDULE = os.getenv('USAGE_CLEANUP_CRON_SCHEDULE', '15 3 * * *')
CRON_LOG_DIR = Path(os.getenv('CRON_LOG_DIR', str(BASE_DIR / 'logs')))


def _prepare_cron_log_file(filename):
    requested_dir = CRON_LOG_DIR
    fallback_dir = BASE_DIR / 'logs'

    try:
        requested_dir.mkdir(parents=True, exist_ok=True)
        target_file = requested_dir / filename
        target_file.touch(exist_ok=True)
        return target_file
    except OSError:
        fallback_dir.mkdir(parents=True, exist_ok=True)
        target_file = fallback_dir / filename
        target_file.touch(exist_ok=True)
        return target_file


RECORD_USAGE_LOG_FILE = _prepare_cron_log_file('record_clients_usage.log')
CLEANUP_USAGE_LOG_FILE = _prepare_cron_log_file('cleanup_expired_clients_usage.log')

CRONJOBS = [
    (USAGE_CRON_SCHEDULE, 'sub.crons.record_clients_usage', f'>> "{RECORD_USAGE_LOG_FILE}" 2>&1'),
    (USAGE_CLEANUP_CRON_SCHEDULE, 'sub.crons.cleanup_expired_clients_usage', f'>> "{CLEANUP_USAGE_LOG_FILE}" 2>&1'),
]
