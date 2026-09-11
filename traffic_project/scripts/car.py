import json, re, requests, time, os
from datetime import datetime, timezone, timedelta
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TW_TZ = timezone(timedelta(hours=8))

def tw_now():
    try:
        import ntplib
        c = ntplib.NTPClient()
        resp = c.request('pool.ntp.org', version=3, timeout=5)
        return datetime.fromtimestamp(resp.tx_time, tz=TW_TZ)
    except Exception:
        return datetime.now(tz=TW_TZ)


# ================== 設定區 ==================
CLIENT_ID        = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET    = 'YOUR_TDX_CLIENT_SECRET'
OUTPUT_FILENAME  = "data/parking_realtime.json"
REFRESH_INTERVAL = 60
IPARKING_URL     = "https://iparking.chiayi.gov.tw/car/open"
# ============================================

def get_access_token():
    url = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
    try:
        r = requests.post(
            url,
            headers={"content-type": "application/x-www-form-urlencoded"},
            data={"grant_type": "client_credentials", "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET},
            timeout=10)
        if r.status_code == 200:
            return r.json().get("access_token")
        print(f"❌ Token 失敗 HTTP {r.status_code}")
    except Exception as e:
        print(f"❌ 認證異常: {e}")
    return None

def build_static_map(token):
    print("📡 下載 TDX 靜態停車場資料...")
    url = "https://tdx.transportdata.tw/api/basic/v1/Parking/OffStreet/CarPark/City/Chiayi"

    # ★ 指數退避：靜態資料必須抓到才往下跑
    wait = 15
    for attempt in range(6):
        try:
            r = requests.get(
                url,
                headers={"authorization": f"Bearer {token}", "Accept": "application/json"},
                params={"$format": "JSON", "$top": 1000},
                timeout=15)
            print(f"   HTTP {r.status_code}，回應長度 {len(r.text)} bytes")
            if r.status_code == 200:
                break   # 成功，往下處理
            elif r.status_code == 429:
                print(f"⚠️ TDX 429 限流，等待 {wait} 秒後重試（第 {attempt+1}/6）...")
                time.sleep(wait)
                wait = min(wait * 2, 300)
                continue
            else:
                print(f"❌ TDX 非 200，回應前 300 字：{r.text[:300]}")
                return {}
        except Exception as e:
            print(f"❌ TDX 靜態異常: {e}")
            import traceback; traceback.print_exc()
            return {}
    else:
        print("❌ TDX 靜態資料重試全部失敗")
        return {}

    try:
        raw = r.json()
        # 偵測回傳格式：可能是 list、{"CarParks":[...]}, {"data":[...]}, 或其他 dict
        if isinstance(raw, list):
            pass  # 直接是 list，不用處理
        elif isinstance(raw, dict):
            # 嘗試各種常見 key
            for key in ("CarParks", "data", "carparks", "items", "results"):
                if key in raw and isinstance(raw[key], list):
                    print(f"   偵測到 root key: '{key}'，共 {len(raw[key])} 筆")
                    raw = raw[key]
                    break
            else:
                # 找不到已知 key，印出所有 key 幫助 debug
                print(f"⚠️  未知 dict 格式，keys = {list(raw.keys())[:10]}")
                # 嘗試找第一個 list 類型的 value
                for k, v in raw.items():
                    if isinstance(v, list) and len(v) > 0:
                        print(f"   用 key '{k}'，共 {len(v)} 筆")
                        raw = v
                        break
                else:
                    print("❌ 找不到有效 list，回傳空 map")
                    return {}
        print(f"   原始筆數：{len(raw)}")
        if raw:
            sample = raw[0]
            print(f"   第一筆 keys：{list(sample.keys())[:12]}")
            print(f"   CarParkID={sample.get('CarParkID')}, Name={sample.get('CarParkName')}, Fare={str(sample.get('FareDescription',''))[:60]}")
    except Exception as e:
        print(f"❌ TDX 靜態異常: {e}")
        import traceback; traceback.print_exc()
        return {}

    def zh(v, fb=""):
        """取中文字串：處理 dict（{"Zh_tw":...}）或直接字串，不做括號截斷"""
        if isinstance(v, dict):
            text = v.get("Zh_tw") or v.get("zh_tw") or v.get("ZhTw") or ""
            if not text:
                # fallback: 取第一個非空值
                text = next((str(val) for val in v.values() if val), fb)
        else:
            text = str(v) if v else ""
        return text.strip() or fb

    def zh_name(v, fb=""):
        """取停車場名稱：dict 取中文，括號內的視為副標題，優先取括號外的主名"""
        raw_text = zh(v, fb)
        if not raw_text:
            return fb
        # 若主名稱（括號前）存在則取主名，否則取全名
        main = re.sub(r'[（(].*?[）)]', '', raw_text).strip()
        return main if main else raw_text

    # 🎯 智慧狀態編碼器：將 TDX 的 0/1 狀態，嚴格對齊為 Android 規格書要求的 Number (1 或 0)
    def flag_to_num(v):
        if v == 1: return 1
        return 0

    static_map = {}
    for p in raw:
        pid = p.get("CarParkID")
        if not pid:
            continue
        pos = p.get("CarParkPosition") or {}
        
        # 計算總車位
        total = 0
        for a in p.get("ParkingAreas", []):
            total += (a.get("SpacesTotal", 0) or 0)
        if total == 0:
            total = p.get("SpacesTotal", 0) or 0

        static_map[pid] = {
            "CarParkName":             zh_name(p.get("CarParkName"), "未命名停車場"),
            "CarParkType":             {0:"平面",1:"立體",2:"地下",3:"機械式",4:"路邊"}.get(p.get("CarParkType",-1), "其他"),
            "Description":             zh(p.get("Description"), "沒有詳細介紹"),
            "Address":                 zh(p.get("Address"), "無提供地址"),
            "PositionLat":             pos.get("PositionLat"), # 保持原始 Float / None
            "PositionLon":             pos.get("PositionLon"), # 保持原始 Float / None
            "SpaceTotal":              int(total) if total else 0,
            "FareDescription":         zh(p.get("FareDescription"), "詳見現場公告"),
            "LiveOccuppancyAvailable": flag_to_num(p.get("LiveOccuppancyAvailable", -1)),
            "OperationType":           {1:"公辦民營",2:"公營",3:"民營"}.get(p.get("OperationType",-1), "其他"),
            "EVRechargingAvailable":   flag_to_num(p.get("EVRechargingAvailable", -1)),
            "Toilet":                  flag_to_num(p.get("Toilet", -1)),
            "Telephone":               p.get("Telephone") or "無電話資訊",
        }
    print(f"✅ TDX 靜態完成，共 {len(static_map)} 座。")
    return static_map

def _strip_tags(s: str) -> str:
    return re.sub(r'<[^>]+>', ' ', s).strip()

def _parse_total(text: str) -> int:
    nums = re.findall(r'\d+', text)
    return sum(int(n) for n in nums) if nums else 0

def _parse_remaining_num(text: str):
    """ 🎯 核心改動：爬蟲解析出來的賸餘車位，必須直接回傳整數(Number)或 None，嚴禁吐出任何中文 """
    if not text:
        return None
    t = text.strip()
    if not t or t == "-":
        return None

    lines = [l.strip() for l in re.split(r'[\n\r]+', t) if l.strip() and l.strip() != "-"]
    if not lines:
        return None

    total = 0
    has_number = False
    for line in lines:
        if "滿場" in line:
            return 0 # 滿場直接代表剩餘 0 個車位
        else:
            m = re.search(r'[（(](\d+)[）)]', line)
            if m:
                total += int(m.group(1))
                has_number = True
            else:
                m2 = re.search(r'\d+', line)
                if m2:
                    total += int(m2.group())
                    has_number = True

    return int(total) if has_number else None

def _norm(name: str) -> str:
    s = re.sub(r'\s+', '', name).lower()
    match = re.search(r'[（(](.*?)[）)]', s)
    if match:
        s = match.group(1)
    s = s.replace("停車場", "").replace("停車區", "").replace("地下", "").replace("立體", "")
    return s

def fetch_iparking() -> dict:
    try:
        r = requests.get(IPARKING_URL, headers={"User-Agent": "Mozilla/5.0"}, verify=False, timeout=15)
        r.encoding = "utf-8"
        if r.status_code != 200:
            return {}
    except:
        return {}

    html = r.text
    result = {}

    for tr_html in re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.S | re.I):
        tds_raw = re.findall(r'<td[^>]*>(.*?)</td>', tr_html, re.S | re.I)
        if len(tds_raw) < 6:
            continue

        name_raw    = _strip_tags(tds_raw[1])
        total_raw   = _strip_tags(tds_raw[2])
        remain_raw  = _strip_tags(tds_raw[3])

        if not name_raw or name_raw in ("停車場名稱", "名稱", ""):
            continue

        total     = _parse_total(total_raw)
        remaining = _parse_remaining_num(remain_raw)

        result[_norm(name_raw)] = {
            "remaining":   remaining,
            "total":       total,
            "raw_name":    name_raw,
        }
    return result

