import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'calendar_screen.dart' show CalendarEventService, CalendarEvent, CalendarEventType, EventDetailScreen;

// ═══════════════════════════════════════════════════════════════
//  最新消息頁面 ─ 接上 Firestore Activities collection
//  Firestore 欄位對照：
//    ActivityName → 標題
//    Category     → 分類標籤（用來 filter 分頁）
//    Date         → 日期字串
//    Description  → 完整內文
//    ImageUrl     → 圖片網址
// ═══════════════════════════════════════════════════════════════

// ─── 資料模型 ──────────────────────────────────────────────────

class ActivityItem {
  final String id;
  final String name;
  final String category;
  final String date;
  final String description;
  final String imageUrl;
  final String imageBase64; // ✨ Base64 圖片支援
  final List<String> tags;

  const ActivityItem({
    required this.id,
    required this.name,
    required this.category,
    required this.date,
    required this.description,
    required this.tags,
    required this.imageUrl,
    this.imageBase64 = '',
  });

  factory ActivityItem.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ActivityItem(
      id:          doc.id,
      name:        d['ActivityName'] as String? ?? '(未命名)',
      category:    d['Category']     as String? ?? '活動',
      date:        d['Date']         as String? ?? '',
      description: d['Description']  as String? ?? '',
      tags:        List<String>.from(d['Tags'] as List? ?? []),
      imageUrl:    d['ImageUrl']     as String? ?? '',
      imageBase64: d['ImageBase64']  as String? ?? '', // ✨
    );
  }

  /// 把 Category 字串對應到顯示用的短標籤與顏色
  String get tagLabel {
    switch (category) {
      case '休閒活動': return '活動';
      case '官方公告': return '官方';
      case '系統通知': return '系統';
      default:        return category.length > 4 ? category.substring(0, 4) : category;
    }
  }

  Color get tagColor {
    switch (category) {
      case '休閒活動': return const Color(0xFF8BAA88);
      case '官方公告': return const Color(0xFF7D6E5D);
      case '系統通知': return const Color(0xFFA5CBD4);
      default:        return const Color(0xFFE8A020);
    }
  }

  /// 分頁 filter 判斷
  bool matchesTab(int tabIndex) {
    switch (tabIndex) {
      case 0: return true;                    // 全部
      case 1: return category == '官方公告';  // 官方公告
      case 2: return category == '休閒活動';  // 在地活動
      case 3: return category == '系統通知';  // 系統通知
      default: return true;
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  主頁面
// ═══════════════════════════════════════════════════════════════

class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});
  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  int _selected = 0;
  final _tabs = ['全部', '官方公告', '在地活動', '系統通知'];
  final TextEditingController _searchCtrl = TextEditingController();
  // ★ ValueNotifier：搜尋結果更新不會觸發 StreamBuilder 重建，解決注音輸入中斷問題
  final ValueNotifier<String> _searchQuery = ValueNotifier('');
  // ★ Stream 快取在 state 層級，不在 build() 裡建立，避免每次 build 重訂閱
  late final Stream<List<ActivityItem>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = FirebaseFirestore.instance
        .collection('Activities')
        .snapshots()
        .map((snap) => snap.docs.map(ActivityItem.fromDoc).toList())
        .asBroadcastStream(); // 讓多個 listener 可以訂閱同一條 stream
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchQuery.dispose();
    super.dispose();
  }

  void _doSearch() {
    _searchQuery.value = _searchCtrl.text.trim();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _searchQuery.value = '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: StreamBuilder<List<ActivityItem>>(
        stream: _stream,
        builder: (context, snapshot) {
          // ── 載入中 ──
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF8BAA88),
                strokeWidth: 2,
              ),
            );
          }

          // ── 錯誤 ──
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_rounded, color: Color(0xFF9E9182), size: 48),
                  const SizedBox(height: 12),
                  Text('載入失敗，請稍後再試\n${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF9E9182), fontSize: 14)),
                ],
              ),
            );
          }

          final all = snapshot.data ?? [];

          // ★ ValueListenableBuilder 只重建 list 部分，不影響 TextField
          return ValueListenableBuilder<String>(
            valueListenable: _searchQuery,
            builder: (context, query, _) {
              final filtered = all.where((a) {
                final matchTab = a.matchesTab(_selected);
                final matchSearch = query.isEmpty ||
                    a.name.toLowerCase().contains(query.toLowerCase()) ||
                    a.description.toLowerCase().contains(query.toLowerCase()) ||
                    a.category.toLowerCase().contains(query.toLowerCase());
                return matchTab && matchSearch;
              }).toList();

              return Column(
                children: [
                  // ── 1. 上方導覽列 ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 60, 20, 16),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFF8BAA88).withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.black.withOpacity(0.02),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2))
                                ],
                              ),
                              child: const Icon(Icons.arrow_back_ios_new_rounded,
                                  size: 20, color: Color(0xFF7D6E5D)),
                            ),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('LATEST ',
                                    style: TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        fontSize: 26,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF7D6E5D),
                                        letterSpacing: 1.5)),
                                Text('NEWS',
                                    style: TextStyle(
                                        fontFamily: 'MyCustomFont',
                                        fontSize: 26,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF8BAA88),
                                        letterSpacing: 1.5)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF8BAA88).withOpacity(0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: const Color(0xFF8BAA88).withOpacity(0.3),
                                    width: 1),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.eco_rounded,
                                      size: 14, color: Color(0xFF8BAA88)),
                                  const SizedBox(width: 6),
                                  Text(
                                    '共 ${all.length} 則消息',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF7D6E5D)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // ── 2. 搜尋框（外觀保留，功能 TODO）──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(
                            color: const Color(0xFF8BAA88).withOpacity(0.3)),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 8,
                              offset: const Offset(0, 3))
                        ],
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          const Icon(Icons.search_rounded,
                              color: Color(0xFF8BAA88), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              // ★ 不用 onChanged — 避免每次按鍵都 setState 重建 StreamBuilder
                              // 打字不中斷，按搜尋鍵 / Enter 才觸發過濾
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) => _doSearch(),
                              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                              decoration: const InputDecoration(
                                hintText: '搜尋最新公告、活動...',
                                border: InputBorder.none,
                                hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF9E9182), fontSize: 14),
                              ),
                            ),
                          ),
                          if (_searchQuery.value.isNotEmpty)
                            GestureDetector(
                              onTap: _clearSearch,
                              child: const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.close_rounded, color: Color(0xFF9E9182), size: 18),
                              ),
                            ),
                          GestureDetector(
                            onTap: _doSearch,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                  right: 6, top: 6, bottom: 6),
                              child: Container(
                                padding:
                                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF8BAA88),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text('搜尋',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── 3. 分類 Tab ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: List.generate(_tabs.length, (i) {
                          final sel = i == _selected;
                          return GestureDetector(
                            onTap: () => setState(() => _selected = i),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              margin: const EdgeInsets.only(right: 10),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: sel
                                    ? const Color(0xFF8BAA88)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: sel
                                        ? const Color(0xFF8BAA88)
                                        : const Color(0xFF8BAA88)
                                        .withOpacity(0.2)),
                                boxShadow: [
                                  if (sel)
                                    BoxShadow(
                                        color: const Color(0xFF8BAA88)
                                            .withOpacity(0.25),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4))
                                ],
                              ),
                              child: Text(
                                _tabs[i],
                                style: TextStyle(
                                  color: sel
                                      ? Colors.white
                                      : const Color(0xFF7D6E5D),
                                  fontWeight: sel
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),

                  // ── 4. 消息列表 ──
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                      child: Text('目前沒有相關消息 🌱',
                          style: TextStyle(
                              color: Color(0xFF9E9182), fontSize: 16)),
                    )
                        : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      physics: const BouncingScrollPhysics(),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        return GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  NewsDetailScreen(activity: item),
                            ),
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xFF8BAA88).withOpacity(0.15)),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black.withOpacity(0.04),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4))
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // ── 上半部：圖片區 ──
                                  SizedBox(
                                    height: 160,
                                    width: double.infinity,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // 圖片（無圖時顯示抹茶色漸層）
                                        item.imageUrl.isNotEmpty
                                            ? Image.network(
                                          item.imageUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                          item.imageBase64.isNotEmpty
                                              ? Image.memory(base64Decode(item.imageBase64), fit: BoxFit.cover)
                                              : _PlaceholderBg(color: item.tagColor),
                                        )
                                            : item.imageBase64.isNotEmpty
                                            ? Image.memory(base64Decode(item.imageBase64), fit: BoxFit.cover)
                                            : _PlaceholderBg(color: item.tagColor),
                                        // 底部漸層，讓標籤可讀
                                        Positioned(
                                          bottom: 0, left: 0, right: 0,
                                          child: Container(
                                            height: 60,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.bottomCenter,
                                                end: Alignment.topCenter,
                                                colors: [
                                                  Colors.black.withOpacity(0.35),
                                                  Colors.transparent,
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        // 左上：分類標籤
                                        Positioned(
                                          top: 12, left: 12,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: item.tagColor,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              item.tagLabel,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w900),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // ── 下半部：文字區 ──
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // 日期（獨立一行，不放 Row 裡，避免溢位）
                                        Text(
                                          item.date,
                                          style: const TextStyle(
                                              color: Color(0xFF9E9182),
                                              fontSize: 12),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 8),
                                        // 標題
                                        Text(
                                          item.name,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w900,
                                              color: Color(0xFF7D6E5D),
                                              height: 1.3),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 8),
                                        // 摘要
                                        Text(
                                          item.description,
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: const Color(0xFF7D6E5D)
                                                  .withOpacity(0.65),
                                              height: 1.5),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 12),
                                        // 閱讀更多
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            Text('閱讀更多',
                                                style: TextStyle(
                                                    color: const Color(0xFF8BAA88),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w800)),
                                            const SizedBox(width: 4),
                                            const Icon(Icons.arrow_forward_rounded,
                                                size: 14, color: Color(0xFF8BAA88)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );    // end of Column
            },   // end of ValueListenableBuilder.builder
          );   // end of ValueListenableBuilder
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  消息詳情頁
// ═══════════════════════════════════════════════════════════════

