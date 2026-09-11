import os  # 🎯 補上 os 套件，確保絕對路徑可用
import json
import requests
import time
from datetime import datetime, timezone, timedelta

CLIENT_ID = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET = 'YOUR_TDX_CLIENT_SECRET'

# 🎯 改為動態絕對路徑，確保不論在哪裡下指令都能正確讀寫 data 資料夾
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILENAME = os.path.join(CURRENT_DIR, "..", "data", "train_realtime.json")

# ★ 台灣時區（UTC+8）
TW_TZ = timezone(timedelta(hours=8))

def get_tw_now() -> datetime:
    """抓取 NTP 時間（台灣時區），若失敗則用本機時間補救"""
    try:
        import ntplib
        c = ntplib.NTPClient()
        resp = c.request('pool.ntp.org', version=3, timeout=5)
        return datetime.fromtimestamp(resp.tx_time, tz=TW_TZ)
    except Exception:
        pass
    # 備援：直接用系統時間，但強制轉成 +08:00
    return datetime.now(tz=TW_TZ)

def tw_strftime(fmt: str) -> str:
    return get_tw_now().strftime(fmt)

# ══════════════════════════════════════════════════
#  認證
# ══════════════════════════════════════════════════
def get_access_token():
    auth_url = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
    headers = {'content-type': 'application/x-www-form-urlencoded'}
    data = {
        'grant_type': 'client_credentials',
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET
    }
    try:
        response = requests.post(auth_url, headers=headers, data=data, timeout=10)
        if response.status_code == 200:
            return response.json().get('access_token')
        elif response.status_code == 429:
            print("❌ Token 失敗：TDX 429 限流，請稍等。")
        else:
            print(f"❌ Token 取得失敗，HTTP {response.status_code}")
    except Exception as e:
        print(f"❌ 網路異常：{e}")
    return None

def fetch(token, endpoint, extra_params=None, is_advanced=False, api_version="v2"):
    api_type = "advanced" if is_advanced else "basic"
    api_url = f"https://tdx.transportdata.tw/api/{api_type}/{api_version}/Rail/TRA/{endpoint}"

    headers = {'authorization': f'Bearer {token}', 'Accept': 'application/json'}
    params = {'$format': 'JSON', '$top': 5000}
    if extra_params:
        params.update(extra_params)

    for attempt in range(4):
        try:
            r = requests.get(api_url, headers=headers, params=params, timeout=20)
            if r.status_code == 200:
                data = r.json()
                
                # 🎯 【防禦一】只要請求成功，強制讓執行緒休息 1.5 秒
                # 確保下一個 API 呼叫不會因為跟這一個「黏太近」而被伺服器判定為 Burst 轟炸[cite: 4]
                time.sleep(1.5)
                
                if isinstance(data, dict):
                    for v in data.values():
                        if isinstance(v, list):
                            return v
                    return []
                return data
            elif r.status_code == 429:
                wait_time = 10 * (2 ** attempt)
                print(f"⚠️ [{endpoint}] 429 限流！等待 {wait_time} 秒後重試（第 {attempt+1} 次）...")
                time.sleep(wait_time)
                continue
            print(f"⚠️ [{endpoint}] HTTP {r.status_code}")
            return []
        except Exception as e:
            print(f"❌ [{endpoint}] 連線異常：{e}")
            time.sleep(2)
    print(f"❌ [{endpoint}] 429 重試全部失敗，保留舊資料")
    return None   # 全部重試都 429

# ══════════════════════════════════════════════════
#  靜態字典
# ══════════════════════════════════════════════════
def build_base_maps(token):
    print("📡 載入車站、車種字典...")
    raw_types    = fetch(token, "TrainType")
    
    # 🎯 靜態檔案抓取中間拉長休息時間（改為 6 秒），防範未然
    time.sleep(6)   
    raw_stations = fetch(token, "Station")

    type_map = {}
    for t in (raw_types or []):
        tid = t.get("TrainTypeID")
        if tid:
            type_map[tid] = {
                "TrainTypeCode": t.get("TrainTypeCode"),
                "TrainTypeName": t.get("TrainTypeName", {}).get("Zh_tw", "沒有")
            }

    station_map = {}
    for s in (raw_stations or []):
        sid = s.get("StationID")
        if sid:
            station_map[sid] = s.get("StationName", {}).get("Zh_tw", "沒有")

    print(f"✅ 車站 {len(station_map)} 座，車種 {len(type_map)} 種")
    return type_map, station_map