def merge(static_map: dict, avail_map: dict) -> list:
    result = []
    
    # 1. 巡迴合併 TDX 靜態場站
    for pid, s in static_map.items():
        name_norm = _norm(s["CarParkName"])
        live = avail_map.get(name_norm)
        
        if not live:
            live = next((v for k, v in avail_map.items() if name_norm in k or k in name_norm or _norm(v["raw_name"]) in name_norm), None)

        # 處理剩餘車位數值型態
        remaining_space = None
        if live:
            remaining_space = live["remaining"]
        
        # 修正總車位對齊
        space_total = s["SpaceTotal"]
        if space_total == 0 and live and live.get("total", 0) > 0:
            space_total = live["total"]

        # 🎯 嚴格遵循 Android 規格書規格，打造完美精簡的 14 個欄位
        result.append({
            # A. 基本資訊欄位
            "CarParkID":               str(pid),
            "CarParkName":             str(s["CarParkName"]),
            "Description":             str(s["Description"]),
            "CarParkType":             str(s["CarParkType"]),
            "SpaceTotal":              int(space_total),
            
            # B. 地理位置欄位 (維持原始 Float 或 None 數值型態)
            "PositionLat":             s["PositionLat"] if s["PositionLat"] else None,
            "PositionLon":             s["PositionLon"] if s["PositionLon"] else None,
            "Address":                 str(s["Address"]),
            
            # C. 收費與優惠資訊欄位
            "FareDescription":         str(s["FareDescription"]),
            
            # D. 營運與即時資訊欄位 (即時資訊與旗標狀態完全對齊 Number)
            "OperationType":           str(s["OperationType"]),
            "LiveOccuppancyAvailable": int(s["LiveOccuppancyAvailable"]),
            "RemainingSpace":          remaining_space, # 整數或 None (null)
            
            # E. 設備與附加設施欄位 (對齊 1 或 0 的 Number 型態)
            "EVRechargingAvailable":   int(s["EVRechargingAvailable"]),
            "Toilet":                  int(s["Toilet"]),
            
            # F. 聯絡資訊
            "Telephone":               str(s["Telephone"])
        })

    # 2. 額外補上 iparking 網頁有，但 TDX 尚未收錄的私有場站
    tdx_names = {_norm(s["CarParkName"]) for s in static_map.values()}
    for k, v in avail_map.items():
        matched = any(k in t or t in k for t in tdx_names)
        if not matched:
            result.append({
                "CarParkID":               f"IPARKING_{k}",
                "CarParkName":             str(v["raw_name"]),
                "Description":             "沒有詳細介紹",
                "CarParkType":             "平面",
                "SpaceTotal":              int(v["total"]),
                "PositionLat":             None, # 爬網頁沒給經緯度，直接老實填 null 才是正解
                "PositionLon":             None,
                "Address":                 "請參考場站名稱導航",
                "FareDescription":         "詳見現場公告",
                "OperationType":           "民營",
                "LiveOccuppancyAvailable": 1,
                "RemainingSpace":          v["remaining"], # 整數或 None
                "EVRechargingAvailable":   0,
                "Toilet":                  0,
                "Telephone":               "無電話資訊"
            })

    return result

