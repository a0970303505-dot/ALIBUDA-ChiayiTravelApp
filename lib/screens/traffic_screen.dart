import 'dart:async';
import 'package:flutter/material.dart';
import 'traffic_api_service.dart';

// ═══════════════════════════════════════════════════════════════
//  交通資訊主頁面 & 各大專屬子頁面
//  配色：抹茶綠 #8BAA88 / 暖褐 #7D6E5D / 米白 #F9F8F4 / 淡藍 #7FA3B0
// ═══════════════════════════════════════════════════════════════

const _green = Color(0xFF8BAA88);
const _brown = Color(0xFF7D6E5D);
const _cream = Color(0xFFF9F8F4);
const _blue  = Color(0xFF7FA3B0);

// ════════════════════════════════════════════════════════════════
//  主頁面
// ════════════════════════════════════════════════════════════════
class TrafficScreen extends StatefulWidget {
  const TrafficScreen({super.key});
  @override
  State<TrafficScreen> createState() => _TrafficScreenState();
}

class _TrafficScreenState extends State<TrafficScreen> {
  List<BusEntry>     _liveBuses    = [];
  List<TrainEntry>   _liveTrains   = [];
  List<UbikeEntry>   _liveUbike    = [];
  List<ParkingEntry> _liveParking  = [];
  bool _homeRefreshing = false;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _loadLiveData();
  }

  Future<void> _loadLiveData() async {
    setState(() => _homeRefreshing = true);
    try {
      final results = await Future.wait([
        TrafficApiService().fetchBus(),
        TrafficApiService().fetchTrain(),
        TrafficApiService().fetchUbike(),
        TrafficApiService().fetchParking(),
      ]);
      if (mounted) setState(() {
        _liveBuses   = results[0] as List<BusEntry>;
        _liveTrains  = results[1] as List<TrainEntry>;
        _liveUbike   = results[2] as List<UbikeEntry>;
        _liveParking = results[3] as List<ParkingEntry>;
        _homeRefreshing = false;
        _lastUpdated = DateTime.now().toUtc().add(const Duration(hours: 8));
      });
    } catch (_) {
      if (mounted) setState(() => _homeRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),
          SliverToBoxAdapter(child: _buildGridSection(context)),
          SliverToBoxAdapter(child: _buildLiveHeader()),
          SliverToBoxAdapter(child: _buildLiveSection()),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 65, 20, 10),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _backBtn(context),
          const Row(children: [
            Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: _brown)),
            Text('TRANSIT', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: _green)),
          ]),
          const SizedBox(width: 44), // 平衡左側返回鍵
        ]),
        const SizedBox(height: 12),
        Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _green.withOpacity(0.5), width: 1.2)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.directions_bus_rounded, size: 14, color: _green),
            SizedBox(width: 6),
            Text('交通資訊系統', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: _green)),
          ]),
        )),
      ]),
    );
  }

  // ─── 最新動態標題列（含刷新鍵 + 更新時間）───
  Widget _buildLiveHeader() {
    final timeStr = _lastUpdated != null
        ? '${_lastUpdated!.hour.toString().padLeft(2,'0')}:${_lastUpdated!.minute.toString().padLeft(2,'0')} 更新'
        : '載入中...';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
      child: Row(children: [
        Container(width: 4, height: 20,
            decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 10),
        const Icon(Icons.sensors_rounded, size: 20, color: _brown),
        const SizedBox(width: 8),
        const Text('最新動態', style: TextStyle(
            fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900,
            color: _brown, letterSpacing: 1.2)),
        const Spacer(),
        if (_lastUpdated != null)
          Text(timeStr, style: const TextStyle(
              fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _homeRefreshing ? null : _loadLiveData,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _homeRefreshing ? _green.withOpacity(0.05) : _green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _green.withOpacity(0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _homeRefreshing
                  ? const SizedBox(width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                  : const Icon(Icons.refresh_rounded, size: 13, color: _green),
              const SizedBox(width: 4),
              Text(_homeRefreshing ? '更新中' : '刷新',
                  style: const TextStyle(fontFamily: 'MyCustomFont',
                      fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildGridSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Column(children: [
        Row(children: [
          _gridBlock(context, '台鐵火車', Icons.train_rounded, _brown, Colors.white, const TrainInfoScreen()),
          const SizedBox(width: 16),
          _gridBlock(context, '市區公車', Icons.directions_bus_rounded, Colors.white, _green, const BusInfoScreen(), border: _green.withOpacity(0.3)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          _gridBlock(context, 'YouBike 2.0', Icons.pedal_bike_rounded, Colors.white, _brown, const YouBikeInfoScreen(), border: _brown.withOpacity(0.2)),
          const SizedBox(width: 16),
          _gridBlock(context, '停車場資訊', Icons.local_parking_rounded, _green, Colors.white, const ParkingInfoScreen()),
        ]),
      ]),
    );
  }

  Widget _gridBlock(BuildContext ctx, String title, IconData icon, Color bg, Color fg, Widget page, {Color? border}) {
    return Expanded(child: GestureDetector(
      onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => page)),
      child: AspectRatio(aspectRatio: 1, child: Container(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24),
            border: border != null ? Border.all(color: border, width: 1.5) : null,
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 5))]),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 48, color: fg),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontFamily: 'MyCustomFont', color: fg, fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
      )),
    ));
  }

  Color _lineColor(String routeName) {
    if (routeName.contains('中山') || routeName.contains('綠')) return _green;
    if (routeName.contains('忠孝') || routeName.contains('紅')) return const Color(0xFFE07B7B);
    if (routeName.contains('光林') || routeName.contains('黃')) return const Color(0xFFD4A84B);
    return _blue;
  }

  Widget _buildLiveSection() {
    if (_homeRefreshing && _liveBuses.isEmpty && _liveTrains.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: _green, strokeWidth: 2)),
      );
    }

    final List<Widget> tiles = [];

    // ── 公車（每輛車一筆，顯示車號 + 目前站）──
    for (final b in _liveBuses.take(4)) {
      if (b.routeName.isEmpty) continue;
      final c = _lineColor(b.routeName);
      final plate = b.plateNumb.isNotEmpty ? b.plateNumb : '';
      final currentStop = b.stopName.isNotEmpty && b.stopName != '沒有' ? b.stopName : null;
      // 解析 estimateTime（可能是秒數字串），過濾「接近中」
      String statusText;
      final etaParsed = int.tryParse(b.estimateTime);
      if (etaParsed != null && etaParsed >= 0) {
        if (etaParsed <= 30) statusText = '進站中';
        else if (etaParsed < 60) statusText = '即將到站';
        else statusText = '約 ${etaParsed ~/ 60} 分';
      } else if (b.estimateTime.isNotEmpty && b.estimateTime != '接近中') {
        statusText = b.estimateTime;
      } else {
        statusText = '行駛中';
      }

      tiles.add(_liveTile(
        icon: Icons.directions_bus_rounded,
        color: c,
        title: b.routeName,
        sub: currentStop != null
            ? '📍 現在：$currentStop'
            : '${b.departureStop} → ${b.destinationStop}',
        status: statusText,
        badge: plate.isNotEmpty ? plate : null,
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => BusInfoScreen(initialSearch: b.routeName))),
      ));
      if (tiles.length >= 3) break;
    }

    // ── 火車（最多2筆正在行駛的）──
    int trainCount = 0;
    for (final t in _liveTrains) {
      if (t.stationName.isEmpty || t.stationName == '沒有') continue;
      final c = t.trainTypeName.contains('自強') || t.trainTypeName.contains('太魯閣') || t.trainTypeName.contains('普悠瑪')
          ? _brown : t.trainTypeName.contains('莒光') ? _blue : _green;
      tiles.add(_liveTile(
        icon: Icons.train_rounded,
        color: c,
        title: '${t.trainTypeName} ${t.trainNo}',
        sub: '📍 現在：${t.stationName}',
        status: t.delayTime == '沒有' ? '準點' : t.delayTime,
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => const TrainInfoScreen())),
      ));
      trainCount++;
      if (trainCount >= 2) break;
    }

    // ── 停車場（有即時資料的前2筆）──
    int parkCount = 0;
    for (final p in _liveParking) {
      if (p.remainingSpace == null) continue;
      final full = p.remainingSpace == 0;
      final color = full ? _brown : (p.remainingSpace! < 10 ? Colors.orange : _green);
      tiles.add(_liveTile(
        icon: Icons.local_parking_rounded,
        color: color,
        title: p.carParkName,
        sub: p.address.isNotEmpty && p.address != '請參考場站名稱導航'
            ? p.address : p.carParkType,
        status: full ? '已滿' : '剩 ${p.remainingSpace}',
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => const ParkingInfoScreen())),
      ));
      parkCount++;
      if (parkCount >= 2) break;
    }

    if (tiles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _green.withOpacity(0.1)),
          ),
          child: Column(children: [
            Icon(Icons.wifi_off_rounded, size: 32, color: _green.withOpacity(0.3)),
            const SizedBox(height: 8),
            const Text('尚無即時資料，請點刷新', style: TextStyle(
                fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 13)),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Column(children: [
        for (int i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          tiles[i],
        ],
      ]),
    );
  }

  Widget _liveTile({
    required IconData icon,
    required Color color,
    required String title,
    required String sub,
    required String status,
    String? badge,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.15)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(
                  fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold,
                  fontSize: 14, color: _brown), overflow: TextOverflow.ellipsis)),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(badge, style: TextStyle(
                      fontFamily: 'MyCustomFont', fontSize: 10,
                      color: color, fontWeight: FontWeight.bold)),
                ),
              ],
            ]),
            const SizedBox(height: 3),
            Text(sub, style: const TextStyle(
                fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis),
          ])),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Text(status, style: TextStyle(
                fontFamily: 'MyCustomFont', color: color,
                fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  共用 Widget 函式
// ════════════════════════════════════════════════════════════════

Widget _backBtn(BuildContext context) {
  return GestureDetector(
    onTap: () => Navigator.pop(context),
    child: Container(width: 44, height: 44,
        decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)]),
        child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: _brown)),
  );
}

