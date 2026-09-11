"""
嘉義市交通資訊 API Server  v2（緩存版）
啟動方式: uvicorn main:app --host 0.0.0.0 --port 8000 --reload
目錄結構:
    project/
    ├── data/           ← JSON 檔案（bus_realtime.json 等）
    ├── scripts/        ← 爬蟲腳本
    └── server/
        ├── main.py     ← 本檔
        └── cache_manager.py
"""

import json
import time
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .cache_manager import cache   # ← server/ 同目錄

# ── 資料目錄：server/ 的上一層再進 data/ ──────────────────────
DATA_DIR = Path(__file__).parent.parent / "data"

# ── weather.py 把結果存在 scripts/data/，單獨指定 ──────────────
WEATHER_FILE = Path(__file__).parent.parent / "scripts" / "data" / "chiayi_weather.json"

# ── 各資料的緩存 TTL（秒）────────────────────────────────────
#   公車/停車：資料變化快，60 秒
#   火車：爬蟲 45 秒跑一次，server 緩存 90 秒就夠
#   YouBike：爬蟲 5 分鐘跑一次，server 緩存 180 秒
#   天氣：10 分鐘爬一次，600 秒
TTL = {
    "bus":     60,
    "train":   90,
    "ubike":   180,
    "parking": 60,
    "weather": 600,
}

app = FastAPI(
    title="嘉義市交通資訊 API",
    description="提供公車、火車、YouBike、停車場、天氣即時資料（含 server 端緩存）",
    version="2.0.0"
)

# ── 允許跨域（Android / Flutter 全部放行）──────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)


# ════════════════════════════════════════════════════════════════
#  共用工具
# ════════════════════════════════════════════════════════════════

def read_json_cached(key: str, filename: str, force: bool = False, custom_path: Path = None):
    """
    先查記憶體緩存，有效期內直接回傳。
    force=True 或過期才重讀 JSON 檔案。
    custom_path: 指定完整路徑，不使用 DATA_DIR（weather 用）。
    ★ 讀到空資料（爬蟲 429 跳過寫檔的那輪）時，繼續用舊緩存，不更新。
    回傳 (data, meta)。
    """
    if force:
        cache.invalidate(key)

    data, meta = cache.get(key)
    if data is not None:
        return data, meta   # ✅ 緩存命中，不碰磁碟

    # ── 緩存 MISS：讀 JSON 檔 ──────────────────────────────────
    path = custom_path if custom_path is not None else DATA_DIR / filename
    if not path.exists():
        raise HTTPException(
            status_code=503,
            detail=f"資料尚未產生，請先執行對應的爬蟲腳本（{filename}）"
        )
    try:
        with open(path, encoding="utf-8") as f:
            new_data = json.load(f)
    except json.JSONDecodeError as e:
        # JSON 格式壞掉（可能爬蟲正在寫到一半）→ 繼續用舊緩存
        if data is not None:
            print(f"⚠️ [{key}] JSON 解析失敗，繼續用舊緩存：{e}")
            return data, meta
        raise HTTPException(status_code=500, detail=f"JSON 解析失敗: {e}")

    # ★ 空資料保護：list 為空 or dict 的主要陣列為空 → 不更新緩存，繼續用舊的
    is_empty = False
    if isinstance(new_data, list) and len(new_data) == 0:
        is_empty = True
    elif isinstance(new_data, dict):
        # 公車格式：{"Vehicles":[], "Routes":[]} 兩個都空才算空
        vehicles = new_data.get("Vehicles") or new_data.get("data") or []
        if isinstance(vehicles, list) and len(vehicles) == 0:
            is_empty = True

    if is_empty:
        old_data, old_meta = cache.get(key)
        if old_data is not None:
            print(f"⚠️ [{key}] 讀到空資料，繼續用舊緩存（可能爬蟲正在 429 等待中）")
            return old_data, old_meta
        # 沒有舊緩存就只能回傳空資料
        print(f"⚠️ [{key}] 讀到空資料且無舊緩存，回傳空")

    cache.set(key, new_data, TTL.get(key, 60))
    _, meta = cache.get(key)
    return new_data, meta


def _wrap(data, meta) -> dict:
    """
    把 _cache 元資訊注入 response payload。
    - data 是 dict（公車格式含 Vehicles/Routes）：直接加 _cache key
    - data 是 list：包成 { "data": [...], "_cache": {...} }
    Flutter 的 TrafficApiService._cachedGet 會依此格式拆開。
    """
    cache_info = {
        "fetched_at":        meta["fetched_at"],
        "age_seconds":       meta["age_seconds"],
        "remaining_seconds": meta["remaining_seconds"],
        "ttl_seconds":       meta["ttl_seconds"],
        "from_cache":        meta["from_cache"],
    }
    if isinstance(data, dict):
        return {**data, "_cache": cache_info}
    return {"data": data, "_cache": cache_info}