def main_loop():
    print("🔄 初始化 TDX 認證...")

    # ★ 錯開啟動：讓 train/bus 先完成靜態資料載入
    print("⏳ 等待 60 秒錯開 TDX 請求...")
    time.sleep(60)

    token = get_access_token()
    if not token:
        return

    time.sleep(5)   # 認證後稍等
    static_map      = build_static_map(token)
    last_token_time = time.time()

    print(f"\n🚀 停車場監控常駐啟動（每 {REFRESH_INTERVAL} 秒重算刷新）")
    try:
        while True:
            if time.time() - last_token_time > 3000:
                new = get_access_token()
                if new:
                    token = new
                    last_token_time = time.time()
                    time.sleep(5)
                    static_map = build_static_map(token)

            avail_map = fetch_iparking()   # 爬網頁，不打 TDX
            merged    = merge(static_map, avail_map)

            # ★ 有資料才寫檔，避免靜態資料空時覆寫
            if merged:
                with open(OUTPUT_FILENAME, 'w', encoding='utf-8') as f:
                    json.dump(merged, f, ensure_ascii=False, indent=4)
                got_count = sum(1 for p in merged if p["RemainingSpace"] is not None)
                print(f"[{time.strftime('%H:%M:%S')}] 💾 停車場同步完畢 ➜ 總數: {len(merged)} 座 | 即時剩餘有效: {got_count} 座")
            else:
                print(f"[{time.strftime('%H:%M:%S')}] ⚠️ 靜態資料空，跳過寫檔")

            time.sleep(REFRESH_INTERVAL)

    except KeyboardInterrupt:
        print("\n🛑 停車場監控已安全停止。")

if __name__ == "__main__":
    main_loop()