Widget _subPageHeader(BuildContext context, String titleEN, String titleTW, IconData icon) {
  return Container(
    padding: const EdgeInsets.fromLTRB(20, 65, 20, 10),
    child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        _backBtn(context),
        Row(children: [
          const Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: _brown)),
          Text(titleEN, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 24, fontWeight: FontWeight.bold, color: _green)),
        ]),
        const SizedBox(width: 44),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _green.withOpacity(0.4), width: 1.2),
            boxShadow: [BoxShadow(color: _green.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: _green), const SizedBox(width: 6),
          Text(titleTW, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.w900, color: _green)),
        ]),
      ),
    ]),
  );
}

Widget _sectionTitle(IconData icon, String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
    child: Row(children: [
      Container(width: 4, height: 20,
          decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 10),
      Icon(icon, size: 20, color: _brown),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 18, fontWeight: FontWeight.w900, color: _brown, letterSpacing: 1.2)),
    ]),
  );
}

void _showErrorDialog(BuildContext context, String msg) {
  showDialog(context: context, builder: (_) => AlertDialog(
    backgroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    title: const Row(children: [
      Icon(Icons.warning_amber_rounded, color: _brown),
      SizedBox(width: 8),
      Text('無法取得資料', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontSize: 16, fontWeight: FontWeight.bold)),
    ]),
    content: Text(msg, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 14)),
    actions: [TextButton(onPressed: () => Navigator.pop(context),
        child: const Text('確定', style: TextStyle(fontFamily: 'MyCustomFont', color: _green, fontWeight: FontWeight.bold)))],
  ));
}

// ════════════════════════════════════════════════════════════════
//  子頁面 1：台鐵火車（即時）
// ════════════════════════════════════════════════════════════════

// 台鐵西部幹線＋東部幹線由北至南排序（含常見支線站名）
const List<String> _kTraStationsNorthToSouth = [
  '基隆','八堵','七堵','百福','五堵','汐止','汐科','南港','松山','台北','萬華','板橋',
  '浮洲','樹林','山佳','鶯歌','桃園','內壢','中壢','埔心','楊梅','富岡','新富岡',
  '北湖','湖口','新豐','竹北','北新竹','新竹','三姓橋','香山','崎頂','竹南',
  '談文','大山','後龍','龍港','福興','苗栗','南勢','銅鑼','三義','泰安','大安',
  '豐原','栗林','潭子','頭家厝','松竹','太原','精武','台中','五權','烏日','新烏日',
  '成功','彰化','花壇','大村','員林','永靖','社頭','田中','二水','林內','石榴',
  '斗六','斗南','石龜','大林','民雄','北回','嘉義','水上','南靖','後壁','新營',
  '柳營','林鳳營','隆田','拔林','善化','南科','新市','永康','大橋','台南',
  '保安','仁德','中洲','長榮大學','沙崙','康橋','造橋','後庄',
  '路竹','岡山','橋頭','楠梓','新左營','左營','三塊厝','鼓山','台鐵高雄',
  '高雄','苓雅','五塊厝','鳳山','後庄','九曲堂','六塊厝','屏東','歸來',
  '麟洛','西勢','竹田','潮州','崁頂','南州','鎮安','林邊','佳冬','東海',
  '枋寮','加祿','內獅','枋山','看寮','卑南','知本','康樂','太麻里',
  '瀧溪','金崙','歸豐','大武','古莊','浮灣','多良','加典','枋野','枋寮',
  // 東部幹線（由北至南）
  '八堵','暖暖','四腳亭','瑞芳','三貂嶺','牡丹','雙溪','貢寮','福隆','石城',
  '大里','大溪','龜山','外澳','頭城','礁溪','四城','宜蘭','二結','中里',
  '羅東','冬山','新馬','蘇澳新','蘇澳','永樂','東澳','南澳','武塔','漢本',
  '和仁','和平','和中','崇德','新城','花蓮','吉安','志學','壽豐','豐田',
  '光復','萬榮','鳳林','南平','鳳榮','大富','富源','瑞穗','三民','玉里',
  '東里','東竹','富里','池上','海端','關山','瑞和','瑞源','鹿野','山里',
  '台東',
];

class TrainInfoScreen extends StatefulWidget {
  final String? initialSearch;
  const TrainInfoScreen({super.key, this.initialSearch});
  @override State<TrainInfoScreen> createState() => _TrainInfoScreenState();
}