def build_general_info_map(token):
    print("📡 載入定期車次基本資料 (GeneralTrainInfo)...")
    raw = fetch(token, "GeneralTrainInfo")
    info_map = {}
    for item in (raw or []):
        no = item.get("TrainNo")
        if no:
            info_map[no] = {
                "TrainTypeID":         item.get("TrainTypeID"),
                "StartingStationID":   item.get("StartingStationID"),
                "StartingStationName": item.get("StartingStationName", {}).get("Zh_tw"),
                "EndingStationID":     item.get("EndingStationID"),
                "EndingStationName":   item.get("EndingStationName", {}).get("Zh_tw"),
                "TripLine":            item.get("TripLine"),
                "WheelchairFlag":      item.get("WheelchairFlag"),
                "BikeFlag":            item.get("BikeFlag"),
                "BreastFeedingFlag":   item.get("BreastFeedingFlag"),
            }
    print(f"✅ 定期車次 {len(info_map)} 筆")
    return info_map

def build_timetable_map(token):
    print("📡 載入定期時刻表 (GeneralTrainTimetable v3)...")

    api_url = "https://tdx.transportdata.tw/api/basic/v3/Rail/TRA/GeneralTrainTimetable"
    headers = {'authorization': f'Bearer {token}', 'Accept': 'application/json'}
    params = {'$format': 'JSON', '$top': 10000}

    raw = []
    for attempt in range(3):
        try:
            r = requests.get(api_url, headers=headers, params=params, timeout=30)
            if r.status_code == 200:
                data = r.json()
                raw = data.get("TrainTimetables", [])
                # 🎯 時刻表下載體積龐大，下載完同樣強制休息 2 秒
                time.sleep(2.0)
                break
            elif r.status_code == 429:
                wait_time = (attempt + 1) * 5
                print(f"⚠️ [GeneralTrainTimetable] 429 限流，{wait_time} 秒後重試...")
                time.sleep(wait_time)
            else:
                print(f"⚠️ [GeneralTrainTimetable] HTTP {r.status_code}")
                break
        except Exception as e:
            print(f"❌ [GeneralTrainTimetable] 連線異常：{e}")
            time.sleep(2)

    timetable_map = {}
    for item in raw:
        train_info = item.get("TrainInfo", {})
        train_no = train_info.get("TrainNo")
        if not train_no:
            continue

        stop_times = item.get("StopTimes", [])
        stops = []
        for s in stop_times:
            stops.append({
                "StopSequence":  s.get("StopSequence"),
                "StationID":     s.get("StationID"),
                "StationName":   s.get("StationName", {}).get("Zh_tw", ""),
                "ArrivalTime":   s.get("ArrivalTime", ""),
                "DepartureTime": s.get("DepartureTime", ""),
            })
        stops.sort(key=lambda x: x.get("StopSequence") or 0)
        timetable_map[train_no] = stops

    print(f"✅ 時刻表 {len(timetable_map)} 班次")
    return timetable_map

# ══════════════════════════════════════════════════
#  工具函式
# ══════════════════════════════════════════════════
def fmt(val):
    if val is None: return "沒有"
    v = str(val).strip()
    return v if v and v not in ("無", "沒有", "null") else "沒有"

def fmt_delay(delay):
    if delay is None or delay == 0: return "沒有"
    return f"誤點 {delay} 分鐘"

def convert_type_id(raw_id):
    if not raw_id: return None
    mapping = {"1":"1100","2":"1110","3":"1120","4":"1131","5":"1140","6":"1150","10":"1132"}
    return mapping.get(str(raw_id).strip(), str(raw_id).strip())

def hhmm(time_str):
    if not time_str or time_str == "沒有":
        return "沒有"
    parts = time_str.split(":")
    if len(parts) >= 2:
        return f"{parts[0]}:{parts[1]}"
    return time_str

