import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminDataManageScreen extends StatefulWidget {
  const AdminDataManageScreen({super.key});

  @override
  State<AdminDataManageScreen> createState() => _AdminDataManageScreenState();
}

class _AdminDataManageScreenState extends State<AdminDataManageScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<Map<String, String>> _categories = [
    {'title': '活動', 'collection': 'Activities'},
    {'title': '景點', 'collection': 'Attractions'},
    {'title': '住宿', 'collection': 'Hotels'},
    {'title': '美食', 'collection': 'Restaurants'},
  ];

  // ── 各集合可編輯的欄位定義 ──────────────────────────────────
  // key = Firestore 欄位名稱, label = 顯示名稱, multiline = 是否多行
  static const Map<String, List<Map<String, dynamic>>> _editFields = {
    'Activities': [
      {'key': 'ActivityName',  'label': '活動名稱',   'multiline': false},
      {'key': 'Description',   'label': '活動描述',   'multiline': true},
      {'key': 'Location',      'label': '活動地點',   'multiline': false},
      {'key': 'StartDate',     'label': '開始日期',   'multiline': false},
      {'key': 'EndDate',       'label': '結束日期',   'multiline': false},
    ],
    'Attractions': [
      {'key': 'AttractionName',  'label': '景點名稱',   'multiline': false},
      {'key': 'Description',     'label': '景點描述',   'multiline': true},
      {'key': 'Address',         'label': '地址',       'multiline': false},
      {'key': 'ServiceTimeInfo', 'label': '開放時間',   'multiline': false},
      {'key': 'TrafficInfo',     'label': '交通資訊',   'multiline': true},
    ],
    'Hotels': [
      {'key': 'HotelName',    'label': '住宿名稱',   'multiline': false},
      {'key': 'Description',  'label': '住宿描述',   'multiline': true},
      {'key': 'Address',      'label': '地址',       'multiline': false},
      {'key': 'Phone',        'label': '電話',       'multiline': false},
      {'key': 'LowestPrice',  'label': '最低價格',   'multiline': false},
      {'key': 'WebsiteUrl',   'label': '官方網站',   'multiline': false},
    ],
    'Restaurants': [
      {'key': 'RestaurantName', 'label': '餐廳名稱',   'multiline': false},
      {'key': 'Description',    'label': '餐廳描述',   'multiline': true},
      {'key': 'Address',        'label': '地址',       'multiline': false},
      {'key': 'OpenTime',       'label': '營業時間',   'multiline': false},
      {'key': 'Phone',          'label': '電話',       'multiline': false},
    ],
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _getItemName(Map<String, dynamic> data, String collection) {
    switch (collection) {
      case 'Activities':  return data['ActivityName']?.toString()  ?? '未命名活動';
      case 'Attractions': return data['AttractionName']?.toString() ?? '未命名景點';
      case 'Hotels':      return data['HotelName']?.toString()      ?? '未命名住宿';
      case 'Restaurants': return data['RestaurantName']?.toString() ?? '未命名美食';
      default:            return '未知名稱';
    }
  }

  // ── 編輯 Dialog ───────────────────────────────────────────────
  void _showEditDialog(
      BuildContext context,
      String collection,
      String docId,
      Map<String, dynamic> data,
      ) {
    final fields = _editFields[collection] ?? [];
    // 建立每個欄位的 TextEditingController，預填現有值
    final controllers = <String, TextEditingController>{
      for (final f in fields)
        f['key'] as String: TextEditingController(
          text: data[f['key']]?.toString() ?? '',
        ),
    };
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: const Color(0xFFF9F8F4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──
              Container(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF8BAA88),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '編輯${_categories.firstWhere((c) => c['collection'] == collection)['title']}',
                        style: const TextStyle(
                          fontFamily: 'MyCustomFont',
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),

              // ── 欄位列表 ──
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Column(
                    children: fields.map((f) {
                      final key = f['key'] as String;
                      final label = f['label'] as String;
                      final multiline = f['multiline'] as bool;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: TextField(
                          controller: controllers[key],
                          maxLines: multiline ? 4 : 1,
                          style: const TextStyle(
                            fontFamily: 'MyCustomFont',
                            color: Color(0xFF7D6E5D),
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            labelText: label,
                            labelStyle: const TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: Color(0xFF8BAA88),
                              fontWeight: FontWeight.bold,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                  color: Colors.grey.withOpacity(0.2)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                  color: Colors.grey.withOpacity(0.2)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                  color: Color(0xFF8BAA88), width: 1.5),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

              // ── 底部按鈕 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(
                              color: Colors.grey.withOpacity(0.4)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text(
                          '取消',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: Colors.grey,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: isSaving
                            ? null
                            : () async {
                          setS(() => isSaving = true);
                          try {
                            // 只寫有值的欄位（避免覆蓋其他欄位如 Images）
                            final updates = <String, dynamic>{};
                            for (final f in fields) {
                              final key = f['key'] as String;
                              final val =
                              controllers[key]!.text.trim();
                              updates[key] = val;
                            }
                            await FirebaseFirestore.instance
                                .collection(collection)
                                .doc(docId)
                                .update(updates);

                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('✅ 已成功更新',
                                    style: TextStyle(
                                        fontFamily: 'MyCustomFont')),
                                backgroundColor: Color(0xFF8BAA88),
                                behavior: SnackBarBehavior.floating,
                              ));
                            }
                          } catch (e) {
                            setS(() => isSaving = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(
                                content: Text('❌ 更新失敗：$e',
                                    style: const TextStyle(
                                        fontFamily: 'MyCustomFont')),
                                backgroundColor:
                                const Color(0xFFB07070),
                                behavior: SnackBarBehavior.floating,
                              ));
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: const Color(0xFF8BAA88),
                          disabledBackgroundColor:
                          const Color(0xFF8BAA88).withOpacity(0.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: isSaving
                            ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                            : const Text(
                          '儲存',
                          style: TextStyle(
                              fontFamily: 'MyCustomFont',
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 刪除確認 ─────────────────────────────────────────────────
  Future<void> _confirmDelete(
      BuildContext context,
      String collection,
      String docId,
      String itemName,
      ) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFB07070)),
            SizedBox(width: 8),
            Text('確認刪除',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF7D6E5D))),
          ],
        ),
        content: Text(
          '確定要永久刪除「$itemName」嗎？\n此動作無法復原喔！',
          style: const TextStyle(
              fontFamily: 'MyCustomFont',
              color: Color(0xFF7D6E5D),
              height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style:
                TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await FirebaseFirestore.instance
                    .collection(collection)
                    .doc(docId)
                    .delete();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('🗑️ 已刪除 $itemName',
                      style: const TextStyle(fontFamily: 'MyCustomFont')),
                  backgroundColor: const Color(0xFF8BAA88),
                  behavior: SnackBarBehavior.floating,
                ));
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('❌ 刪除失敗: $e',
                      style: const TextStyle(fontFamily: 'MyCustomFont')),
                  backgroundColor: const Color(0xFFB07070),
                  behavior: SnackBarBehavior.floating,
                ));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFB07070),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('確定刪除',
                style: TextStyle(
                    fontFamily: 'MyCustomFont',
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F8F4),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5),
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Color(0xFF7D6E5D)),
        title: const Text('資料管理中心',
            style: TextStyle(
                fontFamily: 'MyCustomFont',
                color: Color(0xFF7D6E5D),
                fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabController,
          labelColor: const Color(0xFF8BAA88),
          unselectedLabelColor: Colors.grey[400],
          indicatorColor: const Color(0xFF8BAA88),
          indicatorWeight: 3,
          labelStyle: const TextStyle(
              fontFamily: 'MyCustomFont',
              fontWeight: FontWeight.bold,
              fontSize: 16),
          tabs: _categories.map((c) => Tab(text: c['title'])).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children:
        _categories.map((c) => _buildDataList(c['collection']!)).toList(),
      ),
    );
  }

  Widget _buildDataList(String collectionName) {
    return StreamBuilder<QuerySnapshot>(
      stream:
      FirebaseFirestore.instance.collection(collectionName).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
              child:
              CircularProgressIndicator(color: Color(0xFF8BAA88)));
        }
        if (snapshot.hasError) {
          return const Center(
              child: Text('載入發生錯誤',
                  style: TextStyle(fontFamily: 'MyCustomFont')));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_open_rounded,
                    size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                const Text('目前沒有任何資料',
                    style: TextStyle(
                        fontFamily: 'MyCustomFont', color: Colors.grey)),
              ],
            ),
          );
        }

        final docs = snapshot.data!.docs;

        return ListView.separated(
          padding: const EdgeInsets.all(20),
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data() as Map<String, dynamic>;
            final itemName = _getItemName(data, collectionName);

            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF8BAA88).withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ],
              ),
              child: ListTile(
                contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: const Color(0xFF8BAA88).withOpacity(0.1),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.insert_drive_file_rounded,
                      color: Color(0xFF8BAA88)),
                ),
                title: Text(
                  itemName,
                  style: const TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF7D6E5D)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'ID: ${doc.id}',
                  style: TextStyle(
                      fontFamily: 'MyCustomFont',
                      fontSize: 11,
                      color: Colors.grey[500]),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ✏️ 編輯按鈕
                    IconButton(
                      icon: const Icon(Icons.edit_rounded,
                          color: Color(0xFF6B8EAD)),
                      tooltip: '編輯',
                      onPressed: () => _showEditDialog(
                          context, collectionName, doc.id, data),
                    ),
                    // 🗑️ 刪除按鈕
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded,
                          color: Color(0xFFB07070)),
                      tooltip: '刪除',
                      onPressed: () => _confirmDelete(
                          context, collectionName, doc.id, itemName),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}