class _TrainInfoScreenState extends State<TrainInfoScreen> {
  int _typeTab = 0; // 0=全部 1=對號列車 2=莒光復興 3=區間車
  int _dirTab  = 0; // 0=全部 1=往北 2=往南
  String? _selectedStart;
  String? _selectedEnd;
  List<TrainEntry> _allData = [];
  bool _loading = true;
  bool _refreshing = false;
  DateTime? _lastUpdated;
  DateTime? _serverNow; // ★ 記錄 server 台灣時間，供 _isDeparted 使用
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() { _scrollCtrl.dispose(); super.dispose(); }

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) setState(() => _refreshing = true);
    try {
      final data = await TrafficApiService().fetchTrain();
      if (mounted) {
        // ★ 使用 UTC+8 作為台灣時間（server 的 train_tdx.py 已改用 NTP，時間是正確的）
        final serverNow = DateTime.now().toUtc().add(const Duration(hours: 8));
        setState(() {
          _allData = data;
          _loading = false;
          _refreshing = false;
          _lastUpdated = DateTime.now();
          _serverNow = serverNow;
        });
        // 若有選站，選完後捲到最近班次
        if (_selectedStart != null && _selectedEnd != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNearest());
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _refreshing = false; });
        _showErrorDialog(context, '無法取得火車資料，請確認伺服器是否運作中。\n錯誤：$e');
      }
    }
  }

  // 判斷班次是否已離站（使用台灣時間，優先用 server 回傳時間）
  bool _isDeparted(TimetableStop boardStop) {
    try {
      // ★ 優先用 _serverNow（從 server 回傳的時間），確保不受虛擬機時間影響
      final tw = _serverNow ?? DateTime.now().toUtc().add(const Duration(hours: 8));
      final parts = boardStop.departureTime.split(':');
      if (parts.length < 2) return false;
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final nowMin = tw.hour * 60 + tw.minute;
      final depMin = h * 60 + m;
      return depMin < nowMin;
    } catch (_) { return false; }
  }

  // 找最近未離站的班次 index（在 availableTrains list 中）
  int _nearestIndex(List<Map<String, dynamic>> trains) {
    for (int i = 0; i < trains.length; i++) {
      final board = trains[i]['boardStop'] as TimetableStop;
      if (!_isDeparted(board)) return i;
    }
    return trains.isEmpty ? 0 : trains.length - 1;
  }

  void _scrollToNearest() {
    final trains = _availableTrains;
    if (trains.isEmpty || !_scrollCtrl.hasClients) return;
    final idx = _nearestIndex(trains);
    // 每個卡片約 110px 高（含 margin）
    const double cardHeight = 110.0;
    final offset = (idx * cardHeight) - 60.0; // 往上偏一點讓前一班也看得到
    _scrollCtrl.animateTo(
      offset.clamp(0.0, _scrollCtrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
    );
  }

  // ★ 車站清單：先按北→南固定順序，不在清單內的補在後面
  List<String> get _allStationsSorted {
    final set = <String>{};
    for (final t in _allData) {
      if (t.startingStationName.isNotEmpty && t.startingStationName != '沒有') set.add(t.startingStationName);
      if (t.endingStationName.isNotEmpty && t.endingStationName != '沒有') set.add(t.endingStationName);
      if (t.stationName.isNotEmpty && t.stationName != '沒有') set.add(t.stationName);
    }
    // 從時刻表裡也收集車站
    for (final t in _allData) {
      for (final s in t.timetable) {
        if (s.stationName.isNotEmpty && s.stationName != '沒有') set.add(s.stationName);
      }
    }
    final result = <String>[];
    // 先依北→南固定順序加入
    for (final s in _kTraStationsNorthToSouth) {
      if (set.contains(s)) result.add(s);
    }
    // 不在固定清單內的補在後面（字母排序）
    final extra = set.difference(result.toSet()).toList()..sort();
    result.addAll(extra);
    return result;
  }

  // ★ 選站 bottom sheet（下拉清單北→南）
  Future<void> _pickStation({required bool isStart}) async {
    final stations = _allStationsSorted;
    if (stations.isEmpty) {
      _showErrorDialog(context, '尚無車站資料，請稍候資料載入完成後再試。');
      return;
    }
    final searchCtrl = TextEditingController();
    String? picked;
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) {
        List<String> filtered = List.from(stations);
        return StatefulBuilder(builder: (ctx2, setModal) {
          return Container(
            height: MediaQuery.of(ctx2).size.height * 0.75,
            decoration: const BoxDecoration(
                color: Color(0xFFF9F8F4),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
            child: Column(children: [
              Container(margin: const EdgeInsets.only(top: 12), width: 36, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: isStart ? _green.withOpacity(0.12) : _brown.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(isStart ? '選擇上車站（由北至南）' : '選擇下車站（由北至南）',
                        style: TextStyle(fontFamily: 'MyCustomFont',
                            color: isStart ? _green : _brown,
                            fontSize: 15, fontWeight: FontWeight.w900)),
                  ),
                  const Spacer(),
                  GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close_rounded, color: Colors.grey)),
                ]),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Container(height: 44,
                    decoration: BoxDecoration(color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: _green.withOpacity(0.3)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8)]),
                    child: Row(children: [
                      const SizedBox(width: 14),
                      const Icon(Icons.search_rounded, color: _green, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: TextField(
                        controller: searchCtrl,
                        onChanged: (v) => setModal(() {
                          final q = v.trim();
                          filtered = q.isEmpty
                              ? List.from(stations)
                              : stations.where((s) => s.contains(q)).toList();
                        }),
                        decoration: const InputDecoration(
                            hintText: '搜尋車站名稱...', border: InputBorder.none, isDense: true,
                            hintStyle: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, color: Colors.grey)),
                      )),
                    ])),
              ),
              Expanded(child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 40),
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final s = filtered[i];
                  // 在北→南固定清單中的站顯示序號
                  final idx = _kTraStationsNorthToSouth.indexOf(s);
                  return GestureDetector(
                    onTap: () { picked = s; Navigator.pop(ctx); },
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.grey.withOpacity(0.1)),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6)]),
                      child: Row(children: [
                        if (idx >= 0)
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                                color: isStart ? _green.withOpacity(0.12) : _brown.withOpacity(0.12),
                                shape: BoxShape.circle),
                            child: Center(child: Text('${idx + 1}',
                                style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10,
                                    color: isStart ? _green : _brown, fontWeight: FontWeight.bold))),
                          )
                        else
                          Icon(Icons.train_rounded, color: isStart ? _green : _brown, size: 18),
                        const SizedBox(width: 12),
                        Text(s, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15,
                            fontWeight: FontWeight.bold, color: isStart ? _green : _brown)),
                      ]),
                    ),
                  );
                },
              )),
            ]),
          );
        });
      },
    );
    if (picked != null) {
      setState(() {
        if (isStart) _selectedStart = picked;
        else _selectedEnd = picked;
      });
      // ★ 兩站都選完後自動捲到最近班次
      if (_selectedStart != null && _selectedEnd != null) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) _scrollToNearest();
      }
    }
  }

  // ★ 找出同時停靠上車站與下車站，且上車站序號在下車站之前的班次
  List<Map<String, dynamic>> get _availableTrains {
    if (_selectedStart == null || _selectedEnd == null) return [];
    final result = <Map<String, dynamic>>[];
    for (final t in _allData) {
      if (t.timetable.isEmpty) continue;
      final startStop = t.timetable.cast<TimetableStop?>().firstWhere(
              (s) => s!.stationName == _selectedStart, orElse: () => null);
      final endStop = t.timetable.cast<TimetableStop?>().firstWhere(
              (s) => s!.stationName == _selectedEnd, orElse: () => null);
      if (startStop == null || endStop == null) continue;
      if (startStop.stopSequence >= endStop.stopSequence) continue;
      result.add({
        'train': t,
        'boardStop': startStop,
        'alightStop': endStop,
      });
    }
    // 依出發時間排序
    result.sort((a, b) {
      final ta = (a['boardStop'] as TimetableStop).departureTime;
      final tb = (b['boardStop'] as TimetableStop).departureTime;
      return ta.compareTo(tb);
    });
    return result;
  }

  // 計算兩站之間行駛時間
  String _travelTime(String dep, String arr) {
    try {
      final dp = dep.split(':');
      final ap = arr.split(':');
      int diff = (int.parse(ap[0]) * 60 + int.parse(ap[1])) -
          (int.parse(dp[0]) * 60 + int.parse(dp[1]));
      if (diff < 0) diff += 1440;
      return diff >= 60 ? '${diff ~/ 60}h${diff % 60}m' : '${diff}分';
    } catch (_) { return ''; }
  }

  List<TrainEntry> get _filtered {
    var list = _allData;
    if (_dirTab == 1) list = list.where((t) => t.direction == '0').toList();
    if (_dirTab == 2) list = list.where((t) => t.direction == '1').toList();
    if (_typeTab == 1) list = list.where((t) => ['自強號','普悠瑪','太魯閣'].any((k) => t.trainTypeName.contains(k))).toList();
    if (_typeTab == 2) list = list.where((t) => t.trainTypeName.contains('莒光') || t.trainTypeName.contains('復興')).toList();
    if (_typeTab == 3) list = list.where((t) => t.trainTypeName.contains('區間')).toList();
    if (widget.initialSearch != null && widget.initialSearch!.isNotEmpty &&
        _typeTab == 0 && _dirTab == 0) {
      final q = widget.initialSearch!;
      list = list.where((t) =>
      t.trainNo.contains(q) || t.trainTypeName.contains(q) ||
          t.startingStationName.contains(q) || t.endingStationName.contains(q) ||
          t.stationName.contains(q)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: _cream,
      body: Column(children: [
        _subPageHeader(context, 'TRAIN', '台鐵班次時刻', Icons.train_rounded),
        _buildStationPicker(),
        _buildTrainFilterRows(),
        if (!_loading)
          Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                if (_selectedStart != null && _selectedEnd != null)
                  Expanded(child: Text(
                    '共 ${_availableTrains.length} 班次（今日全部）',
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey),
                  ))
                else
                  Expanded(child: Text('共找到 ${list.length} 班列車',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey))),
                Row(children: [
                  if (_lastUpdated != null)
                    Text('${_lastUpdated!.hour.toString().padLeft(2,'0')}:${_lastUpdated!.minute.toString().padLeft(2,'0')} 更新  ',
                        style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                  GestureDetector(
                    onTap: _refreshing ? null : () => _load(isRefresh: true),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: _green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _green.withOpacity(0.3))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _refreshing
                            ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                            : const Icon(Icons.refresh_rounded, size: 12, color: _green),
                        const SizedBox(width: 3),
                        Text(_refreshing ? '更新中' : '刷新',
                            style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                  ),
                  if (_selectedStart != null || _selectedEnd != null) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() { _selectedStart = null; _selectedEnd = null; }),
                      child: const Row(children: [
                        Icon(Icons.close_rounded, size: 13, color: Colors.grey),
                        SizedBox(width: 2),
                        Text('清除', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
                      ]),
                    ),
                  ],
                ]),
              ])),
        const SizedBox(height: 4),
        // 若有選站，顯示全天班次（含已離站）；否則顯示一般篩選結果
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : (_selectedStart != null && _selectedEnd != null)
            ? _buildAllDayTrainList()
            : list.isEmpty
            ? _emptyState('找不到符合條件的列車')
            : ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            itemBuilder: (_, i) => _trainCard(list[i]))),
      ]),
    );
  }

  // ★ 全天班次列表（選站後使用），帶「已離站」標示，預設捲到最近班次
  Widget _buildAllDayTrainList() {
    final trains = _availableTrains;
    if (trains.isEmpty) return _emptyState('此區間今日無可搭乘班次');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) _scrollToNearest();
    });

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.only(top: 8, bottom: 40),
      physics: const BouncingScrollPhysics(),
      itemCount: trains.length,
      itemBuilder: (_, i) {
        final item = trains[i];
        final t = item['train'] as TrainEntry;
        final board = item['boardStop'] as TimetableStop;
        final alight = item['alightStop'] as TimetableStop;
        final departed = _isDeparted(board);
        final isNearest = i == _nearestIndex(trains);
        return _allDayTrainCard(t, board, alight, departed, isNearest);
      },
    );
  }

  Widget _allDayTrainCard(TrainEntry t, TimetableStop board, TimetableStop alight, bool departed, bool isNearest) {
    final onTime = t.delayTime == '沒有';
    Color c;
    if (t.trainTypeName.contains('自強') || t.trainTypeName.contains('太魯閣') || t.trainTypeName.contains('普悠瑪')) {
      c = _brown;
    } else if (t.trainTypeName.contains('莒光') || t.trainTypeName.contains('復興')) {
      c = _blue;
    } else { c = _green; }

    final effectiveColor = departed ? Colors.grey.shade400 : c;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: isNearest ? 16 : 24, vertical: 5),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: departed ? Colors.grey.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(isNearest ? 22 : 16),
        border: isNearest
            ? Border.all(color: c, width: 2)
            : Border.all(color: departed ? Colors.grey.withOpacity(0.08) : c.withOpacity(0.2)),
        boxShadow: isNearest
            ? [BoxShadow(color: c.withOpacity(0.18), blurRadius: 14, offset: const Offset(0, 4))]
            : [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Flexible(child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: effectiveColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(t.trainTypeName, style: TextStyle(fontFamily: 'MyCustomFont',
                  color: effectiveColor, fontWeight: FontWeight.bold, fontSize: 12),
                  overflow: TextOverflow.ellipsis, maxLines: 1))),
          const SizedBox(width: 6),
          Flexible(child: Text('車次 ${t.trainNo}', style: TextStyle(fontFamily: 'MyCustomFont',
              color: departed ? Colors.grey.shade400 : Colors.grey, fontWeight: FontWeight.bold, fontSize: 13),
              overflow: TextOverflow.ellipsis)),
          const Spacer(),
          if (departed)
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: const Text('已離站', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)))
          else if (isNearest)
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                child: Text('最近班次', style: TextStyle(fontFamily: 'MyCustomFont', color: c, fontWeight: FontWeight.bold, fontSize: 12)))
          else
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: onTime ? _green.withOpacity(0.1) : Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(onTime ? '準點' : t.delayTime,
                    style: TextStyle(fontFamily: 'MyCustomFont', color: onTime ? _green : Colors.orange, fontWeight: FontWeight.bold, fontSize: 12))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_selectedStart!, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                color: departed ? Colors.grey.shade400 : Colors.grey),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            Text(board.departureTime, style: TextStyle(fontFamily: 'MyCustomFont',
                fontSize: 20, fontWeight: FontWeight.w900,
                color: departed ? Colors.grey.shade400 : _green)),
          ])),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.arrow_forward_rounded, size: 14, color: departed ? Colors.grey.shade300 : Colors.grey),
              const SizedBox(height: 2),
              Text(_travelTime(board.departureTime, alight.arrivalTime),
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10,
                      color: departed ? Colors.grey.shade300 : Colors.grey)),
            ]),
          ),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_selectedEnd!, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                color: departed ? Colors.grey.shade400 : Colors.grey),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            Text(alight.arrivalTime, style: TextStyle(fontFamily: 'MyCustomFont',
                fontSize: 20, fontWeight: FontWeight.w900,
                color: departed ? Colors.grey.shade400 : _brown)),
          ])),
        ]),
      ]),
    );
  }

  Widget _buildTrainFilterRows() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _green.withOpacity(0.15)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
        child: Column(children: [
          Row(children: [
            _filterIcon(Icons.train_rounded, _brown),
            const SizedBox(width: 8),
            Expanded(child: Row(children: List.generate(4, (i) {
              final labels = ['全部', '對號列車', '莒光復興', '區間車'];
              final icons  = [Icons.all_inclusive_rounded, Icons.airline_seat_recline_extra_rounded,
                Icons.directions_railway_rounded, Icons.tram_rounded];
              final sel = i == _typeTab;
              return Expanded(child: GestureDetector(
                onTap: () => setState(() => _typeTab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? _brown : _cream, borderRadius: BorderRadius.circular(12),
                    boxShadow: sel ? [BoxShadow(color: _brown.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))] : [],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icons[i], size: 16, color: sel ? Colors.white : Colors.grey.shade400),
                    const SizedBox(height: 3),
                    Text(labels[i], style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10,
                        fontWeight: FontWeight.bold, color: sel ? Colors.white : Colors.grey.shade500)),
                  ]),
                ),
              ));
            }))),
          ]),
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 1, color: _green.withOpacity(0.08)),
          const SizedBox(height: 10),
          Row(children: [
            _filterIcon(Icons.swap_vert_rounded, _blue),
            const SizedBox(width: 8),
            Expanded(child: Row(children: List.generate(3, (i) {
              final labels = ['全部方向', '↑ 往北', '↓ 往南'];
              final colors = [_green, _blue, _brown];
              final sel = i == _dirTab;
              return Expanded(child: GestureDetector(
                onTap: () => setState(() => _dirTab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: sel ? colors[i] : _cream, borderRadius: BorderRadius.circular(12),
                    boxShadow: sel ? [BoxShadow(color: colors[i].withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))] : [],
                  ),
                  child: Center(child: Text(labels[i], style: TextStyle(
                      fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold,
                      color: sel ? Colors.white : Colors.grey.shade500))),
                ),
              ));
            }))),
          ]),
        ]),
      ),
    );
  }

  Widget _filterIcon(IconData icon, Color color) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
    child: Icon(icon, size: 16, color: color),
  );

  Widget _buildStationPicker() {
    return Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _green.withOpacity(0.3)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
        child: Row(children: [
          GestureDetector(
            onTap: () => setState(() { final tmp = _selectedStart; _selectedStart = _selectedEnd; _selectedEnd = tmp; }),
            child: Container(padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _green.withOpacity(0.1), shape: BoxShape.circle),
                child: const Icon(Icons.swap_vert_rounded, color: _green, size: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(children: [
            GestureDetector(
              onTap: () => _pickStation(isStart: true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                    color: _selectedStart != null ? _green.withOpacity(0.07) : _cream,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _selectedStart != null ? _green.withOpacity(0.4) : Colors.grey.withOpacity(0.2))),
                child: Row(children: [
                  _stationTag('上車', _green), const SizedBox(width: 10),
                  Expanded(child: Text(_selectedStart ?? '點選選擇上車站...',
                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14,
                          fontWeight: _selectedStart != null ? FontWeight.bold : FontWeight.normal,
                          color: _selectedStart != null ? _green : Colors.grey))),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      color: _selectedStart != null ? _green : Colors.grey, size: 20),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _pickStation(isStart: false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                    color: _selectedEnd != null ? _brown.withOpacity(0.07) : _cream,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _selectedEnd != null ? _brown.withOpacity(0.4) : Colors.grey.withOpacity(0.2))),
                child: Row(children: [
                  _stationTag('下車', _brown), const SizedBox(width: 10),
                  Expanded(child: Text(_selectedEnd ?? '點選選擇下車站...',
                      style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14,
                          fontWeight: _selectedEnd != null ? FontWeight.bold : FontWeight.normal,
                          color: _selectedEnd != null ? _brown : Colors.grey))),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      color: _selectedEnd != null ? _brown : Colors.grey, size: 20),
                ]),
              ),
            ),
          ])),
          // ★ 若兩站都選了，顯示「捲到最近班次」按鈕
          if (_selectedStart != null && _selectedEnd != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _scrollToNearest,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(12)),
                child: const Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.vertical_align_center_rounded, color: Colors.white, size: 18),
                  SizedBox(height: 2),
                  Text('最近', style: TextStyle(fontFamily: 'MyCustomFont',
                      color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _stationTag(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(t, style: TextStyle(fontFamily: 'MyCustomFont', color: c, fontSize: 10, fontWeight: FontWeight.bold)));

  Widget _trainCard(TrainEntry t) {
    final onTime = t.delayTime == '沒有';
    Color c;
    if (t.trainTypeName.contains('自強') || t.trainTypeName.contains('太魯閣') || t.trainTypeName.contains('普悠瑪')) {
      c = _brown;
    } else if (t.trainTypeName.contains('莒光') || t.trainTypeName.contains('復興')) {
      c = _blue;
    } else { c = _green; }

    final hasRoute = t.startingStationName != '沒有' && t.endingStationName != '沒有';
    final hasCurrent = t.stationName != '沒有' && t.stationName.isNotEmpty;

    return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.withOpacity(0.12)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110),
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                  child: Text(t.trainTypeName, style: TextStyle(fontFamily: 'MyCustomFont', color: c,
                      fontWeight: FontWeight.bold, fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1)),
            ),
            const SizedBox(width: 8),
            Text('車次 ${t.trainNo}', style: const TextStyle(fontFamily: 'MyCustomFont',
                color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 13)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: onTime ? _green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(onTime ? '準點' : t.delayTime,
                  style: TextStyle(fontFamily: 'MyCustomFont',
                      color: onTime ? _green : Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ]),
          if (hasRoute) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.circle, size: 7, color: c), const SizedBox(width: 6),
              Text(t.startingStationName, style: TextStyle(fontFamily: 'MyCustomFont',
                  fontSize: 13, color: _brown, fontWeight: FontWeight.w600)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.grey.withOpacity(0.5))),
              Icon(Icons.location_on_rounded, size: 12, color: c), const SizedBox(width: 4),
              Expanded(child: Text(t.endingStationName, style: TextStyle(fontFamily: 'MyCustomFont',
                  fontSize: 13, color: _brown, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            ]),
          ],
          if (hasCurrent) ...[
            const SizedBox(height: 4),
            Row(children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: _green, shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: _green.withOpacity(0.4), blurRadius: 4, spreadRadius: 1)])),
              const SizedBox(width: 6),
              Text('目前停靠：${t.stationName}',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
            ]),
          ],
        ]));
  }
}

