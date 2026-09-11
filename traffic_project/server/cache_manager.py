# ═══════════════════════════════════════════════════════════════
#  cache_manager.py
#  Server 端通用緩存管理器
#  - 每個 key 獨立 TTL，避免所有資料同時過期一起打 TDX
#  - thread-safe（多 worker 也安全）
#  - 回傳 fetched_at 給 Flutter 顯示「N 秒前更新」
# ═══════════════════════════════════════════════════════════════
import time
import threading
from typing import Any, Optional, Tuple


class CacheEntry:
    def __init__(self, data: Any, ttl_seconds: int):
        self.data        = data
        self.fetched_at  = time.time()          # unix timestamp
        self.expires_at  = self.fetched_at + ttl_seconds
        self.ttl_seconds = ttl_seconds

    @property
    def is_expired(self) -> bool:
        return time.time() >= self.expires_at

    @property
    def age_seconds(self) -> int:
        return int(time.time() - self.fetched_at)

    @property
    def remaining_seconds(self) -> int:
        return max(0, int(self.expires_at - time.time()))


class CacheManager:
    """
    使用方式：
        cache = CacheManager()
        cache.set('bus', data, ttl_seconds=60)
        data, meta = cache.get('bus')   # meta 為 None 或 dict
    """

    def __init__(self):
        self._store: dict[str, CacheEntry] = {}
        self._lock  = threading.Lock()

    # ── 取得緩存 ────────────────────────────────────────────────
    def get(self, key: str) -> Tuple[Optional[Any], Optional[dict]]:
        """
        回傳 (data, meta) 或 (None, None)
        meta = {
            "fetched_at":       float,   # unix timestamp
            "age_seconds":      int,     # 資料年齡（秒）
            "remaining_seconds":int,     # 距過期剩餘秒數
            "ttl_seconds":      int,     # 設定的 TTL
            "from_cache":       bool,    # 永遠 True（供 Flutter 辨識）
        }
        """
        with self._lock:
            entry = self._store.get(key)
            if entry is None or entry.is_expired:
                return None, None
            meta = {
                "fetched_at":        entry.fetched_at,
                "age_seconds":       entry.age_seconds,
                "remaining_seconds": entry.remaining_seconds,
                "ttl_seconds":       entry.ttl_seconds,
                "from_cache":        True,
            }
            return entry.data, meta

    # ── 寫入緩存 ────────────────────────────────────────────────
    def set(self, key: str, data: Any, ttl_seconds: int) -> None:
        with self._lock:
            self._store[key] = CacheEntry(data, ttl_seconds)

    # ── 強制清除某 key（讓下次 get 強制重抓）──────────────────────
    def invalidate(self, key: str) -> None:
        with self._lock:
            self._store.pop(key, None)

    # ── 查詢是否有有效緩存 ────────────────────────────────────────
    def has_valid(self, key: str) -> bool:
        with self._lock:
            entry = self._store.get(key)
            return entry is not None and not entry.is_expired

    # ── 所有 key 的狀態（用於 /api/cache/status 診斷端點）─────────
    def status(self) -> dict:
        with self._lock:
            result = {}
            for key, entry in self._store.items():
                result[key] = {
                    "age_seconds":       entry.age_seconds,
                    "remaining_seconds": entry.remaining_seconds,
                    "ttl_seconds":       entry.ttl_seconds,
                    "expired":           entry.is_expired,
                }
            return result


# ── 單例（全域共享）────────────────────────────────────────────
cache = CacheManager()
