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
