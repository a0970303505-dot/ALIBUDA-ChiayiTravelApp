import json
import requests
import time

CLIENT_ID = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET = 'YOUR_TDX_CLIENT_SECRET'

OUTPUT_FILENAME = "data/bus_realtime.json"

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
    response = requests.post(auth_url, headers=headers, data=data)
    if response.status_code == 200:
        return response.json().get('access_token')
    print(f"❌ Token 取得失敗: {response.status_code}")
    return None

def fetch_bus(token, endpoint, extra_params=None):
    api_url = f"https://tdx.transportdata.tw/api/basic/v2/Bus/{endpoint}/City/Chiayi"
    headers = {'authorization': f'Bearer {token}', 'Accept': 'application/json'}
    params = {'$format': 'JSON', '$top': 5000}
    if extra_params:
        params.update(extra_params)

    for attempt in range(5):
        try:
            r = requests.get(api_url, headers=headers, params=params, timeout=20)
            if r.status_code == 200:
                return r.json()
            elif r.status_code == 429:
                # 優先讀 Retry-After header，沒有就用指數退避（10s, 20s, 40s, 80s...）
                retry_after = r.headers.get("Retry-After")
                if retry_after:
                    wait_time = int(retry_after)
                else:
                    wait_time = min(10 * (2 ** attempt), 120)  # 最多等 120 秒
                print(f"⚠️ [{endpoint}] 429 限流，等待 {wait_time} 秒後重試（第 {attempt+1} 次）...")
                time.sleep(wait_time)
                continue
            print(f"⚠️ [{endpoint}] HTTP {r.status_code}")
            break
        except requests.exceptions.ConnectTimeout:
            wait_time = min(5 * (attempt + 1), 30)
            print(f"⚠️ [{endpoint}] 連線逾時，{wait_time} 秒後重試...")
            time.sleep(wait_time)
        except requests.exceptions.ConnectionError:
            wait_time = min(5 * (attempt + 1), 30)
            print(f"⚠️ [{endpoint}] 網路中斷，{wait_time} 秒後重試...")
            time.sleep(wait_time)
        except Exception as e:
            print(f"❌ [{endpoint}] 連線異常：{e}")
            time.sleep(2)
            break
    return []

# ══════════════════════════════════════════════════
#  工具
# ══════════════════════════════════════════════════
def clean_str(val):
    if val is None: return ""
    v = str(val).strip()
    return "" if not v or v in ("無","沒有","null") else v

def clean_num(val):
    if val is None: return None
    try:
        return float(val) if '.' in str(val) else int(val)
    except:
        return None

# ══════════════════════════════════════════════════
#  靜態字典（啟動時載一次）
# ══════════════════════════════════════════════════
def build_route_map(token):
    print("📡 載入路線起訖站對照表 (Route)...")
    raw = fetch_bus(token, "Route")
    route_map = {}
    # ★ 新增：RouteID → RouteName 對照表（讓 timeline 可以正確填入名稱）
    rid_to_name = {}
    for r in raw:
        rid   = r.get("RouteID")
        rname = r.get("RouteName", {}).get("Zh_tw", "")
        if rid and rname:
            rid_to_name[str(rid)] = rname
        for sub in (r.get("SubRoutes") or []):
            d    = sub.get("Direction", 0)
            dep  = clean_str(sub.get("DepartureStopNameZh")  or r.get("DepartureStopNameZh"))
            dest = clean_str(sub.get("DestinationStopNameZh") or r.get("DestinationStopNameZh"))
            info = {"DepartureStopName": dep, "DestinationStopName": dest, "RouteName": rname}
            route_map[f"{rid}_{d}"]   = info
            route_map[f"{rname}_{d}"] = info
    print(f"✅ 路線對照表 {len(route_map)} 筆，RouteID→Name {len(rid_to_name)} 筆")
    return route_map, rid_to_name

def build_stop_position_cache(token):
    print("📡 載入靜態站牌位置 (Stop)...")
    raw = fetch_bus(token, "Stop")
    cache = {}
    for s in raw:
        sid = s.get("StopID")
        pos = s.get("StopPosition") or {}
        lat = clean_num(pos.get("PositionLat"))
        lon = clean_num(pos.get("PositionLon"))
        if sid and lat and lon:
            cache[str(sid).strip()] = {"lat": lat, "lon": lon}
    print(f"✅ 站牌位置 {len(cache)} 筆")
    return cache