// ════════════════════════════════════════════════════════════════
//  子頁面 2：市區公車（即時 + 起訖站牌搜尋）
// ════════════════════════════════════════════════════════════════
class BusInfoScreen extends StatefulWidget {
  final String? initialSearch;
  const BusInfoScreen({super.key, this.initialSearch});
  @override State<BusInfoScreen> createState() => _BusInfoScreenState();
}

class _BusInfoScreenState extends State<BusInfoScreen> {
  int _lineTab = 0;
  int _dirTab  = 0;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchFocused = false;
  List<BusEntry> _allData = [];
  List<Map<String, dynamic>> _routesData = []; // Routes 含完整站點清單
  bool _loading = true;
  bool _refreshing = false;
  String? _errorMsg;
  DateTime? _lastUpdated;

  static const _hotStops = ['嘉義火車站', '嘉義市轉運中心', '中正公園', '文化公園', '嘉義高工', '彌陀夜市'];

  static const _lineKeywords = {
    1: ['中山','綠'],
    2: ['忠孝','紅'],
    3: ['光林','黃'],
  };

  @override
  void initState() {
    super.initState();
    if (widget.initialSearch != null) _searchCtrl.text = widget.initialSearch!;
    _searchFocus.addListener(() => setState(() => _searchFocused = _searchFocus.hasFocus));
    _load();
  }

