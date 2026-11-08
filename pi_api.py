#!/usr/bin/env python3
"""واجهة تحكم صغيرة (HTTP + JSON) لمراقب المواعيد على Raspberry Pi.

تعتمد على مكتبة بايثون القياسية فقط. كل الطلبات تحتاج:
    Authorization: Bearer <API_TOKEN>

المسارات:
    GET  /status                 حالة الخدمة وآخر فحص وحالة الجهاز
    GET  /log?n=80               آخر أسطر السجل
    POST /cutoff   {"date":"YYYY-MM-DD"}   تغيير التاريخ + إعادة التشغيل
    POST /service/<start|stop|restart>     التحكم بالخدمة
    POST /test                   يرسل رسالة اختبار إلى Telegram
"""
import datetime as dt
import hmac
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(APP_DIR, "termin.env")
STATUS_FILE = os.path.join(APP_DIR, "termin_status.json")
SERVICE = "termin-watch"
PORT = int(os.environ.get("API_PORT", "8787"))
API_TOKEN = os.environ.get("API_TOKEN", "").strip()


def read_env():
    out = {}
    try:
        with open(ENV_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def set_env_value(key, value):
    lines, found = [], False
    try:
        with open(ENV_FILE, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        pass
    for i, line in enumerate(lines):
        if line.split("=", 1)[0].strip() == key:
            lines[i] = f"{key}={value}"
            found = True
    if not found:
        lines.append(f"{key}={value}")
    tmp = ENV_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, ENV_FILE)


def run(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:  # noqa: BLE001
        return 1, str(e)


def service_state():
    _, out = run(["systemctl", "is-active", SERVICE])
    out = out.strip().splitlines()[0] if out.strip() else ""
    known = ("active", "inactive", "failed", "activating", "deactivating", "reloading")
    return out if out in known else "unknown"


def device_info():
    info = {}
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            info["temp_c"] = round(int(f.read().strip()) / 1000, 1)
    except Exception:  # noqa: BLE001
        pass
    try:
        with open("/proc/uptime") as f:
            info["uptime_s"] = int(float(f.read().split()[0]))
        info["load"] = os.getloadavg()[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        with open("/proc/meminfo") as f:
            m = {l.split(":")[0]: int(l.split()[1]) for l in f if ":" in l}
        info["mem_used_pct"] = round(100 * (1 - m["MemAvailable"] / m["MemTotal"]))
    except Exception:  # noqa: BLE001
        pass
    try:
        du = shutil.disk_usage("/")
        info["disk_used_pct"] = round(100 * du.used / du.total)
    except Exception:  # noqa: BLE001
        pass
    return info


def get_status():
    env = read_env()
    st = {}
    try:
        with open(STATUS_FILE, encoding="utf-8") as f:
            st = json.load(f)
    except Exception:  # noqa: BLE001
        pass
    return {
        "service": service_state(),
        "cutoff": env.get("CUTOFF_DATE"),
        "telegram": bool(env.get("TELEGRAM_TOKEN") and env.get("TELEGRAM_CHAT_ID")),
        "last_check": st.get("last_check"),
        "ok": st.get("ok"),
        "error": st.get("error"),
        "total": st.get("total"),
        "earliest": st.get("earliest"),
        "upcoming": st.get("upcoming", {}),
        "device": device_info(),
        "now": dt.datetime.now().isoformat(timespec="seconds"),
    }


def get_log(n):
    n = max(1, min(n, 300))
    _, out = run(["journalctl", "-u", SERVICE, "-n", str(n), "--no-pager", "-o", "short"])
    return out.splitlines()


def service_cmd(action):
    if action not in ("start", "stop", "restart"):
        return False, "أمر غير معروف"
    code, out = run(["sudo", "-n", "systemctl", action, SERVICE])
    return code == 0, out.strip()


def send_test():
    env = read_env()
    tok, chat = env.get("TELEGRAM_TOKEN"), env.get("TELEGRAM_CHAT_ID")
    if not tok or not chat:
        return False, "Telegram غير مُعدّ"
    data = urllib.parse.urlencode({"chat_id": chat, "text": "✅ رسالة اختبار من واجهة التحكم على الـ Pi"}).encode()
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/sendMessage", data, timeout=15) as r:
            return r.status == 200, "تم الإرسال"
    except Exception as e:  # noqa: BLE001
        return False, str(e)[:200]


class Handler(BaseHTTPRequestHandler):
    server_version = "TerminAPI/1.0"

    def log_message(self, *a):  # صامت
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        got = self.headers.get("Authorization", "")
        want = f"Bearer {API_TOKEN}"
        if API_TOKEN and hmac.compare_digest(got.encode(), want.encode()):
            return True
        time.sleep(1)  # إبطاء المحاولات الخاطئة
        self._send(401, {"error": "غير مصرّح"})
        return False

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            return json.loads(self.rfile.read(min(n, 4096)) or b"{}")
        except Exception:  # noqa: BLE001
            return {}

    def do_GET(self):  # noqa: N802
        if not self._auth():
            return
        u = urllib.parse.urlparse(self.path)
        if u.path == "/status":
            self._send(200, get_status())
        elif u.path == "/log":
            q = urllib.parse.parse_qs(u.query)
            try:
                n = int(q.get("n", ["80"])[0])
            except ValueError:
                n = 80
            self._send(200, {"lines": get_log(n)})
        else:
            self._send(404, {"error": "غير موجود"})

    def do_POST(self):  # noqa: N802
        if not self._auth():
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/cutoff":
            date = str(self._body().get("date", "")).strip()
            try:
                dt.datetime.strptime(date, "%Y-%m-%d")
            except ValueError:
                return self._send(400, {"error": "صيغة التاريخ يجب أن تكون YYYY-MM-DD"})
            set_env_value("CUTOFF_DATE", date)
            ok, msg = service_cmd("restart")
            return self._send(200 if ok else 500, {"ok": ok, "cutoff": date, "message": msg})
        if path.startswith("/service/"):
            ok, msg = service_cmd(path.rsplit("/", 1)[1])
            return self._send(200 if ok else 500, {"ok": ok, "message": msg, "service": service_state()})
        if path == "/test":
            ok, msg = send_test()
            return self._send(200 if ok else 500, {"ok": ok, "message": msg})
        self._send(404, {"error": "غير موجود"})


def main():
    if not API_TOKEN or len(API_TOKEN) < 16 or not re.fullmatch(r"[A-Za-z0-9_-]+", API_TOKEN):
        raise SystemExit("API_TOKEN مفقود أو ضعيف (16 حرفاً على الأقل، أحرف وأرقام فقط)")
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Termin API على المنفذ {PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
