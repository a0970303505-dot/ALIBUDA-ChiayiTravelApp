import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AdminAccountManageScreen extends StatefulWidget {
  const AdminAccountManageScreen({super.key});

  @override
  State<AdminAccountManageScreen> createState() => _AdminAccountManageScreenState();
}

class _AdminAccountManageScreenState extends State<AdminAccountManageScreen> {
  // 取得當前登入管理員的 UID，用來防止「自己停權自己」
  final String? _currentAdminUid = FirebaseAuth.instance.currentUser?.uid;

  // 🛑 切換帳號停權狀態與防呆確認
  Future<void> _toggleUserStatus(BuildContext context, String uid, String userName, bool isCurrentlySuspended) async {
    final actionName = isCurrentlySuspended ? '解除停權' : '停權';
    final actionColor = isCurrentlySuspended ? const Color(0xFF8BAA88) : const Color(0xFFB07070);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFCF5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(isCurrentlySuspended ? Icons.check_circle_outline_rounded : Icons.block_rounded, color: actionColor),
            const SizedBox(width: 8),
            Text('確認$actionName', style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
          ],
        ),
        content: Text('確定要將「$userName」$actionName嗎？', style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx); // 先關閉對話框
              try {
                // 更新 Firestore 中該使用者的 isSuspended 欄位
                await FirebaseFirestore.instance.collection('users').doc(uid).update({
                  'isSuspended': !isCurrentlySuspended,
                });

                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ 已將 $userName $actionName'), backgroundColor: actionColor),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('❌ 狀態更新失敗: $e'), backgroundColor: const Color(0xFFB07070)),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: actionColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('確定$actionName', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
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
        title: const Text('會員帳號管理', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        // 監聽 users 集合
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)));
          }
          if (snapshot.hasError) {
            return const Center(child: Text('載入發生錯誤', style: TextStyle(fontFamily: 'MyCustomFont')));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.group_off_rounded, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  const Text('目前還沒有任何註冊會員', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey)),
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
              final uid = doc.id;

              // 容錯處理：抓取名稱或 Email
              final userName = data['displayName'] ?? data['name'] ?? '未知使用者';
              final email = data['email'] ?? '無 Email 資訊';
              final isAdmin = data['isAdmin'] == true;
              final isSuspended = data['isSuspended'] == true;

              // 判斷是不是自己
              final isMe = uid == _currentAdminUid;

              return Container(
                decoration: BoxDecoration(
                  color: isSuspended ? const Color(0xFFF5E8E8) : Colors.white, // 停權的話背景稍微變紅
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isSuspended ? const Color(0xFFB07070).withOpacity(0.3) : const Color(0xFF8BAA88).withOpacity(0.2)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: CircleAvatar(
                    backgroundColor: isAdmin ? const Color(0xFF6B8EAD) : const Color(0xFF8BAA88),
                    child: Text(
                      userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
                      style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          userName,
                          style: TextStyle(
                            fontFamily: 'MyCustomFont',
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isSuspended ? const Color(0xFFB07070) : const Color(0xFF7D6E5D),
                            decoration: isSuspended ? TextDecoration.lineThrough : TextDecoration.none, // 停權加刪除線
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isAdmin)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6B8EAD).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('管理員', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Color(0xFF6B8EAD), fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    email,
                    style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey[500]),
                  ),
                  trailing: isMe
                      ? const Padding(
                    padding: EdgeInsets.only(right: 8.0),
                    child: Text('您自己', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                  )
                      : ElevatedButton(
                    onPressed: () => _toggleUserStatus(context, uid, userName, isSuspended),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isSuspended ? Colors.white : const Color(0xFFB07070).withOpacity(0.1),
                      foregroundColor: isSuspended ? const Color(0xFF8BAA88) : const Color(0xFFB07070),
                      elevation: 0,
                      side: BorderSide(color: isSuspended ? const Color(0xFF8BAA88) : Colors.transparent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(
                      isSuspended ? '解除' : '停權',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}