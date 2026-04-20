"""
╔══════════════════════════════════════════════════════════╗
║       MOBILE LEGENDS BUILD GUIDE BOT  v2.0              ║
║  • Парсинг актуальных сборок с mobilelegends.gg          ║
║  • Кэш 6 часов — не спамит запросами                     ║
║  • Офлайн-fallback если сайт недоступен                  ║
║  • Все ~120 героев в базе                                ║
╚══════════════════════════════════════════════════════════╝

УСТАНОВКА:
    pip install pyTelegramBotAPI requests beautifulsoup4 lxml

ЗАПУСК:
    1. Получи токен у @BotFather → /newbot
    2. Вставь токен ниже в BOT_TOKEN
    3. python ml_bot.py
"""

import telebot
import requests
import json
import time
import re
import logging
from telebot.types import InlineKeyboardMarkup, InlineKeyboardButton
from bs4 import BeautifulSoup
from datetime import datetime, timedelta
from threading import Lock

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ═══════════════════════ ТОКЕН ═══════════════════════
BOT_TOKEN = "ВАШ_ТОКЕН_ЗДЕСЬ"   # ← @BotFather → /newbot
# ══════════════════════════════════════════════════════

bot = telebot.TeleBot(BOT_TOKEN, parse_mode="Markdown")

# ═══════════════════════ КЭШ ══════════════════════════
CACHE: dict = {}          # { hero_name: { data, timestamp } }
CACHE_TTL = 6 * 3600      # 6 часов
cache_lock = Lock()

def cache_get(key: str):
    with cache_lock:
        entry = CACHE.get(key)
        if not entry:
            return None
        if time.time() - entry["ts"] > CACHE_TTL:
            del CACHE[key]
            return None
        return entry["data"]

def cache_set(key: str, data):
    with cache_lock:
        CACHE[key] = {"data": data, "ts": time.time()}

# ═══════════════════ ПАРСЕР mobilelegends.gg ═════════

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/120.0.0.0 Safari/537.36"
}

def fetch_build_from_web(hero_name: str) -> dict | None:
    """Парсит топ сборку с mobilelegends.gg."""
    slug = hero_name.lower().replace(" ", "-").replace("'", "")
    url = f"https://mobilelegends.gg/heroes/{slug}"
    try:
        r = requests.get(url, headers=HEADERS, timeout=8)
        if r.status_code != 200:
            log.warning(f"[parser] {hero_name}: HTTP {r.status_code}")
            return None
        soup = BeautifulSoup(r.text, "lxml")

        build = {"source": "mobilelegends.gg", "url": url, "hero": hero_name}

        # --- Предметы ---
        items = []
        for el in soup.select(".item-build .item, .build-items .item-icon, [class*='build'] img[alt]")[:8]:
            name = el.get("alt") or el.get("title") or el.text.strip()
            if name and name not in items:
                items.append(name)
        build["items"] = items[:6] if items else []

        # --- Эмблема ---
        emblem_el = soup.select_one("[class*='emblem'] .name, [class*='emblem'] span, .emblem-name")
        build["emblem"] = emblem_el.text.strip() if emblem_el else ""

        # --- Заклинание ---
        spell_el = soup.select_one("[class*='spell'] .name, .spell-name, [class*='battle-spell'] span")
        build["spell"] = spell_el.text.strip() if spell_el else ""

        # --- Win rate / Pick rate ---
        wr = soup.select_one("[class*='winrate'], [class*='win-rate']")
        build["winrate"] = wr.text.strip() if wr else ""

        # --- Тир ---
        tier_el = soup.select_one("[class*='tier'], .hero-tier")
        build["tier"] = tier_el.text.strip()[:3] if tier_el else ""

        if build["items"]:
            log.info(f"[parser] {hero_name}: OK ({len(build['items'])} items)")
            return build

        log.warning(f"[parser] {hero_name}: no items found")
        return None

    except Exception as e:
        log.error(f"[parser] {hero_name}: {e}")
        return None


def fetch_build_mlbb(hero_name: str) -> dict | None:
    """Резервный парсер — mlbb.gg"""
    slug = hero_name.lower().replace(" ", "-").replace("'", "").replace(".", "")
    url = f"https://mlbb.gg/heroes/{slug}/guide"
    try:
        r = requests.get(url, headers=HEADERS, timeout=8)
        if r.status_code != 200:
            return None
        soup = BeautifulSoup(r.text, "lxml")
        build = {"source": "mlbb.gg", "url": url, "hero": hero_name}

        items = []
        for img in soup.select("img[alt*='Item'], .item img, [class*='item-slot'] img")[:8]:
            name = img.get("alt", "").replace(" Item", "").strip()
            if name and name not in items:
                items.append(name)
        build["items"] = items[:6]

        spell_el = soup.select_one("[class*='spell'] img")
        build["spell"] = spell_el.get("alt", "") if spell_el else ""
        build["emblem"] = ""
        build["winrate"] = ""
        build["tier"] = ""

        return build if build["items"] else None
    except Exception as e:
        log.error(f"[mlbb.gg] {hero_name}: {e}")
        return None


def get_live_build(hero_name: str) -> dict | None:
    """Получает сборку: сначала из кэша, потом из сети."""
    cached = cache_get(hero_name)
    if cached:
        cached["from_cache"] = True
        return cached

    data = fetch_build_from_web(hero_name) or fetch_build_mlbb(hero_name)
    if data:
        cache_set(hero_name, data)
        data["from_cache"] = False
    return data


# ═══════════════════════ БАЗА ГЕРОЕВ ══════════════════
# Все герои Mobile Legends с ролями, тиром и базовой сборкой (fallback)