  @override
  void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); super.dispose(); }

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) setState(() => _refreshing = true);
    try {
      final results = await Future.wait([
        TrafficApiService().fetchBus(),
        TrafficApiService().fetchBusRoutes(),
      ]);
      if (mounted) setState(() {
        _allData = results[0] as List<BusEntry>;
        _routesData = results[1] as List<Map<String, dynamic>>;
        _loading = false;
        _refreshing = false;
        _errorMsg = null;
        _lastUpdated = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _refreshing = false;
        _errorMsg = '無法取得公車資料，請確認伺服器是否運作中。';
      });
    }
  }


  // 從 Routes 找出路線名稱有通過某站（StopName 包含 q）的 set
  // ★ 回傳 {routeName: isAllTerminal}
  Map<String, bool> _routeInfoThroughStop(String q) {
    final result = <String, bool>{};
    for (final route in _routesData) {
      final stops = route['Stops'] as List? ?? [];
      final hasStop = stops.any((s) =>
          ((s['StopName'] as String?) ?? '').contains(q));
      if (hasStop) {
        final rn = (route['RouteName'] ?? '') as String;
        final isTerminal = (route['IsAllTerminal'] as bool?) ?? false;
        if (rn.isNotEmpty) result[rn] = isTerminal;
      }
    }
    return result;
  }

  Set<String> _routeNamesThroughStop(String q) =>
      _routeInfoThroughStop(q).keys.toSet();

  // 計算某站有幾班車目前在跑（路線有停該站）
  int countActiveBusesForStop(String stop) {
    final routeNames = _routeNamesThroughStop(stop);
    if (routeNames.isEmpty) return 0;
    final seen = <String>{};
    for (final b in _allData) {
      final key = '${b.routeName}-${b.direction}';
      if (!seen.contains(key) && routeNames.any((rn) =>
      b.routeName.contains(rn) || rn.contains(b.routeName))) {
        seen.add(key);
      }
    }
    return seen.length;
  }

  // 判斷某條路線是否為全線末班
  bool _isRouteAllTerminal(BusEntry b) {
    for (final route in _routesData) {
      final rn = (route['RouteName'] ?? '') as String;
      final dir = (route['Direction'] as num?)?.toInt() ?? -1;
      if (dir == b.direction &&
          (rn == b.routeName || rn.contains(b.routeName) || b.routeName.contains(rn))) {
        return (route['IsAllTerminal'] as bool?) ?? false;
      }
    }
    return false;
  }

  List<BusEntry> get _filtered {
    var list = _allData;
    if (_dirTab == 1) list = list.where((b) => b.direction == 0).toList();
    if (_dirTab == 2) list = list.where((b) => b.direction == 1).toList();
    if (_lineTab > 0) {
      final kw = _lineKeywords[_lineTab]!;
      list = list.where((b) => kw.any((k) => b.routeName.contains(k))).toList();
    }
    final q = _searchCtrl.text.trim();
    if (q.isNotEmpty) {
      final directMatch = list.where((b) =>
      b.routeName.contains(q) ||
          b.departureStop.contains(q) ||
          b.destinationStop.contains(q)).toSet();
      final routeInfo = _routeInfoThroughStop(q);
      final routeNames = routeInfo.keys.toSet();
      final stopMatch = routeNames.isNotEmpty
          ? list.where((b) => routeNames.any((rn) =>
      b.routeName == rn ||
          b.routeName.contains(rn) ||
          rn.contains(b.routeName))).toSet()
          : <BusEntry>{};
      final merged = [...directMatch];
      for (final b in stopMatch) {
        if (!directMatch.contains(b)) merged.add(b);
      }
      // ★ 末班路線排後面：正常行駛 → 末班駛離
      merged.sort((a, b) {
        final aTerminal = _isRouteAllTerminal(a) ? 1 : 0;
        final bTerminal = _isRouteAllTerminal(b) ? 1 : 0;
        return aTerminal.compareTo(bTerminal);
      });
      list = merged;
    }
    return list;
  }


  Color _lineColor(String routeName) {
    if (routeName.contains('中山') || routeName.contains('綠')) return _green;
    if (routeName.contains('忠孝') || routeName.contains('紅')) return const Color(0xFFE07B7B);
    if (routeName.contains('光林') || routeName.contains('黃')) return const Color(0xFFD4A84B);
    return _blue;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: _cream,
      body: Column(children: [
        _subPageHeader(context, 'BUS', '市區公車動態', Icons.directions_bus_rounded),
        _buildBusSearchBar(),
        _buildBusFilterTabs(),
        // 狀態列：更新時間 + 刷新鍵
        Padding(padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            if (_errorMsg != null)
              Expanded(child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange),
                const SizedBox(width: 4),
                Expanded(child: Text(_errorMsg!, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.orange), overflow: TextOverflow.ellipsis)),
              ]))
            else if (_lastUpdated != null)
              Text('更新：${_lastUpdated!.hour.toString().padLeft(2,'0')}:${_lastUpdated!.minute.toString().padLeft(2,'0')}:${_lastUpdated!.second.toString().padLeft(2,'0')}',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey))
            else
              Text('共 ${list.length} 筆', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)),
            GestureDetector(
              onTap: _refreshing ? null : () => _load(isRefresh: true),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                    color: _refreshing ? _green.withOpacity(0.05) : _green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _green.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _refreshing
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                      : const Icon(Icons.refresh_rounded, size: 13, color: _green),
                  const SizedBox(width: 4),
                  Text(_refreshing ? '更新中...' : '手動刷新',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          ]),
        ),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : _errorMsg != null && _allData.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.cloud_off_rounded, size: 60, color: _green.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('無法取得資料', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 15)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _load(isRefresh: true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(16)),
              child: const Text('重試', style: TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ]))
            : list.isEmpty
            ? _emptyState('找不到符合條件的公車')
            : ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            itemBuilder: (_, i) => _busCard(list[i]))),
      ]),
    );
  }

  // ── 搜尋卡（YouBike 風格：白色圓角卡片包搜尋框 + 熱門站牌）──
  Widget _buildBusSearchBar() {
    final q = _searchCtrl.text.trim();
    final showHot = q.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _green.withOpacity(0.25)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 搜尋框
          Container(height: 50, padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.search_rounded, color: _green, size: 20),
              const SizedBox(width: 10),
              Expanded(child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '搜尋路線或站牌名稱...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFB0A99F), fontSize: 14),
                ),
              )),
              if (_searchCtrl.text.isNotEmpty)
                GestureDetector(
                    onTap: () { _searchCtrl.clear(); setState(() {}); },
                    child: const Icon(Icons.clear_rounded, color: Colors.grey, size: 18)),
            ]),
          ),
          // 熱門站牌（僅搜尋欄空白時顯示）
          if (showHot) ...[
            Divider(height: 1, thickness: 1, color: _green.withOpacity(0.08), indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('熱門站牌', style: TextStyle(
                    fontFamily: 'MyCustomFont', fontSize: 11,
                    color: Colors.grey, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: _hotStops.map((stop) {
                  final matchCount = countActiveBusesForStop(stop);
                  final isSelected = _searchCtrl.text == stop;
                  return GestureDetector(
                    onTap: () { _searchCtrl.text = stop; _searchFocus.unfocus(); setState(() {}); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? _green.withOpacity(0.15)
                            : (matchCount > 0 ? _green.withOpacity(0.07) : _cream),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: isSelected
                                ? _green.withOpacity(0.6)
                                : (matchCount > 0 ? _green.withOpacity(0.35) : Colors.grey.withOpacity(0.2))),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.location_on_rounded, size: 10,
                            color: isSelected || matchCount > 0 ? _green : Colors.grey.shade400),
                        const SizedBox(width: 3),
                        Text(stop, style: TextStyle(
                            fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold,
                            color: isSelected || matchCount > 0 ? _green : _brown)),
                        if (matchCount > 0) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                                color: _green.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(8)),
                            child: Text('$matchCount 班', style: const TextStyle(
                                fontFamily: 'MyCustomFont', fontSize: 10,
                                color: _green, fontWeight: FontWeight.w900)),
                          ),
                        ],
                      ]),
                    ),
                  );
                }).toList()),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
  // ── 分類標籤（線別 + 方向），放在搜尋框下方、清單上方 ──
  Widget _buildBusFilterTabs() {
    final lineLabels = ['全部', '綠線', '紅線', '黃線'];
    final lineColors = [_green, _green, const Color(0xFFE07B7B), const Color(0xFFD4A84B)];
    final lineDots   = ['', '●', '●', '●'];

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 線別選擇
        Row(children: List.generate(lineLabels.length, (i) {
          final sel = i == _lineTab;
          final color = i == 0 ? _green : lineColors[i];
          return Expanded(child: GestureDetector(
            onTap: () => setState(() => _lineTab = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: sel ? color.withOpacity(0.13) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? color.withOpacity(0.55) : Colors.grey.withOpacity(0.18)),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (i == 0)
                  Icon(Icons.directions_bus_rounded, size: 15, color: sel ? _green : Colors.grey.shade400)
                else
                  Text(lineDots[i], style: TextStyle(fontSize: 10,
                      color: sel ? lineColors[i] : Colors.grey.shade400, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(lineLabels[i], style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: sel ? color : Colors.grey.shade500)),
              ]),
            ),
          ));
        })),
        const SizedBox(height: 8),
        // 方向選擇
        Row(children: [
          _dirChip('全部方向', 0), const SizedBox(width: 6),
          _dirChip('去程 →', 1), const SizedBox(width: 6),
          _dirChip('← 返程', 2),
        ]),
      ]),
    );
  }




  Widget _dirChip(String label, int index) {
    final sel = _dirTab == index;
    return GestureDetector(
      onTap: () => setState(() => _dirTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? _green : _cream,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: sel ? _green : Colors.grey.withOpacity(0.2)),
          boxShadow: sel ? [BoxShadow(color: _green.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 2))] : [],
        ),
        child: Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold,
            color: sel ? Colors.white : _brown)),
      ),
    );
  }

  Widget _busCard(BusEntry b) {
    final c = _lineColor(b.routeName);
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => BusRouteDetailScreen(busEntry: b))),
      child: Container(margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.withOpacity(0.3), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
        child: Row(children: [
          Container(width: 4, height: 50, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.routeName, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15, fontWeight: FontWeight.w900, color: c)),
            const SizedBox(height: 4),
            Text('${b.departureStop} → ${b.destinationStop}',
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
            if (b.stopName.isNotEmpty && b.stopName != '沒有') ...[
              const SizedBox(height: 2),
              Text('📍 現在：${b.stopName}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _brown)),
            ],
          ])),
          const SizedBox(width: 8),
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Builder(builder: (_) {
              // 過濾「接近中」等狀態文字，嘗試解析秒數
              final raw = b.estimateTime;
              String display;
              Color displayColor = c;
              final parsed = int.tryParse(raw);
              if (parsed != null && parsed >= 0) {
                if (parsed <= 30) {
                  display = '進站中';
                } else if (parsed < 60) {
                  display = '即將到站';
                } else {
                  final mins = parsed ~/ 60;
                  display = '約 $mins 分';
                  if (mins > 15) displayColor = Colors.grey.shade600;
                  else if (mins > 5) displayColor = Colors.orange;
                }
              } else if (raw.isEmpty || raw == '接近中' || raw == '行駛中') {
                display = '行駛中';
              } else {
                display = raw;
              }
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: displayColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(display, style: TextStyle(fontFamily: 'MyCustomFont', color: displayColor, fontSize: 11, fontWeight: FontWeight.bold)),
              );
            }),
            const SizedBox(height: 4),
            Text(b.direction == 0 ? '去程 →' : '← 返程',
                style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
          ]),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  公車路線即時時刻表頁（各站 ETA + 進站標示）
// ════════════════════════════════════════════════════════════════
class BusRouteDetailScreen extends StatefulWidget {
  final BusEntry busEntry;
  const BusRouteDetailScreen({super.key, required this.busEntry});
  @override State<BusRouteDetailScreen> createState() => _BusRouteDetailScreenState();
}