def build_stop_of_route_map(token, stop_pos_cache):
    print("📡 載入全線站點排序 (StopOfRoute)...")
    raw = fetch_bus(token, "StopOfRoute")
    sor_map = {}

    for item in raw:
        rid   = item.get("RouteID", "")
        rname = item.get("RouteName", {}).get("Zh_tw", "")
        d     = item.get("Direction", 0)
        stops_raw = item.get("Stops", [])

        stops = []
        for s in stops_raw:
            sid  = clean_str(s.get("StopID"))
            pos  = s.get("StopPosition") or {}
            lat  = clean_num(pos.get("PositionLat")) or (stop_pos_cache.get(sid) or {}).get("lat")
            lon  = clean_num(pos.get("PositionLon")) or (stop_pos_cache.get(sid) or {}).get("lon")
            stops.append({
                "StopSequence": clean_num(s.get("StopSequence")),
                "StopID":       sid,
                "StopName":     clean_str(s.get("StopName", {}).get("Zh_tw")),
                "PositionLat":  lat,
                "PositionLon":  lon,
            })
        stops.sort(key=lambda x: x.get("StopSequence") or 0)

        sor_map[f"{rid}_{d}"]   = (stops, rname, rid)
        sor_map[f"{rname}_{d}"] = (stops, rname, rid)

    print(f"✅ 路線站點地圖 {len(sor_map)} 組")
    return sor_map



def format_eta(secs, stop_status):
    ss = stop_status
    if ss == 1:  return "尚未發車"
    if ss == 2:  return "交管停駛"
    if ss == 3:  return "末班駛離"
    if ss == 4:  return "今日未營運"

    if secs is None or secs < 0:
        return "無資料"
    if secs == 0:
        return "進站中"
    minutes = secs // 60
    if minutes == 0:
        return "即將到站"
    return f"約 {minutes} 分"

def merge_gps_stops(raw_gps, raw_near_stop, route_map, stop_pos_cache):
    stop_map = {}
    for s in raw_near_stop:
        plate = s.get("PlateNumb")
        if plate:
            sid = clean_str(s.get("StopID"))
            cached = stop_pos_cache.get(sid) or {}
            stop_map[plate] = {
                "StopID":       sid,
                "StopName":     clean_str(s.get("StopName", {}).get("Zh_tw")),
                "StopSequence": clean_num(s.get("StopSequence")),
                "StopStatus":   s.get("StopStatus"),
                "A0Status":     s.get("A0Status"),
                "StopLat":      cached.get("lat"),
                "StopLon":      cached.get("lon"),
            }

    vehicles = []
    for item in raw_gps:
        plate    = item.get("PlateNumb")
        rid      = item.get("RouteID")
        rname    = item.get("RouteName", {}).get("Zh_tw", "")
        direction = clean_num(item.get("Direction")) if item.get("Direction") is not None else 0
        if not plate: continue

        bus_pos = item.get("BusPosition") or {}
        b_lat = clean_num(bus_pos.get("PositionLat"))
        b_lon = clean_num(bus_pos.get("PositionLon"))

        ms = stop_map.get(plate, {})
        rk = f"{rid}_{direction}"
        mr_entry = route_map.get(rk) or route_map.get(f"{rname}_{direction}") or {}
        mr = mr_entry if isinstance(mr_entry, dict) else {}

        a0 = ms.get("A0Status")
        sc = ms.get("StopStatus")
        if a0 == 0:   status_desc, est_desc = "進站中",   "即將到站"
        elif a0 == 1: status_desc, est_desc = "已離站",   "前往下一站"
        elif sc == 0: status_desc, est_desc = "正常營運", "行駛中"
        else:         status_desc, est_desc = "正常行駛", "行駛中"

        vehicles.append({
            "RouteID":            clean_str(rid),
            "RouteName":          clean_str(rname),
            "DepartureStopName":  clean_str(mr.get("DepartureStopName")),
            "DestinationStopName":clean_str(mr.get("DestinationStopName")),
            "Direction":          direction,
            "StopID":             clean_str(ms.get("StopID")),
            "StopName":           clean_str(ms.get("StopName")),
            "StopSequence":       ms.get("StopSequence"),
            "StopPosition": {
                "PositionLat": ms.get("StopLat"),
                "PositionLon": ms.get("StopLon"),
            },
            "EstimateTime":       est_desc,
            "StopStatus":         status_desc,
            "PlateNumb":          clean_str(plate),
            "BusPosition": {
                "PositionLat": b_lat,
                "PositionLon": b_lon,
            },
            "Azimuth": clean_num(item.get("Azimuth")),
        })
    return vehicles