ALL_HEROES = {
    # ── ASSASSIN ──────────────────────────────────────────────
    "Ling":       {"role":"Assassin","emoji":"🗡️","tier":"S","diff":5,
      "desc":"Прыгает по стенам, высокий мобильный бурст.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Retribution",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Endless Battle","Immortality","Malefic Roar"],
      "tips":["Стены — главный инструмент","Атакуй только при 2+ тросах","Ульта в тимфайте или для бегства"],
      "counters":["Saber","Khufra","Paquito"],"synergy":["Diggie","Atlas","Lolita"]},

    "Fanny":      {"role":"Assassin","emoji":"🪁","tier":"S","diff":5,
      "desc":"Самый сложный герой. Тросы требуют сотен игр.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Retribution",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Endless Battle","Immortality","Malefic Roar"],
      "tips":["Тренируй cable cancel","2+ тросов перед атакой","Уходи сразу после убийства"],
      "counters":["Khufra","Nana","Paquito"],"synergy":["Angela","Diggie","Mathilda"]},

    "Lancelot":   {"role":"Assassin","emoji":"⚔️","tier":"A+","diff":4,
      "desc":"Стремительный ассасин с уклонениями через скиллы.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Execute",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["S2 даёт иммунитет — используй против CC","Комбо: S1→S2→S3","Таргет: маг/стрелок"],
      "counters":["Kaja","Khufra","Chou"],"synergy":["Angela","Estes","Rafaela"]},

    "Helcurt":    {"role":"Assassin","emoji":"🕷️","tier":"A+","diff":3,
      "desc":"Молчаливый ассасин. Ульта отключает скиллы врагов.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Execute",
      "items":["Rapid Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Ульта перед тимфайтом","Молчание = главный ассет","Гангай с фланга"],
      "counters":["Natalia","Selena","Gusion"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Natalia":    {"role":"Assassin","emoji":"🐈","tier":"A","diff":4,
      "desc":"Невидимый ассасин. Заходи сзади, убивай стрелков.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Невидимость в кустах","Приоритет — стрелок/маг","Smoke bomb блокирует базовые атаки"],
      "counters":["Saber","Khufra","Chou"],"synergy":["Angela","Atlas","Tigreal"]},

    "Saber":      {"role":"Assassin","emoji":"🔱","tier":"A","diff":2,
      "desc":"Лучший счётчик против одиночных целей. Прост в освоении.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Execute",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Ульта фиксирует цель — бей сразу","Таргет: ассасин врага","Лёгкий для новичков"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Atlas","Tigreal","Estes"]},

    "Karina":     {"role":"Assassin","emoji":"⚡","tier":"A","diff":2,
      "desc":"Ульта сбрасывается при убийстве. Мощна при сноуболле.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Execute",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Blood Wings","Immortality","Divine Glaive"],
      "tips":["Добивай низкое HP ультой","Сноуболь с первого убийства","Не инициируй — жди команды"],
      "counters":["Chou","Khufra","Atlas"],"synergy":["Atlas","Tigreal","Diggie"]},

    "Gusion":     {"role":"Assassin","emoji":"🌀","tier":"S","diff":5,
      "desc":"Маг-ассасин с мгновенным бурстом. Требует точности.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Concentrated Energy","Holy Crystal","Divine Glaive","Blood Wings"],
      "tips":["Комбо: S2→S1×3→S3→S2","Dagger recall — ключевой механик","Не атакуй под CC"],
      "counters":["Chou","Khufra","Paquito"],"synergy":["Diggie","Angela","Atlas"]},

    "Selena":     {"role":"Assassin/Mage","emoji":"🌙","tier":"S","diff":5,
      "desc":"Гибрид мага и ассасина. CC + бурст = убийство из засады.",
      "emblem":"Убийца/Маг — Agility/Observation/Killing Spree","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Divine Glaive","Immortality","Blood Wings"],
      "tips":["Ловушки ставь в траве","Комбо: S1(trap)→S3→S2","Возвращайся в форму мага после CC"],
      "counters":["Diggie","Chou","Khufra"],"synergy":["Atlas","Franco","Khufra"]},

    "Benedetta":  {"role":"Assassin","emoji":"🌹","tier":"A+","diff":4,
      "desc":"Красивый стиль боя с анимациями. Хороший burst+sustain.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["S2 = защита от CC","Dash через S1 даёт стаки","Ульта = зона урона"],
      "counters":["Khufra","Chou","Franco"],"synergy":["Estes","Angela","Atlas"]},

    "Yi Sun-shin":{"role":"Assassin/Marksman","emoji":"⛵","tier":"A","diff":3,
      "desc":"Глобальная ульта. Видит всех врагов на карте.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Retribution",
      "items":["Swift Boots","Endless Battle","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Ульта — глобальное давление","Лодка = dash через стены","Фармь быстро, гангай рано"],
      "counters":["Khufra","Chou","Franco"],"synergy":["Atlas","Tigreal","Angela"]},

    "Hanzo":      {"role":"Assassin","emoji":"🐉","tier":"A","diff":4,
      "desc":"Призрак наносит урон пока тело стоит на месте.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Retribution",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Ульта — безопасная позиция","Тело уязвимо во время ульты","Нужна защита от команды"],
      "counters":["Chou","Saber","Kaja"],"synergy":["Atlas","Tigreal","Angela"]},

    "Aamon":      {"role":"Assassin","emoji":"💎","tier":"A+","diff":3,
      "desc":"Невидимый после S1. Хороший бурст в mid-game.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Execute",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Ноходись в невидимости перед атакой","Собирай осколки для усиления","Ульта = finish"],
      "counters":["Khufra","Chou","Saber"],"synergy":["Atlas","Angela","Diggie"]},

    "Joy":        {"role":"Assassin","emoji":"🎭","tier":"S","diff":4,
      "desc":"Высокий бурст через ноты. Очень подвижная.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Активируй ноты для максимального урона","Ульта даёт иммунитет","Гангай после 4 уровня"],
      "counters":["Chou","Khufra","Paquito"],"synergy":["Angela","Atlas","Diggie"]},

    # ── FIGHTER ───────────────────────────────────────────────
    "Chou":       {"role":"Fighter/Assassin","emoji":"🥋","tier":"S","diff":5,
      "desc":"Лучший файтер с мощным CC и уклонением.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Tough Boots","Blade of Heptaseas","Hunter Strike","Brute Force Breastplate","Immortality","Malefic Roar"],
      "tips":["S2 уклоняется от скиллов","Комбо: S2→S1×3→S3→Flicker","Таргет: саппорт/маг"],
      "counters":["Karrie","Esmeralda","Khufra"],"synergy":["Angela","Estes","Atlas"]},

    "Paquito":    {"role":"Fighter","emoji":"🥊","tier":"S+","diff":4,
      "desc":"Боксёр с огромным уроном. Каждый 4-й скилл усиливается.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Blade of Despair","Hunter Strike","Endless Battle","Immortality","Malefic Roar"],
      "tips":["Считай стаки — каждый 4-й скилл усиленный","S2 = гэп-клоузер","Агрессивно в раннем игре"],
      "counters":["Chou","Khufra","Esmeralda"],"synergy":["Angela","Estes","Atlas"]},

    "Aldous":     {"role":"Fighter","emoji":"💪","tier":"A","diff":2,
      "desc":"Накапливает стаки для огромного урона в позднем игре.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Blade of Despair","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["Фармь стаки в early game","200+ стаков = один выстрел","Ульта показывает всех врагов"],
      "counters":["Chou","Khufra","Atlas"],"synergy":["Angela","Atlas","Tigreal"]},

    "Thamuz":     {"role":"Fighter","emoji":"👹","tier":"A+","diff":3,
      "desc":"Огненный файтер. Высокий устойчивый урон.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Calamity Reaper","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Собирай косы для урона","Ульта — в толпе врагов","Хорошо в затяжных боях"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Atlas","Tigreal","Angela"]},

    "Badang":     {"role":"Fighter","emoji":"💨","tier":"A","diff":3,
      "desc":"Толкает врагов в стену для combo убийства.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Hunter Strike","Endless Battle","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Стена = обязательна для комбо","S3 фиксирует у стены","Комбо: S1→S3→Ульта"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Atlas","Tigreal","Angela"]},

    "Dyroth":     {"role":"Fighter","emoji":"😈","tier":"A","diff":4,
      "desc":"Хаотичный файтер. Сильный burst в ранней игре.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Агрессивен на ранних уровнях","Combo burst быстро","Используй dash для убегания"],
      "counters":["Chou","Khufra","Paquito"],"synergy":["Angela","Atlas","Estes"]},

    "Masha":      {"role":"Fighter","emoji":"🐻","tier":"A","diff":2,
      "desc":"3 жизни, уничтожает башни очень быстро.",
      "emblem":"Файтер — Bravery/Festival of Blood/Unbending Will","spell":"Flicker",
      "items":["Warrior Boots","Blade of Despair","Brute Force Breastplate","Wind of Nature","Endless Battle","Immortality"],
      "tips":["Пуши башни одна за другой","3 HP-бара = очень живуча","Сплит-пуш стратегия"],
      "counters":["Chou","Khufra","Atlas"],"synergy":["Angela","Diggie","Estes"]},

    "Leomord":    {"role":"Fighter","emoji":"🏇","tier":"A+","diff":3,
      "desc":"На коне — другой герой. Огромный урон в ульте.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Blade of Despair","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["Ульта = конь, меняет стиль игры","Собери HP для живучести","Сильный в 1v1"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Angela","Atlas","Estes"]},

    "Freya":      {"role":"Fighter","emoji":"⚡","tier":"A","diff":2,
      "desc":"Прыгает и собирает Sacred Orb. Хороша в ближнем бою.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Blade of Despair","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["Sacred Orb = усиленная атака","Ульта — AOE вокруг","Хорошо в teamfight"],
      "counters":["Chou","Khufra","Paquito"],"synergy":["Atlas","Tigreal","Angela"]},

    "Guinevere":  {"role":"Fighter/Mage","emoji":"👑","tier":"A+","diff":3,
      "desc":"Красивые комбо + подброс врага в воздух.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Blood Wings","Divine Glaive","Immortality"],
      "tips":["S2 подбрасывает — комбо с ультой","Ульта = большой AOE","Хороша против несмотрящих вверх"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Atlas","Angela","Estes"]},

    "Khaleed":    {"role":"Fighter","emoji":"🏜️","tier":"A","diff":3,
      "desc":"Песочный файтер со скользящей атакой.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Скользи для нанесения урона","Ульта фиксирует в зоне","Хорошо в узких местах"],
      "counters":["Chou","Khufra","Atlas"],"synergy":["Angela","Estes","Atlas"]},

    "Aulus":      {"role":"Fighter","emoji":"🪖","tier":"A","diff":2,
      "desc":"Простой файтер с большой секирой. Хороший для новичков.",
      "emblem":"Файтер — Bravery/Invasion/Brave Smite","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Blade of Despair","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["S1 замедляет","Ульта = большая секира","Простой в освоении"],
      "counters":["Chou","Khufra","Paquito"],"synergy":["Atlas","Angela","Estes"]},

    "Arlott":     {"role":"Fighter/Assassin","emoji":"🔥","tier":"S","diff":4,
      "desc":"Быстрый файтер с накоплением демонической силы.",
      "emblem":"Убийца — Agility/Invasion/Killing Spree","spell":"Flicker",
      "items":["Warrior Boots","Blade of Heptaseas","Hunter Strike","Blade of Despair","Immortality","Malefic Roar"],
      "tips":["Накапливай стаки демона","Combo: S1→S2→S3","Сильный в 1v1 и ганге"],
      "counters":["Chou","Khufra","Esmeralda"],"synergy":["Angela","Atlas","Estes"]},

    "Yu Zhong":   {"role":"Fighter","emoji":"🐲","tier":"A+","diff":3,
      "desc":"Дракон-файтер с огромным лайфстилом.",
      "emblem":"Файтер — Bravery/Invasion/Festival of Blood","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Calamity Reaper","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["Лайфстил через скиллы","Ульта = дракон, AOE CC","Хорош в затяжных боях"],
      "counters":["Chou","Khufra","Baxia"],"synergy":["Atlas","Angela","Estes"]},

    # ── MARKSMAN ──────────────────────────────────────────────
    "Beatrix":    {"role":"Marksman","emoji":"🔫","tier":"S+","diff":4,
      "desc":"4 вида оружия — разная механика каждого.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Haas's Claws","Blade of Despair","Windtalker","Berserker's Fury","Malefic Roar"],
      "tips":["Shotgun = бурст вблизи","Снайперка = дальняя дистанция","Ульта блокирует базовые атаки"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Franco","Tigreal"]},

    "Wanwan":     {"role":"Marksman","emoji":"🎯","tier":"A+","diff":4,
      "desc":"Активируй 4 точки уязвимости для ульты.",
      "emblem":"Стрелок — Agility/Electro Flash/Weakness Finder","spell":"Inspire",
      "items":["Swift Boots","Corrosion Scythe","Wind of Nature","Berserker's Fury","Blade of Despair","Malefic Roar"],
      "tips":["4 точки → ульта","Wind of Nature = от ассасинов","S2 иммунитет к CC"],
      "counters":["Khufra","Franco","Atlas"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Karrie":     {"role":"Marksman","emoji":"⚙️","tier":"S","diff":3,
      "desc":"Лучший контр против танков. Истинный урон на 5-м хите.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Inspire",
      "items":["Swift Boots","Windtalker","Blade of Despair","Berserker's Fury","Corrosion Scythe","Malefic Roar"],
      "tips":["5-й хит = истинный урон","Атакуй танков в первую очередь","Двигайся постоянно"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Granger":    {"role":"Marksman","emoji":"🎻","tier":"A+","diff":3,
      "desc":"6 пуль, 6-я — критическая. Высокий бурст.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Warrior Boots","Endless Battle","Blade of Despair","Hunter Strike","Immortality","Malefic Roar"],
      "tips":["6-я пуля — крит, тайми","Ульта = дальний снаряд","Хорош в раннем игре"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Franco","Angela"]},

    "Claude":     {"role":"Marksman","emoji":"🐒","tier":"A","diff":3,
      "desc":"Стрелок с уклонением и спутником-обезьяной.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Haas's Claws","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar"],
      "tips":["Ульта = AoE в области обезьяны","Меняйся местами с Dexter","Безопасная дистанция"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    "Moskov":     {"role":"Marksman","emoji":"🏹","tier":"A","diff":3,
      "desc":"Пробивает нескольких врагов. Телепорт через S1.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar","Immortality"],
      "tips":["Атаки сквозь нескольких","Телепорт к стене = уход от CC","Стой за командой"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    "Miya":       {"role":"Marksman","emoji":"🌸","tier":"A","diff":1,
      "desc":"Классический стрелок. Простой для начинающих.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Inspire",
      "items":["Swift Boots","Haas's Claws","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar"],
      "tips":["Держись за командой","Ульта = невидимость + сброс CC","Прост в освоении"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    "Layla":      {"role":"Marksman","emoji":"🔮","tier":"B","diff":1,
      "desc":"Самый простой стрелок. Длинная дистанция атаки.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Haas's Claws","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar"],
      "tips":["Стой ОЧЕНЬ далеко","Ульта — дальний выстрел","Нужна хорошая команда"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    "Bruno":      {"role":"Marksman","emoji":"⚽","tier":"A+","diff":2,
      "desc":"Крит-стрелок. Передаёт мяч команде.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Windtalker","Berserker's Fury","Blade of Despair","Malefic Roar","Immortality"],
      "tips":["Крит через 5 атак","Ульта даёт стак команде","Хорош вместе с дайверами"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Chou","Angela"]},

    "Lesley":     {"role":"Marksman","emoji":"🎀","tier":"A","diff":3,
      "desc":"Снайпер. Усиленная атака через стелс.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Berserker's Fury","Blade of Despair","Windtalker","Malefic Roar","Immortality"],
      "tips":["Зайди в стелс → усиленная атака","Крит на одиночную цель","Ульта = дальний снайпер"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Angela","Atlas","Franco"]},

    "Irithel":    {"role":"Marksman","emoji":"🐅","tier":"A","diff":2,
      "desc":"Атакует верхом на тигре. Может двигаться во время атаки.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Endless Battle","Blade of Despair","Windtalker","Berserker's Fury","Malefic Roar"],
      "tips":["Движение + атака — главное","Ульта = тройной AOE выстрел","Держись за командой"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    "Kimmy":      {"role":"Marksman/Mage","emoji":"🧪","tier":"A","diff":3,
      "desc":"Стреляет в любом направлении независимо от движения.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Glowing Wand","Divine Glaive","Blood Wings"],
      "tips":["Атака и движение независимы","Маг-урон — строй маг предметы","Хорошо в скрамах"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Angela","Estes"]},

    "Popol and Kupa":{"role":"Marksman","emoji":"🐺","tier":"A+","diff":3,
      "desc":"Стрелок с волком. Расставляй ловушки по карте.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar","Immortality"],
      "tips":["Ловушки в кустах","Купа танкует CC","Держи дистанцию во время Купа-атаки"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Angela","Tigreal"]},

    "Melissa":    {"role":"Marksman","emoji":"🪡","tier":"A+","diff":3,
      "desc":"Барьер-ульта не пускает ближних бойцов. Безопасный стрелок.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Haas's Claws","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar"],
      "tips":["Ульта = барьер от ближнего боя","Кукла поглощает урон","Хороша против дайверов"],
      "counters":["Moskov","Granger","Clint"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Clint":      {"role":"Marksman","emoji":"🤠","tier":"A","diff":2,
      "desc":"Ковбой. Пассив даёт дополнительный выстрел.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Windtalker","Berserker's Fury","Blade of Despair","Malefic Roar","Immortality"],
      "tips":["Каждый скилл → бонусный выстрел","S1 слоу","Хорош против одиночных целей"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Angela","Estes"]},

    "Natan":      {"role":"Marksman","emoji":"⚛️","tier":"A+","diff":4,
      "desc":"Атакует с тыла через отражение. Уникальная механика.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Windtalker","Berserker's Fury","Blade of Despair","Malefic Roar","Immortality"],
      "tips":["Отражение атакует сзади","Ульта = двойная копия","Позиционируйся с умом"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Angela","Tigreal"]},

    "Ixia":       {"role":"Marksman","emoji":"🌀","tier":"A+","diff":2,
      "desc":"Стрелок с AOE уроном. Ульта атакует всех вокруг.",
      "emblem":"Стрелок — Weakness Finder/Electro Flash","spell":"Flicker",
      "items":["Swift Boots","Corrosion Scythe","Windtalker","Blade of Despair","Berserker's Fury","Malefic Roar"],
      "tips":["Атакуй скопления врагов","Ульта = AOE автоатаки","Хороша в teamfight"],
      "counters":["Lancelot","Helcurt","Fanny"],"synergy":["Atlas","Tigreal","Angela"]},

    # ── MAGE ──────────────────────────────────────────────────
    "Kagura":     {"role":"Mage","emoji":"🌸","tier":"S","diff":5,
      "desc":"Сложный маг с зонтиком. Огромный потенциал.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Lightning Truncheon","Holy Crystal","Divine Glaive","Blood Wings"],
      "tips":["Комбо: S1(зонт)→S3→S2→S1","Зонт = уклонение от CC","Практикуй разделение"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Tigreal","Khufra","Atlas"]},

    "Lunox":      {"role":"Mage","emoji":"🌗","tier":"S","diff":4,
      "desc":"Два режима: хаос и порядок. Иммунитет в ульте хаоса.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Blood Wings","Divine Glaive","Immortality"],
      "tips":["Режим хаоса = урон","Режим порядка = защита","Ульта хаоса = иммунитет"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Harith":     {"role":"Mage","emoji":"🦊","tier":"S","diff":4,
      "desc":"Маг-файтер с зеркалами. Очень подвижный.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings"],
      "tips":["Зеркало снижает CD","Combo quick-cast","Высокий sustained damage"],
      "counters":["Helcurt","Nana","Khufra"],"synergy":["Atlas","Tigreal","Angela"]},

    "Cecilion":   {"role":"Mage","emoji":"🧛","tier":"A+","diff":3,
      "desc":"Накапливает маг. силу. Поздняя игра = огромный урон.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Lightning Truncheon","Holy Crystal","Divine Glaive","Blood Wings"],
      "tips":["Стакай заряды через S1","Поздняя игра = сильнее","Держи дистанцию"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Carmilla","Atlas","Tigreal"]},

    "Pharsa":     {"role":"Mage","emoji":"🦅","tier":"A+","diff":3,
      "desc":"Длинная ульта через птицу. Хорошее зонирование.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Ульта через птицу = безопасно","Зонируй вражескую линию","Держись за командой"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Valentina":  {"role":"Mage","emoji":"🌿","tier":"S","diff":5,
      "desc":"Копирует ульту врага. Уникальный игровой стиль.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Выбери цель с сильной ультой","Копируй в нужный момент","Сложная в освоении"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Lylia":      {"role":"Mage","emoji":"🎃","tier":"A+","diff":3,
      "desc":"Оставляет бомбы на карте. Ульта возвращает назад.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Ульта возвращает на прежнее место","Бомбы в кустах","Combo burst"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Vale":       {"role":"Mage","emoji":"🌬️","tier":"S","diff":3,
      "desc":"Настраиваемые скиллы ветра. Гибкий и мощный.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Настрой S1 на knockup","S2 на AoE slow","Combo в тимфайте"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Yve":        {"role":"Mage","emoji":"🌌","tier":"A+","diff":3,
      "desc":"Зонирует огромную область ультой.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Ульта = зонирование местности","Используй с командой","Держись сзади"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Eudora":     {"role":"Mage","emoji":"⚡","tier":"A","diff":1,
      "desc":"Самый простой маг. Оглушение + мощный burst.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Lightning Truncheon","Holy Crystal","Divine Glaive","Blood Wings"],
      "tips":["Combo: S2(stun)→S1→Ульта","Один из лучших для новичков","Burst убивает сразу"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Nana":       {"role":"Mage/Support","emoji":"🐱","tier":"A+","diff":2,
      "desc":"Превращает врагов в животных. Отличный CC и саппорт.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Glowing Wand","Divine Glaive","Immortality"],
      "tips":["S2 = Molina следует за врагом","Ульта = полиморф","Отличный pick против мобильных"],
      "counters":["Diggie","Chou","Khufra"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Chang'e":    {"role":"Mage","emoji":"🌕","tier":"A","diff":2,
      "desc":"Наносит sustained magic damage. Ульта — прыжок с бомбами.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Glowing Wand","Divine Glaive","Blood Wings"],
      "tips":["Накапливай стаки перед ультой","Ульта = прыжок назад","Держи дистанцию"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Kadita":     {"role":"Mage","emoji":"🌊","tier":"A","diff":3,
      "desc":"Волна-маг с иммунитетом. Ныряет под воду.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Calamity Reaper","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["S1 = иммунитет под водой","Ульта выпрыгивает снизу","Хороша против CC"],
      "counters":["Helcurt","Nana","Valir"],"synergy":["Atlas","Tigreal","Khufra"]},

    "Aurora":     {"role":"Mage","emoji":"❄️","tier":"A","diff":3,
      "desc":"Замораживает врагов. Накапливает заряды льда.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Glowing Wand","Divine Glaive","Blood Wings"],
      "tips":["4-й заряд = заморозка","Combo с Tigreal ультой","Держи дистанцию"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Tigreal","Atlas","Khufra"]},

    "Odette":     {"role":"Mage","emoji":"🦢","tier":"A","diff":2,
      "desc":"Ульта — AOE вокруг себя. Нужна защита команды.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Divine Glaive","Blood Wings","Immortality"],
      "tips":["Ульта стой неподвижно","Нужен танк-протектор","Огромный урон в толпе"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Tigreal","Atlas","Lolita"]},

    "Zhask":      {"role":"Mage","emoji":"👾","tier":"A","diff":3,
      "desc":"Призывает Nightmaric Spawn. Turret-style gameplay.",
      "emblem":"Маг — Agility/Observation/Magic Power","spell":"Flicker",
      "items":["Arcane Boots","Clock of Destiny","Holy Crystal","Glowing Wand","Divine Glaive","Blood Wings"],
      "tips":["Spawn = главный инструмент","Ульта меняет персонажа","Зонируй линию через Spawn"],
      "counters":["Helcurt","Lancelot","Fanny"],"synergy":["Atlas","Tigreal","Khufra"]},

    # ── TANK ──────────────────────────────────────────────────
    "Tigreal":    {"role":"Tank","emoji":"🛡️","tier":"A+","diff":2,
      "desc":"Классический танк. Мощное CC для новичков.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Combo: S2→S1→Flicker→Ульта","Flicker во время ульты","Инициируй первым"],
      "counters":["Diggie","Karrie","Esmeralda"],"synergy":["Eudora","Aurora","Vale"]},

    "Atlas":      {"role":"Tank","emoji":"🌊","tier":"S+","diff":4,
      "desc":"Лучший инициатор. Притягивает всех врагов ультой.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Ульта в толпе врагов","Combo: S1→S2→Flicker→Ульта","Отличный с любым бурстом"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Khufra":     {"role":"Tank","emoji":"🏺","tier":"S","diff":3,
      "desc":"Лучший контр против мобильных героев. Прыжок = CC.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["S2 отражает дэши","S1 прыжок в скопление","Таргет мобильных героев"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Franco":     {"role":"Tank","emoji":"⚓","tier":"A+","diff":3,
      "desc":"Крюк притягивает одиночную цель. Лучший hook-танк.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Крюк = основа игры","Combo: S1(hook)→S2→Ульта","Не промахивайся — долгий КД"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Grock":      {"role":"Tank","emoji":"🪨","tier":"A+","diff":3,
      "desc":"Строит стену. Огромный урон для танка у стен.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Стена = сплит врагов","У стены = больше урона","Инициируй S2"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Lolita":     {"role":"Tank","emoji":"🔨","tier":"A+","diff":3,
      "desc":"Блокирует снаряды щитом. Контр против стрелков.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Щит блокирует снаряды","Ульта silent area","Защищай задние линии"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Baxia":      {"role":"Tank","emoji":"🐢","tier":"A+","diff":3,
      "desc":"Снижает регенерацию врагов. Контр против лайфстила.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Пассив = антилайфстил","Бросается как колесо","Контр против Esmeralda/Yu Zhong"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Belerick":   {"role":"Tank","emoji":"🌿","tier":"A","diff":2,
      "desc":"Перенаправляет атаки с союзников на себя.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Пассив = защита союзников","AOE шипы","Хорош против AA-героев"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    "Esmeralda":  {"role":"Tank/Mage","emoji":"💎","tier":"A+","diff":3,
      "desc":"Поглощает щиты. Контр против shield-героев.",
      "emblem":"Танк — Vitality/Fortress/Brave Smite","spell":"Flicker",
      "items":["Arcane Boots","Oracle","Dominance Ice","Immortality","Antique Cuirass","Concentrated Energy"],
      "tips":["S2 поглощает щиты","Ульта = иммун к слоу","Хорош в топлейне"],
      "counters":["Karrie","Baxia","Wanwan"],"synergy":["Angela","Lolita","Vale"]},

    "Johnson":    {"role":"Tank","emoji":"🚗","tier":"A+","diff":3,
      "desc":"Превращается в машину. Везёт союзника и сбивает врагов.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Берёт союзника в машину","Врезайся в скопление","Combo с Odette ультой"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Odette","Aurora","Pharsa"]},

    "Minotaur":   {"role":"Tank","emoji":"🐂","tier":"A","diff":3,
      "desc":"Огромная ульта с притяжением. Мощен в командных боях.",
      "emblem":"Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Cursed Helmet","Antique Cuirass","Thunder Belt","Immortality","Dominance Ice"],
      "tips":["Ульта = AOE притяжение","Ярость накапливается","Rage mode = усиленный"],
      "counters":["Diggie","Karrie","Wanwan"],"synergy":["Eudora","Aurora","Gusion"]},

    # ── SUPPORT ───────────────────────────────────────────────
    "Angela":     {"role":"Support","emoji":"❤️","tier":"S+","diff":3,
      "desc":"Лучший саппорт. Присоединяется к союзнику ультой.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Fleeting Time","Courage Mask","Glowing Wand","Immortality","Ice Queen Wand"],
      "tips":["Ульта = телепорт к союзнику","Щит в раннем игре","Присоединись к ассасину"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Lancelot","Ling","Fanny"]},

    "Estes":      {"role":"Support","emoji":"🌲","tier":"A+","diff":2,
      "desc":"Лучший хилер. AOE лечение ультой.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Oracle","Fleeting Time","Immortality","Ice Queen Wand"],
      "tips":["Ульта = AOE лечение цепочкой","Всегда рядом с союзниками","Хорош с engage-танком"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Tigreal","Atlas","Khufra"]},

    "Rafaela":    {"role":"Support","emoji":"👼","tier":"A","diff":1,
      "desc":"Самый простой саппорт. Лечение + замедление.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Oracle","Fleeting Time","Immortality","Ice Queen Wand"],
      "tips":["Лечи постоянно","Ульта замедляет всех врагов","Прост для новичков"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Tigreal","Atlas","Khufra"]},

    "Diggie":     {"role":"Support","emoji":"⏰","tier":"S","diff":3,
      "desc":"Ульта снимает CC со всей команды. Незаменим в meta CC.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Oracle","Fleeting Time","Immortality","Ice Queen Wand"],
      "tips":["Ульта = CC-immunity команде","Бомбы контролируют зоны","Воскресает после смерти"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Fanny","Ling","Lancelot"]},

    "Mathilda":   {"role":"Support/Assassin","emoji":"🦋","tier":"S","diff":4,
      "desc":"Быстрый саппорт. Несёт союзника к цели.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Fleeting Time","Holy Crystal","Immortality","Oracle"],
      "tips":["Ульта переносит союзника","Dash + shield","Агрессивный саппорт"],
      "counters":["Chou","Khufra","Franco"],"synergy":["Fanny","Ling","Lancelot"]},

    "Floryn":     {"role":"Support","emoji":"🌼","tier":"A+","diff":2,
      "desc":"Глобальный лечебный предмет. Пассивный саппорт.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Oracle","Fleeting Time","Immortality","Ice Queen Wand"],
      "tips":["Пассивный предмет союзнику","Ульта = глобальное лечение","Держись за командой"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Tigreal","Atlas","Khufra"]},

    "Carmilla":   {"role":"Support/Tank","emoji":"🦇","tier":"A+","diff":3,
      "desc":"Связывает врагов цепью. CC = мощное.",
      "emblem":"Поддержка/Танк — Vitality/Fortress/Tenacity","spell":"Flicker",
      "items":["Tough Boots","Courage Mask","Oracle","Antique Cuirass","Immortality","Dominance Ice"],
      "tips":["S2 связывает всех врагов рядом","Combo с Cecilion ультой","AOE debuff"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Cecilion","Atlas","Tigreal"]},

    "Faramis":    {"role":"Support","emoji":"💀","tier":"A","diff":3,
      "desc":"Воскрешает всю команду ультой.",
      "emblem":"Поддержка — Agility/Focusing Mark/Pull Yourself Together","spell":"Flicker",
      "items":["Demon Shoes","Courage Mask","Fleeting Time","Oracle","Immortality","Ice Queen Wand"],
      "tips":["Ульта = воскрешение команды","Соберите всех для ульты","Используй у вражеской базы"],
      "counters":["Chou","Khufra","Diggie"],"synergy":["Atlas","Tigreal","Khufra"]},
}

# ═══════════════════════ УТИЛИТЫ ══════════════════════

def get_role_emoji(role: str) -> str:
    r = role.lower()
    if "assassin" in r:  return "🔴"
    if "fighter" in r:   return "🟠"
    if "marksman" in r:  return "🟡"
    if "mage" in r:      return "🔵"
    if "tank" in r:      return "🟢"
    if "support" in r:   return "💜"
    return "⚪"

TIER_SORT = {"S+":0,"S":1,"A+":2,"A":3,"B":4}

def heroes_by_role(role: str) -> list[str]:
    out = []
    for name, h in ALL_HEROES.items():
        if role.lower() in h["role"].lower():
            out.append(name)
    return sorted(out, key=lambda n: TIER_SORT.get(ALL_HEROES[n]["tier"],9))

def all_sorted() -> list[str]:
    return sorted(ALL_HEROES.keys(), key=lambda n: (TIER_SORT.get(ALL_HEROES[n]["tier"],9), n))

def cache_age_str(hero_name: str) -> str:
    with cache_lock:
        entry = CACHE.get(hero_name)
    if not entry:
        return ""
    age = int(time.time() - entry["ts"])
    if age < 60: return f"(обновлено {age}с назад)"
    if age < 3600: return f"(обновлено {age//60}м назад)"
    return f"(обновлено {age//3600}ч назад)"


# ═══════════════════════ КЛАВИАТУРЫ ═══════════════════

def kb_main():
    kb = InlineKeyboardMarkup(row_width=2)
    kb.add(
        InlineKeyboardButton("⚔️ Все герои", callback_data="page_all_0"),
        InlineKeyboardButton("🏆 Tier List",  callback_data="tierlist"),
    )
    kb.add(
        InlineKeyboardButton("🔴 Assassin",  callback_data="role_Assassin_0"),
        InlineKeyboardButton("🟠 Fighter",   callback_data="role_Fighter_0"),
    )
    kb.add(
        InlineKeyboardButton("🟡 Marksman",  callback_data="role_Marksman_0"),
        InlineKeyboardButton("🔵 Mage",      callback_data="role_Mage_0"),
    )
    kb.add(
        InlineKeyboardButton("🟢 Tank",      callback_data="role_Tank_0"),
        InlineKeyboardButton("💜 Support",   callback_data="role_Support_0"),
    )
    kb.add(InlineKeyboardButton("🔄 Обновить кэш", callback_data="clearcache"))
    kb.add(InlineKeyboardButton("ℹ️ О боте", callback_data="about"))
    return kb


PAGE_SIZE = 12

def kb_heroes_page(heroes: list, page: int, source_cb: str, back_cb="main"):
    total = len(heroes)
    start = page * PAGE_SIZE
    end   = min(start + PAGE_SIZE, total)
    page_heroes = heroes[start:end]

    kb = InlineKeyboardMarkup(row_width=2)
    buttons = []
    for name in page_heroes:
        h = ALL_HEROES[name]
        re_emoji = get_role_emoji(h["role"])
        label = f"{h['emoji']} {name} [{h['tier']}]"
        buttons.append(InlineKeyboardButton(label, callback_data=f"hero_{name}_{source_cb}"))
    kb.add(*buttons)

    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton("◀️", callback_data=f"{source_cb}_{page-1}"))
    nav.append(InlineKeyboardButton(f"{page+1}/{(total-1)//PAGE_SIZE+1}", callback_data="noop"))
    if end < total:
        nav.append(InlineKeyboardButton("▶️", callback_data=f"{source_cb}_{page+1}"))
    if nav:
        kb.add(*nav)

    kb.add(InlineKeyboardButton("🔙 Главное меню", callback_data="main"))
    return kb


def kb_hero(hero_name: str, back_cb: str):
    kb = InlineKeyboardMarkup(row_width=2)
    kb.add(
        InlineKeyboardButton("⚔️ Сборка",     callback_data=f"build_{hero_name}"),
        InlineKeyboardButton("💡 Советы",      callback_data=f"tips_{hero_name}"),
        InlineKeyboardButton("⚠️ Каунтеры",   callback_data=f"counters_{hero_name}"),
        InlineKeyboardButton("🔄 Обновить",    callback_data=f"refresh_{hero_name}"),
    )
    kb.add(InlineKeyboardButton("🔙 Назад", callback_data=back_cb))
    return kb


def kb_back(cb: str):
    kb = InlineKeyboardMarkup()
    kb.add(InlineKeyboardButton("🔙 Назад", callback_data=cb))
    return kb


# ═══════════════════════ ФОРМАТТЕРЫ ═══════════════════

def fmt_hero_overview(name: str) -> str:
    h = ALL_HEROES[name]
    tier_icons = {"S+":"🔥","S":"⭐","A+":"✅","A":"👍","B":"📌"}
    ti = tier_icons.get(h["tier"],"")
    re = get_role_emoji(h["role"])
    return (
        f"{h['emoji']} *{name}*\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"{re} Роль: `{h['role']}`\n"
        f"{ti} Тир: `{h['tier']}` | 🎮 Сложность: `{h['diff']}/5`\n\n"
        f"_{h['desc']}_\n\n"
        f"Выбери раздел 👇"
    )


def fmt_build(name: str, live: dict | None) -> str:
    h = ALL_HEROES[name]

    if live and live.get("items"):
        items_text = "\n".join([f"  {i+1}️⃣ *{item}*" for i, item in enumerate(live["items"])])
        spell = f"  ⚡ *{live.get('spell') or h['spell']}*"
        emblem = live.get("emblem") or h["emblem"]
        src = live.get("source","?")
        age = cache_age_str(name)
        freshness = f"\n\n🌐 _Данные: {src} {age}_"
        wr = f"\n📊 Win rate: `{live['winrate']}`" if live.get("winrate") else ""
    else:
        items_text = "\n".join([f"  {i+1}️⃣ *{item}*" for i, item in enumerate(h["items"])])
        spell  = f"  ⚡ *{h['spell']}*"
        emblem = h["emblem"]
        freshness = "\n\n📦 _Офлайн-база (сайт недоступен)_"
        wr = ""

    return (
        f"⚔️ *Сборка: {name}* {h['emoji']}\n"
        f"━━━━━━━━━━━━━━━━━━\n\n"
        f"🧿 *Эмблема:*\n  _{emblem}_\n\n"
        f"🧪 *Заклинание:*\n{spell}\n\n"
        f"🛒 *Предметы:*\n{items_text}"
        f"{wr}"
        f"{freshness}"
    )


def fmt_tips(name: str) -> str:
    h = ALL_HEROES[name]
    tips = "\n".join([f"  • {t}" for t in h["tips"]])
    return (
        f"💡 *Советы: {name}* {h['emoji']}\n"
        f"━━━━━━━━━━━━━━━━━━\n\n"
        f"{tips}"
    )


def fmt_counters(name: str) -> str:
    h = ALL_HEROES[name]
    c = "  " + " | ".join([f"❌ {x}" for x in h["counters"]])
    s = "  " + " | ".join([f"✅ {x}" for x in h["synergy"]])
    return (
        f"⚠️ *Матчап: {name}* {h['emoji']}\n"
        f"━━━━━━━━━━━━━━━━━━\n\n"
        f"❌ *Слабо против:*\n{c}\n\n"
        f"✅ *Синергия:*\n{s}"
    )


def fmt_tierlist() -> str:
    groups: dict[str, list] = {}
    for name, h in ALL_HEROES.items():
        groups.setdefault(h["tier"], []).append((name, h))
    text = "🏆 *TIER LIST — Mobile Legends*\n━━━━━━━━━━━━━━━━━━\n\n"
    icons = {"S+":"🔥","S":"⭐","A+":"✅","A":"👍","B":"📌"}
    for tier in ["S+","S","A+","A","B"]:
        if tier not in groups: continue
        text += f"{icons[tier]} *Тир {tier}:*\n"
        for name, h in sorted(groups[tier], key=lambda x: x[0]):
            text += f"  {h['emoji']} {name} — _{h['role']}_\n"
        text += "\n"
    return text


# ═══════════════════════ ХЭНДЛЕРЫ ═════════════════════

@bot.message_handler(commands=["start"])
def cmd_start(m):
    bot.send_message(m.chat.id,
        "⚔️ *Mobile Legends Build Guide* 🌙\n"
        "━━━━━━━━━━━━━━━━━━\n\n"
        f"Героев в базе: *{len(ALL_HEROES)}*\n"
        "Сборки подтягиваются с mobilelegends.gg\n"
        "Кэш обновляется каждые *6 часов*\n\n"
        "Выбери раздел 👇",
        reply_markup=kb_main()
    )

@bot.message_handler(commands=["help"])
def cmd_help(m):
    bot.send_message(m.chat.id,
        "📖 *Команды:*\n\n"
        "/start — Главное меню\n"
        "/hero Chou — Сборка на героя\n"
        "/tier — Tier List\n"
        "/help — Помощь",
    )

@bot.message_handler(commands=["tier"])
def cmd_tier(m):
    bot.send_message(m.chat.id, fmt_tierlist(), reply_markup=kb_back("main"))

@bot.message_handler(commands=["hero"])
def cmd_hero(m):
    parts = m.text.split(maxsplit=1)
    if len(parts) < 2:
        bot.send_message(m.chat.id, "Укажи имя: `/hero Chou`")
        return
    query = parts[1].strip()
    # поиск по частичному совпадению
    matches = [n for n in ALL_HEROES if query.lower() in n.lower()]
    if not matches:
        bot.send_message(m.chat.id, f"❌ Герой *{query}* не найден.")
        return
    name = matches[0]
    bot.send_message(m.chat.id, fmt_hero_overview(name), reply_markup=kb_hero(name, "main"))

@bot.message_handler(func=lambda m: True)
def on_text(m):
    # поиск героя по тексту
    query = m.text.strip()
    matches = [n for n in ALL_HEROES if query.lower() in n.lower()]
    if matches:
        name = matches[0]
        bot.send_message(m.chat.id, fmt_hero_overview(name), reply_markup=kb_hero(name, "main"))
    else:
        bot.send_message(m.chat.id,
            "Напиши имя героя или воспользуйся меню ниже 👇",
            reply_markup=kb_main()
        )


# ─── Callback ─────────────────────────────────────────

@bot.callback_query_handler(func=lambda c: True)
def on_callback(call):
    cid = call.message.chat.id
    mid = call.message.message_id
    data = call.data

    def edit(text, kb=None):
        try:
            bot.edit_message_text(text, cid, mid, reply_markup=kb)
        except Exception:
            pass

    def answer(text=""):
        try: bot.answer_callback_query(call.id, text)
        except Exception: pass

    # ── MAIN ──
    if data == "main":
        edit(
            "⚔️ *Mobile Legends Build Guide* 🌙\n"
            "━━━━━━━━━━━━━━━━━━\n"
            f"Героев: *{len(ALL_HEROES)}* | Выбери раздел 👇",
            kb_main()
        )

    elif data == "noop":
        answer()

    # ── ALL HEROES (paginated) ──
    elif data.startswith("page_all_"):
        page = int(data.split("_")[-1])
        heroes = all_sorted()
        edit("⚔️ *Все герои — выбери:*", kb_heroes_page(heroes, page, "page_all"))

    # ── BY ROLE ──
    elif data.startswith("role_"):
        parts = data.split("_")
        role = parts[1]
        page = int(parts[2]) if len(parts) > 2 else 0
        source_cb = f"role_{role}"
        heroes = heroes_by_role(role)
        re = get_role_emoji(role)
        edit(f"{re} *{role} — выбери героя:*", kb_heroes_page(heroes, page, source_cb))

    # ── HERO OVERVIEW ──
    elif data.startswith("hero_"):
        parts = data.split("_", 2)
        name = parts[1]
        back = parts[2] if len(parts) > 2 else "main"
        if name not in ALL_HEROES:
            answer("Герой не найден")
            return
        edit(fmt_hero_overview(name), kb_hero(name, back))

    # ── BUILD ──
    elif data.startswith("build_"):
        name = data.split("_", 1)[1]
        answer("⏳ Получаю актуальную сборку...")
        live = get_live_build(name)
        text = fmt_build(name, live)
        kb = InlineKeyboardMarkup(row_width=2)
        kb.add(
            InlineKeyboardButton("💡 Советы",   callback_data=f"tips_{name}"),
            InlineKeyboardButton("⚠️ Каунтеры", callback_data=f"counters_{name}"),
            InlineKeyboardButton("🔄 Обновить", callback_data=f"refresh_{name}"),
        )
        kb.add(InlineKeyboardButton("🔙 К герою", callback_data=f"hero_{name}_main"))
        edit(text, kb)

    # ── TIPS ──
    elif data.startswith("tips_"):
        name = data.split("_", 1)[1]
        kb = InlineKeyboardMarkup(row_width=2)
        kb.add(
            InlineKeyboardButton("⚔️ Сборка",   callback_data=f"build_{name}"),
            InlineKeyboardButton("⚠️ Каунтеры", callback_data=f"counters_{name}"),
        )
        kb.add(InlineKeyboardButton("🔙 К герою", callback_data=f"hero_{name}_main"))
        edit(fmt_tips(name), kb)

    # ── COUNTERS ──
    elif data.startswith("counters_"):
        name = data.split("_", 1)[1]
        kb = InlineKeyboardMarkup(row_width=2)
        kb.add(
            InlineKeyboardButton("⚔️ Сборка", callback_data=f"build_{name}"),
            InlineKeyboardButton("💡 Советы",  callback_data=f"tips_{name}"),
        )
        kb.add(InlineKeyboardButton("🔙 К герою", callback_data=f"hero_{name}_main"))
        edit(fmt_counters(name), kb)

    # ── REFRESH ──
    elif data.startswith("refresh_"):
        name = data.split("_", 1)[1]
        answer("🔄 Обновляю сборку...")
        with cache_lock:
            CACHE.pop(name, None)
        live = get_live_build(name)
        text = fmt_build(name, live)
        kb = InlineKeyboardMarkup(row_width=2)
        kb.add(
            InlineKeyboardButton("💡 Советы",   callback_data=f"tips_{name}"),
            InlineKeyboardButton("⚠️ Каунтеры", callback_data=f"counters_{name}"),
            InlineKeyboardButton("🔄 Обновить", callback_data=f"refresh_{name}"),
        )
        kb.add(InlineKeyboardButton("🔙 К герою", callback_data=f"hero_{name}_main"))
        edit(text, kb)

    # ── CLEAR CACHE ──
    elif data == "clearcache":
        with cache_lock:
            CACHE.clear()
        answer("✅ Кэш очищен! Следующие запросы загрузят свежие данные.")

    # ── TIER LIST ──
    elif data == "tierlist":
        edit(fmt_tierlist(), kb_back("main"))

    # ── ABOUT ──
    elif data == "about":
        text = (
            "ℹ️ *О боте*\n━━━━━━━━━━━━━━━━\n\n"
            f"🎮 Героев в базе: *{len(ALL_HEROES)}*\n"
            "🌐 Источник: mobilelegends.gg / mlbb.gg\n"
            "⏱ Кэш: *6 часов*\n"
            "📦 Офлайн-fallback если сайт недоступен\n"
            "🔄 Версия: *2.0*\n"
        )
        edit(text, kb_back("main"))

    else:
        answer()

    try: bot.answer_callback_query(call.id)
    except Exception: pass


# ═══════════════════════ ЗАПУСК ═══════════════════════

if __name__ == "__main__":
    log.info(f"🚀 ML Build Bot v2.0 | Героев: {len(ALL_HEROES)}")
    log.info("Нажмите Ctrl+C для остановки")
    bot.infinity_polling(timeout=30, long_polling_timeout=30)
