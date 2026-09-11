import requests
import json
import urllib3
import time  # 引入時間套件來控制每隔一天更新
import os

# 自動忽略因跳過 SSL 檢查而產生的警告訊息
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ================== 設定區 ==================
API_KEY = "YOUR_CWA_API_KEY"
OUTPUT_FILE = "data/chiayi_weather.json"  # 最終產出的 JSON 檔案名稱

# 設定更新間隔時間（單位：秒）
UPDATE_INTERVAL_SECONDS = 60 * 60 * 24 
# ============================================

API_URLS = {
    "CHIAYI_COUNTY": f"https://opendata.cwa.gov.tw/api/v1/rest/datastore/F-D0047-031?Authorization={API_KEY}&format=JSON",
    "CHIAYI_CITY": f"https://opendata.cwa.gov.tw/api/v1/rest/datastore/F-D0047-059?Authorization={API_KEY}&format=JSON"
}

def extract_pure_value(value_list):
    """ 🎯 核心抽取：從 elementValue 的陣列中，榨出真正的數字或字串 """
    if not value_list or not isinstance(value_list, list):
        return None
    
    for d in value_list:
        if isinstance(d, dict):
            if "value" in d and d["value"] is not None and str(d["value"]).strip() != "":
                return str(d["value"]).strip()
                
    if len(value_list) > 0 and isinstance(value_list[0], dict):
        for k, v in value_list[0].items():
            if v is not None and str(v).strip() != "" and k.lower() != "dataid":
                return str(v).strip()
    return None

def find_first_valid_value_in_all_slots(time_slots):
    """ 🎯 地毯式搜索時段 """
    if not time_slots or not isinstance(time_slots, list):
        return None
        
    for slot in time_slots:
        if not isinstance(slot, dict):
            continue
            
        values = None
        for k, v in slot.items():
            if k.lower() == "elementvalue":
                values = v
                break
                
        if not values:
            continue
            
        val = extract_pure_value(values)
        if val is not None and str(val).strip() != "":
            return val
            
    return None

def convert_weather_to_code(weather_text):
    """ 智慧代碼轉換器 """
    if not weather_text:
        return "01"
    txt = str(weather_text)
    if "晴天" in txt or txt == "晴": return "01"
    elif "晴時多雲" in txt: return "02"
    elif "多雲時晴" in txt: return "03"
    elif "多雲" in txt and "陰" not in txt and "雨" not in txt: return "04"
    elif "多雲時陰" in txt: return "05"
    elif "陰時多雲" in txt: return "06"
    elif "陰天" in txt or txt == "陰": return "07"
    elif "陣雨" in txt or "短暫雨" in txt or "短暫陣雨" in txt: return "08"
    elif "雷雨" in txt or "雷陣雨" in txt: return "15"
    elif "雨" in txt: return "11"
    return "01"

def get_latest_forecast(weather_elements):
    """ 終極中文欄位對照 """
    result = {
        "Temperature": None,
        "MaxComfortIndex": None,
        "ProbabilityOfPrecipitation": 0,
        "Weather": None,
        "WeatherCode": None,          
        "RelativeHumidity": None
    }
    
    element_map = {}
    for element in weather_elements:
        name = element.get("elementName") or element.get("ElementName")
        slots = element.get("time") or element.get("Time")
        if name and slots:
            element_map[str(name).strip()] = slots

    # 1. 平均溫度
    if "平均溫度" in element_map:
        val = find_first_valid_value_in_all_slots(element_map["平均溫度"])
        try: result["Temperature"] = float(val) if val else None
        except: pass

    # 2. 最大舒適度指數
    if "最大舒適度指數" in element_map:
        result["MaxComfortIndex"] = find_first_valid_value_in_all_slots(element_map["最大舒適度指數"])

    # 3. 12小時降雨機率
    if "12小時降雨機率" in element_map:
        val = find_first_valid_value_in_all_slots(element_map["12小時降雨機率"])
        result["ProbabilityOfPrecipitation"] = int(val) if (val and str(val).isdigit()) else 0

    # 4. 天氣現象
    if "天氣現象" in element_map:
        weather_text = find_first_valid_value_in_all_slots(element_map["天氣現象"])
        result["Weather"] = weather_text
        result["WeatherCode"] = convert_weather_to_code(weather_text)

    # 5. 平均相對濕度
    if "平均相對濕度" in element_map:
        val = find_first_valid_value_in_all_slots(element_map["平均相對濕度"])
        try: result["RelativeHumidity"] = int(val) if val else None
        except: pass
                
    return result

def fetch_weather_data(url, city_name):
    try:
        response = requests.get(url, verify=False)
        if response.status_code != 200: return []
        data = response.json()
        records = data.get("records", {})
        locations_container = records.get("Locations") or records.get("locations")
        if isinstance(locations_container, list) and len(locations_container) > 0:
            locations = locations_container[0].get("Location") or locations_container[0].get("location") or []
        else:
            locations = records.get("Location") or records.get("location") or []
            
        if not locations: return []
            
        formatted_data = []
        for loc in locations:
            district_name = loc.get("locationName") or loc.get("LocationName")
            weather_elements = loc.get("weatherElement") or loc.get("WeatherElement") or []
            weather_info = get_latest_forecast(weather_elements)
            
            # 🎯 在這裡移除了 "City" 與 "District" 欄位，僅保留 LocationID 
            formatted_data.append({
                "LocationID": f"{city_name}_{district_name}",
                **weather_info
            })
        return formatted_data
    except Exception as e:
        print(f"【錯誤】解析 {city_name} 資料失敗: {e}")
        return []

def run_sync():
    print("\n[系統通知] 正在向中央氣象署抓取最新天氣資料...")
    city_data = fetch_weather_data(API_URLS["CHIAYI_CITY"], "嘉義市")
    county_data = fetch_weather_data(API_URLS["CHIAYI_COUNTY"], "嘉義縣")
    all_chiayi_weather = city_data + county_data
    if len(all_chiayi_weather) == 0:
        print("[警告] 抓取資料為 0 筆，本次放棄更新 JSON 檔。")
        return
    try:
        output_dir = os.path.dirname(OUTPUT_FILE)
        if output_dir and not os.path.exists(output_dir):
            os.makedirs(output_dir, exist_ok=True)
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            json.dump(all_chiayi_weather, f, ensure_ascii=False, indent=2)
        print(f"🎉 成功更新！已將最新資料寫入 【 {OUTPUT_FILE} 】")
    except Exception as e:
        print(f"【錯誤】儲存 JSON 檔案時失敗: {e}")

def main():
    print("==================================================")
    print("  嘉義縣市即時天氣『自動天天更新系統』已啟動")
    print(f"  程式將常駐後台，每隔一天 ({UPDATE_INTERVAL_SECONDS} 秒) 更新一次。")
    print("  提示：若要關閉此自動更新程式，請在視窗內按 Ctrl + C")
    print("==================================================")
    while True:
        try:
            run_sync()
            print(f"⏰ 進入睡眠狀態。將於一天後自動進行下一次天氣同步...\n")
            time.sleep(UPDATE_INTERVAL_SECONDS)
        except KeyboardInterrupt:
            print("\n[系統通知] 偵測到關閉指令，成功結束天氣更新程式。")
            break
        except Exception as e:
            print(f"[異常] 發生非預期錯誤: {e}，將於 5 分鐘後重新嘗試...")
            time.sleep(300)

if __name__ == "__main__":
    main()