import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  String _selectedType = '活動';
  final List<String> _dataTypeList = ['活動', '景點', '住宿', '美食'];

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _serviceTimeCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  final _webUrlCtrl = TextEditingController();

  // 📸 圖片處理變數
  File? _selectedImage;
  String? _base64Image; // 準備存進資料庫的字串
  final ImagePicker _picker = ImagePicker();

  String _activityCategory = '藝文活動';
  final List<String> _actCategories = ['藝文活動', '最新消息', '節慶活動', '展覽藝文', '市集活動'];
  final _attrPriceCtrl = TextEditingController();
  final _attrPriceNameCtrl = TextEditingController();
  final _hotelLowestPriceCtrl = TextEditingController();
  final _hotelCeilingPriceCtrl = TextEditingController();
  final _hotelStarsCtrl = TextEditingController();
  final _hotelTownCtrl = TextEditingController();
  final _restPriceDescCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose(); _descCtrl.dispose(); _addressCtrl.dispose();
    _phoneCtrl.dispose(); _serviceTimeCtrl.dispose();
    _latCtrl.dispose(); _lonCtrl.dispose(); _webUrlCtrl.dispose();
    _attrPriceCtrl.dispose(); _attrPriceNameCtrl.dispose();
    _hotelLowestPriceCtrl.dispose(); _hotelCeilingPriceCtrl.dispose();
    _hotelStarsCtrl.dispose(); _hotelTownCtrl.dispose(); _restPriceDescCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF8BAA88), onPrimary: Colors.white, onSurface: Color(0xFF7D6E5D)),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _serviceTimeCtrl.text = "${picked.start.year}/${picked.start.month.toString().padLeft(2, '0')}/${picked.start.day.toString().padLeft(2, '0')} ~ ${picked.end.year}/${picked.end.month.toString().padLeft(2, '0')}/${picked.end.day.toString().padLeft(2, '0')}";
      });
    }
  }

  // 📸 從相簿選取圖片 (使用 image_picker 內建強力壓縮，絕不報錯！)
  Future<void> _pickImage() async {
    final pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,      // 直接在這裡限制最大寬度
      maxHeight: 800,     // 限制最大高度
      imageQuality: 60,   // 畫質直接壓到 60%
    );

    if (pickedFile != null) {
      // 直接把選好的檔案讀成 Byte 陣列
      final bytes = await pickedFile.readAsBytes();

      setState(() {
        _selectedImage = File(pickedFile.path); // 留給畫面上預覽用
        _base64Image = base64Encode(bytes);     // 轉換成 Base64 字串準備丟上雲端！
      });
    }
  }

  // 🚀 核心寫入
  // 🚀 核心寫入與防重複檢查
  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final db = FirebaseFirestore.instance;
    final Map<String, dynamic> data = {};

    // 👑 拿出你輸入的名稱，準備當作檔案名稱！
    final String docName = _nameCtrl.text.trim();

    try {
      // 🛡️ 第 1 步：決定要存到哪個集合
      String collectionName = '';
      switch (_selectedType) {
        case '活動': collectionName = 'Activities'; break;
        case '景點': collectionName = 'Attractions'; break;
        case '住宿': collectionName = 'Hotels'; break;
        case '美食': collectionName = 'Restaurants'; break;
      }

      // 🛡️ 第 2 步：去資料庫檢查這個名字是不是已經被用過了？
      final docRef = db.collection(collectionName).doc(docName);
      final docSnap = await docRef.get();

      if (docSnap.exists) {
        // 💥 抓到了！有重複的名字，直接擋下來並跳出警告
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('❌ 新增失敗：資料庫已經有叫做「$docName」的$_selectedType了！請更改名稱。', style: const TextStyle(fontFamily: 'MyCustomFont', fontWeight: FontWeight.bold)),
                backgroundColor: const Color(0xFFB07070)
            )
        );
        setState(() => _isLoading = false);
        return; // 直接結束，絕不寫入！
      }

      // 🛡️ 第 3 步：沒有重複，開始安全地打包資料
      double lat = double.tryParse(_latCtrl.text.trim()) ?? 23.47;
      double lon = double.tryParse(_lonCtrl.text.trim()) ?? 120.41;
      String phone = _phoneCtrl.text.trim().isEmpty ? "沒有" : _phoneCtrl.text.trim();
      String web = _webUrlCtrl.text.trim().isEmpty ? "沒有" : _webUrlCtrl.text.trim();

      List<Map<String, String>> formattedTelephones = [{"memo": _selectedType == '住宿' ? "訂房專線" : "聯絡電話", "phoneNumber": phone}];
      List<Map<String, String>> formattedImages = [{"caption": "${docName}實景圖", "url": ""}];

      switch (_selectedType) {
        case '活動':
          data['ActivityName'] = docName;
          data['Category'] = _activityCategory;
          data['Date'] = _serviceTimeCtrl.text.trim();
          data['Description'] = _descCtrl.text.trim();
          data['ImageUrl'] = "";
          data['ImageBase64'] = _base64Image;
          break;

        case '景點':
          data['AttractionName'] = docName;
          data['Address'] = _addressCtrl.text.trim();
          data['Description'] = _descCtrl.text.trim();
          data['ServiceTimeInfo'] = _serviceTimeCtrl.text.trim().isEmpty ? "每日開放" : _serviceTimeCtrl.text.trim();
          data['PositionLat'] = lat; data['PositionLon'] = lon;
          data['Price'] = int.tryParse(_attrPriceCtrl.text.trim()) ?? 0;
          data['Price_Name'] = _attrPriceNameCtrl.text.trim().isEmpty ? "免費入場" : _attrPriceNameCtrl.text.trim();
          data['IsAccessibleForFree'] = (int.tryParse(_attrPriceCtrl.text.trim()) ?? 0) == 0 ? 1 : 0;
          data['Images'] = formattedImages; data['Telephones'] = formattedTelephones; data['WebsiteUrl'] = web;
          data['TrafficInfo'] = "尚無交通資訊說明"; data['ServiceStatus'] = 0; data['Tags'] = ["自然風景類"];
          data['ImageBase64'] = _base64Image;
          break;

        case '住宿':
          data['HotelName'] = docName;
          data['StreetAddress'] = _addressCtrl.text.trim();
          data['Town'] = _hotelTownCtrl.text.trim().isEmpty ? "嘉義縣" : _hotelTownCtrl.text.trim();
          data['City'] = "嘉義縣"; data['Description'] = _descCtrl.text.trim();
          data['LowestPrice'] = int.tryParse(_hotelLowestPriceCtrl.text.trim()) ?? 1200;
          data['CeilingPrice'] = int.tryParse(_hotelCeilingPriceCtrl.text.trim()) ?? 5000;
          data['HotelStars'] = double.tryParse(_hotelStarsCtrl.text.trim()) ?? 4.0;
          data['CheckInTime'] = "15:00"; data['CheckOutTime'] = "11:00";
          data['Images'] = formattedImages; data['Telephones'] = formattedTelephones;
          data['ServiceTimeInfo'] = "無線網路,停車場"; data['ServiceStatus'] = 0; data['WebsiteUrl'] = web;
          data['Comments'] = "沒有"; data['PositionLat'] = lat; data['PositionLon'] = lon;
          data['ImageBase64'] = _base64Image;
          break;

        case '美食':
          data['RestaurantName'] = docName;
          data['StreetAddress'] = _addressCtrl.text.trim();
          data['Description'] = _descCtrl.text.trim();
          data['Price'] = _restPriceDescCtrl.text.trim().isEmpty ? "沒有" : _restPriceDescCtrl.text.trim();
          data['ServiceTimeInfo'] = _serviceTimeCtrl.text.trim().isEmpty ? "沒有" : _serviceTimeCtrl.text.trim();
          data['PositionLat'] = lat; data['PositionLon'] = lon;
          data['Images'] = formattedImages; data['Telephones'] = formattedTelephones; data['WebsiteUrl'] = web;
          data['Comments'] = "沒有"; data['CuisineClasses'] = [1]; data['ServiceStatus'] = 0;
          data['ImageBase64'] = _base64Image;
          break;
      }

      // 🛡️ 第 4 步：確定沒問題，使用 .set() 指定檔名寫入！
      await docRef.set(data);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 新增【$_selectedType】成功！'), backgroundColor: const Color(0xFF8BAA88)));
      _clearAllFields();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ 新增失敗: $e'), backgroundColor: const Color(0xFFB07070)));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _clearAllFields() {
    _nameCtrl.clear(); _descCtrl.clear(); _addressCtrl.clear();
    _phoneCtrl.clear(); _serviceTimeCtrl.clear();
    _latCtrl.clear(); _lonCtrl.clear(); _webUrlCtrl.clear();
    _attrPriceCtrl.clear(); _attrPriceNameCtrl.clear();
    _hotelLowestPriceCtrl.clear(); _hotelCeilingPriceCtrl.clear();
    _hotelStarsCtrl.clear(); _hotelTownCtrl.clear(); _restPriceDescCtrl.clear();
    setState(() {
      _selectedImage = null;
      _base64Image = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFCF5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFCF5), elevation: 0, centerTitle: true,
        iconTheme: const IconThemeData(color: Color(0xFF7D6E5D)),
        title: const Text('系統管理員後台', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8BAA88)))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('資料新增類別', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedType,
                decoration: InputDecoration(
                  filled: true, fillColor: const Color(0xFF8BAA88).withOpacity(0.08),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
                style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontWeight: FontWeight.bold, fontSize: 16),
                items: _dataTypeList.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (val) => setState(() => _selectedType = val!),
              ),
              const SizedBox(height: 24),

              // 📸 圖片上傳區塊 (本機選取預覽)
              const Text('首圖照片 (Image)', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _pickImage,
                child: Container(
                  height: 160,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF8BAA88), width: 1.5, style: BorderStyle.solid),
                  ),
                  child: _selectedImage != null
                      ? ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(_selectedImage!, fit: BoxFit.cover))
                      : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_rounded, size: 48, color: const Color(0xFF8BAA88).withOpacity(0.7)),
                      const SizedBox(height: 8),
                      const Text('點擊相簿選擇圖片', style: TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF8BAA88), fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              _buildTextField('名稱 / 標題 (必填)', _nameCtrl, isRequired: true),
              const SizedBox(height: 16),

              if (_selectedType != '活動') ...[
                _buildTextField('詳細地址 (必填)', _addressCtrl, isRequired: true),
                const SizedBox(height: 16),
              ],

              _buildTextField(
                _selectedType == '活動' ? '活動日期區間 (點擊選擇)' : '營業時間說明',
                _serviceTimeCtrl,
                hintText: _selectedType == '活動' ? '請點擊選擇日期...' : '例如: 每日開放 或 09:00-18:00',
                onTap: _selectedType == '活動' ? _pickDateRange : null,
                readOnly: _selectedType == '活動',
              ),
              const SizedBox(height: 16),

              _buildTextField('聯絡電話 / 訂房專線', _phoneCtrl, hintText: '例如: 886-5-2593900'),
              const SizedBox(height: 16),
              _buildTextField('官方網站 WebsiteUrl', _webUrlCtrl),
              const SizedBox(height: 16),

              if (_selectedType != '活動') ...[
                Row(
                  children: [
                    Expanded(child: _buildTextField('緯度 (Lat)', _latCtrl, hintText: '例如: 23.5595')),
                    const SizedBox(width: 14),
                    Expanded(child: _buildTextField('經度 (Lon)', _lonCtrl, hintText: '例如: 120.679')),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              if (_selectedType == '活動') ...[
                const Text('活動分類標籤 (Category)', style: TextStyle(fontFamily: 'MyCustomFont', fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE2E8F0))),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _activityCategory, isExpanded: true,
                      items: _actCategories.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D))))).toList(),
                      onChanged: (val) => setState(() => _activityCategory = val!),
                    ),
                  ),
                ),
              ],

              if (_selectedType == '景點') ...[
                _buildTextField('門票票價金額 (Price)', _attrPriceCtrl, hintText: '免費請輸入 0'),
                const SizedBox(height: 16),
                _buildTextField('門票名稱說明 (Price_Name)', _attrPriceNameCtrl, hintText: '例如: 免費入場 或 全票150元'),
              ],

              if (_selectedType == '住宿') ...[
                _buildTextField('所屬鄉鎮地區 (Town)', _hotelTownCtrl, hintText: '例如: 六腳鄉 或 東區'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: _buildTextField('最低價', _hotelLowestPriceCtrl, hintText: '數字')),
                    const SizedBox(width: 14),
                    Expanded(child: _buildTextField('最高價', _hotelCeilingPriceCtrl, hintText: '數字')),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTextField('旅館星級評分 (HotelStars)', _hotelStarsCtrl, hintText: '例如: 4.7'),
              ],

              if (_selectedType == '美食') ...[
                _buildTextField('消費價位 / 均價說明 (Price)', _restPriceDescCtrl, hintText: '例如: 每人平均 300 元'),
              ],

              const SizedBox(height: 16),
              _buildTextField('詳細內容介紹描述 (Description)', _descCtrl, maxLines: 5),
              const SizedBox(height: 36),

              SizedBox(
                width: double.infinity, height: 52,
                child: ElevatedButton(
                  onPressed: _submitForm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8BAA88),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    elevation: 2,
                  ),
                  child: Text('發布全新$_selectedType', style: const TextStyle(fontFamily: 'MyCustomFont', color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(height: 50),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, {bool isRequired = false, int maxLines = 1, String? hintText, VoidCallback? onTap, bool readOnly = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontFamily: 'MyCustomFont', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF7D6E5D))),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller, maxLines: maxLines, readOnly: readOnly, onTap: onTap,
          style: const TextStyle(fontFamily: 'MyCustomFont', color: Color(0xFF7D6E5D), fontSize: 14),
          decoration: InputDecoration(
            hintText: hintText, hintStyle: TextStyle(color: Colors.grey[400], fontSize: 12),
            filled: true, fillColor: readOnly ? const Color(0xFFF5F3F0) : Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF8BAA88), width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          validator: isRequired ? (value) => value!.isEmpty ? '此欄位不可為空喔！' : null : null,
        ),
      ],
    );
  }
}