def calc_duration(dep_time, arr_time):
    try:
        def to_min(t):
            p = t.split(":")
            return int(p[0]) * 60 + int(p[1])
        diff = to_min(arr_time) - to_min(dep_time)
        if diff < 0:
            diff += 24 * 60
        if diff >= 60:
            return f"{diff // 60} 小時 {diff % 60} 分"
        return f"{diff} 分鐘"
    except:
        return "沒有"

# ══════════════════════════════════════════════════
#  整合即時動態 + 時刻表
# ══════════════════════════════════════════════════
def process_train_data(raw_delay, raw_liveboard, info_map, type_map, station_map, timetable_map):
    live_map = {}

    for board in (raw_liveboard or []):
        no = board.get("TrainNo")
        if not no: continue
        live_map[no] = {
            "DelayTime":   board.get("DelayTime"),
            "StationID":   board.get("StationID"),
            "StationName": board.get("StationName", {}).get("Zh_tw") if isinstance(board.get("StationName"), dict) else board.get("StationName"),
            "Direction":   board.get("Direction"),
            "TrainTypeID": board.get("TrainTypeID"),
        }

    for item in (raw_delay or []):
        no = item.get("TrainNo")
        if not no: continue
        if no not in live_map:
            live_map[no] = {
                "DelayTime":   item.get("DelayTime"),
                "StationID":   item.get("StationID"),
                "StationName": item.get("StationName", {}).get("Zh_tw") if isinstance(item.get("StationName"), dict) else item.get("StationName"),
                "Direction":   item.get("Direction"),
                "TrainTypeID": item.get("TrainTypeID"),
            }
        else:
            if item.get("DelayTime") is not None:
                live_map[no]["DelayTime"] = item.get("DelayTime")
            if item.get("Direction") is not None and live_map[no].get("Direction") is None:
                live_map[no]["Direction"] = item.get("Direction")
            if item.get("TrainTypeID") and not live_map[no].get("TrainTypeID"):
                live_map[no]["TrainTypeID"] = item.get("TrainTypeID")

    result = []
    all_train_nos = set(timetable_map.keys()) | set(live_map.keys())

    now_tw = get_tw_now()
    today_str = now_tw.strftime('%Y-%m-%d')
    now_time_str = now_tw.strftime('%Y-%m-%dT%H:%M:%S+08:00')

    for no in all_train_nos:
        timetable_stops = timetable_map.get(no, [])
        dyn  = live_map.get(no, {})
        info = info_map.get(no) or {}

        raw_tid = dyn.get("TrainTypeID") or info.get("TrainTypeID")
        tid = convert_type_id(raw_tid)
        if not tid:
            try:
                n = int(no)
                if 1 <= n <= 499:     tid = "1100"
                elif 500 <= n <= 799: tid = "1110"
                elif n >= 1000:       tid = "1131"
            except: pass
        matched_type = type_map.get(tid) or {}

        cur_sid   = dyn.get("StationID")
        cur_name  = dyn.get("StationName") or (station_map.get(cur_sid) if cur_sid else None)
        start_name = info.get("StartingStationName") or station_map.get(info.get("StartingStationID", ""))
        end_name   = info.get("EndingStationName")   or station_map.get(info.get("EndingStationID", ""))

        if timetable_stops:
            if not start_name or start_name == "沒有":
                start_name = timetable_stops[0].get("StationName", "沒有")
            if not end_name or end_name == "沒有":
                end_name = timetable_stops[-1].get("StationName", "沒有")

        direction = dyn.get("Direction")
        if direction is None:
            direction = info.get("Direction")

        stops_for_json = []
        for s in timetable_stops:
            stops_for_json.append({
                "StopSequence":  s.get("StopSequence"),
                "StationID":     fmt(s.get("StationID")),
                "StationName":   fmt(s.get("StationName")),
                "ArrivalTime":   hhmm(s.get("ArrivalTime", "")),
                "DepartureTime": hhmm(s.get("DepartureTime", "")),
            })

        trip_duration = "沒有"
        if len(timetable_stops) >= 2:
            first_dep = timetable_stops[0].get("DepartureTime", "")
            last_arr  = timetable_stops[-1].get("ArrivalTime", "")
            if first_dep and last_arr:
                trip_duration = calc_duration(first_dep, last_arr)

        entry = {
            "TrainDate":           fmt(today_str),
            "UpdateTime":          fmt(now_time_str),
            "TrainNo":             fmt(no),
            "Direction":           fmt(direction),
            "TrainTypeID":         fmt(tid),
            "TrainTypeCode":       fmt(matched_type.get("TrainTypeCode")),
            "TrainTypeName":       fmt(matched_type.get("TrainTypeName")),
            "TripLine":            fmt(info.get("TripLine")),
            "StartingStationID":   fmt(info.get("StartingStationID")),
            "StartingStationName": fmt(start_name),
            "EndingStationID":     fmt(info.get("EndingStationID")),
            "EndingStationName":   fmt(end_name),
            "WheelchairFlag":      fmt(info.get("WheelchairFlag")),
            "BikeFlag":            fmt(info.get("BikeFlag")),
            "BreastFeedingFlag":   fmt(info.get("BreastFeedingFlag")),
            "StationID":           fmt(cur_sid),
            "StationName":         fmt(cur_name),
            "DelayTime":           fmt_delay(dyn.get("DelayTime")),
            "TripDuration":        trip_duration,
            "Timetable":           stops_for_json,
        }
        result.append(entry)

    def sort_key(e):
        tt = e.get("Timetable", [])
        if tt:
            return tt[0].get("DepartureTime", "99:99")
        return "99:99"

    result.sort(key=sort_key)
    return result

