import os
import time
import re
import logging
from typing import Any, Dict, List, Tuple, Optional
from urllib.parse import urlencode

import requests
from fastapi import FastAPI
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
INFLUX_USER = os.getenv("INFLUX_USER", "").strip()

INFLUX_PASS_FILE = os.getenv("INFLUX_PASS_FILE", "").strip()
INFLUX_PASS = os.getenv("INFLUX_PASS", "").strip()  # compatibility fallback

GEO_MEASUREMENT = os.getenv("GEO_MEASUREMENT", "geoip2influx")

HEATMAP_TIME_WINDOW = os.getenv("HEATMAP_TIME_WINDOW", "24h")
HEATMAP_REFRESH_SECONDS = int(os.getenv("HEATMAP_REFRESH_SECONDS", "30"))
HEATMAP_CACHE_SECONDS = int(os.getenv("HEATMAP_CACHE_SECONDS", "30"))
HEATMAP_MAX_POINTS = int(os.getenv("HEATMAP_MAX_POINTS", "20000"))
HEATMAP_TITLE = os.getenv("HEATMAP_TITLE", "").strip()

# Internal: base URL to InfluxDB v1
INFLUX_BASE = f"http://{INFLUX_HOST}:{INFLUX_HOST_PORT}".rstrip("/")

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
# in-memory cache for /data
# -----------------------------
_cache_at: float = 0.0
_cache_points: List[List[float]] = []  # [[lat, lon, weight], ...]
_cache_last_error: Optional[str] = None

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

    # Important debug visibility
    if DEBUG:
        log.debug("Influx GET %s", url)
        log.debug("InfluxQL: %s", q)

    r = requests.get(url, auth=_influx_auth(), timeout=10)

    # If non-2xx, log body (Influx often returns useful JSON errors)
    if r.status_code >= 400:
        body = r.text[:2000]
        log.error("Influx error: HTTP %s body=%s", r.status_code, body)
        r.raise_for_status()

    return r.json()


def _build_query() -> str:
    window = HEATMAP_TIME_WINDOW.strip()
    if not _DURATION_RE.match(window):
        log.warning("Invalid HEATMAP_TIME_WINDOW=%r, falling back to 24h", window)
        window = "24h"

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
    }


@APP.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    try:
        with open("/app/index.html", "r", encoding="utf-8") as f:
            return HTMLResponse(f.read())
    except FileNotFoundError:
        return HTMLResponse("<h1>index.html not found</h1>", status_code=500)


@APP.get("/data")
def data() -> JSONResponse:
    global _cache_at, _cache_points, _cache_last_error

    now = time.time()
    if HEATMAP_CACHE_SECONDS > 0 and (now - _cache_at) < HEATMAP_CACHE_SECONDS:
        if DEBUG:
            log.debug("GET /data cache-hit points=%s", len(_cache_points))
        return JSONResponse(_cache_points)

    q = _build_query()
    try:
        payload = _influx_query(q)
        pts = _parse_points(payload)
        _cache_points = pts
        _cache_last_error = None
        _cache_at = now

        log.info("GET /data points=%s", len(pts))
        if DEBUG and len(pts) == 0:
            log.warning("No points returned. Check Influx connection/auth/db/measurement/time_window.")
        return JSONResponse(_cache_points)

    except Exception as e:
        _cache_last_error = repr(e)
        log.exception("GET /data failed")
        _cache_points = []
        _cache_at = now

        # In debug, return more detail (still safe-ish: doesn't leak password)
        if DEBUG:
            return JSONResponse(
                {
                    "error": "influx_query_failed",
                    "exception": repr(e),
                    "influx_base": INFLUX_BASE,
                    "db": INFLUX_DATABASE,
                    "measurement": GEO_MEASUREMENT,
                    "window": HEATMAP_TIME_WINDOW,
                },
                status_code=502,
            )

        return JSONResponse([])


@APP.get("/debug/query", response_class=PlainTextResponse)
def debug_query() -> str:
    if not DEBUG:
        return "Not Found"
    return _build_query()


@APP.get("/debug/last_error", response_class=JSONResponse)
def debug_last_error() -> JSONResponse:
    if not DEBUG:
        return JSONResponse({"detail": "Not Found"}, status_code=404)
    return JSONResponse({"last_error": _cache_last_error})
