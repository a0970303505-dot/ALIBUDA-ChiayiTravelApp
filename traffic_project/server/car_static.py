"""
car_static.py  ─ 停車場靜態資料一次性產生腳本
用途：只跑一次，產生 assets/data/parking_static.json，之後不需要再打 TDX API。
執行：python car_static.py
"""
import json, re, requests, time, os
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ================== 設定區 ==================
CLIENT_ID        = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET    = 'YOUR_TDX_CLIENT_SECRET'
OUTPUT_FILENAME  = "assets/data/parking_static.json"   # ← 直接寫進 Flutter assets
IPARKING_URL     = "https://iparking.chiayi.gov.tw/car/open"
# ============================================

def get_access_token():
    url = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
    r = requests.post(
        url,
        headers={"content-type": "application/x-www-form-urlencoded"},
        data={"grant_type": "client_credentials", "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET},
        timeout=10)
    if r.status_code == 200:
        return r.json().get("access_token")
    raise RuntimeError(f"Token 失敗 HTTP {r.status_code}")

def build_static_map(token):
    print("📡 下載 TDX 靜態停車場資料...")
    url = "https://tdx.transportdata.tw/api/basic/v1/Parking/OffStreet/CarPark/City/Chiayi"
    wait = 15
    for attempt in range(6):
        r = requests.get(
            url,
            headers={"authorization": f"Bearer {token}", "Accept": "application/json"},
            params={"$format": "JSON", "$top": 1000},
            timeout=15)
        if r.status_code == 200:
            break
        elif r.status_code == 429:
            print(f"⚠️ 429 限流，等待 {wait} 秒（第 {attempt+1}/6）...")
            time.sleep(wait); wait = min(wait * 2, 300)
        else:
            raise RuntimeError(f"TDX 回傳 {r.status_code}")
    else:
        raise RuntimeError("TDX 重試全部失敗")

    raw = r.json()
    if isinstance(raw, dict):
        for key in ("CarParks", "data", "carparks", "items", "results"):
            if key in raw and isinstance(raw[key], list):
                raw = raw[key]; break
        else:
            for k, v in raw.items():
                if isinstance(v, list) and v:
                    raw = v; break

    def zh(v, fb=""):
        if isinstance(v, dict):
            text = v.get("Zh_tw") or v.get("zh_tw") or v.get("ZhTw") or ""
            return text.strip() or fb
        return str(v).strip() if v else fb

    def zh_name(v, fb=""):
        raw_text = zh(v, fb)
        main = re.sub(r'[（(].*?[）)]', '', raw_text).strip()
        return main if main else raw_text

    def flag_to_num(v):
        return 1 if v == 1 else 0

    static_map = {}
    for p in raw:
        pid = p.get("CarParkID")
        if not pid: continue
        pos = p.get("CarParkPosition") or {}
        lat = pos.get("PositionLat")
        lon = pos.get("PositionLon")
        # 沒座標的場站，地圖上無法顯示，直接跳過
        if lat is None or lon is None:
            continue

        total = sum(a.get("SpacesTotal", 0) or 0 for a in p.get("ParkingAreas", []))
        if total == 0:
            total = p.get("SpacesTotal", 0) or 0

        static_map[pid] = {
            "CarParkID":               str(pid),
            "CarParkName":             zh_name(p.get("CarParkName"), "未命名停車場"),
            "CarParkType":             {0:"平面",1:"立體",2:"地下",3:"機械式",4:"路邊"}.get(p.get("CarParkType",-1), "其他"),
            "Description":             zh(p.get("Description"), "沒有詳細介紹"),
            "Address":                 zh(p.get("Address"), "無提供地址"),
            "PositionLat":             float(lat),
            "PositionLon":             float(lon),
            "SpaceTotal":              int(total),
            "FareDescription":         zh(p.get("FareDescription"), "詳見現場公告"),
            "LiveOccuppancyAvailable": flag_to_num(p.get("LiveOccuppancyAvailable", -1)),
            "OperationType":           {1:"公辦民營",2:"公營",3:"民營"}.get(p.get("OperationType",-1), "其他"),
            "EVRechargingAvailable":   flag_to_num(p.get("EVRechargingAvailable", -1)),
            "Toilet":                  flag_to_num(p.get("Toilet", -1)),
            "Telephone":               p.get("Telephone") or "無電話資訊",
            # 靜態檔案不含即時剩餘車位，Flutter 顯示 "--"
            "RemainingSpace":          None,
        }
    print(f"✅ 共取得 {len(static_map)} 座有座標的停車場")
    return static_map

def main():
    token = get_access_token()
    static_map = build_static_map(token)
    result = list(static_map.values())

    os.makedirs(os.path.dirname(OUTPUT_FILENAME), exist_ok=True)
    with open(OUTPUT_FILENAME, 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"💾 已儲存至 {OUTPUT_FILENAME}（{len(result)} 筆）")
    print("👉 請將此檔案加入 pubspec.yaml 的 assets 清單！")

if __name__ == "__main__":
    main()