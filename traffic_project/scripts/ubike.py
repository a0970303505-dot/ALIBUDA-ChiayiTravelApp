import requests
import json
import time
from datetime import datetime, timezone, timedelta


TW_TZ = timezone(timedelta(hours=8))

def tw_now() -> datetime:
    """取台灣時間，優先用 NTP"""
    try:
        import ntplib
        c = ntplib.NTPClient()
        resp = c.request('pool.ntp.org', version=3, timeout=5)
        return datetime.fromtimestamp(resp.tx_time, tz=TW_TZ)
    except Exception:
        return datetime.now(tz=TW_TZ)

CLIENT_ID = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET = 'YOUR_TDX_CLIENT_SECRET'

def get_tdx_token():
    """負責向 TDX 申請 Access Token"""
    auth_url = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
    auth_headers = {'content-type': 'application/x-www-form-urlencoded'}
    auth_data = {
        'grant_type': 'client_credentials',
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET
    }
    print("🔄 正在向 TDX 申請/更新 Access Token...")
    response = requests.post(auth_url, data=auth_data, headers=auth_headers)
    if response.status_code == 200:
        print("✅ 成功取得 Token！")
        return response.json().get('access_token')
    else:
        print(f"❌ 取得 Token 失敗: {response.status_code}, {response.text}")
        return None

def fetch_station_info(access_token):
    """抓取嘉義市 YouBike 站點基本資料（含中文站名＋座標）"""
    url = "https://tdx.transportdata.tw/api/basic/v2/Bike/Station/City/Chiayi?$format=JSON"
    headers = {'authorization': f'Bearer {access_token}'}
    response = requests.get(url, headers=headers)
    if response.status_code == 200:
        return response.json()
    print(f"❌ 站點資訊抓取失敗: {response.status_code}")
    return []

def merge_ubike_data(stations, availability):
    """
    合併站點基本資料與即時狀態。
    注入：中文站名、PositionLat、PositionLon
    """
    # 建立 UID → {name, lat, lon} 對照表
    station_map = {}
    for s in stations:
        uid = s.get('StationUID', '')
        name_obj = s.get('StationName', {})
        zh_name = name_obj.get('Zh_tw', '') if isinstance(name_obj, dict) else str(name_obj)

        # ✅ 座標在 StationPosition 裡
        pos = s.get('StationPosition', {}) or {}
        lat = pos.get('PositionLat')
        lon = pos.get('PositionLon')

        if uid:
            station_map[uid] = {
                'name': zh_name,
                'lat':  lat,
                'lon':  lon,
            }

    # 將站名與座標注入即時狀態資料
    merged = []
    missing_coords = 0
    for item in availability:
        uid  = item.get('StationUID', '')
        info = station_map.get(uid, {})

        item['StationName']  = info.get('name', '')
        item['PositionLat']  = info.get('lat')   # float 或 None
        item['PositionLon']  = info.get('lon')   # float 或 None

        if item['PositionLat'] is None:
            missing_coords += 1

        merged.append(item)

    if missing_coords:
        print(f"  ⚠️  {missing_coords} 個站點座標為 None（可能 TDX 資料不完整）")

    return merged


if __name__ == '__main__':
    print("=== 啟動 TDX YouBike 即時監控系統（含中文站名＋座標）===")

    current_token = get_tdx_token()
    if not current_token:
        print("初始化失敗，程式結束。")
        exit()

    # 站點基本資料只需要抓一次（站名和座標都不會變動）
    print("📡 正在下載站點基本資料（用於取得中文站名＋座標）...")
    stations = fetch_station_info(current_token)
    print(f"✅ 已載入 {len(stations)} 個站點基本資料")

    while True:
        now = tw_now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"\n[{now}] 開始抓取即時資料...")

        resp_availability = None
        try:
            resp_availability = requests.get(
                "https://tdx.transportdata.tw/api/basic/v2/Bike/Availability/City/Chiayi?$format=JSON",
                headers={'authorization': f'Bearer {current_token}'}
            )
        except Exception as e:
            print(f"❌ 網路異常: {e}")
            time.sleep(60)
            continue

        if resp_availability.status_code == 200:
            availability = resp_availability.json()
            merged = merge_ubike_data(stations, availability)
            print(f"✅ 成功抓到 {len(merged)} 筆即時站點動態！")

            if merged:
                first = merged[0]
                print(f"   ➤ 站點代號: {first.get('StationUID')}")
                print(f"   ➤ 站點名稱: {first.get('StationName')}")
                print(f"   ➤ 座標:     ({first.get('PositionLat')}, {first.get('PositionLon')})")  # ✅ 確認有座標
                print(f"   ➤ 可借車輛: {first.get('AvailableRentBikes')} 台")
                print(f"   ➤ 可還空位: {first.get('AvailableReturnBikes')} 個")
                print(f"   ➤ 站點狀態: {'正常營運' if first.get('ServiceStatus') == 1 else '暫停營運'}")

            with open('data/ubike_realtime.json', 'w', encoding='utf-8') as f:
                json.dump(merged, f, ensure_ascii=False, indent=4)

        elif resp_availability.status_code == 401:
            print("⚠️ Token 過期，重新申請...")
            current_token = get_tdx_token()
            # Token 過期時同步更新站點資料
            stations = fetch_station_info(current_token)
            continue
        else:
            print(f"❌ 抓取失敗: {resp_availability.status_code}")

        print("⏳ 等待 300 秒後進行下一次更新...")
        time.sleep(300)