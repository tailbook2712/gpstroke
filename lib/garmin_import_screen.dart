import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'tcx_parser.dart';
import 'database_helper.dart';
import 'firestore_service.dart';

class GarminImportScreen extends StatefulWidget {
  @override
  _GarminImportScreenState createState() => _GarminImportScreenState();
}

class _GarminImportScreenState extends State<GarminImportScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final FirestoreService _firestoreService = FirestoreService();
  List<GarminActivityData> _importedActivities = [];
  bool _isLoading = false;
  double _userHeightCm = 170.0; // デフォルト170cm

  @override
  void initState() {
    super.initState();
    _loadUserHeight();
  }

  /// SharedPreferencesから身長を読み込み
  Future<void> _loadUserHeight() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userHeightCm = prefs.getDouble('user_height_cm') ?? 170.0;
    });
  }

  /// 身長を保存
  Future<void> _saveUserHeight(double height) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('user_height_cm', height);
    setState(() {
      _userHeightCm = height;
    });
  }

  /// 身長入力ダイアログを表示
  void _showHeightInputDialog() {
    final controller =
        TextEditingController(text: _userHeightCm.toStringAsFixed(1));

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('身長を入力'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '身長 (cm)',
                hintText: '例: 170',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            Text(
              '身長から歩幅を計算し、距離から歩数を推定します',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              final height = double.tryParse(controller.text);
              if (height != null && height > 0) {
                _saveUserHeight(height);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content:
                          Text('身長を保存しました: ${height.toStringAsFixed(1)}cm')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('正しい数値を入力してください')),
                );
              }
            },
            child: Text('保存'),
          ),
        ],
      ),
    );
  }

  /// TCX ファイルを選択してインポート
  Future<void> _pickAndImportTcxFile() async {
    try {
      print('📂 ファイルピッカーを開く');
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['tcx'],
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        print('📄 ファイルを選択: ${result.files.single.name}');
        final file = File(result.files.single.path!);
        final tcxContent = await file.readAsString();
        print('📖 ファイル読み込み完了: ${tcxContent.length} bytes');

        setState(() {
          _isLoading = true;
        });

        // TCX ファイルをパース（身長を渡す）
        print('🔄 TCXパース開始 (身長: ${_userHeightCm.toStringAsFixed(1)}cm)');
        final activityData = await TcxParser.parseTcxFile(
          tcxContent,
          userHeightCm: _userHeightCm,
        );

        if (!mounted) return;

        if (activityData != null) {
          setState(() {
            _importedActivities.add(activityData);
            _isLoading = false;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${activityData.activityName} をインポートしました\n'
                '距離: ${activityData.distance.toStringAsFixed(2)}km, '
                '歩数: ${activityData.steps}',
              ),
            ),
          );
        } else {
          setState(() {
            _isLoading = false;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('TCX ファイルの解析に失敗しました'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });

      print('❌ ファイルピッカーエラー: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('エラー: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// インポートしたアクティビティを削除
  void _removeActivity(int index) {
    setState(() {
      _importedActivities.removeAt(index);
    });
  }

  /// すべてのインポート済みアクティビティをデータベースに保存
  Future<void> _saveAllActivities() async {
    if (_importedActivities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('インポートするアクティビティがありません')),
      );
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      int savedCount = 0;

      for (final activity in _importedActivities) {
        // Position オブジェクトを Map に変換
        final positions = activity.positions.map((pos) {
          return {
            'latitude': pos.latitude,
            'longitude': pos.longitude,
            'timestamp': pos.timestamp.toIso8601String(),
          };
        }).toList();

        final groupId = activity.generateGroupId();
        final date = activity.getFormattedDate();

        // ローカルDBに保存
        await _dbHelper.insertWalkingData(
          groupId: groupId,
          date: date,
          steps: activity.steps,
          distance: activity.distance,
          positions: positions,
        );

        // Firestoreにも保存
        await _firestoreService.saveWalkingData(
          groupId: groupId,
          positions: positions,
          steps: activity.steps,
          distance: activity.distance,
        );

        savedCount++;
      }

      setState(() {
        _isLoading = false;
        _importedActivities.clear();
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$savedCount 個のアクティビティを保存しました')),
      );

      // 画面を閉じる
      Navigator.pop(context);
    } catch (e) {
      setState(() {
        _isLoading = false;
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存エラー: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('インポート'),
      ),
      body: Column(
        children: [
          // インストラクション
          Container(
            padding: EdgeInsets.all(16),
            color: Colors.blue[50],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TCX ファイルをインポート',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  '1. Garmin Connect からアクティビティをダウンロード\n'
                  '2. ファイルを .tcx 形式で保存\n'
                  '3. 下のボタンからファイルを選択\n'
                  '4. 身長が正しいか確認（下で変更可能）\n'
                  '5. プレビュー後、保存ボタンで完了',
                  style: TextStyle(fontSize: 12),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '身長: ${_userHeightCm.toStringAsFixed(1)}cm',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: Icon(Icons.edit, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                      onPressed: _showHeightInputDialog,
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 16),

          // ファイルピッカーボタン
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _pickAndImportTcxFile,
              icon: Icon(Icons.folder_open),
              label: Text('TCX ファイルを選択'),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 48),
              ),
            ),
          ),

          SizedBox(height: 16),

          // インポート済みアクティビティのリスト
          if (_importedActivities.isNotEmpty)
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.symmetric(horizontal: 16),
                itemCount: _importedActivities.length,
                itemBuilder: (context, index) {
                  final activity = _importedActivities[index];
                  return Card(
                    margin: EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      title: Text(activity.activityName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 4),
                          Text(
                            '日時: ${activity.getFormattedDate()}',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            '距離: ${activity.distance.toStringAsFixed(2)} km',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            '歩数: ${activity.steps} 歩',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            'ポイント数: ${activity.positions.length}',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _removeActivity(index),
                      ),
                    ),
                  );
                },
              ),
            )
          else if (!_isLoading)
            Expanded(
              child: Center(
                child: Text('ファイルを選択してください'),
              ),
            ),

          SizedBox(height: 16),

          // 保存ボタン
          if (_importedActivities.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  ElevatedButton(
                    onPressed: _isLoading ? null : _saveAllActivities,
                    style: ElevatedButton.styleFrom(
                      minimumSize: Size(double.infinity, 48),
                      backgroundColor: Colors.green,
                    ),
                    child: _isLoading
                        ? SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : Text(
                            '${_importedActivities.length} 個のアクティビティを保存',
                            style: TextStyle(color: Colors.white),
                          ),
                  ),
                  SizedBox(height: 8),
                  TextButton(
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    child: Text('キャンセル'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