# ════════════════════════════════════════════════════════════════
#  路由
# ════════════════════════════════════════════════════════════════

@app.get("/", summary="Server 健康確認")
def root():
    return {
        "status":  "ok",
        "message": "嘉義市交通資訊 API Server v2 運作中 🚀",
        "data_dir": str(DATA_DIR),
        "cache_keys": list(TTL.keys()),
    }


@app.get("/api/bus", summary="公車即時動態")
def get_bus(force: bool = False):
    """
    ?force=true 跳過緩存，強制重讀 JSON 檔案。
    格式：{ "Vehicles": [...], "Routes": [...], "_cache": {...} }
    """
    data, meta = read_json_cached("bus", "bus_realtime.json", force=force)
    return JSONResponse(content=_wrap(data, meta))


@app.get("/api/train", summary="台鐵列車即時動態")
def get_train(force: bool = False):
    """格式：{ "data": [...], "_cache": {...} }"""
    data, meta = read_json_cached("train", "train_realtime.json", force=force)
    return JSONResponse(content=_wrap(data, meta))


@app.get("/api/ubike", summary="YouBike 2.0 即時站點")
def get_ubike(force: bool = False):
    data, meta = read_json_cached("ubike", "ubike_realtime.json", force=force)
    return JSONResponse(content=_wrap(data, meta))


@app.get("/api/parking", summary="停車場即時剩餘車位")
def get_parking(force: bool = False):
    data, meta = read_json_cached("parking", "parking_realtime.json", force=force)
    return JSONResponse(content=_wrap(data, meta))


@app.get("/api/weather", summary="嘉義縣市天氣預報")
def get_weather(force: bool = False):
    data, meta = read_json_cached("weather", "chiayi_weather.json", force=force, custom_path=WEATHER_FILE)
    return JSONResponse(content=_wrap(data, meta))


# ── 聚合端點（Dashboard 用）──────────────────────────────────
@app.get("/api/all", summary="聚合端點：一次取得全部資料")
def get_all():
    """
    一次取得所有資料，各子項目都走各自的緩存。
    任一項目不存在時該 key 回傳 null，不影響其他項目。
    """
    mapping = {
        "bus":     ("bus_realtime.json",     None),
        "train":   ("train_realtime.json",   None),
        "ubike":   ("ubike_realtime.json",   None),
        "parking": ("parking_realtime.json", None),
        "weather": ("chiayi_weather.json",   WEATHER_FILE),
    }
    result = {}
    for key, (filename, custom_path) in mapping.items():
        try:
            data, meta = read_json_cached(key, filename, custom_path=custom_path)
            result[key] = _wrap(data, meta)
        except HTTPException:
            result[key] = None
    return JSONResponse(content=result)


# ════════════════════════════════════════════════════════════════
#  緩存診斷端點（開發 / 除錯用）
# ════════════════════════════════════════════════════════════════

@app.get("/api/cache/status", summary="查看各 key 緩存狀態")
def cache_status():
    """
    回傳各 key 的 age_seconds、remaining_seconds、ttl_seconds。
    age_seconds 持續增加但不超過 TTL，代表緩存正常運作。
    """
    return {
        "server_time": time.strftime("%Y-%m-%dT%H:%M:%S+08:00"),
        "data_dir":    str(DATA_DIR),
        "dir_exists":  DATA_DIR.exists(),
        "keys":        cache.status(),
    }


@app.get("/api/cache/invalidate/{key}", summary="手動清除某 key 的緩存")
def cache_invalidate(key: str):
    """清除後下次請求會強制重讀 JSON 檔案。"""
    if key not in TTL and key != "all":
        raise HTTPException(status_code=404, detail=f"未知的 key: {key}，可用: {list(TTL.keys())}")
    if key == "all":
        for k in TTL:
            cache.invalidate(k)
        return {"invalidated": list(TTL.keys())}
    cache.invalidate(key)
    return {"invalidated": key}


@app.get("/health", summary="Server 健康 + 各 JSON 檔案狀態")
def health():
    """確認各爬蟲 JSON 檔案存在且是否過舊。"""
    files = {}
    file_map = {
        "bus":     (DATA_DIR / "bus_realtime.json"),
        "train":   (DATA_DIR / "train_realtime.json"),
        "ubike":   (DATA_DIR / "ubike_realtime.json"),
        "parking": (DATA_DIR / "parking_realtime.json"),
        "weather": WEATHER_FILE,   # scripts/data/
    }
    for name, path in file_map.items():
        if path.exists():
            age = int(time.time() - os.path.getmtime(path))
            files[name] = {
                "exists":      True,
                "age_seconds": age,
                "size_kb":     round(path.stat().st_size / 1024, 1),
                "stale":       age > TTL.get(name, 60) * 3,
            }
        else:
            files[name] = {"exists": False}

    return {
        "status":    "ok",
        "data_dir":  str(DATA_DIR),
        "files":     files,
        "cache":     cache.status(),
    }