class NewsDetailScreen extends StatefulWidget {
  final ActivityItem activity;

  const NewsDetailScreen({super.key, required this.activity});

  @override
  State<NewsDetailScreen> createState() => _NewsDetailScreenState();
}

class _NewsDetailScreenState extends State<NewsDetailScreen> {
  bool _isAdded = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkIfAdded();
  }

  // ★ 查詢 Firestore，確認此活動是否已加入月曆（重新進入頁面時保持灰色）
  Future<void> _checkIfAdded() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('calendar_events')
          .where('news_activity_id', isEqualTo: widget.activity.id)
          .limit(1)
          .get();
      if (mounted && snap.docs.isNotEmpty) {
        setState(() => _isAdded = true);
      }
    } catch (_) {}
  }

  // 從活動日期字串嘗試萃取 yyyy-MM-dd 格式
  String _parseDate(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final match = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(cleaned);
    if (match != null) {
      final y = match.group(1)!;
      final m = match.group(2)!.padLeft(2, '0');
      final d = match.group(3)!.padLeft(2, '0');
      return '$y-$m-$d';
    }
    return cleaned.split(' ').first;
  }

  // ✨ 從活動日期字串萃取結束日期（如 "2026/06/01 ~ 2026/06/23" 抓第二個）
  String _parseEndDate(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final matches = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})').allMatches(cleaned).toList();
    if (matches.length >= 2) {
      final m = matches[1];
      final y = m.group(1)!;
      final mo = m.group(2)!.padLeft(2, '0');
      final d = m.group(3)!.padLeft(2, '0');
      return '$y-$mo-$d';
    }
    return '';
  }

  // 建立 CalendarEvent 供加入提醒用
  CalendarEvent _buildCalendarEvent() => CalendarEvent(
    id: '',
    type: CalendarEventType.officialEvent,
    title: widget.activity.name,
    date: _parseDate(widget.activity.date),
    endDate: _parseEndDate(widget.activity.date), // ✨
    time: '',
    location: widget.activity.category.isNotEmpty ? widget.activity.category : '嘉義活動',
    desc: widget.activity.description,
    image: widget.activity.imageUrl.isNotEmpty
        ? widget.activity.imageUrl
        : (widget.activity.imageBase64.isNotEmpty ? 'base64:${widget.activity.imageBase64}' : ''), // ✨
    tags: widget.activity.tags,
    newsActivityId: widget.activity.id,
    createdAt: DateTime.now(),
  );

  // 分享彈窗（與 calendar_screen EventDetailScreen 同邏輯）
  void _showShareDialog() {
    final emailCtrl = TextEditingController();
    Map<String, String>? foundUser;
    bool isSearching = false;
    String? errorMsg;
    bool isSent = false;
    bool isSending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            decoration: BoxDecoration(color: const Color(0xFFF9F8F4), borderRadius: BorderRadius.circular(28)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
                const Text('分享消息', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 4),
                Text('對方會在首頁鈴鐺收到通知，點擊可查看消息介紹', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 14),
                // 活動預覽
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.25))),
                  child: Row(children: [
                    if (widget.activity.imageUrl.isNotEmpty || widget.activity.imageBase64.isNotEmpty)
                      ClipRRect(borderRadius: BorderRadius.circular(8),
                          child: widget.activity.imageUrl.isNotEmpty
                              ? Image.network(widget.activity.imageUrl, width: 48, height: 48, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                              widget.activity.imageBase64.isNotEmpty
                                  ? Image.memory(base64Decode(widget.activity.imageBase64), width: 48, height: 48, fit: BoxFit.cover)
                                  : Container(width: 48, height: 48, color: const Color(0xFFE8E0D8)))
                              : Image.memory(base64Decode(widget.activity.imageBase64), width: 48, height: 48, fit: BoxFit.cover))
                    else
                      Container(width: 48, height: 48,
                          decoration: BoxDecoration(color: const Color(0xFF8BAA88).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.event_rounded, color: Color(0xFF8BAA88), size: 24)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.activity.name, style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D), fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(widget.activity.date, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ])),
                  ]),
                ),
                const SizedBox(height: 14),
                // Email 輸入
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
                      onChanged: (_) => setS(() { foundUser = null; errorMsg = null; isSent = false; }),
                      decoration: InputDecoration(
                        hintText: '輸入對方 Email…',
                        hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey[400], fontSize: 13),
                        prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF8BAA88), size: 18),
                        filled: true, fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(height: 46, child: ElevatedButton(
                    onPressed: isSearching ? null : () async {
                      final email = emailCtrl.text.trim();
                      if (email.isEmpty) { setS(() => errorMsg = '請輸入 Email'); return; }
                      setS(() { isSearching = true; foundUser = null; errorMsg = null; isSent = false; });
                      final r = await CalendarEventService.instance.findUserByEmail(email);
                      final myUid = FirebaseAuth.instance.currentUser?.uid;
                      setS(() {
                        isSearching = false;
                        if (r == null) errorMsg = '找不到此 Email 的使用者';
                        else if (r['uid'] == myUid) errorMsg = '不能分享給自己';
                        else { foundUser = r; errorMsg = null; }
                      });
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), padding: const EdgeInsets.symmetric(horizontal: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: isSearching
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('搜尋', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  )),
                ]),
                if (errorMsg != null)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text(errorMsg!, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFD4A017), fontSize: 12, fontWeight: FontWeight.bold))),
                if (foundUser != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8BAA88).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                    ),
                    child: Row(children: [
                      CircleAvatar(radius: 18, backgroundColor: const Color(0xFF8BAA88).withOpacity(0.2),
                          child: Text((foundUser!['displayName'] ?? '?')[0].toUpperCase(),
                              style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold))),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(foundUser!['displayName'] ?? '使用者', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(foundUser!['email'] ?? '', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 11)),
                      ])),
                      if (isSent)
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF8BAA88), size: 20)
                      else
                        ElevatedButton(
                          onPressed: isSending ? null : () async {
                            setS(() => isSending = true);
                            final event = _buildCalendarEvent();
                            final r = await CalendarEventService.instance.shareEventToUser(
                              targetEmail: foundUser!['email']!,
                              event: event,
                            );
                            setS(() { isSending = false; isSent = r == 'ok'; });
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                content: Text(r == 'ok' ? '✅ 通知已成功發送給 ${foundUser!['displayName']}！' : '❌ 發送失敗',
                                    style: const TextStyle(fontFamily: 'MyCustomFont')),
                                backgroundColor: r == 'ok' ? const Color(0xFF8BAA88) : const Color(0xFF9E7B6B),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ));
                            }
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8BAA88), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                          child: isSending
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('發送', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── 頂部圖片 AppBar ──
          SliverAppBar(
            expandedHeight: 250.0,
            pinned: true,
            backgroundColor: const Color(0xFFF9F8F4),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    shape: BoxShape.circle),
                child: const Icon(Icons.arrow_back_ios_new_rounded,
                    size: 18, color: Color(0xFF7D6E5D)),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // 有圖就顯示，沒有就用純色替代
                  widget.activity.imageUrl.isNotEmpty
                      ? Image.network(
                    widget.activity.imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                    widget.activity.imageBase64.isNotEmpty
                        ? Image.memory(base64Decode(widget.activity.imageBase64), fit: BoxFit.cover)
                        : Container(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                  )
                      : widget.activity.imageBase64.isNotEmpty
                      ? Image.memory(base64Decode(widget.activity.imageBase64), fit: BoxFit.cover)
                      : Container(color: const Color(0xFF8BAA88).withOpacity(0.3)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          const Color(0xFFF9F8F4).withOpacity(0.9)
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 文章內容 ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 標籤 + 日期（橫排，日期用 Flexible 防溢位）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: widget.activity.tagColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          widget.activity.tagLabel,
                          style: TextStyle(
                              color: widget.activity.tagColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w900),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Icon(Icons.access_time_rounded,
                          size: 13, color: Color(0xFF9E9182)),
                      const SizedBox(width: 4),
                      // Flexible 讓日期在空間不足時自動換行，不會撐破 Row
                      Flexible(
                        child: Text(
                          // 把原始日期字串的換行/多空白壓成單行
                          widget.activity.date
                              .replaceAll(RegExp(r'\s+'), ' ')
                              .trim(),
                          style: const TextStyle(
                              color: Color(0xFF9E9182),
                              fontSize: 12,
                              height: 1.4),
                          softWrap: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // 大標題
                  Text(
                    widget.activity.name,
                    style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF7D6E5D),
                        height: 1.3,
                        letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 24),

                  // 分隔線
                  Container(
                      height: 1.5,
                      width: 60,
                      color: const Color(0xFF8BAA88).withOpacity(0.5)),
                  const SizedBox(height: 24),

                  // 完整內文 + hashtag chips
                  _DescriptionWithTags(
                    description: widget.activity.description,
                    tags: widget.activity.tags,
                    tagColor: widget.activity.tagColor,
                  ),

                  const SizedBox(height: 40),

                  // 底部按鈕
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showShareDialog,
                          icon: const Icon(Icons.share_rounded,
                              size: 18, color: Color(0xFF8BAA88)),
                          label: const Text('分享資訊',
                              style: TextStyle(
                                  color: Color(0xFF8BAA88),
                                  fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(
                                color: const Color(0xFF8BAA88).withOpacity(0.5)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: (_isAdded || _isLoading) ? null : () async {
                            setState(() => _isLoading = true);
                            final event = _buildCalendarEvent();
                            final ok = await CalendarEventService.instance.addEventReminder(event);
                            if (mounted) {
                              setState(() { _isAdded = ok || _isAdded; _isLoading = false; });
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                  ok ? '✅ 已加入月曆！可到「活動月曆」依日期查看' : '⚠️ 此活動已在月曆中',
                                  style: const TextStyle(fontFamily: 'MyCustomFont'),
                                ),
                                backgroundColor: ok ? const Color(0xFF8BAA88) : const Color(0xFF9EB89A),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ));
                            }
                          },
                          icon: Icon(_isAdded ? Icons.check_rounded : Icons.calendar_today_rounded,
                              size: 18, color: Colors.white),
                          label: Text(_isAdded ? '已加入月曆' : '加入月曆',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: _isAdded ? const Color(0xFF9EB89A) : const Color(0xFF8BAA88),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 圖片載入失敗 / 無圖時的佔位背景 ───────────────────────────

class _PlaceholderBg extends StatelessWidget {
  final Color color;
  const _PlaceholderBg({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(0.3), color.withOpacity(0.6)],
        ),
      ),
      child: Center(
        child: Icon(Icons.image_not_supported_outlined,
            color: color.withOpacity(0.4), size: 40),
      ),
    );
  }
}

// ─── Description 顯示：正文 + hashtag chips ──────────────────────
// description 已在 JSON 預處理時清理完畢（正文中 # 已去除）
// tags 直接從 ActivityItem.tags 傳入，不再做任何解析

class _DescriptionWithTags extends StatelessWidget {
  final String description;
  final List<String> tags;
  final Color tagColor;

  const _DescriptionWithTags({
    required this.description,
    required this.tags,
    required this.tagColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 正文（直接顯示，換行結構已在 JSON 處理好）──
        if (description.isNotEmpty)
          Text(
            description,
            style: const TextStyle(
              fontSize: 16,
              color: Color(0xFF4A4036),
              height: 1.8,
              letterSpacing: 0.3,
            ),
          ),

        // ── Hashtag chips（來自 Tags 欄位）──
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tagColor.withOpacity(0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tagColor.withOpacity(0.15)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: tagColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: tagColor.withOpacity(0.25)),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 12,
                      color: tagColor.withOpacity(0.9),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }
}