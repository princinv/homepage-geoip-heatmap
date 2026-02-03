import os
import time
import re
import logging
from typing import Any, Dict, List, Tuple, Optional
from urllib.parse import urlencode
from pathlib import Path

import requests
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from rich.logging import RichHandler

APP = FastAPI(title="homepage-geoip-heatmap")

# -----------------------------
# Env (reusing SWAG/geoip2influx where possible)
# -----------------------------
DEBUG = os.getenv("DEBUG", "false").strip().lower() in {"1", "true", "yes", "on"}

INFLUX_HOST = os.getenv("INFLUX_HOST", "influxdb")
INFLUX_HOST_PORT = int(os.getenv("INFLUX_HOST_PORT", "8086"))
INFLUX_DATABASE = os.getenv("INFLUX_DATABASE", "geoip2influx")
INFLUX_USER = os.getenv("INFLUX_USER", "influxer").strip()

INFLUX_PASS_FILE = os.getenv("INFLUX_PASS_FILE", "/run/secrets/influxdbv1_pass").strip()
INFLUX_PASS = os.getenv("INFLUX_PASS", "").strip()  # compatibility fallback

# Internal: base URL to InfluxDB v1
INFLUX_BASE = f"http://{INFLUX_HOST}:{INFLUX_HOST_PORT}".rstrip("/")

GEO_MEASUREMENT = os.getenv("GEO_MEASUREMENT", "geoip2influx")

HEATMAP_TIME_WINDOW = os.getenv("HEATMAP_TIME_WINDOW", "24h")
HEATMAP_REFRESH_SECONDS = int(os.getenv("HEATMAP_REFRESH_SECONDS", "30"))
HEATMAP_CACHE_SECONDS = int(os.getenv("HEATMAP_CACHE_SECONDS", "30"))
HEATMAP_MAX_POINTS = int(os.getenv("HEATMAP_MAX_POINTS", "20000"))
HEATMAP_TITLE = os.getenv("HEATMAP_TITLE", "").strip()

THEME_MODE = os.getenv("THEME_MODE", "auto").strip().lower()
if THEME_MODE not in {"auto", "dark", "light"}:
    THEME_MODE = "auto"

# -----------------------------
# Logging (pretty + simple)
# -----------------------------
LOG_LEVEL = "DEBUG" if DEBUG else os.getenv("LOG_LEVEL", "INFO").strip().upper()

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(message)s",
    datefmt="[%X]",
    handlers=[RichHandler(rich_tracebacks=True, markup=True)],
)
log = logging.getLogger("homepage-geoip-heatmap")

log.info("[bold]Starting homepage-geoip-heatmap[/bold]")
log.info(
    "Influx target: base=%s db=%s measurement=%s user=%s window=%s",
    INFLUX_BASE,
    INFLUX_DATABASE,
    GEO_MEASUREMENT,
    (INFLUX_USER if INFLUX_USER else "(none)"),
    HEATMAP_TIME_WINDOW,
)
log.info("Debug mode: %s", DEBUG)

# -----------------------------
# Static files (/static/*)
# -----------------------------
STATIC_DIR_CANDIDATES = [
    os.getenv("STATIC_DIR", "/app/static").strip(),
    "/app/src/static",
]

_static_dir = None
for d in STATIC_DIR_CANDIDATES:
    if Path(d).is_dir() and Path(d, "countries.geojson").is_file():
        _static_dir = d
        break

if _static_dir:
    APP.mount("/static", StaticFiles(directory=_static_dir), name="static")
    log.info("Serving static files from %s at /static", _static_dir)
else:
    log.warning("Static dir missing (no countries.geojson found). Checked: %s", STATIC_DIR_CANDIDATES)

# -----------------------------
# Caches
# -----------------------------
_cache_points_by_window: Dict[str, Tuple[float, List[List[float]]]] = {}
_country_cache_by_window: Dict[str, Tuple[float, Dict[str, float]]] = {}