class _BusRouteDetailScreenState extends State<BusRouteDetailScreen> {
  List<dynamic> _stops = []; // stops from Routes timeline
  // 同條路線上所有即時行駛的車輛 {stopName: plate}
  List<BusEntry> _activeVehicles = [];
  bool _loading = true;
  bool _refreshing = false;
  DateTime? _lastUpdated;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) setState(() => _refreshing = true);
    try {
      // 同時抓 Routes（時間軸）和 Vehicles（即時位置）
      final results = await Future.wait([
        TrafficApiService().fetchBusRoutes(),
        TrafficApiService().fetchBus(),
      ]);
      final allBusData = results[0] as List<Map<String, dynamic>>;
      final allVehicles = results[1] as List<BusEntry>;

      final routeName = widget.busEntry.routeName;
      final direction = widget.busEntry.direction;

      // ── Step1: 找對應的 Route timeline ──
      List<dynamic> found = [];

      // 精確比對 RouteName + Direction
      for (final route in allBusData) {
        final rn  = (route['RouteName'] ?? '') as String;
        final rid = (route['RouteID'] ?? '') as String;
        final dir = (route['Direction'] as num?)?.toInt() ?? -1;
        if (dir != direction) continue;
        if (rn == routeName || rid == routeName ||
            rn.contains(routeName) || routeName.contains(rn) ||
            rid.contains(routeName) || routeName.contains(rid)) {
          found = List<dynamic>.from(route['Stops'] ?? []);
          break;
        }
      }

      // 模糊比對：同方向，路線名關鍵字命中
      if (found.isEmpty) {
        for (final route in allBusData) {
          final dir = (route['Direction'] as num?)?.toInt() ?? -1;
          if (dir != direction) continue;
          final rn = (route['RouteName'] ?? '') as String;
          final words = routeName.split(RegExp(r'[\s（(【]'));
          if (words.any((w) => w.length > 1 && rn.contains(w))) {
            final stops = route['Stops'] as List?;
            if (stops != null && stops.isNotEmpty) {
              found = List<dynamic>.from(stops);
              break;
            }
          }
        }
      }

      // ── Step2: 從 Vehicles 找這條線上即時行駛的公車站點序列號 ──
      // 如果某站的 ETA 是「尚未發車」但同條線另一輛車正在跑，
      // 這代表是不同班次的資料混合，我們將那些站加 override 標記
      final Set<String> activeStopNames = {};
      for (final v in allVehicles) {
        if (v.direction != direction) continue;
        if (v.routeName.contains(routeName) || routeName.contains(v.routeName) ||
            v.routeName == routeName) {
          if (v.stopName.isNotEmpty && v.stopName != '沒有') {
            activeStopNames.add(v.stopName);
          }
        }
      }

      // ── Step3: 標記 HasBus（保留 server 原始資料，不動 EstimateTime/RawSeconds）
      List<dynamic> processedStops = found.map((s) {
        final stop = Map<String, dynamic>.from(s as Map);
        final stopName = stop['StopName'] as String? ?? '';
        if (activeStopNames.contains(stopName)) {
          stop['HasBus'] = true;
        }
        return stop;
      }).toList();

      if (mounted) setState(() {
        _stops = processedStops;
        _activeVehicles = allVehicles.where((v) {
          if (v.direction != direction) return false;
          return v.routeName == routeName ||
              v.routeName.contains(routeName) ||
              routeName.contains(v.routeName);
        }).toList();
        _loading = false;
        _refreshing = false;
        _lastUpdated = DateTime.now().toUtc().add(const Duration(hours: 8));
        _errorMsg = found.isEmpty ? '目前無此路線即時資料，請稍後再試' : null;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false; _refreshing = false;
        _errorMsg = '無法取得路線資料：$e';
      });
    }
  }

  Color get _routeColor {
    final n = widget.busEntry.routeName;
    if (n.contains('中山') || n.contains('綠')) return _green;
    if (n.contains('忠孝') || n.contains('紅')) return const Color(0xFFE07B7B);
    if (n.contains('光林') || n.contains('黃')) return const Color(0xFFD4A84B);
    return _blue;
  }

  @override
  Widget build(BuildContext context) {
    final c = _routeColor;
    final b = widget.busEntry;
    return Scaffold(
      backgroundColor: _cream,
      body: Column(children: [
        // ── 頁首 ──
        Container(
          padding: const EdgeInsets.fromLTRB(20, 65, 20, 12),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _backBtn(context),
              Row(children: [
                const Text('EXPLORE ', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, fontWeight: FontWeight.bold, color: _brown)),
                Text('BUS', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, fontWeight: FontWeight.bold, color: c)),
              ]),
              const SizedBox(width: 44),
            ]),
            const SizedBox(height: 12),
            // 路線資訊卡
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: c.withOpacity(0.3)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
              child: Row(children: [
                Container(width: 5, height: 48, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.routeName, style: TextStyle(fontFamily: 'MyCustomFont',
                      fontSize: 17, fontWeight: FontWeight.w900, color: c)),
                  const SizedBox(height: 4),
                  Text('${b.departureStop} → ${b.destinationStop}',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
                ])),
                Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                    child: Text(b.direction == 0 ? '去程 →' : '← 返程',
                        style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: c, fontWeight: FontWeight.bold)),
                  ),
                  if (_activeVehicles.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: c.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.directions_bus_rounded, size: 11, color: c),
                        const SizedBox(width: 3),
                        Text('${_activeVehicles.length} 輛在線',
                            style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: c, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                  ],
                ]),
              ]),
            ),
          ]),
        ),
        // 更新時間 + 刷新鍵
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            if (_lastUpdated != null)
              Text('更新：${_lastUpdated!.hour.toString().padLeft(2,'0')}:${_lastUpdated!.minute.toString().padLeft(2,'0')}:${_lastUpdated!.second.toString().padLeft(2,'0')}',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey))
            else
              const SizedBox(),
            GestureDetector(
              onTap: _refreshing ? null : () => _load(isRefresh: true),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                    color: _refreshing ? _green.withOpacity(0.05) : _green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _green.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _refreshing
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                      : const Icon(Icons.refresh_rounded, size: 13, color: _green),
                  const SizedBox(width: 4),
                  Text(_refreshing ? '更新中...' : '刷新',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          ]),
        ),
        // ── 站點列表 ──
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : _errorMsg != null
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.route_rounded, size: 60, color: _green.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(_errorMsg!, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center),
        ]))
            : Builder(builder: (_) {
          // ★ 判斷是否所有站都已末班駛離
          final allTerminal = _stops.isNotEmpty && _stops.every((s) {
            final eta = s['EstimateTime'] as String? ?? '';
            const terminalSet = {'末班駛離', '今日未營運', '交管停駛'};
            return terminalSet.any((t) => eta.contains(t));
          });
          return Column(children: [
            // ★ 全線末班橫幅
            if (allTerminal)
              Container(
                margin: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: Colors.grey.shade500),
                  const SizedBox(width: 8),
                  Text('此路線今日所有班次已駛離',
                      style: TextStyle(fontFamily: 'MyCustomFont',
                          fontSize: 13, color: Colors.grey.shade600,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            Expanded(child: ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 40),
              physics: const BouncingScrollPhysics(),
              itemCount: _stops.length,
              itemBuilder: (_, i) {
                final stop = _stops[i];
                final stopName = stop['StopName'] as String? ?? '';
                final plates = _activeVehicles
                    .where((v) => v.stopName == stopName && v.plateNumb.isNotEmpty)
                    .map((v) => v.plateNumb)
                    .toList();
                return _stopTile(i, c, plates);
              },
            )),
          ]);
        })),
      ]),
    );
  }

  Widget _stopTile(int i, Color c, List<String> plates) {
    final s = _stops[i];
    final stopName = s['StopName'] as String? ?? '';
    final hasBus   = s['HasBus'] == true || plates.isNotEmpty;
    final rawSec   = (s['RawSeconds'] as num?)?.toInt() ?? -1;
    final isFirst  = i == 0;
    final isLast   = i == _stops.length - 1;

    // ── ETA 顯示文字與顏色 ──
    // RawSeconds >= 0 表示有即時資料，優先用秒數換算分鐘
    String eta;
    Color etaColor;

    // 有效秒數優先（來自 RawSeconds 欄位）
    int effectiveSec = rawSec;
    // 若 rawSec == -1，嘗試把 EstimateTime 當秒數解析
    if (effectiveSec < 0) {
      final etaRaw = s['EstimateTime'] as String? ?? '';
      final parsed = int.tryParse(etaRaw);
      if (parsed != null && parsed >= 0) effectiveSec = parsed;
    }

    if (hasBus) {
      // 公車在此站：優先顯示 ETA，若沒有則顯示進站中
      if (effectiveSec >= 0 && effectiveSec <= 30) {
        eta = '進站中';
        etaColor = c;
      } else if (effectiveSec > 30 && effectiveSec < 60) {
        eta = '即將到站';
        etaColor = c;
      } else if (effectiveSec >= 60) {
        final mins = effectiveSec ~/ 60;
        eta = '約 $mins 分';
        etaColor = c;
      } else {
        eta = '進站中';
        etaColor = c;
      }
    } else if (effectiveSec >= 0 && effectiveSec <= 30) {
      eta = '進站中';
      etaColor = c;
    } else if (effectiveSec > 30 && effectiveSec < 60) {
      eta = '即將到站';
      etaColor = c;
    } else if (effectiveSec >= 60) {
      final mins = effectiveSec ~/ 60;
      eta = '約 $mins 分';
      etaColor = mins <= 5 ? c : (mins <= 15 ? Colors.orange : Colors.grey.shade600);
    } else {
      // 純文字狀態
      final etaStr = s['EstimateTime'] as String? ?? '無資料';
      // 過濾掉純數字（避免直接顯示秒數）
      final isNumeric = int.tryParse(etaStr) != null;
      if (isNumeric) {
        eta = '無資料';
        etaColor = Colors.grey.shade400;
      } else {
        eta = etaStr;
        etaColor = (etaStr == '尚未發車' || etaStr == '今日未營運' || etaStr == '末班駛離' || etaStr == '交管停駛')
            ? Colors.grey.shade400 : Colors.grey.shade600;
      }
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 時間軸線
      const SizedBox(width: 28),
      Column(children: [
        if (!isFirst)
          Container(width: 2, height: 16, color: c.withOpacity(0.25)),
        Container(
          width: hasBus ? 20 : 14,
          height: hasBus ? 20 : 14,
          decoration: BoxDecoration(
            color: hasBus ? c : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: c, width: hasBus ? 0 : 2),
            boxShadow: hasBus ? [BoxShadow(color: c.withOpacity(0.4), blurRadius: 8, spreadRadius: 1)] : [],
          ),
          child: hasBus ? const Icon(Icons.directions_bus_rounded, size: 12, color: Colors.white) : null,
        ),
        if (!isLast)
          Container(width: 2, height: 36, color: c.withOpacity(0.25)),
      ]),
      const SizedBox(width: 14),
      // 站名 + ETA
      Expanded(child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Container(
          margin: const EdgeInsets.only(right: 20, top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: hasBus ? c.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: hasBus ? c.withOpacity(0.4) : Colors.grey.withOpacity(0.1),
                width: hasBus ? 1.5 : 1),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.015), blurRadius: 6)],
          ),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(stopName, style: TextStyle(fontFamily: 'MyCustomFont',
                  fontSize: 14, fontWeight: hasBus ? FontWeight.w900 : FontWeight.w600,
                  color: hasBus ? c : _brown)),
              if (hasBus && plates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Wrap(spacing: 4, children: plates.map((p) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(p, style: TextStyle(fontFamily: 'MyCustomFont',
                        fontSize: 10, color: c, fontWeight: FontWeight.bold)),
                  )).toList()),
                )
              else if (hasBus)
                Text('公車即將到站', style: TextStyle(fontFamily: 'MyCustomFont',
                    fontSize: 11, color: c.withOpacity(0.8))),
            ])),
            if (eta.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: etaColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Text(eta, style: TextStyle(
                    fontFamily: 'MyCustomFont', fontSize: 12,
                    color: etaColor, fontWeight: FontWeight.bold)),
              ),
          ]),
        ),
      )),
    ]);
  }
}

