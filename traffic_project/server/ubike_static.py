"""
ubike_static.py  ─ YouBike 站點靜態資料一次性產生腳本
用途：只跑一次，產生 assets/data/ubike_static.json（站點名稱+座標）
      即時可借/可還數量因為常變動，靜態檔案不包含，Flutter 顯示 "--"
執行：python ubike_static.py
"""
import requests, json, os, time

CLIENT_ID     = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET = 'YOUR_TDX_CLIENT_SECRET'
OUTPUT_FILE   = "assets/data/ubike_static.json"

def get_token():
    r = requests.post(
        "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token",
        headers={"content-type": "application/x-www-form-urlencoded"},
        data={"grant_type": "client_credentials", "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET})
    if r.status_code == 200:
        return r.json()["access_token"]
    raise RuntimeError(f"Token 失敗 {r.status_code}")

def fetch_with_retry(url, headers, max_retry=5):
    wait = 10
    for i in range(max_retry):
        r = requests.get(url, headers=headers, timeout=20)
        if r.status_code == 200:
            return r.json()
        if r.status_code == 429:
            print(f"⚠️ 429 限流，等待 {wait} 秒（第 {i+1}/{max_retry}）...")
            time.sleep(wait); wait = min(wait * 2, 120)
        else:
            raise RuntimeError(f"HTTP {r.status_code}")
    raise RuntimeError("重試全部失敗")

def main():
    print("🔑 取得 TDX Token...")
    token = get_token()
    headers = {"authorization": f"Bearer {token}"}

    print("📡 下載站點基本資料（名稱 + 座標）...")
    stations = fetch_with_retry(
        "https://tdx.transportdata.tw/api/basic/v2/Bike/Station/City/Chiayi?$format=JSON",
        headers)

    result = []
    missing = 0
    for s in stations:
        uid = s.get("StationUID", "")
        name_obj = s.get("StationName", {})
        name = name_obj.get("Zh_tw", "") if isinstance(name_obj, dict) else str(name_obj)
        pos = s.get("StationPosition") or {}
        lat = pos.get("PositionLat")
        lon = pos.get("PositionLon")

        if lat is None or lon is None:
            missing += 1
            continue   # 沒座標直接跳過

        result.append({
            "StationUID":           uid,
            "StationName":          name,
            "PositionLat":          float(lat),
            "PositionLon":          float(lon),
            # 靜態檔案不含即時數量，預設 -1 讓 Flutter 顯示 "--"
            "AvailableRentBikes":   -1,
            "AvailableReturnBikes": -1,
            "ServiceStatus":        1,
        })

    print(f"✅ 共 {len(result)} 個站點（跳過 {missing} 個無座標）")
    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"💾 已儲存至 {OUTPUT_FILE}")
    print("👉 請將此檔案加入 pubspec.yaml 的 assets 清單！")

if __name__ == "__main__":
    main()