_cache_last_error_by_window: Dict[str, str] = {}
_country_cache_last_error_by_window: Dict[str, str] = {}

# duration check to avoid accidental query injection via env
_DURATION_RE = re.compile(r"^[0-9]+(ms|s|m|h|d|w)$")


def _read_influx_password() -> str:
    if INFLUX_PASS:
        return INFLUX_PASS
    if INFLUX_PASS_FILE:
        try:
            with open(INFLUX_PASS_FILE, "r", encoding="utf-8") as f:
                return f.read().strip()
        except FileNotFoundError:
            log.warning("INFLUX_PASS_FILE not found: %s", INFLUX_PASS_FILE)
            return ""
    return ""


def _influx_auth() -> Optional[Tuple[str, str]]:
    if not INFLUX_USER:
        return None
    pw = _read_influx_password()
    return (INFLUX_USER, pw)


def _influx_query(q: str) -> Dict[str, Any]:
    params = {"db": INFLUX_DATABASE, "q": q}
    url = f"{INFLUX_BASE}/query?{urlencode(params)}"

    if DEBUG:
        log.debug("Influx GET %s", url)
        log.debug("InfluxQL: %s", q)

    r = requests.get(url, auth=_influx_auth(), timeout=10)

    if r.status_code >= 400:
        body = r.text[:2000]
        log.error("Influx error: HTTP %s body=%s", r.status_code, body)
        r.raise_for_status()

    return r.json()


def _sanitize_window(window_raw: Optional[str]) -> str:
    window = (window_raw or HEATMAP_TIME_WINDOW).strip()
    if not _DURATION_RE.match(window):
        log.warning("Invalid window=%r, falling back to %s", window, HEATMAP_TIME_WINDOW)
        window = HEATMAP_TIME_WINDOW.strip()
        if not _DURATION_RE.match(window):
            window = "24h"
    return window

def _build_query_points(window_raw: Optional[str]) -> str:
    window = _sanitize_window(window_raw)
    meas = GEO_MEASUREMENT.replace('"', "")
    return (
        f'SELECT SUM("count") AS hits '
        f'FROM "{meas}" '
        f'WHERE time > now() - {window} '
        f'GROUP BY "latitude","longitude"'
    )


def _parse_points(payload: Dict[str, Any]) -> List[List[float]]:
    points: List[List[float]] = []

    results = payload.get("results") or []
    if not results:
        return points

    series_list = results[0].get("series") or []
    for s in series_list:
        tags = s.get("tags") or {}
        lat_s = tags.get("latitude")
        lon_s = tags.get("longitude")
        if lat_s is None or lon_s is None:
            continue

        try:
            lat = float(lat_s)
            lon = float(lon_s)
        except (ValueError, TypeError):
            continue

        values = s.get("values") or []
        hits = 0.0
        if values and len(values[0]) >= 2 and values[0][1] is not None:
            try:
                hits = float(values[0][1])
            except (ValueError, TypeError):
                hits = 0.0

        if hits > 0:
            points.append([lat, lon, hits])

    if HEATMAP_MAX_POINTS and HEATMAP_MAX_POINTS > 0 and len(points) > HEATMAP_MAX_POINTS:
        points.sort(key=lambda p: p[2], reverse=True)
        points = points[:HEATMAP_MAX_POINTS]

    return points

def _build_query_countries(window_raw: Optional[str]) -> str:
    window = _sanitize_window(window_raw)
    meas = GEO_MEASUREMENT.replace('"', "")
    return (
        f'SELECT SUM("count") AS hits '
        f'FROM "{meas}" '
        f'WHERE time > now() - {window} '
        f'GROUP BY "country_code"'
    )