// ════════════════════════════════════════════════════════════════
//  子頁面 3：YouBike（即時 + 互動卡片）
// ════════════════════════════════════════════════════════════════
class YouBikeInfoScreen extends StatefulWidget {
  final String? initialSearch;
  const YouBikeInfoScreen({super.key, this.initialSearch});
  @override State<YouBikeInfoScreen> createState() => _YouBikeInfoScreenState();
}

class _YouBikeInfoScreenState extends State<YouBikeInfoScreen> {
  final _searchCtrl = TextEditingController();
  List<UbikeEntry> _allData = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _selectedId; // 點選中的站點 uid
  int _districtTab = 0; // 0=全部，之後依站名前綴分區

  static const _hotKeywords = ['嘉義火車站','文化公園','市政府','蘭潭','嘉大','中正公園'];

  // 嘉義市常見行政區關鍵字（依站名判斷）
  static const _districts = ['全部', '東區', '西區', '北區', '南區', '嘉大', '其他'];
  static const _districtKeywords = {
    1: ['東區','東'],
    2: ['西區','西'],
    3: ['北區','北'],
    4: ['南區','南'],
    5: ['嘉大','蘭潭','大學'],
  };

  @override
  void initState() {
    super.initState();
    if (widget.initialSearch != null) _searchCtrl.text = widget.initialSearch!;
    _load();
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final data = await TrafficApiService().fetchUbike();
      if (mounted) setState(() { _allData = data; _loading = false; _refreshing = false; });
    } catch (e) {
      if (mounted) { setState(() { _loading = false; _refreshing = false; }); _showErrorDialog(context, '無法取得 YouBike 資料，請確認伺服器是否運作中。\n錯誤：$e'); }
    }
  }

  String _parseName(UbikeEntry e) => e.stationName.isNotEmpty ? e.stationName : e.stationUid;

  List<UbikeEntry> get _filtered {
    var list = _allData;
    final q = _searchCtrl.text.trim();
    if (q.isNotEmpty) list = list.where((e) => _parseName(e).contains(q)).toList();
    // 地區篩選
    if (_districtTab > 0 && _districtTab < 6) {
      final kws = _districtKeywords[_districtTab]!;
      list = list.where((e) => kws.any((k) => _parseName(e).contains(k))).toList();
    } else if (_districtTab == 6) {
      // 其他：不屬於任何已知區的
      list = list.where((e) {
        final name = _parseName(e);
        for (final kws in _districtKeywords.values) {
          if (kws.any((k) => name.contains(k))) return false;
        }
        return true;
      }).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: _cream,
      body: Column(children: [
        _subPageHeader(context, 'BIKE', 'YouBike 站點', Icons.pedal_bike_rounded),
        _buildBikeSearchCard(),
        // ── 地區分類標籤 ──
        _buildDistrictTabs(),
        Padding(padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('共 ${list.length} 個站點', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
              Row(children: [
                const Icon(Icons.pedal_bike, color: _green, size: 14), const SizedBox(width: 4),
                const Text('可借', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                const Icon(Icons.local_parking, color: _brown, size: 14), const SizedBox(width: 4),
                const Text('可還', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _refreshing ? null : () => _load,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: _green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _green.withOpacity(0.3))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _refreshing
                          ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                          : const Icon(Icons.refresh_rounded, size: 12, color: _green),
                      const SizedBox(width: 3),
                      Text(_refreshing ? '更新中' : '刷新',
                          style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ]),
            ])),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : list.isEmpty
            ? _emptyState('找不到符合條件的站點')
            : ListView.builder(
            padding: const EdgeInsets.only(top: 4, bottom: 40),
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            itemBuilder: (_, i) => _bikeTile(list[i]))),
      ]),
    );
  }

  Widget _buildDistrictTabs() {
    return SizedBox(
      height: 38,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: _districts.length,
        itemBuilder: (_, i) {
          final sel = i == _districtTab;
          return GestureDetector(
            onTap: () => setState(() { _districtTab = i; _selectedId = null; }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? _green : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: sel ? _green : _green.withOpacity(0.25)),
                boxShadow: sel ? [BoxShadow(color: _green.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 2))] : [],
              ),
              child: Text(_districts[i], style: TextStyle(
                  fontFamily: 'MyCustomFont', fontSize: 12, fontWeight: FontWeight.bold,
                  color: sel ? Colors.white : _brown)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBikeSearchCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _green.withOpacity(0.25)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 12, offset: const Offset(0, 4))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 搜尋框
          Container(height: 50, padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.search_rounded, color: _green, size: 20), const SizedBox(width: 10),
              Expanded(child: TextField(controller: _searchCtrl, onChanged: (_) => setState((){}),
                  decoration: const InputDecoration(hintText: '搜尋站點名稱或代號...',
                      border: InputBorder.none,
                      hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFFB0A99F), fontSize: 14)))),
              if (_searchCtrl.text.isNotEmpty)
                GestureDetector(onTap: () { _searchCtrl.clear(); setState((){}); },
                    child: const Icon(Icons.clear_rounded, color: Colors.grey, size: 18)),
            ]),
          ),
          Divider(height: 1, thickness: 1, color: _green.withOpacity(0.08), indent: 16, endIndent: 16),
          // 熱門站點
          Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('熱門站點', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: _hotKeywords.map((k) =>
                  GestureDetector(
                    onTap: () { _searchCtrl.text = k; setState((){}); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          color: _searchCtrl.text == k ? _green.withOpacity(0.15) : _cream,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _searchCtrl.text == k ? _green.withOpacity(0.5) : Colors.grey.withOpacity(0.2))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.location_on_rounded, size: 10, color: _searchCtrl.text == k ? _green : Colors.grey.shade400),
                        const SizedBox(width: 3),
                        Text(k, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                            color: _searchCtrl.text == k ? _green : _brown, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                  )).toList()),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bikeTile(UbikeEntry e) {
    final isSelected = _selectedId == e.stationUid;
    final rentColor  = e.availableRentBikes > 0 ? _green : Colors.grey;
    final retColor   = e.availableReturnBikes > 0 ? _brown : Colors.grey;

    return GestureDetector(
      onTap: () => setState(() => _selectedId = isSelected ? null : e.stationUid),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: EdgeInsets.symmetric(horizontal: isSelected ? 16 : 24, vertical: 5),
        padding: EdgeInsets.all(isSelected ? 20 : 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(isSelected ? 22 : 16),
          border: isSelected
              ? Border.all(color: _green, width: 2)
              : Border.all(color: Colors.grey.withOpacity(0.1)),
          boxShadow: isSelected
              ? [BoxShadow(color: _green.withOpacity(0.18), blurRadius: 16, offset: const Offset(0, 4))]
              : [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: EdgeInsets.all(isSelected ? 12 : 8),
              decoration: BoxDecoration(
                  color: e.isActive ? _green.withOpacity(isSelected ? 0.18 : 0.1) : Colors.grey.withOpacity(0.1),
                  shape: BoxShape.circle),
              child: Icon(Icons.pedal_bike_rounded, color: e.isActive ? _green : Colors.grey, size: isSelected ? 24 : 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_parseName(e), style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold,
                  color: isSelected ? _green : _brown, fontSize: isSelected ? 15 : 14),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(e.isActive ? '服務中' : '暫停服務',
                  style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: e.isActive ? _green : Colors.grey)),
            ])),
            // 可借數量
            Row(children: [
              _bikeCountBadge(Icons.pedal_bike, e.availableRentBikes, rentColor, isSelected),
              const SizedBox(width: 12),
              _bikeCountBadge(Icons.local_parking, e.availableReturnBikes, retColor, isSelected),
            ]),
          ]),
          // 展開詳情
          if (isSelected) ...[
            const SizedBox(height: 12),
            Divider(color: _green.withOpacity(0.15), height: 1),
            const SizedBox(height: 12),
            Row(children: [
              _detailChip(Icons.pedal_bike_rounded, '可借 ${e.availableRentBikes} 輛', rentColor),
              const SizedBox(width: 8),
              _detailChip(Icons.local_parking_rounded, '可還 ${e.availableReturnBikes} 位', retColor),
              const SizedBox(width: 8),
              _detailChip(Icons.power_settings_new_rounded, e.isActive ? '服務中' : '暫停', e.isActive ? _green : Colors.grey),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _bikeCountBadge(IconData icon, int count, Color c, bool large) {
    return Column(children: [
      Icon(icon, color: c, size: large ? 18 : 16),
      const SizedBox(height: 2),
      Text('$count', style: TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold, color: c, fontSize: large ? 18 : 16)),
    ]);
  }

  Widget _detailChip(IconData icon, String label, Color c) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: c.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: c, fontWeight: FontWeight.bold)),
      ]),
    ));
  }
}