# ══════════════════════════════════════════════════
#  ★ 修正版：組裝 Route Timeline，確保 RouteName 填正確名稱
# ══════════════════════════════════════════════════
def build_route_timeline(sor_map, eta_map, route_map, rid_to_name):
    seen_keys = set()
    active_timelines  = []   # 有正常行駛班次的路線
    terminal_timelines = []  # 全部末班/未發車的路線（排後面）

    for key, value in sor_map.items():
        stops, rname_from_sor, rid_from_sor = value

        parts = key.rsplit("_", 1)
        if len(parts) != 2: continue
        route_key_id, dir_str = parts[0], parts[1]
        try:
            direction = int(dir_str)
        except:
            continue

        dedup_key = f"{route_key_id}_{direction}_{len(stops)}"
        if dedup_key in seen_keys:
            continue
        seen_keys.add(dedup_key)

        mr_entry = route_map.get(key) or {}
        mr = mr_entry if isinstance(mr_entry, dict) else {}
        dep_stop  = mr.get("DepartureStopName", "")
        dest_stop = mr.get("DestinationStopName", "")

        actual_name = rname_from_sor or rid_to_name.get(str(route_key_id), "") or route_key_id

        if not dep_stop:
            alt_entry = route_map.get(f"{actual_name}_{direction}") or {}
            if isinstance(alt_entry, dict):
                dep_stop  = alt_entry.get("DepartureStopName", "")
                dest_stop = alt_entry.get("DestinationStopName", "")

        stops_with_eta = []
        has_any_active = False

        for s in stops:
            sid      = s.get("StopID", "")
            eta_info = (eta_map.get(f"{rid_from_sor}_{direction}_{sid}") or
                        eta_map.get(f"{route_key_id}_{direction}_{sid}") or {})
            raw_secs = eta_info.get("EstimateTime")
            stop_st  = eta_info.get("StopStatus")
            eta_str  = format_eta(raw_secs, stop_st)

            has_bus = (stop_st == 0
                       and raw_secs is not None
                       and raw_secs >= 0
                       and raw_secs <= 300)

            if stop_st == 0 and raw_secs is not None and raw_secs >= 0:
                has_any_active = True

            stops_with_eta.append({
                "StopSequence": s.get("StopSequence"),
                "StopID":       s.get("StopID"),
                "StopName":     s.get("StopName"),
                "PositionLat":  s.get("PositionLat"),
                "PositionLon":  s.get("PositionLon"),
                "EstimateTime": eta_str,
                "RawSeconds":   raw_secs if raw_secs is not None else -1,
                "HasBus":       has_bus,
            })

        timeline = {
            "RouteID":              rid_from_sor or route_key_id,
            "RouteName":            actual_name,
            "DepartureStopName":    dep_stop,
            "DestinationStopName":  dest_stop,
            "Direction":            direction,
            "Stops":                stops_with_eta,
            # ★ 新增：Flutter 用來判斷是否全線已駛離，搜尋時排後面
            "IsAllTerminal":        not has_any_active,
        }

        if has_any_active:
            active_timelines.append(timeline)
        else:
            terminal_timelines.append(timeline)

    # ★ 有效路線排前面，末班路線排後面
    return active_timelines + terminal_timelines