def _parse_country_hits(payload: Dict[str, Any]) -> Dict[str, float]:
    out: Dict[str, float] = {}

    results = payload.get("results") or []
    if not results:
        return out

    series_list = results[0].get("series") or []
    for s in series_list:
        tags = s.get("tags") or {}
        cc = tags.get("country_code")
        if not cc:
            continue

        values = s.get("values") or []
        hits = 0.0
        if values and len(values[0]) >= 2 and values[0][1] is not None:
            try:
                hits = float(values[0][1])
            except (ValueError, TypeError):
                hits = 0.0

        if hits > 0:
            out[str(cc).upper()] = hits

    return out


@APP.get("/healthz")
def healthz() -> Dict[str, bool]:
    return {"ok": True}


@APP.get("/config")
def config() -> Dict[str, Any]:
    return {
        "title": HEATMAP_TITLE,
        "refresh_seconds": HEATMAP_REFRESH_SECONDS,
        "time_window": HEATMAP_TIME_WINDOW,
        "max_points": HEATMAP_MAX_POINTS,
        "theme_mode": THEME_MODE,
    }


@APP.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    try:
        with open("/app/index.html", "r", encoding="utf-8") as f:
            return HTMLResponse(f.read())
    except FileNotFoundError:
        return HTMLResponse("<h1>index.html not found</h1>", status_code=500)


@APP.get("/data")
def data(window: Optional[str] = None) -> JSONResponse:
    now = time.time()
    win = _sanitize_window(window)

    cached = _cache_points_by_window.get(win)
    if cached and HEATMAP_CACHE_SECONDS > 0 and (now - cached[0]) < HEATMAP_CACHE_SECONDS:
        if DEBUG:
            log.debug("GET /data cache-hit window=%s points=%s", win, len(cached[1]))
        return JSONResponse(cached[1])

    q = _build_query_points(win)
    try:
        payload = _influx_query(q)
        pts = _parse_points(payload)
        _cache_points_by_window[win] = (now, pts)
        _cache_last_error_by_window.pop(win, None)
        log.info("GET /data window=%s points=%s", win, len(pts))
        return JSONResponse(pts)
    except Exception as e:
        _cache_last_error_by_window[win] = repr(e)
        log.exception("GET /data failed window=%s", win)
        _cache_points_by_window[win] = (now, [])
        return JSONResponse(
            [] if not DEBUG else {"error": "influx_query_failed", "exception": repr(e), "window": win},
            status_code=502 if DEBUG else 200,
        )


@APP.get("/data/countries")
def data_countries(window: Optional[str] = None) -> JSONResponse:
    now = time.time()
    win = _sanitize_window(window)

    cached = _country_cache_by_window.get(win)
    if cached and HEATMAP_CACHE_SECONDS > 0 and (now - cached[0]) < HEATMAP_CACHE_SECONDS:
        if DEBUG:
            log.debug("GET /data/countries cache-hit window=%s countries=%s", win, len(cached[1]))
        return JSONResponse(cached[1])

    q = _build_query_countries(win)
    try:
        payload = _influx_query(q)
        hits = _parse_country_hits(payload)
        _country_cache_by_window[win] = (now, hits)
        _country_cache_last_error_by_window.pop(win, None)
        log.info("GET /data/countries window=%s countries=%s", win, len(hits))
        return JSONResponse(hits)
    except Exception as e:
        _country_cache_last_error_by_window[win] = repr(e)
        log.exception("GET /data/countries failed window=%s", win)
        _country_cache_by_window[win] = (now, {})
        return JSONResponse(
            {} if not DEBUG else {"error": "influx_query_failed", "exception": repr(e), "window": win, "query": q},
            status_code=502 if DEBUG else 200,
        )


@APP.get("/debug/query", response_class=PlainTextResponse)
def debug_query() -> str:
    if not DEBUG:
        return "Not Found"
    return _build_query_points()


@APP.get("/debug/query/countries", response_class=PlainTextResponse)
def debug_query_countries() -> str:
    if not DEBUG:
        return "Not Found"
    return _build_query_countries()
