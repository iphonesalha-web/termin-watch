#!/usr/bin/env bash
# تنصيب مراقب المواعيد على Raspberry Pi (Raspberry Pi OS 64-bit)
# التشغيل:  bash pi_setup.sh
set -euo pipefail

APP_DIR="$HOME/termin-watch"
REPO="https://github.com/iphonesalha-web/termin-watch.git"

echo "==> تحديث النظام وتثبيت الحزم"
sudo apt update
sudo apt install -y git python3 python3-pip python3-venv chromium chromium-common || \
sudo apt install -y git python3 python3-pip python3-venv chromium-browser

echo "==> جلب الكود"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull
else
  git clone "$REPO" "$APP_DIR"
fi
cd "$APP_DIR"

echo "==> بيئة بايثون"
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

CHROME=""
for c in /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && CHROME="$c" && break
done
if [ -z "$CHROME" ]; then
  echo "!! لم أجد Chromium. ثبّته يدوياً:  sudo apt install chromium"
  exit 1
fi
echo "==> Chromium: $CHROME"

# ---------- الإعدادات ----------
if [ ! -f "$APP_DIR/termin.env" ]; then
  echo
  echo "===== الإعدادات ====="
  read -rp "التاريخ (أنبّهك على أي موعد قبله) [YYYY-MM-DD]: " CUT
  read -rp "Telegram bot token: " TOK
  read -rp "Telegram chat id: " CHAT
  cat > "$APP_DIR/termin.env" <<ENV
CUTOFF_DATE=$CUT
TELEGRAM_TOKEN=$TOK
TELEGRAM_CHAT_ID=$CHAT
CHROMIUM_PATH=$CHROME
ENV
  chmod 600 "$APP_DIR/termin.env"
  echo "تم الحفظ في $APP_DIR/termin.env"
fi

# ---------- خدمة systemd ----------
echo "==> إنشاء الخدمة"
sudo tee /etc/systemd/system/termin-watch.service > /dev/null <<UNIT
[Unit]
Description=Termin Watch - Auslaenderamt Aachen
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/termin.env
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/termin_watch.py
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now termin-watch

# ---------- واجهة التحكم (للتطبيق على الآيفون) ----------
echo "==> واجهة التحكم (API)"
if [ ! -f "$APP_DIR/api.env" ]; then
  TOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
  echo "API_TOKEN=$TOKEN" > "$APP_DIR/api.env"
  chmod 600 "$APP_DIR/api.env"
fi

# السماح لواجهة التحكم بتشغيل/إيقاف خدمة المراقب فقط (بدون كلمة سر)
echo "$USER ALL=(root) NOPASSWD: /usr/bin/systemctl start termin-watch, /usr/bin/systemctl stop termin-watch, /usr/bin/systemctl restart termin-watch" \
  | sudo tee /etc/sudoers.d/termin-api > /dev/null
sudo chmod 440 /etc/sudoers.d/termin-api
sudo visudo -c -f /etc/sudoers.d/termin-api > /dev/null || { sudo rm -f /etc/sudoers.d/termin-api; echo "!! خطأ في sudoers"; exit 1; }

sudo tee /etc/systemd/system/termin-api.service > /dev/null <<UNIT
[Unit]
Description=Termin Watch control API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/api.env
ExecStart=/usr/bin/python3 $APP_DIR/pi_api.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now termin-api
sudo systemctl restart termin-api

# ---------- Tailscale (اختياري: للوصول من خارج البيت) ----------
if ! command -v tailscale >/dev/null 2>&1; then
  read -rp "تثبيت Tailscale للتحكم من خارج البيت؟ [y/N]: " TS
  if [ "${TS:-n}" = "y" ] || [ "${TS:-n}" = "Y" ]; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "افتح الرابط الذي سيظهر الآن لتسجيل الدخول:"
    sudo tailscale up
  fi
fi
IPADDR=$(hostname -I | awk '{print $1}')

echo
echo "================================================"
echo " تم! الخدمة تعمل وستبدأ تلقائياً عند كل إقلاع."
echo
echo " متابعة السجل:   journalctl -u termin-watch -f"
echo " إيقاف:          sudo systemctl stop termin-watch"
echo " تشغيل:          sudo systemctl start termin-watch"
echo
echo " === بيانات الاتصال بالتطبيق ==="
echo " العنوان:   http://$IPADDR:8787   (أو http://pi.local:8787)"
echo " كلمة السر: $(grep API_TOKEN "$APP_DIR/api.env" | cut -d= -f2)"
echo " (تُعرض لاحقاً بالأمر: grep API_TOKEN $APP_DIR/api.env)"
echo
echo " تغيير التاريخ:  nano $APP_DIR/termin.env ثم"
echo "                 sudo systemctl restart termin-watch"
echo "================================================"