# ══════════════════════════════════════════════════
#  主迴圈
# ══════════════════════════════════════════════════
def main_loop():
    print("=" * 50)
    print("  嘉義市公車即時動態（含全線站點時間軸版）")
    print("=" * 50)

    token = get_access_token()
    if not token:
        return

    # 靜態字典（每次啟動載一次）
    route_map, rid_to_name = build_route_map(token)
    time.sleep(1)
    stop_pos_cache = build_stop_position_cache(token)
    time.sleep(1)

    # 全線站點（每小時刷新）
    sor_map           = build_stop_of_route_map(token, stop_pos_cache)
    sor_refreshed_at  = time.time()
    SOR_REFRESH_SEC   = 3600

    # 連續 429 計數，用來動態延長主迴圈間隔
    consecutive_429 = 0
    BASE_INTERVAL   = 20   # 正常間隔（秒）
    MAX_INTERVAL    = 120  # 退避上限（秒）

    print(f"\n🚀 公車監控啟動，正常每 {BASE_INTERVAL} 秒刷新...")

    try:
        while True:
            loop_start = time.time()

            if time.time() - sor_refreshed_at > SOR_REFRESH_SEC:
                print("🔁 路線站點每小時刷新...")
                sor_map          = build_stop_of_route_map(token, stop_pos_cache)
                sor_refreshed_at = time.time()
                time.sleep(2)  # 刷新靜態資料後稍微緩一緩

            # 各 endpoint 之間插入短暫間隔，避免連包觸發限速
            raw_gps = fetch_bus(token, "RealTimeByFrequency")
            time.sleep(1)
            raw_near_stop = fetch_bus(token, "RealTimeNearStop")
            time.sleep(1)
            eta_raw = fetch_bus(token, "EstimatedTimeOfArrival")

            # 偵測是否整輪都 429（回傳空 list）
            all_empty = (not raw_gps and not raw_near_stop and not eta_raw)
            if all_empty:
                consecutive_429 += 1
            else:
                consecutive_429 = 0

            eta_map = {}
            if eta_raw:
                # 直接在此 inline 建 eta_map（避免重複呼叫 fetch）
                from collections import defaultdict
                _tmp = {}
                for item in eta_raw:
                    rid  = item.get("RouteID", "")
                    d    = item.get("Direction", 0)
                    sid  = clean_str(item.get("StopID"))
                    secs = item.get("EstimateTime")
                    s2   = item.get("StopStatus")
                    key  = f"{rid}_{d}_{sid}"
                    new_entry = {"EstimateTime": secs, "StopStatus": s2}
                    existing  = _tmp.get(key)
                    if existing is None:
                        _tmp[key] = new_entry
                    else:
                        prev_secs   = existing["EstimateTime"]
                        prev_status = existing["StopStatus"]
                        new_is_active  = (s2 == 0 and secs is not None and secs >= 0)
                        prev_is_active = (prev_status == 0 and prev_secs is not None and prev_secs >= 0)
                        if new_is_active and not prev_is_active:
                            _tmp[key] = new_entry
                        elif new_is_active and prev_is_active:
                            if secs < prev_secs:
                                _tmp[key] = new_entry
                eta_map = _tmp

            if raw_gps:
                vehicles  = merge_gps_stops(raw_gps, raw_near_stop, route_map, stop_pos_cache)
                timelines = build_route_timeline(sor_map, eta_map, route_map, rid_to_name)

                output = {
                    "UpdateTime": time.strftime('%Y-%m-%dT%H:%M:%S+08:00'),
                    "Vehicles":   vehicles,
                    "Routes":     timelines,
                }

                with open(OUTPUT_FILENAME, 'w', encoding='utf-8') as f:
                    json.dump(output, f, ensure_ascii=False, indent=4)

                print(f"[{time.strftime('%H:%M:%S')}] 💾 公車資料已更新 → "
                      f"{len(vehicles)} 輛車 / {len(timelines)} 條路線時間軸")

            # 動態間隔：連續空回傳時拉長等待
            interval = min(BASE_INTERVAL + consecutive_429 * 15, MAX_INTERVAL)
            if consecutive_429 > 0:
                print(f"⏳ 連續 {consecutive_429} 次空回傳，延長間隔至 {interval} 秒...")

            elapsed = time.time() - loop_start
            sleep_sec = max(0, interval - elapsed)
            time.sleep(sleep_sec)

    except KeyboardInterrupt:
        print("\n🛑 公車監控已安全停止。")

if __name__ == "__main__":
    main_loop()