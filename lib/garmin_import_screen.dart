import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'activity_file_loader.dart';
import 'tcx_parser.dart';
import 'database_helper.dart';
import 'firestore_service.dart';
import 'healthkit_service.dart';

/// インポート方法（セグメントコントロールで切り替え）
enum _ImportMode { appleWatch, file }

class GarminImportScreen extends StatefulWidget {
  @override
  _GarminImportScreenState createState() => _GarminImportScreenState();
}

class _GarminImportScreenState extends State<GarminImportScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final FirestoreService _firestoreService = FirestoreService();
  final HealthKitService _healthKitService = HealthKitService();
  List<GarminActivityData> _importedActivities = []; // ファイルから読み込んだもの
  bool _isLoading = false;
  _ImportMode _mode = _ImportMode.appleWatch;
  double _userHeightCm = 170.0; // デフォルト170cm

  // スマートウォッチ（HealthKit）連携
  bool _isHealthKitAvailable = false;
  bool _isHealthKitConnected = false;
  bool _isSyncing = false;
  bool _hasSynced = false;
  List<SmartwatchWorkout> _syncedWorkouts = [];
  Set<String> _savedGroupIds = {};
  final Set<String> _selectedWorkoutGroupIds = {}; // 保存対象として選んだワークアウト

  /// 保存対象（選択した Apple Watch のワークアウト + 読み込んだファイル）
  List<GarminActivityData> get _activitiesToSave => [
        ..._syncedWorkouts
            .map((w) => w.activity)
            .where((a) => _selectedWorkoutGroupIds.contains(a.generateGroupId())),
        ..._importedActivities,
      ];

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
      if (!available) _mode = _ImportMode.file;
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
        title: Text('Apple Watch と接続'),
        content: Text(
          'Apple Watch で記録したアクティビティを，'
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

  /// 同期したワークアウトの保存対象の選択を切り替え
  void _toggleSyncedWorkout(SmartwatchWorkout workout) {
    final groupId = workout.activity.generateGroupId();
    setState(() {
      if (!_selectedWorkoutGroupIds.remove(groupId)) {
        _selectedWorkoutGroupIds.add(groupId);
      }
    });
  }

  /// 読み込んだファイルを保存待ちリストに追加する。取り込み済み（DBに同じgroupIdがある）ものと，
  /// すでに保存対象にあるものは除外し，除外した件数を返す
  Future<({int alreadySaved, int alreadyQueued})> _queueActivities(
      List<GarminActivityData> activities) async {
    final queuedGroupIds =
        _activitiesToSave.map((a) => a.generateGroupId()).toSet();
    final toAdd = <GarminActivityData>[];
    int alreadySaved = 0;
    int alreadyQueued = 0;

    for (final activity in activities) {
      final groupId = activity.generateGroupId();
      if (queuedGroupIds.contains(groupId)) {
        alreadyQueued++;
      } else if (await _dbHelper.getWalkingDataByGroupId(groupId) != null) {
        alreadySaved++;
        _savedGroupIds.add(groupId);
      } else {
        queuedGroupIds.add(groupId);
        toAdd.add(activity);
      }
    }

    if (mounted) {
      setState(() {
        _importedActivities.addAll(toAdd);
      });
    }
    return (alreadySaved: alreadySaved, alreadyQueued: alreadyQueued);
  }

  bool _isSelected(SmartwatchWorkout workout) =>
      _selectedWorkoutGroupIds.contains(workout.activity.generateGroupId());

  /// SharedPreferencesから身長を読み込み
  Future<void> _loadUserHeight() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
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
              'ファイルに歩数が記録されていない場合，身長から歩幅を計算し、距離から歩数を推定します',
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

  /// アクティビティファイルを選択してインポート
  Future<void> _pickAndImportFile() async {
    try {
      print('📂 ファイルピッカーを開く');
      // Android では拡張子 'tcx' を MIME タイプに解決できず
      // FileType.custom + allowedExtensions が
      // PlatformException(Unsupported filter) を投げる端末があるため、
      // FileType.any で選択させ、拡張子は選択後に検証する。
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final paths = <String>[];
      for (final file in result.files) {
        if (file.path != null && ActivityFileLoader.isSupported(file.name)) {
          paths.add(file.path!);
        } else {
          print('⚠️ 対応していないファイルが選択されました: ${file.name}');
        }
      }
      if (paths.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('.tcx / .fit / .zip 形式のファイルを選択してください'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      await _importFiles(paths);
    } catch (e) {
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

  /// ファイルを解析して保存待ちリストに追加
  Future<void> _importFiles(List<String> paths) async {
    setState(() {
      _isLoading = true;
    });

    final activities = <GarminActivityData>[];
    final failedFiles = <String>[];
    for (final path in paths) {
      print('📄 ファイルを読み込み: $path (身長: ${_userHeightCm.toStringAsFixed(1)}cm)');
      try {
        final parsed = await ActivityFileLoader.load(
          path,
          userHeightCm: _userHeightCm,
        );
        if (parsed.isEmpty) {
          failedFiles.add(p.basename(path));
        }
        activities.addAll(parsed);
      } catch (e) {
        print('❌ ファイル読み込みエラー: $e');
        failedFiles.add(p.basename(path));
      }
    }

    final skipped = await _queueActivities(activities);
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });

    final addedCount =
        activities.length - skipped.alreadySaved - skipped.alreadyQueued;
    final messages = [
      if (addedCount > 0) '$addedCount 件のアクティビティを読み込みました',
      if (skipped.alreadySaved > 0) '取り込み済みのため除外: ${skipped.alreadySaved} 件',
      if (skipped.alreadyQueued > 0) 'リストに追加済みのため除外: ${skipped.alreadyQueued} 件',
      if (failedFiles.isNotEmpty) '解析に失敗: ${failedFiles.join(', ')}',
    ];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(messages.join('\n')),
        backgroundColor: activities.isEmpty ? Colors.red : null,
      ),
    );
  }

  /// インポートしたアクティビティを削除
  void _removeActivity(int index) {
    setState(() {
      _importedActivities.removeAt(index);
    });
  }

  /// 保存対象のアクティビティをすべてデータベースに保存
  Future<void> _saveAllActivities() async {
    final activitiesToSave = _activitiesToSave;
    if (activitiesToSave.isEmpty) {
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

      for (final activity in activitiesToSave) {
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

        // ローカルDBに保存（同じgroupIdが既にあれば挿入されないので，Firestoreも上書きしない）
        final inserted = await _dbHelper.insertWalkingData(
          groupId: groupId,
          date: date,
          steps: activity.steps,
          distance: activity.distance,
          positions: positions,
        );
        if (inserted == 0) continue;

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
        _selectedWorkoutGroupIds.clear();
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

  /// 「Apple Watch と同期」タブ
  List<Widget> _buildAppleWatchTab() {
    return [
      Container(
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
                  'ヘルスケアと同期',
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
              'ヘルスケアに保存された直近30日のワークアウトのうち，'
              'ルート付きのものを表示します。保存するものを選んでください',
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
          ],
        ),
      ),
      if (_hasSynced && _syncedWorkouts.isEmpty)
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'ルート付きのワークアウトが見つかりませんでした。\n'
            '「設定 > ヘルスケア > データアクセスとデバイス」で'
            'ワークアウトとワークアウトルートの読み取りが許可されているか確認してください',
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
        )
      else if (!_hasSynced && _isHealthKitConnected)
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('「データを同期」を押してください')),
        ),
      for (final workout in _syncedWorkouts)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: _buildSyncedWorkoutTile(workout),
        ),
      SizedBox(height: 16),
    ];
  }

  Widget _buildSyncedWorkoutTile(SmartwatchWorkout workout) {
    final activity = workout.activity;
    final isSaved = _savedGroupIds.contains(activity.generateGroupId());
    final isSelected = _isSelected(workout);

    return Card(
      margin: EdgeInsets.only(top: 12),
      child: ListTile(
        title: Text('${activity.activityName}（${workout.sourceName}）'),
        subtitle: Text(
          '${activity.getFormattedDate()}\n'
          '${activity.distance.toStringAsFixed(2)} km・${activity.steps} 歩'
          '${activity.isStepsEstimated ? '（推定）' : ''}・'
          '${activity.positions.length} ポイント',
          style: TextStyle(fontSize: 12),
        ),
        isThreeLine: true,
        enabled: !isSaved,
        onTap: isSaved || _isLoading ? null : () => _toggleSyncedWorkout(workout),
        trailing: isSaved
            ? Text('取り込み済み', style: TextStyle(color: Colors.grey))
            : Icon(
                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isSelected ? Colors.green : Colors.grey,
              ),
      ),
    );
  }

  /// 「ファイルをインポート」タブ
  List<Widget> _buildFileTab() {
    return [
      Container(
        padding: EdgeInsets.all(16),
        color: Colors.blue[50],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ファイルをインポート',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '1. Garmin Connect からアクティビティをエクスポート\n'
              '   （.tcx / .fit / オリジナルの .zip に対応）\n'
              '2. 下のボタンからファイルを選択\n'
              '3. 身長が正しいか確認（下で変更可能）\n'
              '4. プレビュー後、保存ボタンで完了',
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
              onPressed: _isLoading ? null : _pickAndImportFile,
              icon: Icon(Icons.folder_open),
              label: Text('ファイルを選択'),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 48),
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: 16),

      // 読み込んだファイルのアクティビティ
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
          child: Center(child: Text('ファイルを選択してください')),
        ),
    ];
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
              '歩数: ${activity.steps} 歩'
              '${activity.isStepsEstimated ? '（身長から推定）' : ''}',
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
    final saveCount = _activitiesToSave.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('インポート'),
      ),
      body: Column(
        children: [
          // インポート方法の切り替え（ヘルスケアが使えない端末ではファイルのみ）
          if (_isHealthKitAvailable)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_ImportMode>(
                  segments: [
                    ButtonSegment(
                      value: _ImportMode.appleWatch,
                      label: Text('Apple Watch と同期'),
                    ),
                    ButtonSegment(
                      value: _ImportMode.file,
                      label: Text('ファイルをインポート'),
                    ),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() {
                      _mode = selection.first;
                    });
                  },
                ),
              ),
            ),

          Expanded(
            child: ListView(
              children: _mode == _ImportMode.appleWatch
                  ? _buildAppleWatchTab()
                  : _buildFileTab(),
            ),
          ),

          // 保存ボタン（両タブで選んだものをまとめて保存）
          if (saveCount > 0)
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
                            '$saveCount 個のアクティビティを保存',
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
