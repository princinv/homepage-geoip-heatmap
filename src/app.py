import os
import time
import re
from typing import Any, Dict, List, Tuple, Optional
from urllib.parse import urlencode

import requests
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

APP = FastAPI(title="homepage-geoip-heatmap")

# -----------------------------
# Env (reusing SWAG/geoip2influx where possible)
# -----------------------------
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
# in-memory cache for /data
# -----------------------------
_cache_at: float = 0.0
_cache_points: List[List[float]] = []  # [[lat, lon, weight], ...]

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
            return ""
    return ""


def _influx_auth() -> Optional[Tuple[str, str]]:
    if not INFLUX_USER:
        return None
    pw = _read_influx_password()
    # If user is set but no pw, still return auth tuple (some setups allow empty pw)
    return (INFLUX_USER, pw)


def _influx_query(q: str) -> Dict[str, Any]:
    # InfluxDB v1 HTTP API: /query?db=<db>&q=<influxql>
    params = {"db": INFLUX_DATABASE, "q": q}
    url = f"{INFLUX_BASE}/query?{urlencode(params)}"
    r = requests.get(url, auth=_influx_auth(), timeout=10)
    r.raise_for_status()
    return r.json()


def _build_query() -> str:
    # Your schema: latitude/longitude are TAGS, count is the FIELD.
    # Aggregate by lat/lon over the selected window.
    window = HEATMAP_TIME_WINDOW.strip()
    if not _DURATION_RE.match(window):
        # Fall back to safe default if someone sets garbage
        window = "24h"

    meas = GEO_MEASUREMENT.replace('"', "")  # safety
    return (
        f'SELECT SUM("count") AS hits '
        f'FROM "{meas}" '
        f'WHERE time > now() - {window} '
        f'GROUP BY "latitude","longitude"'
    )


def _parse_points(payload: Dict[str, Any]) -> List[List[float]]:
    """
    Convert Influx response to Leaflet.heat points:
      [[lat, lon, weight], ...]
    Influx groups by tags => each series has tags.latitude/tags.longitude
    and values like [time, hits]
    """
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
        # row: [time, hits]
        hits = 0.0
        if values and len(values[0]) >= 2 and values[0][1] is not None:
            try:
                hits = float(values[0][1])
            except (ValueError, TypeError):
                hits = 0.0

        if hits > 0:
            points.append([lat, lon, hits])

    # safety cap: keep highest weights
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
    # Serve the repo’s src/index.html verbatim TODO: keeps the door open for assets later.
    try:
        with open("/app/index.html", "r", encoding="utf-8") as f:
            return HTMLResponse(f.read())
    except FileNotFoundError:
        return HTMLResponse("<h1>index.html not found</h1>", status_code=500)


@APP.get("/data")
def data() -> JSONResponse:
    global _cache_at, _cache_points

    now = time.time()
    if HEATMAP_CACHE_SECONDS > 0 and (now - _cache_at) < HEATMAP_CACHE_SECONDS:
        return JSONResponse(_cache_points)

    q = _build_query()
    try:
        payload = _influx_query(q)
        pts = _parse_points(payload)
    except Exception:
        pts = []

    _cache_points = pts
    _cache_at = now
    return JSONResponse(_cache_points)


# Optional: helpful for quick debugging without logs
@APP.get("/debug/query", response_class=PlainTextResponse)
def debug_query() -> str:
    return _build_query()
