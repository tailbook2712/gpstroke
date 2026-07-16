import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/artwork_list_screen.dart';
import 'package:walk_tracker_app/artwork_creation_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'database_helper.dart';
import 'firestore_service.dart';
import 'auth_service.dart';
import 'garmin_import_screen.dart';
import 'route_design_canvas_screen.dart';
import 'package:pedometer/pedometer.dart';

import 'utils/utils.dart';

// 記録モードの定義
enum RecordingMode {
  freeMode, // フリー記録モード（現在の軌跡を自由に記録）
  routeFollowMode, // ルート追従モード（ルート提案のルートをなぞって記録）
}

class WalkingTrackerScreen extends StatefulWidget {
  /// 初期ルートパス（ルート追従モードで開始する場合）
  final List<LatLng>? initialRoutePath;

  /// ルートメタデータ（距離、類似度など）
  final Map<String, dynamic>? initialRouteMetadata;

  const WalkingTrackerScreen({
    Key? key,
    this.initialRoutePath,
    this.initialRouteMetadata,
  }) : super(key: key);

  @override
  _WalkingTrackerScreenState createState() => _WalkingTrackerScreenState();
}

class _WalkingTrackerScreenState extends State<WalkingTrackerScreen> {
  // SharedPreferences キー（バックグラウンド強制終了時の記録バックアップ用）
  static const String _positionsBufferKey = 'walking_positions_buffer';

  // 記録モード（デフォルト: フリーモード）
  RecordingMode _recordingMode = RecordingMode.freeMode;

  // ルート追従モード用のデータ
  // ignore: unused_field
  List<LatLng>? _suggestedRoutePath; // 提案ルート（Polyline用）
  // ignore: unused_field
  Map<String, dynamic>? _routeMetadata; // ルート情報（距離など）

  // ignore: unused_field
  Position? _currentPosition;
  Position? _previousPosition;
  List<Position> _positions = [];
  // ignore: unused_field
  bool _isMoving = false;
  // ignore: unused_field
  bool _isTracking = false;
  bool _isRecording = false;
  double _totalDistance = 0.0; // km単位
  int _stepCount = 0;
  int _initialStepCount = 0; // 記録開始時の初期歩数
  int _lastNotificationStepCount = 0; // 最後にロック画面通知を更新した時の歩数

  final double speedThreshold = 0.3;
  final double noiseThreshold = 2.0;
  static const int _stepNotificationInterval = 50; // 50歩ごとにロック画面通知を更新

