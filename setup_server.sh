#!/bin/bash

set -e

APP_DIR="/opt/app"
PROJECT_DIR="$APP_DIR/test_project"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="/etc/django.env"
GUNICORN_SERVICE="/etc/systemd/system/gunicorn.service"
NGINX_CONFIG="/etc/nginx/sites-available/django"

echo "🚀 Начинаем настройку сервера..."

# 1. Обновление системы
echo "📦 Updating system..."
sudo apt update
sudo apt upgrade -y

# 2. Установка зависимостей
echo "📦 Installing dependencies..."
sudo apt install -y python3 python3-pip python3-venv git nginx postgresql postgresql-contrib

# 3. Настройка PostgreSQL
echo "🐘 Configuring PostgreSQL..."
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '$PG_PASS';"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE DATABASE postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'postgres')\gexec
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE postgres TO postgres;"
sudo systemctl restart postgresql

# 4. Проверка PostgreSQL
echo "🔎 Testing PostgreSQL connection..."
PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -U postgres -d postgres -c "SELECT current_user;"

# 5. Клонирование/обновление проекта
echo "📂 Updating project..."
if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    git fetch origin
    git pull --ff-only
else
    sudo mkdir -p "$APP_DIR"
    git clone https://github.com/ksm44/deploy_test.git "$APP_DIR"
    cd "$APP_DIR"
fi

# 6. Виртуальное окружение
echo "🐍 Creating virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

# 7. Установка зависимостей
echo "📚 Installing Python dependencies..."
python -m pip install --upgrade pip
if [ -f "$APP_DIR/requirements.txt" ]; then
    pip install -r "$APP_DIR/requirements.txt"
else
    pip install django gunicorn psycopg2-binary
fi

# 8. Проверка manage.py
if [ ! -f "$PROJECT_DIR/manage.py" ]; then
    echo "❌ ERROR: manage.py not found: $PROJECT_DIR/manage.py"
    exit 1
fi

# 9. Создание /etc/django.env (ВСЕ ДАННЫЕ ИЗ ПЕРЕМЕННЫХ)
echo "🔐 Configuring Django environment..."
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
    EXISTING_SECRET_KEY="${SECRET_KEY:-}"
else
    EXISTING_SECRET_KEY=""
fi

if [ -z "$EXISTING_SECRET_KEY" ]; then
    SECRET_KEY_VALUE="$("$VENV_DIR/bin/python" -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())')"
else
    SECRET_KEY_VALUE="$EXISTING_SECRET_KEY"
fi

sudo tee "$ENV_FILE" > /dev/null <<EOF
SECRET_KEY='$SECRET_KEY_VALUE'
DEBUG='False'
ALLOWED_HOSTS='$VPS_HOST,localhost'
PG_DB='$PG_DB'
PG_USER='$PG_USER'
PG_PASS='$PG_PASS'
PG_HOST='$PG_HOST'
PG_PORT='$PG_PORT'
EOF

sudo chmod 600 "$ENV_FILE"
echo "✅ Environment configured."

# 10. Загрузка переменных и миграции
echo "🌱 Loading Django environment..."
set -a
source "$ENV_FILE"
set +a

cd "$PROJECT_DIR"
"$VENV_DIR/bin/python" manage.py migrate --noinput
"$VENV_DIR/bin/python" manage.py collectstatic --noinput

# 11. Настройка Gunicorn
echo "🔄 Configuring Gunicorn..."
sudo tee "$GUNICORN_SERVICE" > /dev/null <<EOF
[Unit]
Description=Gunicorn daemon for Django
After=network.target postgresql.service
Requires=postgresql.service
[Service]
Type=simple
User=root
Group=www-data
WorkingDirectory=$PROJECT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/gunicorn --workers 3 --bind unix:$APP_DIR/gunicorn.sock test_project.test_project.wsgi:application
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# 12. Запуск Gunicorn
echo "🚀 Starting Gunicorn..."
sudo systemctl daemon-reload
sudo systemctl enable gunicorn
sudo systemctl restart gunicorn
sleep 2

if sudo systemctl is-active --quiet gunicorn; then
    echo "✅ Gunicorn is running."
else
    echo "❌ Gunicorn failed to start."
    sudo systemctl status gunicorn --no-pager
    exit 1
fi

# 13. Настройка Nginx
echo "🌐 Configuring Nginx..."
sudo tee "$NGINX_CONFIG" > /dev/null <<EOF
server {
    listen 80;
    server_name $VPS_HOST localhost;
    location /static/ { alias $PROJECT_DIR/staticfiles/; }
    location /media/ { alias $PROJECT_DIR/media/; }
    location / {
        include proxy_params;
        proxy_pass http://unix:$APP_DIR/gunicorn.sock:/;
    }
}
EOF

# 14. Активация сайта и удаление дефолтного
echo "🔗 Enabling Nginx site..."
sudo ln -sf "$NGINX_CONFIG" /etc/nginx/sites-enabled/django
sudo rm -f /etc/nginx/sites-enabled/default

# 15. Проверка и перезагрузка Nginx
echo "🔎 Testing Nginx configuration..."
sudo nginx -t

echo "🔄 Restarting Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

# 16. Финальная проверка
echo ""
echo "=========================================="
echo "✅ Настройка сервера завершена!"
echo "=========================================="
echo ""
echo "PostgreSQL:"
sudo systemctl is-active postgresql
echo ""
echo "Gunicorn:"
sudo systemctl is-active gunicorn
echo ""
echo "Nginx:"
sudo systemctl is-active nginx
echo ""
echo "🌍 Сайт: http://$VPS_HOST"
echo ""
echo "🎉 Готово!"