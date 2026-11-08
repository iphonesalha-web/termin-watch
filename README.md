# Termin Watch — Ausländeramt StädteRegion Aachen

مراقب مواعيد Infostelle / Beratungs- und Antragsservice.
يرسل إشعار Telegram عند ظهور موعد قبل تاريخ محدد. لا يحجز شيئاً.

## التشغيل على GitHub Actions

1. أنشئ مستودعاً **Private** وارفع هذه الملفات.
2. Settings → Secrets and variables → Actions:
   - **Secrets** → New repository secret:
     - `TELEGRAM_TOKEN` = توكن البوت
     - `TELEGRAM_CHAT_ID` = رقم الدردشة
   - **Variables** → New repository variable:
     - `CUTOFF_DATE` = مثلاً `2026-12-01`
3. تبويب Actions → Termin Watch → **Run workflow** للتجربة.

الجدولة في `.github/workflows/termin.yml` (بتوقيت UTC).

## التشغيل المحلي (ويندوز)

```
python -m pip install -r requirements.txt
python -m playwright install chromium
python termin_watch.py
```

يسألك أول مرة عن التاريخ وبيانات Telegram ويحفظها في `config.json`.

## التشغيل على Raspberry Pi (24/7)

بعد تنصيب Raspberry Pi OS 64-bit وتفعيل SSH:

```
curl -fsSL https://raw.githubusercontent.com/iphonesalha-web/termin-watch/main/pi_setup.sh -o pi_setup.sh
bash pi_setup.sh
```

يسألك عن التاريخ وبيانات Telegram، ثم ينشئ خدمة systemd تعمل تلقائياً
عند كل إقلاع وتعيد تشغيل نفسها إن توقفت.

| العملية | الأمر |
|---|---|
| متابعة السجل | `journalctl -u termin-watch -f` |
| إيقاف | `sudo systemctl stop termin-watch` |
| تشغيل | `sudo systemctl start termin-watch` |
| تغيير الإعدادات | `nano ~/termin-watch/termin.env` ثم `sudo systemctl restart termin-watch` |