  late DatabaseHelper _dbHelper;
  List<List<Position>> trajectories = [];
  late FirestoreService _firestoreService;
  final AuthService _authService = AuthService();
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<StepCount>? _stepStream;
  List<Map<String, dynamic>> savedArtworks = []; // スクリーンショットとキャンバス状態のリスト

  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};

  // コーチマーク用 GlobalKey
  final GlobalKey _recordButtonKey = GlobalKey();
  final GlobalKey _modeToggleKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();

    // 初期ルートが渡された場合はルート追従モードで開始
    if (widget.initialRoutePath != null &&
        widget.initialRoutePath!.isNotEmpty) {
      _suggestedRoutePath = widget.initialRoutePath;
      _routeMetadata = widget.initialRouteMetadata;
      _recordingMode = RecordingMode.routeFollowMode;
    }

    _initializeScreen(); // 非同期初期化処理をまとめたメソッド
    _loadSavedArtworks();

    // ポリラインを初期化
    _polylines.add(Polyline(
      polylineId: PolylineId("current_route"),
      points: [],
      color: Colors.blue,
      width: 5,
    ));

    // コーチマーク表示後に位置情報の権限リクエストを行う
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWalkingCoachMarkIfNeeded();
    });
  }

  void _initializeLocationServices() {
    _checkPermissionAndStartTracking();
    _initializeLocationTracking();
    _setInitialCameraPosition();
  }

  Future<void> _showWalkingCoachMarkIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('coach_mark_walking_shown') ?? false) {
      _initializeLocationServices();
      return;
    }
    if (!mounted) return;

    void markShown() {
      prefs.setBool('coach_mark_walking_shown', true);
      _initializeLocationServices();
    }

    final targets = [
      TargetFocus(
        identify: 'record_button',
        keyTarget: _recordButtonKey,
        shape: ShapeLightFocus.RRect,
        radius: 12,
        paddingFocus: 8,
        enableOverlayTab: true,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('記録開始',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('ボタンを押して軌跡の記録を開始しよう',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: 'mode_toggle',
        keyTarget: _modeToggleKey,
        shape: ShapeLightFocus.RRect,
        radius: 12,
        paddingFocus: 8,
        enableOverlayTab: true,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('記録モード',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text(
                    'フリーモードは自由に歩いて軌跡を記録、\nルートモードはルートに沿って記録します',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    ];

    TutorialCoachMark(
      targets: targets,
      colorShadow: Colors.black,
      textSkip: 'スキップ',
      paddingFocus: 10,
      opacityShadow: 0.8,
      onFinish: markShown,
      onSkip: () {
        markShown();
        return true;
      },
    ).show(context: context);
  }

  // 非同期初期化処理をまとめたメソッド
  Future<void> _initializeScreen() async {
    await _restoreDataFromFirestore(); // FirestoreからローカルDBにデータを復元
    await _loadTrajectories(); // 復元後にローカルDBから軌跡をロード
    await _syncUsedTrajectories(); // 使用済み軌跡情報を同期
    await _restoreArtworksFromFirestore(); // Firestoreからアートワークを復元
    await _checkUnfinishedRecording(); // バックグラウンド終了で未保存の記録がないか確認
  }

  Future<void> _syncUsedTrajectories() async {
    await _dbHelper.syncUsedTrajectoriesFromFirestore();
  }

  /// ユーザーIDでスコープされたアートワーク・キャンバスディレクトリを返す
  Future<(Directory, Directory)> _getUserArtworkDirectories() async {
    final userId = _authService.userId!;
    final base = await getApplicationDocumentsDirectory();
    final artworksDir = Directory('${base.path}/artworks/$userId');
    final canvasDir = Directory('${base.path}/canvas_states/$userId');
    return (artworksDir, canvasDir);
  }

  // Firestoreから保存されたアートワークを復元
  Future<void> _restoreArtworksFromFirestore() async {
    try {
      final artworks = await _firestoreService.getAllArtworks();
      if (artworks.isEmpty) {
        print('復元可能なアートワークが見つかりませんでした');
        return;
      }

      final (artworksDirectory, canvasDirectory) =
          await _getUserArtworkDirectories();

      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true);
      }
      if (!(await canvasDirectory.exists())) {
        await canvasDirectory.create(recursive: true);
      }

      int restoredCount = 0;
      for (var artwork in artworks) {
        try {
          final artworkId = artwork['artworkId'] ?? '';
          if (artworkId.isEmpty) {
            print('アートワークIDが見つかりません。スキップします。');
            continue;
          }

          final canvasState = artwork['canvasState'];
          if (canvasState == null) {
            print('キャンバス状態が見つかりません。スキップします: $artworkId');
            continue;
          }

          // 画像データをBase64からデコード
          if (artwork['imageData'] == null) {
            print('画像データが見つかりません。スキップします: $artworkId');
            continue;
          }

          Uint8List imageData = base64Decode(artwork['imageData']);

          // ファイルに保存
          File imgFile = File('${artworksDirectory.path}/$artworkId.png');

          // タイムスタンプの取得（エラーハンドリングを追加）
          String timestamp = '';
          try {
            if (artworkId.contains('_')) {
              timestamp = artworkId.split('_').last;
            } else {
              // タイムスタンプを生成
              timestamp = DateTime.now().millisecondsSinceEpoch.toString();
            }
          } catch (e) {
            // タイムスタンプの取得に失敗した場合は現在時刻を使用
            print('タイムスタンプの取得に失敗しました: $e');
            timestamp = DateTime.now().millisecondsSinceEpoch.toString();
          }

          File canvasFile =
              File('${canvasDirectory.path}/canvas_$timestamp.json');

          // すでに存在する場合はスキップ
          if (await imgFile.exists() && await canvasFile.exists()) {
            print('アートワークはすでに存在します: $artworkId');
            continue;
          }

          // ファイルに書き込み
          await imgFile.writeAsBytes(imageData);
          await canvasFile.writeAsString(jsonEncode(canvasState));

          print('アートワークを復元しました: $artworkId');
          restoredCount++;
        } catch (e) {
          print('アートワークの復元中にエラー: $e');
        }
      }

      print('Firestoreからアートワークを復元しました: $restoredCount件');

      // アートワークのリストを更新
      await _loadSavedArtworks();
    } catch (e) {
      print('Firestoreからのアートワーク復元エラー: $e');
    }
  }

  // 保存された作品をロード
  Future<void> _loadSavedArtworks() async {
    final (artworksDirectory, canvasDirectory) =
        await _getUserArtworkDirectories();

    // 両ディレクトリが存在しない場合は空リストのまま返す
    if (!await artworksDirectory.exists() || !await canvasDirectory.exists()) {
      savedArtworks = [];
      return;
    }

    // スクリーンショットとキャンバス状態を対応付けてロード
    final artworkFiles = artworksDirectory.listSync().whereType<File>();
    final canvasFiles = canvasDirectory.listSync().whereType<File>();

    savedArtworks = artworkFiles
        .map((artworkFile) {
          // 対応するキャンバス状態ファイルを取得
          final timestamp = artworkFile.path.split('_').last.split('.').first;
          final canvasFile = canvasFiles.firstWhere(
            (file) => file.path.contains(timestamp),
            orElse: () => File(''), // 見つからなければ空ファイル（スキップ）
          );

          if (canvasFile.existsSync()) {
            return {
              'imageFile': artworkFile,
              'canvasFile': canvasFile,
            };
          }
          return null; // キャンバスファイルがない場合スキップ
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // 位置情報の許可を確認してトラッキングを開始
  Future<void> _checkPermissionAndStartTracking() async {
    LocationPermission permission;
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("位置情報の許可が拒否されました。");
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      print("位置情報の許可が永久に拒否されています。設定から変更してください。");
      return;
    }
    _startTracking();
  }

  // 位置情報のトラッキングを開始
  void _startTracking() {
    setState(() {
      _isTracking = true;
    });
    // flutter_background は Android 専用（iOS は OS が背面位置情報更新を
    // ネイティブに処理するため、常駐通知の仕組みは不要）
    if (Platform.isAndroid) {
      FlutterBackground.enableBackgroundExecution();
    }
  }

  // 位置情報の記録を開始
  void _startRecording() async {
    // 前回の未保存バッファをクリアしてから開始
    await _clearPositionsBuffer();

    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _totalDistance = 0.0;
      _stepCount = 0;
      _initialStepCount = 0;
      _lastNotificationStepCount = 0;
      _positions.clear();
    });

    // 記録開始時にロック画面通知を「記録中」に切り替える
    _updateLockScreenNotification();

    // 歩数のstreamを監視
    _stepStream = Pedometer.stepCountStream.listen((StepCount event) {
      if (!mounted) return;
      if (_isRecording) {
        setState(() {
          if (_initialStepCount == 0) {
            _initialStepCount = event.steps; // 記録開始時の歩数を保存
          }
          _stepCount = event.steps - _initialStepCount; // 初期歩数を差し引いて0からカウント
        });
        // 50歩ごとにロック画面通知の歩数を更新
        if (_stepCount - _lastNotificationStepCount >= _stepNotificationInterval) {
          _lastNotificationStepCount = _stepCount;
          _updateLockScreenNotification();
        }
      }
    });

    // 位置情報の取得自体は _initializeLocationTracking で継続的に行われている
    // (Geolocator.getPositionStream 経由、フォアグラウンド・バックグラウンド共通)
  }

  // 位置情報の記録を停止
  Future<void> _stopRecording() async {
    setState(() {
      _isRecording = false;
      _initialStepCount = 0;
    });

    _stepStream?.cancel();

    // メモリバッファが空の場合、SharedPreferencesから復元を試みる
    // （バックグラウンドでアプリが一時停止された際の対策）
    if (_positions.isEmpty) {
      _positions = await _loadPositionsFromBuffer();
      debugPrint('SharedPreferencesから${_positions.length}件の位置情報を復元しました');
    }

    if (_positions.isEmpty) {
      await _clearPositionsBuffer();
      return;
    }

    final positionData = _positions.map((position) {
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp.toIso8601String(),
      };
    }).toList();

    // generateGroupId を使って groupId を生成
    String groupId = generateGroupId(_positions);

    // positions[0]のtimestampをdateとして使用
    final currentDate = _positions[0].timestamp.toIso8601String();

    // 記録モードの情報をメタデータとして保存
    Map<String, dynamic> metadata = {
      'recordingMode': _recordingMode.toString(),
    };

    // ルート追従モードの場合、ルート情報も保存
    if (_recordingMode == RecordingMode.routeFollowMode &&
        _routeMetadata != null) {
      metadata['routeMetadata'] = _routeMetadata;
      metadata['suggestedRouteDistance'] = _routeMetadata?['distance'];
    }

    await _dbHelper.insertWalkingData(
      groupId: groupId,
      date: currentDate,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    // Firestore に保存
    await _firestoreService.saveWalkingData(
      groupId: groupId,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    print("保存した groupId: $groupId");

    _positions.clear();
    await _clearPositionsBuffer(); // バッファをクリア

    // 記録終了後、ロック画面通知を待機状態に戻す（Android のみ）
    if (Platform.isAndroid) {
      await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'GPStroke',
          notificationText: '待機中',
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      );
      await FlutterBackground.enableBackgroundExecution();
    }
  }

  // ── ロック画面通知の更新 ────────────────────────────────────

  /// 記録中の歩数・距離をロック画面通知（Android: フォアグラウンドサービス通知）に反映する。
  /// 距離更新（10m移動ごと）と歩数更新（50歩ごと）の両タイミングで呼ばれる。
  /// iOS はシステムが背面位置情報更新を管理するため常駐通知の概念がなく、対象外。
  void _updateLockScreenNotification() {
    if (_isRecording && Platform.isAndroid) {
      FlutterBackground.initialize(
        androidConfig: FlutterBackgroundAndroidConfig(
          notificationTitle: '🚶 GPStroke 記録中',
          notificationText:
              '歩数: $_stepCount 歩  |  距離: ${_totalDistance.toStringAsFixed(2)} km',
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      ).then((_) => FlutterBackground.enableBackgroundExecution());
    }
  }

  // 位置情報トラッキングの初期化
  Future<void> _initializeLocationTracking() async {
    // flutter_background は Android 専用。iOS は Info.plist の
    // UIBackgroundModes(location) + AppleSettings.allowBackgroundLocationUpdates
    // により OS がネイティブに背面位置情報更新を継続してくれる。
    if (Platform.isAndroid) {
      await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'GPStroke',
          notificationText: '待機中',
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      );
    }

    // distanceFilter: 10m ごとにコールバックを発火（バッテリー節約の核心）
    final LocationSettings locationSettings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            activityType: ActivityType.fitness,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _checkIfUserIsMoving,
      onError: (Object error) {
        print("[onLocation] ERROR: $error");
      },
    );
  }

  // ユーザーが移動しているかどうかをチェック
  // BackgroundGeolocation の onLocation コールバックから呼ばれる（単一の位置情報ソース）
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    if (!mounted) return;
    if (_previousPosition != null) {
      final double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // distanceFilter:10m で大半のノイズは除去済みだが念のため残す
      if (_isNoise(distance)) {
        return;
      }

      // 記録中の場合、距離を累積し位置を保存
      if (_isRecording) {
        // 移動距離をkm単位で累積
        final double distanceKm = distance / 1000.0;

        setState(() {
          _totalDistance += distanceKm;
          _positions.add(newPosition);
          _polylines = {
            Polyline(
              polylineId: const PolylineId("current_route"),
              points: _positions
                  .map((pos) => LatLng(pos.latitude, pos.longitude))
                  .toList(),
              color: Colors.blue,
              width: 5,
            ),
          };
        });

        // バックグラウンド強制終了に備えて SharedPreferences にもバックアップ
        await _savePositionToBuffer(newPosition);

        // 距離が更新されたのでロック画面通知を更新（10m移動ごと）
        _updateLockScreenNotification();

        // 記録中は現在地を地図の中央に固定
        _mapController?.animateCamera(
          CameraUpdate.newLatLng(
            LatLng(newPosition.latitude, newPosition.longitude),
          ),
        );
      }

      if (newPosition.speed > speedThreshold) {
        setState(() {
          _isMoving = true;
          _currentPosition = newPosition;
        });
      } else {
        setState(() {
          _isMoving = false;
        });
      }
    } else {
      setState(() {
        _currentPosition = newPosition;
      });
    }

    _previousPosition = newPosition;
  }

  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  // ── SharedPreferences バッファ操作 ──────────────────────────

  /// 位置情報を SharedPreferences バッファに保存
  /// バックグラウンド中にアプリが強制終了された場合の記録復元に使用
  Future<void> _savePositionToBuffer(Position position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final buffer = prefs.getStringList(_positionsBufferKey) ?? [];
      buffer.add(jsonEncode({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp.toIso8601String(),
      }));
      await prefs.setStringList(_positionsBufferKey, buffer);
    } catch (e) {
      print('位置情報バッファの保存に失敗: $e');
    }
  }

  /// SharedPreferences バッファをクリア
  Future<void> _clearPositionsBuffer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_positionsBufferKey);
    } catch (e) {
      print('位置情報バッファのクリアに失敗: $e');
    }
  }

  /// SharedPreferences バッファから位置情報を復元
  Future<List<Position>> _loadPositionsFromBuffer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final buffer = prefs.getStringList(_positionsBufferKey) ?? [];
      if (buffer.isEmpty) return [];

      return buffer.map((raw) {
        final pos = jsonDecode(raw) as Map<String, dynamic>;
        return Position(
          latitude: (pos['latitude'] as num).toDouble(),
          longitude: (pos['longitude'] as num).toDouble(),
          timestamp: DateTime.tryParse(pos['timestamp'] as String) ?? DateTime.now(),
          accuracy: 0.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );
      }).toList();
    } catch (e) {
      print('位置情報バッファの読み込みに失敗: $e');
      return [];
    }
  }

  /// 起動時に未保存の記録バッファがないか確認し、あればユーザーに復元を提案する
  Future<void> _checkUnfinishedRecording() async {
    final prefs = await SharedPreferences.getInstance();
    final buffer = prefs.getStringList(_positionsBufferKey) ?? [];
    if (buffer.isEmpty) return;
    if (!mounted) return;

    final shouldRecover = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未保存の記録があります'),
        content: Text(
          '前回の記録中にアプリが終了した可能性があります。\n'
          '記録を復元して保存しますか？（${buffer.length} ポイント）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('破棄'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('復元して保存'),
          ),
        ],
      ),
    );

    if (shouldRecover == true) {
      final positions = await _loadPositionsFromBuffer();
      if (positions.isNotEmpty) {
        // 距離を再計算（km）
        double totalDist = 0.0;
        for (int i = 1; i < positions.length; i++) {
          totalDist += Geolocator.distanceBetween(
                positions[i - 1].latitude,
                positions[i - 1].longitude,
                positions[i].latitude,
                positions[i].longitude,
              ) /
              1000.0;
        }

        final positionData = positions
            .map((p) => {
                  'latitude': p.latitude,
                  'longitude': p.longitude,
                  'timestamp': p.timestamp.toIso8601String(),
                })
            .toList();

        final groupId = generateGroupId(positions);
        final currentDate = positions.first.timestamp.toIso8601String();

        await _dbHelper.insertWalkingData(
          groupId: groupId,
          date: currentDate,
          steps: 0, // バックグラウンド終了時は歩数不明
          distance: totalDist,
          positions: positionData,
        );
        await _firestoreService.saveWalkingData(
          groupId: groupId,
          steps: 0,
          distance: totalDist,
          positions: positionData,
        );

        debugPrint('未保存の記録を復元・保存しました: $groupId');
        await _loadTrajectories();
      }
    }

    await _clearPositionsBuffer();
  }

  // Firestoreからデータを復元
  Future<void> _restoreDataFromFirestore() async {
    try {
      List<Map<String, dynamic>> allWalkingData =
          await _firestoreService.getAllWalkingData();
      for (var data in allWalkingData) {
        // 各フィールドを取得
        String groupId = data['groupId'] ?? 0;
        String date = data['timestamp'] ?? DateTime.now().toIso8601String();
        int steps = data['steps'] ?? 0;
        double distance = data['distance'] ?? 0.0;

        // positionsがリスト型かを確認
        if (data['positions'] is List) {
          List<Map<String, dynamic>> positions =
              List<Map<String, dynamic>>.from(data['positions']);

          // データをローカルデータベースに保存
          await _dbHelper.insertWalkingData(
            groupId: groupId,
            date: date,
            steps: steps,
            distance: distance,
            positions: positions,
          );
        } else {
          print("予期しないpositionsの形式: ${data['positions']}");
        }
      }
      print("Firestoreからローカルデータベースにデータを復元しました");
    } catch (e) {
      print("データの復元に失敗しました: $e");
    }
  }

  // ローカルデータベースから軌跡を読み込む
  Future<void> _loadTrajectories() async {
    try {
      List<Map<String, dynamic>> walkingData =
          await _dbHelper.getAllWalkingData();
      List<List<Position>> loadedTrajectories = [];

      for (var data in walkingData) {
        // positions フィールドを JSON デコード
        List<dynamic> positionsData = jsonDecode(data['positions']);

        // Position オブジェクトに変換
        List<Position> positions = positionsData.map((pos) {
          return Position(
            latitude: pos['latitude'],
            longitude: pos['longitude'],
            timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
            accuracy: 0.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          );
        }).toList();

        loadedTrajectories.add(positions);
      }

      if (!mounted) return;
      setState(() {
        trajectories = loadedTrajectories;
      });
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  // アートワーク作成画面に遷移
  void _navigateToArtworkCreationScreen() async {
    // ローカルDBのみ読み込み（Firestoreへのアクセスは起動時に済んでいる）
    await _loadTrajectories();

    if (!mounted) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkCreationScreen(trajectories: trajectories),
      ),
    );

    // 作品が保存された場合のみFirestoreと同期してギャラリーを更新
    if (result != null) {
      await _syncUsedTrajectories();
      await _loadSavedArtworks();
    }
  }

  // アートワークギャラリー画面に遷移
  Future<void> _navigatetoArtworkGalleryScreen() async {
    await _loadSavedArtworks();

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkListScreen(savedArtworks: savedArtworks),
      ),
    );
  }

  // Garmin インポート画面に遷移
  Future<void> _navigateToGarminImportScreen() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GarminImportScreen(),
      ),
    );

    // インポート後、軌跡を再読み込み
    if (result != null) {
      await _loadTrajectories();
    }
  }

  // ルート提案画面に遷移
  Future<void> _navigateToRouteSuggestionScreen() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteDesignCanvasScreen(),
      ),
    );

    if (!mounted) return;
    // ルート選択画面から戻った場合、トグルをフリーモードにリセット
    setState(() {
      _recordingMode = RecordingMode.freeMode;
    });

    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        _suggestedRoutePath = result['routePath'] as List<LatLng>;
        _routeMetadata = result['metadata'] as Map<String, dynamic>;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ルートが設定されました: ${(_routeMetadata?['distance'] / 1000).toStringAsFixed(2)}km',
          ),
        ),
      );
    }
  }

  /// Polylineを構築（モードに応じて表示内容を分岐）
  Set<Polyline> _buildPolylines() {
    Set<Polyline> polylines = {};

    // 現在記録中の軌跡（青色）
    polylines.add(
      Polyline(
        polylineId: PolylineId("current_route"),
        points: _positions
            .map((pos) => LatLng(pos.latitude, pos.longitude))
            .toList(),
        color: Colors.blue,
        width: 5,
      ),
    );

    // ルート追従モード時、提案ルートを表示（緑色）
    if (_recordingMode == RecordingMode.routeFollowMode &&
        _suggestedRoutePath != null &&
        _suggestedRoutePath!.isNotEmpty) {
      polylines.add(
        Polyline(
          polylineId: PolylineId("suggested_route"),
          points: _suggestedRoutePath!,
          color: Colors.green,
          width: 4,
          geodesic: true,
        ),
      );
    }

    return polylines;
  }

  @override
  void dispose() {
    _stepStream?.cancel();
    _positionStream?.cancel();
    if (Platform.isAndroid) {
      FlutterBackground.disableBackgroundExecution();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('軌跡の記録', style: TextStyle(fontSize: 20)),
            SizedBox(height: 4),
            Text(
              '歩数: $_stepCount 歩  距離: ${_totalDistance.toStringAsFixed(2)}km',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          // ユーザーアイコン（ログアウトメニュー）
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage: _authService.currentUser?.photoURL != null
                  ? NetworkImage(_authService.currentUser!.photoURL!)
                  : null,
              child: _authService.currentUser?.photoURL == null
                  ? Icon(Icons.person, size: 20)
                  : null,
            ),
            onSelected: (value) async {
              if (value == 'logout') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('ログアウト'),
                    content: Text('ログアウトしますか？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text('キャンセル'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text('ログアウト'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await _authService.signOut();
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _authService.currentUser?.displayName ?? 'ユーザー',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    Text(
                      _authService.currentUser?.email ?? '',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 8),
                    Text('ログアウト', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(35.0, 135.0),
              zoom: 16,
            ),
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              _setInitialCameraPosition();
            },
            polylines: _buildPolylines(),
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
          ),
          // モード選択パネルとボタン（BottomNavigationBar の上）
          Positioned(
            bottom: 60,
            left: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // モード切り替えトグル
                Container(
                  key: _modeToggleKey,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // フリーモード
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _recordingMode = RecordingMode.freeMode;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: _recordingMode == RecordingMode.freeMode
                                ? Colors.blue[700]
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.location_on,
                                size: 18,
                                color: _recordingMode == RecordingMode.freeMode
                                    ? Colors.white
                                    : Colors.grey[600],
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'フリー',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color:
                                      _recordingMode == RecordingMode.freeMode
                                          ? Colors.white
                                          : Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // ルート追従モード
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _recordingMode = RecordingMode.routeFollowMode;
                            if (_suggestedRoutePath == null ||
                                _suggestedRoutePath!.isEmpty) {
                              _navigateToRouteSuggestionScreen();
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: _recordingMode ==
                                    RecordingMode.routeFollowMode
                                ? Colors.orange[700]
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.route,
                                size: 18,
                                color: _recordingMode ==
                                        RecordingMode.routeFollowMode
                                    ? Colors.white
                                    : Colors.grey[600],
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'ルート',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: _recordingMode ==
                                          RecordingMode.routeFollowMode
                                      ? Colors.white
                                      : Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // アクションボタン
                SizedBox(
                  key: _recordButtonKey,
                  width: 200,
                  child: ElevatedButton.icon(
                    onPressed: _isRecording
                        ? _stopRecording
                        : (_recordingMode == RecordingMode.routeFollowMode &&
                                (_suggestedRoutePath == null ||
                                    _suggestedRoutePath!.isEmpty))
                            ? _navigateToRouteSuggestionScreen
                            : _startRecording,
                    icon: Icon(
                      _isRecording
                          ? Icons.stop_rounded
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? Icons.add_location
                              : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      _isRecording
                          ? '記録停止'
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? 'ルート提案'
                              : '記録開始',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecording
                          ? Colors.red[600]
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? Colors.orange[700]
                              : Colors.blue[700],
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: 0,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: [
          BottomNavigationBarItem(
            icon: Icon(Icons.location_on),
            label: '軌跡の記録',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.brush),
            label: '作品の制作',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download),
            label: 'Garmin',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.collections),
            label: 'ギャラリー',
          ),
        ],
        onTap: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              _navigateToArtworkCreationScreen();
              break;
            case 2:
              _navigateToGarminImportScreen();
              break;
            case 3:
              _navigatetoArtworkGalleryScreen();
              break;
          }
        },
      ),
    );
  }

  Future<void> _setInitialCameraPosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });

      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 16,
          ),
        ),
      );
    } catch (e) {
      print("現在位置を取得できませんでした: $e");
    }
  }
}
