"""
weather_api.py  ★ 修正版
────────────────────────────────────────────────────────────────
放在：traffic_project/server/weather_api.py

JSON 路徑問題：
  - weather.py 在 scripts/ 執行，產出 scripts/data/chiayi_weather.json
  - FastAPI server 在 server/ 目錄跑
  - 用 __file__ 解析絕對路徑，不受工作目錄影響

掛載方式（在 server/main.py 最底部加）：
    from weather_api import router as weather_router
    app.include_router(weather_router)
────────────────────────────────────────────────────────────────
"""

import json
from pathlib import Path
from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse

router = APIRouter()

# ★ 核心修正：用 __file__ 計算絕對路徑
_THIS_FILE   = Path(__file__).resolve()      # .../server/weather_api.py
_SERVER_DIR  = _THIS_FILE.parent             # .../server/
_PROJECT_DIR = _SERVER_DIR.parent            # .../traffic_project/
_SCRIPTS_DIR = _PROJECT_DIR / "scripts"      # .../traffic_project/scripts/

# weather.py 的輸出：scripts/data/chiayi_weather.json
WEATHER_FILE = _SCRIPTS_DIR / "data" / "chiayi_weather.json"

# fallback：server/data/（方便本機測試）
_ALT_FILE    = _SERVER_DIR / "data" / "chiayi_weather.json"


def _get_weather_path() -> Path:
    if WEATHER_FILE.exists():
        return WEATHER_FILE
    if _ALT_FILE.exists():
        return _ALT_FILE
    return WEATHER_FILE  # 不存在時回傳主路徑，讓 endpoint 報正確錯誤


@router.get("/weather", summary="取得嘉義最新天氣資料")
async def get_weather():
    path = _get_weather_path()
    if not path.exists():
        raise HTTPException(
            status_code=503,
            detail=f"天氣資料尚未產生，請先執行 scripts/weather.py。預期路徑：{WEATHER_FILE}"
        )
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return JSONResponse(content=data)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"讀取天氣資料失敗: {e}")


@router.get("/weather/{location_id}", summary="取得特定地區天氣")
async def get_weather_by_location(location_id: str):
    path = _get_weather_path()
    if not path.exists():
        raise HTTPException(status_code=503, detail="天氣資料尚未產生")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        matches = [d for d in data if d.get("LocationID", "").startswith(location_id)]
        if not matches:
            raise HTTPException(status_code=404, detail=f"找不到 LocationID 以 '{location_id}' 開頭的資料")
        return JSONResponse(content=matches[0])
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))