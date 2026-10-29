import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'tcx_parser.dart';
import 'database_helper.dart';
import 'firestore_service.dart';
import 'healthkit_service.dart';

class GarminImportScreen extends StatefulWidget {
  @override
  _GarminImportScreenState createState() => _GarminImportScreenState();
}

class _GarminImportScreenState extends State<GarminImportScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final FirestoreService _firestoreService = FirestoreService();
  final HealthKitService _healthKitService = HealthKitService();
  List<GarminActivityData> _importedActivities = [];
  bool _isLoading = false;
  double _userHeightCm = 170.0; // デフォルト170cm

  // スマートウォッチ（HealthKit）連携
  bool _isHealthKitAvailable = false;
  bool _isHealthKitConnected = false;
  bool _isSyncing = false;
  bool _hasSynced = false;
  List<SmartwatchWorkout> _syncedWorkouts = [];
  Set<String> _savedGroupIds = {};

  @override
  void initState() {
    super.initState();
    _loadUserHeight();
    _initHealthKit();
  }

  /// ヘルスケア連携の状態を確認し，初回は接続するか尋ねる
  Future<void> _initHealthKit() async {
    final available = await _healthKitService.isAvailable();
    final connected = available && await _healthKitService.isConnected();
    if (!mounted) return;
    setState(() {
      _isHealthKitAvailable = available;
      _isHealthKitConnected = connected;
    });

    if (available &&
        !connected &&
        !await _healthKitService.hasShownConnectPrompt()) {
      await _healthKitService.markConnectPromptShown();
      if (!mounted) return;
      _showConnectPromptDialog();
    }
  }

  void _showConnectPromptDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('スマートウォッチと接続'),
        content: Text(
          'Apple Watch や Garmin で記録したアクティビティを，'
          'ヘルスケア経由で軌跡として取り込めます。\n今すぐ接続しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('あとで'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _connectHealthKit();
            },
            child: Text('接続する'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectHealthKit() async {
    try {
      final success = await _healthKitService.connect();
      if (!mounted) return;
      setState(() {
        _isHealthKitConnected = success;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'ヘルスケアと接続しました' : '接続できませんでした')),
      );
    } catch (e) {
      print('❌ ヘルスケア接続エラー: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('接続エラー: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// 直近のルート付きワークアウトを同期
  Future<void> _syncWorkouts() async {
    setState(() {
      _isSyncing = true;
    });
    try {
      final workouts = await _healthKitService.fetchRecentWorkouts(
        userHeightCm: _userHeightCm,
      );
      final savedGroupIds = <String>{};
      for (final workout in workouts) {
        final groupId = workout.activity.generateGroupId();
        if (await _dbHelper.getWalkingDataByGroupId(groupId) != null) {
          savedGroupIds.add(groupId);
        }
      }
      if (!mounted) return;
      setState(() {
        _syncedWorkouts = workouts;
        _savedGroupIds = savedGroupIds;
        _hasSynced = true;
        _isSyncing = false;
      });
    } catch (e) {
      print('❌ ワークアウト同期エラー: $e');
      if (!mounted) return;
      setState(() {
        _isSyncing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('同期エラー: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// 同期したワークアウトを保存待ちリストに追加
  void _addSyncedWorkout(SmartwatchWorkout workout) {
    setState(() {
      _importedActivities.add(workout.activity);
    });
  }

  bool _isQueued(SmartwatchWorkout workout) {
    final groupId = workout.activity.generateGroupId();
    return _importedActivities.any((a) => a.generateGroupId() == groupId);
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
      // Android では拡張子 'tcx' を MIME タイプに解決できず
      // FileType.custom + allowedExtensions が
      // PlatformException(Unsupported filter) を投げる端末があるため、
      // FileType.any で選択させ、拡張子は選択後に検証する。
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final pickedName = result.files.single.name;
        if (!pickedName.toLowerCase().endsWith('.tcx')) {
          print('⚠️ TCX以外のファイルが選択されました: $pickedName');
          setState(() {
            _isLoading = false;
          });
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('.tcx 形式のファイルを選択してください'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }

        print('📄 ファイルを選択: $pickedName');
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

      // 画面を閉じる（呼び出し元で軌跡を再読み込みさせる）
      Navigator.pop(context, true);
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

  /// スマートウォッチ連携セクション
  Widget _buildSmartwatchSection() {
    return Container(
      padding: EdgeInsets.all(16),
      color: Colors.green[50],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.watch, size: 20),
              SizedBox(width: 8),
              Text(
                'スマートウォッチと同期',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Spacer(),
              Text(
                _isHealthKitConnected ? '接続済み' : '未接続',
                style: TextStyle(
                  fontSize: 12,
                  color: _isHealthKitConnected ? Colors.green : Colors.grey,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Apple Watch や Garmin Connect がヘルスケアに書き込んだ\n'
            '直近30日のワークアウトのうち，ルート付きのものを表示します',
            style: TextStyle(fontSize: 12),
          ),
          SizedBox(height: 12),
          if (!_isHealthKitConnected)
            ElevatedButton.icon(
              onPressed: _connectHealthKit,
              icon: Icon(Icons.link),
              label: Text('ヘルスケアと接続'),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 48),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: _isSyncing || _isLoading ? null : _syncWorkouts,
              icon: _isSyncing
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.sync),
              label: Text(_isSyncing ? '同期中...' : 'データを同期'),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 48),
              ),
            ),
          if (_hasSynced && _syncedWorkouts.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'ルート付きのワークアウトが見つかりませんでした。\n'
                '「設定 > ヘルスケア > データアクセスとデバイス」で'
                'ワークアウトとワークアウトルートの読み取りが許可されているか確認してください',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
          ..._syncedWorkouts.map(_buildSyncedWorkoutTile),
        ],
      ),
    );
  }

  Widget _buildSyncedWorkoutTile(SmartwatchWorkout workout) {
    final activity = workout.activity;
    final isSaved = _savedGroupIds.contains(activity.generateGroupId());
    final isQueued = _isQueued(workout);

    Widget trailing;
    if (isSaved) {
      trailing = Text('取り込み済み', style: TextStyle(color: Colors.grey));
    } else if (isQueued) {
      trailing = Icon(Icons.check_circle, color: Colors.green);
    } else {
      trailing = TextButton(
        onPressed: () => _addSyncedWorkout(workout),
        child: Text('追加'),
      );
    }

    return Card(
      margin: EdgeInsets.only(top: 12),
      child: ListTile(
        title: Text('${activity.activityName}（${workout.sourceName}）'),
        subtitle: Text(
          '${activity.getFormattedDate()}\n'
          '${activity.distance.toStringAsFixed(2)} km・${activity.steps} 歩・'
          '${activity.positions.length} ポイント',
          style: TextStyle(fontSize: 12),
        ),
        isThreeLine: true,
        trailing: trailing,
      ),
    );
  }

  Widget _buildTcxSection() {
    return Container(
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
          SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _pickAndImportTcxFile,
            icon: Icon(Icons.folder_open),
            label: Text('TCX ファイルを選択'),
            style: ElevatedButton.styleFrom(
              minimumSize: Size(double.infinity, 48),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportedActivityCard(int index) {
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('インポート'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                if (_isHealthKitAvailable) _buildSmartwatchSection(),
                _buildTcxSection(),
                SizedBox(height: 16),

                // 保存待ちのアクティビティのリスト
                if (_importedActivities.isNotEmpty) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '保存するアクティビティ',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  for (int i = 0; i < _importedActivities.length; i++)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: _buildImportedActivityCard(i),
                    ),
                ] else if (!_isLoading)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(_isHealthKitAvailable
                          ? 'アクティビティを同期またはファイルを選択してください'
                          : 'ファイルを選択してください'),
                    ),
                  ),
              ],
            ),
          ),

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
