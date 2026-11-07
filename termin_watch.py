#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
termin_watch.py  (v4 - يعمل محلياً وعلى GitHub Actions)

مراقب مواعيد Ausländeramt StädteRegion Aachen / Infostelle / Beratungs- und Antragsservice
يرسل إشعار Telegram عند ظهور موعد قبل التاريخ المحدد. لا يحجز شيئاً.

الإعدادات تُقرأ أولاً من متغيرات البيئة (GitHub Actions)،
وإن لم توجد فمن config.json (التشغيل المحلي على ويندوز).

التشغيل:
    python termin_watch.py                     # مراقبة مستمرة
    python termin_watch.py --once              # فحص واحد
    python termin_watch.py --loop-minutes 90   # يفحص لمدة 90 دقيقة ثم يتوقف (لـ GitHub)
    python termin_watch.py --once --show --debug
"""

import argparse
import datetime as dt
import json
import os
import random
import re
import time

import requests
from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

# ==========================  الإعدادات  ==========================

START_URL = "https://termine.staedteregion-aachen.de/auslaenderamt/"

CUTOFF_DATE = "2026-12-01"
EARLIEST_TIME = None      # مثال: "09:00"
LATEST_TIME = None        # مثال: "15:00"
TELEGRAM_TOKEN = ""
TELEGRAM_CHAT_ID = ""

CONFIG_FILE = "config.json"
STATE_FILE = "termin_seen.json"

INTERVAL_SECONDS = 120
JITTER_SECONDS = 30

# ساعات الفحص بالتوقيت المحلي للجهاز. None = طوال اليوم.
# على GitHub تُلغى تلقائياً لأن السيرفر بتوقيت UTC والجدولة تتكفّل بالتوقيت.
ACTIVE_HOURS = (6, 21)

IN_CI = bool(os.environ.get("GITHUB_ACTIONS"))

# =================================================================

WEEKDAYS = "Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag"
DATE_RE = re.compile(r"(?:%s)\s*,\s*(\d{2})\.(\d{2})\.(\d{4})" % WEEKDAYS)
TIME_RE = re.compile(r"^(\d{1,2}:\d{2})$")


def log(msg):
    print(f"[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


# ----------------------  الإعدادات  ----------------------

def setup_config():
    """البيئة أولاً (GitHub Actions)، ثم config.json، ثم السؤال التفاعلي."""
    global CUTOFF_DATE, TELEGRAM_TOKEN, TELEGRAM_CHAT_ID

    env_token = os.environ.get("TELEGRAM_TOKEN", "").strip()
    env_chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    env_cut = os.environ.get("CUTOFF_DATE", "").strip()

    # التاريخ يُقرأ دائماً من البيئة إن كان صالحاً
    if re.match(r"^\d{4}-\d{2}-\d{2}$", env_cut):
        CUTOFF_DATE = env_cut

    if env_token and env_chat:
        TELEGRAM_TOKEN = env_token
        TELEGRAM_CHAT_ID = env_chat
        log("الإعدادات من متغيرات البيئة.")
        return

    if IN_CI:
        missing = []
        if not env_token:
            missing.append("TELEGRAM_TOKEN")
        if not env_chat:
            missing.append("TELEGRAM_CHAT_ID")
        log(f"تحذير: ناقص في Secrets: {', '.join(missing)} - لن تصل إشعارات Telegram.")
        return

    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, encoding="utf-8-sig") as f:
                cfg = json.load(f)
            CUTOFF_DATE = cfg.get("cutoff_date", CUTOFF_DATE)
            TELEGRAM_TOKEN = cfg.get("telegram_token", "")
            TELEGRAM_CHAT_ID = str(cfg.get("telegram_chat_id", ""))
            return
        except Exception as e:
            log(f"config.json تالف ({e}) - سأسأل من جديد.")

    print("\n===== الإعداد الأول =====")
    print("(اضغط Enter لقبول القيمة بين القوسين)\n")

    d = input(f"نبّهني على أي موعد قبل تاريخ [YYYY-MM-DD] ({CUTOFF_DATE}): ").strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}$", d):
        CUTOFF_DATE = d

    print("\nلإشعارات Telegram: أنشئ بوت عبر @BotFather.")
    print("اتركها فارغة إن أردت الطباعة في الشاشة فقط.")
    TELEGRAM_TOKEN = input("Telegram bot token: ").strip()
    if TELEGRAM_TOKEN:
        TELEGRAM_CHAT_ID = input("Telegram chat id: ").strip()

    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "cutoff_date": CUTOFF_DATE,
                "telegram_token": TELEGRAM_TOKEN,
                "telegram_chat_id": TELEGRAM_CHAT_ID,
            }, f, ensure_ascii=False, indent=1)
        print(f"\nتم الحفظ في {CONFIG_FILE}.\n")
    except Exception as e:
        log(f"تعذّر حفظ config.json: {e}")


# ----------------------  الحالة المحفوظة  ----------------------

def load_seen():
    if IN_CI:
        return set()
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, encoding="utf-8") as f:
                return set(json.load(f))
        except Exception:
            pass
    return set()


def save_seen(seen):
    if IN_CI:
        return
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(sorted(seen), f, ensure_ascii=False, indent=1)
    except Exception as e:
        log(f"تعذّر حفظ الحالة: {e}")


# ----------------------  المرور على الخطوات  ----------------------

def click_safe(page, role, name, timeout=8000, exact=False):
    try:
        page.get_by_role(role, name=name, exact=exact).first.click(timeout=timeout)
        return True
    except Exception:
        return False


def click_any(page, name, roles=("button", "link", "tab"), timeout=20000, tries=2):
    per = max(3000, timeout // (len(roles) + 1))
    for _ in range(tries):
        for role in roles:
            if click_safe(page, role, name, timeout=per):
                return True
        try:
            page.get_by_text(name, exact=False).first.click(timeout=per)
            return True
        except Exception:
            pass
        page.wait_for_timeout(1500)
    return False


def _flow_once(page):
    page.goto(START_URL, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(800)

    click_safe(page, "button", "Akzeptieren", timeout=4000)

    if not click_any(page, "Ausländer- und Staatsangehö", timeout=25000):
        raise RuntimeError("لم أجد زر 'Ausländer- und Staatsangehörigkeitsbehörde'")
    page.wait_for_timeout(600)

    click_any(page, "Infostelle", roles=("tab", "link", "button"), timeout=12000, tries=1)
    page.wait_for_timeout(400)

    if not click_any(page, "Erhöhen der Anzahl des Anliegens Beratungs- und Antragsservice",
                     roles=("button",), timeout=15000):
        raise RuntimeError("لم أجد زر '+' الخاص بـ Beratungs- und Antragsservice")

    click_any(page, "Weiter", roles=("button", "link"), timeout=12000, tries=1)
    click_safe(page, "button", "OK", timeout=4000)
    click_any(page, "Weiter", roles=("button", "link"), timeout=12000, tries=1)

    page.wait_for_load_state("domcontentloaded")
    page.wait_for_timeout(1500)

    if "suggest" not in page.url:
        raise RuntimeError(f"لم أصل لصفحة المواعيد. العنوان: {page.url}")


def goto_suggest(page, attempts=2):
    last = None
    for i in range(attempts):
        try:
            _flow_once(page)
            return
        except Exception as e:
            last = e
            if i < attempts - 1:
                log(f"محاولة {i + 1} فشلت ({e}) - إعادة المحاولة...")
                page.wait_for_timeout(3000)
    raise last


# ----------------------  قراءة المواعيد  ----------------------

def is_clickable(tag):
    if tag.name in ("a", "button"):
        if tag.has_attr("disabled"):
            return False
        cls = " ".join(tag.get("class") or []).lower()
        if any(w in cls for w in ("disabled", "belegt", "gesperrt", "inactive")):
            return False
        if tag.name == "a":
            return bool(tag.get("href") or tag.get("onclick"))
        return True
    if tag.name == "input" and tag.get("type") in ("submit", "button"):
        return not tag.has_attr("disabled")
    return False


def parse_page(html):
    soup = BeautifulSoup(html, "html.parser")
    slots, labels = {}, {}
    current = None

    for tag in soup.find_all(True):
        text = tag.get_text(" ", strip=True)
        if not text or len(text) > 90:
            continue

        m = DATE_RE.search(text)
        if m and len(text) < 45:
            d, mo, y = m.groups()
            current = f"{y}-{mo}-{d}"
            slots.setdefault(current, set())
            labels[current] = m.group(0)
            continue

        tm = TIME_RE.match(text)
        if tm and current and is_clickable(tag):
            v = tm.group(1)
            slots[current].add(v if len(v) == 5 else "0" + v)

    return {d: sorted(t) for d, t in slots.items()}, labels


def read_slots(page, cutoff, debug=False):
    html = page.content()
    slots, labels = parse_page(html)

    to_expand = [d for d in slots if d < cutoff and not slots[d]]
    for d in to_expand[:6]:
        try:
            page.get_by_text(labels[d], exact=False).first.click(timeout=4000)
            page.wait_for_timeout(700)
        except Exception:
            pass

    if to_expand:
        html = page.content()
        slots, labels = parse_page(html)

    if debug:
        with open("last_page.html", "w", encoding="utf-8") as f:
            f.write(html)
        log("تم حفظ الصفحة في last_page.html")

    return {d: t for d, t in slots.items() if t}


# ----------------------  الإشعار  ----------------------

def send_telegram(text):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
        print("\n" + "=" * 55 + "\n" + text + "\n" + "=" * 55 + "\n", flush=True)
        return
    try:
        r = requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage",
            data={"chat_id": TELEGRAM_CHAT_ID, "text": text},
            timeout=20)
        if r.status_code != 200:
            log(f"فشل Telegram: {r.status_code} {r.text[:180]}")
    except Exception as e:
        log(f"فشل Telegram: {e}")


def filter_slots(slots, cutoff, earliest, latest):
    out = {}
    for d, times in slots.items():
        if d >= cutoff:
            continue
        keep = [t for t in times
                if (earliest is None or t >= earliest)
                and (latest is None or t <= latest)]
        if keep:
            out[d] = keep
    return out


# ----------------------  الفحص  ----------------------

def check_once(headless=True, debug=False, seen=None):
    seen = seen if seen is not None else set()
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=headless)
        ctx = browser.new_context(locale="de-DE")
        page = ctx.new_page()
        try:
            goto_suggest(page)
            slots = read_slots(page, CUTOFF_DATE, debug=debug)
        finally:
            ctx.close()
            browser.close()

    if not slots:
        log("لم أجد أي مواعيد متاحة إطلاقاً (أو تغيّرت بنية الصفحة).")
        return

    total = sum(len(v) for v in slots.values())
    log(f"{total} موعد متاح في {len(slots)} يوم | أقرب يوم: {min(slots)}")

    matches = filter_slots(slots, CUTOFF_DATE, EARLIEST_TIME, LATEST_TIME)
    new = []
    for d in sorted(matches):
        for t in matches[d]:
            key = f"{d} {t}"
            if key not in seen:
                seen.add(key)
                new.append(key)

    if new:
        shown = new[:15]
        msg = ["🚨 موعد قريب في دائرة الأجانب (Infostelle)!", ""]
        msg += [f"• {k}" for k in shown]
        if len(new) > len(shown):
            msg.append(f"... و {len(new) - len(shown)} موعد آخر")
        msg += ["", "احجز الآن:", START_URL]
        send_telegram("\n".join(msg))
        save_seen(seen)
        log(f"تم إرسال إشعار بـ {len(new)} موعد.")
    elif matches:
        log("موعد قريب موجود لكن سبق التنبيه عليه.")
    else:
        log(f"لا يوجد موعد قبل {CUTOFF_DATE}.")


def in_active_hours():
    if IN_CI or not ACTIVE_HOURS:
        return True
    return ACTIVE_HOURS[0] <= dt.datetime.now().hour < ACTIVE_HOURS[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--show", action="store_true", help="إظهار نافذة المتصفح")
    ap.add_argument("--debug", action="store_true", help="حفظ الصفحة في last_page.html")
    ap.add_argument("--loop-minutes", type=int, default=0,
                    help="يفحص لهذه المدة بالدقائق ثم يتوقف (للتشغيل على GitHub)")
    args = ap.parse_args()

    setup_config()
    log(f"سأنبّه على أي موعد قبل {CUTOFF_DATE}"
        + (" | إشعارات Telegram مفعّلة" if TELEGRAM_TOKEN else " | طباعة في الشاشة فقط"))

    deadline = None
    if args.loop_minutes > 0:
        deadline = time.time() + args.loop_minutes * 60
        log(f"سأعمل {args.loop_minutes} دقيقة ثم أتوقف.")

    seen = load_seen()
    fails = 0

    while True:
        if in_active_hours():
            try:
                check_once(headless=not args.show, debug=args.debug, seen=seen)
                fails = 0
            except Exception as e:
                fails += 1
                log(f"خطأ: {e}")
        else:
            log("خارج ساعات الفحص.")

        if args.once:
            break

        wait = INTERVAL_SECONDS + random.randint(0, JITTER_SECONDS)
        if fails >= 3:
            wait *= 4
            log("أخطاء متكررة - زيادة فترة الانتظار.")

        if deadline is not None and time.time() + wait >= deadline:
            log("انتهت مدة التشغيل.")
            break

        log(f"الانتظار {max(1, wait // 60)} دقيقة...")
        time.sleep(wait)


if __name__ == "__main__":
    main()
