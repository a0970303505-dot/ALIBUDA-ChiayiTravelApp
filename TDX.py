import json
import requests
import time

CLIENT_ID = 'YOUR_TDX_CLIENT_ID'
CLIENT_SECRET = 'YOUR_TDX_CLIENT_SECRET'

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

def fetch_taiwan_trip_news(token):
    time.sleep(1) # 防禦 429 Too Many Requests
    
    # 🎯 台灣好行最新消息專屬端點
    api_url = "https://tdx.transportdata.tw/api/basic/v2/Tourism/News/TaiwanTrip"
    headers = {
        'authorization': f'Bearer {token}',
        'Accept': 'application/json'
    }
    # 全台消息一次抓，不在 API 端篩選以防 400 錯誤
    params = {'$format': 'JSON'}
    
    print("📡 正在請求台灣好行最新消息...")
    response = requests.get(api_url, headers=headers, params=params)
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ 成功拉取 {len(data)} 筆全台消息")
        return data
    else:
        print(f"⚠️ 失敗 (狀態碼: {response.status_code}) -> {response.text}")
        return []

def clean_val(val):
    if val is None: return None
    if isinstance(val, str):
        v = val.strip()
        if not v or v == "無": return None
        return v
    if isinstance(val, (list, dict)):
        if not val: return None
        return val
    return val

def process_chiayi_news(raw_data):
    target_news = []
    
    # 🎯 定義嘉義好行路線與關鍵字 (暴力掃描法)
    chiayi_keywords = ["嘉義", "阿里山", "光林我嘉", "故宮南院", "瑞里", "太平"]
    
    for item in raw_data:
        # 把整筆 JSON 轉成字串，只要裡面出現嘉義關鍵字就抓下來！
        item_str = json.dumps(item, ensure_ascii=False)
        is_chiayi_related = any(kw in item_str for kw in chiayi_keywords)
        
        if not is_chiayi_related:
            continue
            
        news_entry = {
            "NewsID": clean_val(item.get("NewsID")),
            "Title": clean_val(item.get("Title")),                     # 標題
            "Description": clean_val(item.get("Description")),         # 內文
            "NewsCategory": clean_val(item.get("NewsCategory")),       # 類別 (例如: 1: 最新消息, 2: 營運調整)
            "NewsUrl": clean_val(item.get("NewsUrl")),                 # 官方新聞連結
            "PublishTime": clean_val(item.get("PublishTime")),         # 發布時間
            "StartTime": clean_val(item.get("StartTime")),             # 事件開始時間
            "EndTime": clean_val(item.get("EndTime")),                 # 事件結束時間
            "UpdateTime": clean_val(item.get("UpdateTime"))            # TDX 平台更新時間
        }
        target_news.append(news_entry)
        
    return target_news

if __name__ == "__main__":
    token = get_access_token()
    if token:
        raw_news = fetch_taiwan_trip_news(token)
        if raw_news:
            chiayi_news = process_chiayi_news(raw_news)
            
            output_filename = "app_news.json"
            with open(output_filename, 'w', encoding='utf-8') as f:
                json.dump(chiayi_news, f, ensure_ascii=False, indent=4)
                
            print(f"\n🎉 篩選大成功！共產出 {len(chiayi_news)} 筆嘉義專屬觀光交通消息。")
            print(f"💾 檔案位置: {output_filename}")