# ══════════════════════════════════════════════════
#  主迴圈
# ══════════════════════════════════════════════════
def main_loop():
    print("🔄 初始化台鐵監控（完整時刻表＋即時誤點版）...")
    token = get_access_token()
    if not token:
        print("❌ 無法取得 Token，程序終止。")
        return

    # 🎯 【防禦二：巨觀錯開】啟動時把拉取大檔案的間隔拉長，不要一次塞爆 API 閘門[cite: 4]
    type_map, station_map = build_base_maps(token)
    print("⏳ [防429安全策略] 休息 8 秒，再載入車次資料...")
    time.sleep(8)

    info_map = build_general_info_map(token)
    print("⏳ [防429安全策略] 休息 8 秒，再載入全台時刻表...")
    time.sleep(8)

    timetable_map = build_timetable_map(token)
    last_timetable_date = get_tw_now().strftime('%Y-%m-%d')

    refresh_interval = 90   # 90 秒一輪符合伺服器快取 TTL
    print(f"🚀 台鐵監控啟動（每 {refresh_interval} 秒刷新，時刻表共 {len(timetable_map)} 班次）...")

    try:
        while True:
            today = get_tw_now().strftime('%Y-%m-%d')
            if today != last_timetable_date:
                print(f"📅 日期切換至 {today}，重新載入時刻表...")
                time.sleep(5)
                timetable_map = build_timetable_map(token)
                last_timetable_date = today
                time.sleep(5)

            # 🎯 兩支動態 API 之間多留 6 秒間隔，避免在同秒發出（QPS 破表）
            raw_delay     = fetch(token, "LiveTrainDelay")
            time.sleep(6)
            raw_liveboard = fetch(token, "LiveBoard")

            if raw_delay is None or raw_liveboard is None:
                print(f"[{get_tw_now().strftime('%H:%M:%S')}] ⚠️ 本輪有 429，跳過寫檔，保留舊資料")
                time.sleep(refresh_interval)
                continue

            processed = process_train_data(
                raw_delay, raw_liveboard,
                info_map, type_map, station_map, timetable_map
            )

            # 🎯 雙重保險：萬一 data 資料夾不見，自動動態建立
            os.makedirs(os.path.dirname(OUTPUT_FILENAME), exist_ok=True)

            with open(OUTPUT_FILENAME, 'w', encoding='utf-8') as f:
                json.dump(processed, f, ensure_ascii=False, indent=4)

            live_count = sum(1 for e in processed if e["StationName"] != "沒有")
            tw_time = get_tw_now().strftime('%H:%M:%S')
            print(f"[{tw_time}] 💾 台鐵資料：共 {len(processed)} 班次（{live_count} 班即時在途）➜ {OUTPUT_FILENAME}")
            time.sleep(refresh_interval)

    except KeyboardInterrupt:
        print("\n🛑 台鐵監控已安全停止。")

if __name__ == "__main__":
    main_loop()