// ════════════════════════════════════════════════════════════════
//  子頁面 4：停車場（即時 + 互動卡片）
// ════════════════════════════════════════════════════════════════
class ParkingInfoScreen extends StatefulWidget {
  final String? initialSearch;
  const ParkingInfoScreen({super.key, this.initialSearch});
  @override State<ParkingInfoScreen> createState() => _ParkingInfoScreenState();
}

class _ParkingInfoScreenState extends State<ParkingInfoScreen> {
  final _searchCtrl = TextEditingController();
  List<ParkingEntry> _allData = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _selectedId; // 點選中的停車場 id
  int _typeTab = 0; // 0=全部 1=地下 2=立體 3=平面 4=機械式

  static const _hotKeywords = ['中正公園','文化路','火車站','市府','蘭潭','嘉大'];
  static const _typeLabels = ['全部', '地下', '立體', '平面', '機械式', '路邊'];
  static const _typeIcons  = [
    Icons.all_inclusive_rounded,
    Icons.layers_rounded,
    Icons.apartment_rounded,
    Icons.crop_landscape_rounded,
    Icons.settings_rounded,
    Icons.remove_road_rounded,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialSearch != null) _searchCtrl.text = widget.initialSearch!;
    _load();
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) setState(() => _refreshing = true);
    try {
      final data = await TrafficApiService().fetchParking();
      if (mounted) setState(() { _allData = data; _loading = false; _refreshing = false; });
    } catch (e) {
      if (mounted) { setState(() { _loading = false; _refreshing = false; }); _showErrorDialog(context, '無法取得停車場資料，請確認伺服器是否運作中。\n錯誤：$e'); }
    }
  }

  List<ParkingEntry> get _filtered {
    var list = _allData;
    final q = _searchCtrl.text.trim();
    if (q.isNotEmpty) list = list.where((p) => p.carParkName.contains(q) || p.address.contains(q)).toList();
    if (_typeTab > 0 && _typeTab < _typeLabels.length) {
      final typeName = _typeLabels[_typeTab];
      list = list.where((p) => p.carParkType.contains(typeName)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: _cream,
      body: Column(children: [
        _subPageHeader(context, 'PARKING', '尋找停車位', Icons.local_parking_rounded),
        _buildParkingSearchCard(),
        // ── 類型篩選標籤 + 刷新鍵 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _typeLabels.length,
                  itemBuilder: (_, i) {
                    final sel = i == _typeTab;
                    return GestureDetector(
                      onTap: () => setState(() { _typeTab = i; _selectedId = null; }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(right: 7),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: sel ? _green : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: sel ? _green : _green.withOpacity(0.25)),
                          boxShadow: sel ? [BoxShadow(color: _green.withOpacity(0.2), blurRadius: 5, offset: const Offset(0, 2))] : [],
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_typeIcons[i], size: 12, color: sel ? Colors.white : _green),
                          const SizedBox(width: 4),
                          Text(_typeLabels[i], style: TextStyle(
                              fontFamily: 'MyCustomFont', fontSize: 11, fontWeight: FontWeight.bold,
                              color: sel ? Colors.white : _brown)),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _refreshing ? null : () => _load(isRefresh: true),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: _green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _green.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _refreshing
                      ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: _green))
                      : const Icon(Icons.refresh_rounded, size: 13, color: _green),
                  const SizedBox(width: 3),
                  Text(_refreshing ? '更新中' : '刷新',
                      style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _green, fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(24, 2, 24, 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('共 ${list.length} 個停車場', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: Colors.grey)),
              Text('即時資料：${list.where((p) => p.remainingSpace != null).length} 個',
                  style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _green, fontWeight: FontWeight.bold)),
            ])),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : list.isEmpty
            ? _emptyState('找不到符合條件的停車場')
            : ListView.builder(
            padding: const EdgeInsets.only(top: 4, bottom: 40),
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            itemBuilder: (_, i) => _parkingCard(list[i]))),
      ]),
    );
  }

  Widget _buildParkingSearchCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _green.withOpacity(0.25)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 12, offset: const Offset(0, 4))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(height: 50, padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.search_rounded, color: _green, size: 20), const SizedBox(width: 10),
              Expanded(child: TextField(controller: _searchCtrl, onChanged: (_) => setState((){}),
                  decoration: const InputDecoration(hintText: '搜尋停車場名稱或地址...',
                      border: InputBorder.none,
                      hintStyle: TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 14)))),
              if (_searchCtrl.text.isNotEmpty)
                GestureDetector(onTap: () { _searchCtrl.clear(); setState((){}); },
                    child: const Padding(padding: EdgeInsets.only(right: 12), child: Icon(Icons.clear_rounded, color: Colors.grey, size: 18))),
            ]),
          ),
          Divider(height: 1, thickness: 1, color: _green.withOpacity(0.08), indent: 16, endIndent: 16),
          Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('熱門搜尋', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: _hotKeywords.map((k) =>
                  GestureDetector(onTap: () { _searchCtrl.text = k; setState((){}); },
                      child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: _searchCtrl.text == k ? _green.withOpacity(0.15) : _green.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _searchCtrl.text == k ? _green.withOpacity(0.5) : _green.withOpacity(0.25))),
                          child: Text(k, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 12,
                              color: _searchCtrl.text == k ? _green : _brown, fontWeight: FontWeight.bold))))).toList()),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _parkingCard(ParkingEntry p) {
    final isSelected = _selectedId == p.carParkId;
    final hasData = p.remainingSpace != null;
    final full    = hasData && p.remainingSpace == 0;
    final spots   = hasData ? p.remainingSpace! : -1;
    final statusColor = !hasData ? Colors.grey : full ? _brown : (spots < 10 ? Colors.orange : _green);

    return GestureDetector(
      onTap: () => setState(() => _selectedId = isSelected ? null : p.carParkId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: EdgeInsets.symmetric(horizontal: isSelected ? 16 : 24, vertical: 5),
        padding: EdgeInsets.all(isSelected ? 20 : 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(isSelected ? 22 : 20),
          border: isSelected
              ? Border.all(color: _green, width: 2)
              : Border.all(color: Colors.grey.withOpacity(0.1)),
          boxShadow: isSelected
              ? [BoxShadow(color: _green.withOpacity(0.18), blurRadius: 16, offset: const Offset(0, 4))]
              : [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.carParkName, style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 15,
                  fontWeight: FontWeight.w900, color: isSelected ? _green : _brown)),
              const SizedBox(height: 6),
              Row(children: [
                _typeChip(p.carParkType),
                const SizedBox(width: 8),
                Expanded(child: Text(
                    p.fareDescription == '詳見現場公告' || p.fareDescription.isEmpty ? '收費請洽現場' : p.fareDescription,
                    style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 12, color: _green, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis)),
              ]),
              if (p.address.isNotEmpty && p.address != '請參考場站名稱導航') ...[
                const SizedBox(height: 4),
                Text(p.address, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey), overflow: TextOverflow.ellipsis),
              ],
            ])),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: isSelected ? 80 : 70,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('剩餘車位', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                const SizedBox(height: 4),
                if (!hasData)
                  const Text('—', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 22, color: Colors.grey, fontWeight: FontWeight.bold))
                else if (full)
                  Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: _brown.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: const Text('滿位', style: TextStyle(fontFamily: 'MyCustomFont', color: _brown, fontSize: 13, fontWeight: FontWeight.bold)))
                else
                  Text('$spots', style: TextStyle(fontFamily: 'MyCustomFont',
                      fontSize: isSelected ? 32 : 28, fontWeight: FontWeight.w900, color: statusColor)),
                if (hasData && !full) ...[
                  const SizedBox(height: 2),
                  Text('共 ${p.spaceTotal}', style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
                ],
              ]),
            ),
          ]),
          // 展開詳情
          if (isSelected) ...[
            const SizedBox(height: 12),
            Divider(color: _green.withOpacity(0.15), height: 1),
            const SizedBox(height: 12),
            Row(children: [
              _detailInfo(Icons.category_rounded, '類型', p.carParkType),
              _detailInfo(Icons.space_bar_rounded, '總車位', '${p.spaceTotal} 格'),
              _detailInfo(Icons.attach_money_rounded, '收費', p.fareDescription.isEmpty ? '請洽現場' : p.fareDescription),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _detailInfo(IconData icon, String label, String value) {
    return Expanded(child: Column(children: [
      Icon(icon, size: 16, color: _green),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: _brown, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis),
    ]));
  }

  Widget _typeChip(String t) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: _cream, borderRadius: BorderRadius.circular(6)),
      child: Text(t, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 11, color: Colors.grey)));
}

// ════════════════════════════════════════════════════════════════
//  共用：空白提示
// ════════════════════════════════════════════════════════════════
Widget _emptyState(String msg) {
  return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Icon(Icons.search_off_rounded, size: 60, color: _green.withOpacity(0.3)),
    const SizedBox(height: 16),
    Text(msg, style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.grey, fontSize: 15)),
  ]));
}