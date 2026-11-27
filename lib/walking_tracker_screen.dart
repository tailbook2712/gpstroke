import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/artwork_list_screen.dart';
import 'package:walk_tracker_app/artwork_creation_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'artwork_store.dart';
import 'auth_service.dart';
import 'draft_store.dart';
import 'garmin_import_screen.dart';
import 'saved_route_list_screen.dart';
import 'trajectory.dart';
import 'trajectory_store.dart';
import 'package:pedometer/pedometer.dart';

import 'utils/android_permissions.dart';
import 'utils/trajectory_filter.dart';
import 'utils/utils.dart';

/// 画面遷移を監視する RouteObserver（MaterialApp.navigatorObservers に登録する）
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

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

class _WalkingTrackerScreenState extends State<WalkingTrackerScreen>
    with RouteAware, WidgetsBindingObserver {
  // SharedPreferences キー（バックグラウンド強制終了時の記録バックアップ用）
  static const String _positionsBufferKey = 'walking_positions_buffer';

  // 記録モード（デフォルト: フリーモード）
  RecordingMode _recordingMode = RecordingMode.freeMode;

  // ルート追従モード用のデータ
  // ignore: unused_field
  List<LatLng>? _suggestedRoutePath; // 提案ルート（Polyline用）
  // ignore: unused_field
  Map<String, dynamic>? _routeMetadata; // ルート情報（距離など）

  // 記録中の軌跡。高速移動（乗り物）を挟んだ場合は区間ごとに分割される
  List<List<Position>> _segments = [];
  bool _isRecording = false;
  bool _isStoppingRecording = false;
  double _totalDistance = 0.0; // km単位
  int _stepCount = 0;
  int? _initialStepCount; // 記録開始時の初期歩数（最初の歩数イベントで設定）
  int _lastNotificationStepCount = 0; // 最後にロック画面通知を更新した時の歩数
  double _lastNotificationDistance = 0.0; // 最後にロック画面通知を更新した時の距離(km)

  // 記録する点の選別（精度・速度上限・ノイズ）。記録中のみ生成される
  TrajectoryPointFilter? _pointFilter;
  // 高速移動を検知して記録を一時停止中か
  bool _isSpeedSuspended = false;

  // 地図上の現在地表示（記録画面が最前面のときのみ有効にする）
  bool _isMapLocationEnabled = false;
  bool _isScreenVisible = true;
  bool _hasLocationPermission = false;

  // SharedPreferences バッファのメモリ上のコピー（毎回の読み込みを避ける）
  final List<String> _bufferCache = [];
  int _unflushedBufferCount = 0;

  static const int _stepNotificationInterval = 50; // 50歩ごとにロック画面通知を更新
  static const double _distanceNotificationIntervalKm = 0.1; // 100mごとに通知を更新
  static const int _bufferFlushInterval = 5; // 5点ごとにバッファを永続化

  final AuthService _authService = AuthService();
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<StepCount>? _stepStream;

  GoogleMapController? _mapController;

  // コーチマーク用 GlobalKey
  final GlobalKey _recordButtonKey = GlobalKey();
  final GlobalKey _modeToggleKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    // 初期ルートが渡された場合はルート追従モードで開始
    if (widget.initialRoutePath != null &&
        widget.initialRoutePath!.isNotEmpty) {
      _suggestedRoutePath = widget.initialRoutePath;
      _routeMetadata = widget.initialRouteMetadata;
      _recordingMode = RecordingMode.routeFollowMode;
    }

    WidgetsBinding.instance.addObserver(this);

    _initializeScreen(); // 非同期初期化処理をまとめたメソッド

    // コーチマーク表示後に位置情報の権限リクエストを行う
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWalkingCoachMarkIfNeeded();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  // ── 画面遷移・アプリ状態に応じた位置情報利用の切り替え ──────────

  // 他の画面（作品の制作・ギャラリー等）が上に積まれた
  @override
  void didPushNext() {
    _isScreenVisible = false;
    _updateMapLocationLayer();
  }

  // 他の画面から記録画面に戻ってきた
  @override
  void didPopNext() {
    _isScreenVisible = true;
    _updateMapLocationLayer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンドへ移る際は記録バッファを確実に永続化しておく
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flushPositionsBuffer();
    }
  }

  /// 地図の現在地レイヤー（青い点）は、記録画面が最前面に表示されている間だけ有効にする。
  /// GoogleMap は下の画面に残ったままなので、明示的に切らないと
  /// 作品の制作画面などでも位置情報を取り続けてしまう。
  void _updateMapLocationLayer() {
    final enabled = _hasLocationPermission && _isScreenVisible;
    if (enabled == _isMapLocationEnabled || !mounted) return;
    setState(() => _isMapLocationEnabled = enabled);
  }

  Future<void> _initializeLocationServices() async {
    // 記録していない間は位置情報ストリームを開始しない（記録開始時に開始する）
    _hasLocationPermission = await _ensureLocationPermission();
    if (!_hasLocationPermission) return;
    _updateMapLocationLayer();
    await _setInitialCameraPosition();
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
    // 軌跡をサーバーから取り込む（その端末で初めてのときはすべて、以降は増えた分だけ）。
    // 画面では端末内のキャッシュから読むため、サーバーから読むのはここだけ（#131）
    await TrajectoryStore.sync();
    await TrajectoryStore.migrateLegacy(); // 以前の形式の軌跡を移す（端末ごとに 1 回）
    // 作品・下書きは件数が少なく 1 件が小さいため、起動時にすべて読む
    // （以前の形式のものは、読み込んだときに軌跡への参照に変換される）
    await ArtworkStore.refresh();
    await ArtworkStore.migrateLocalFiles(); // 端末内にだけある作品を移す（端末ごとに 1 回）
    await DraftStore.refresh();
    await _checkUnfinishedRecording(); // バックグラウンド終了で未保存の記録がないか確認
  }

  /// 位置情報の許可を確認し、必要ならリクエストする。許可されていれば true。
  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      print("位置情報サービスが無効です。");
      return false;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("位置情報の許可が拒否されました。");
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      print("位置情報の許可が永久に拒否されています。設定から変更してください。");
      return false;
    }
    return true;
  }

  /// 記録用の位置情報設定。
  /// - distanceFilter 10m: 10m 移動するまでコールバックを発火しない
  /// - iOS: high = kCLLocationAccuracyNearestTenMeters（Best より省電力）、
  ///   fitness で歩行向けの測位にする。バックグラウンド更新はこのストリーム
  ///   （＝記録中）の間だけ有効になる
  /// - Android: 測位間隔を 5 秒にして GPS の稼働頻度を抑える
  LocationSettings _recordingLocationSettings() {
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
    );
  }

  // 位置情報の記録を開始
  Future<void> _startRecording() async {
    if (_isRecording) return;

    if (!_hasLocationPermission) {
      _hasLocationPermission = await _ensureLocationPermission();
      _updateMapLocationLayer();
    }
    if (!_hasLocationPermission) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('位置情報の利用が許可されていないため記録できません')),
      );
      return;
    }

    // Android: 歩数計（身体活動）と通知の権限は Manifest に書くだけでは有効にならず、
    // 実行時に許可を求める必要がある。拒否されても位置情報の記録は続ける。
    final runtimePermissions = await AndroidRuntimePermissions.request([
      AndroidRuntimePermissions.activityRecognition,
      AndroidRuntimePermissions.notification,
    ]);
    final canCountSteps =
        runtimePermissions[AndroidRuntimePermissions.activityRecognition] ??
            false;
    if (!canCountSteps && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('「身体活動」の権限が許可されていないため、歩数は記録されません。設定アプリから許可できます'),
        ),
      );
    }

    // 前回の未保存バッファをクリアしてから開始
    await _clearPositionsBuffer();

    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _isSpeedSuspended = false;
      _totalDistance = 0.0;
      _stepCount = 0;
      _initialStepCount = null;
      _lastNotificationStepCount = 0;
      _lastNotificationDistance = 0.0;
      _segments = [];
    });
    _pointFilter = TrajectoryPointFilter();

    // Android: 記録中のみフォアグラウンドサービス（ロック画面通知）を起動する
    if (Platform.isAndroid) {
      await _showRecordingNotification();
    }

    // 位置情報ストリームは記録中のみ購読する（記録していない間は GPS を使わない）
    await _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: _recordingLocationSettings(),
    ).listen(
      _onPositionUpdate,
      onError: (Object error) {
        print("[onLocation] ERROR: $error");
      },
    );

    // 歩数のstreamを監視（権限が無いと Android ではイベントが一切届かないため購読しない）
    await _stepStream?.cancel();
    _stepStream = null;
    if (!canCountSteps) return;
    _stepStream = Pedometer.stepCountStream.listen(
      (StepCount event) {
        if (!mounted || !_isRecording) return;
        setState(() {
          // Android の歩数は端末起動時からの累計（再起動直後は 0 もあり得る）なので
          // 0 を「未設定」の目印にせず、null で判定する
          final initial = _initialStepCount ??= event.steps; // 記録開始時の歩数を保存
          _stepCount = event.steps - initial; // 初期歩数を差し引いて0からカウント
        });
        // 50歩ごとにロック画面通知の歩数を更新
        if (_stepCount - _lastNotificationStepCount >=
            _stepNotificationInterval) {
          _lastNotificationStepCount = _stepCount;
          _updateLockScreenNotification();
        }
      },
      onError: (Object error) {
        // 歩数センサーを持たない端末など
        debugPrint('[pedometer] ERROR: $error');
      },
    );
  }

  /// 位置情報・歩数・バックグラウンド実行をすべて停止する
  Future<void> _stopLocationAndSensors() async {
    await _positionStream?.cancel();
    _positionStream = null;
    await _stepStream?.cancel();
    _stepStream = null;
    _pointFilter = null;
    if (Platform.isAndroid && FlutterBackground.isBackgroundExecutionEnabled) {
      await FlutterBackground.disableBackgroundExecution();
    }
  }

  // 位置情報の記録を停止
  Future<void> _stopRecording() async {
    if (!_isRecording || _isStoppingRecording) return;
    _isStoppingRecording = true;
    try {
      // 先に GPS・歩数計・常駐通知を止める（保存処理の間も測位し続けないように）
      await _stopLocationAndSensors();

      final steps = _stepCount;
      var segments = _segments;

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSpeedSuspended = false;
          _initialStepCount = null;
        });
      }

      // メモリ上の記録が空の場合、SharedPreferencesから復元を試みる
      // （バックグラウンドでアプリが一時停止された際の対策）
      if (segments.isEmpty) {
        segments = await _loadSegmentsFromBuffer();
        debugPrint('SharedPreferencesから${segments.length}区間の位置情報を復元しました');
      }

      await _saveSegments(segments, steps);

      if (mounted) {
        setState(() => _segments = []);
      }
      await _clearPositionsBuffer(); // バッファをクリア
    } finally {
      _isStoppingRecording = false;
    }
  }

  /// 区間ごとに軌跡を保存する。2 点未満の区間は軌跡にならないため保存しない。
  /// 歩数は区間ごとに分からないため、距離の比で按分する。
  Future<void> _saveSegments(List<List<Position>> segments, int steps) async {
    final valid = segments.where((s) => s.length >= 2).toList();
    if (valid.isEmpty) return;

    final distances = valid.map(_segmentDistanceKm).toList();
    final totalKm = distances.fold<double>(0, (a, b) => a + b);

    var assignedSteps = 0;
    for (var i = 0; i < valid.length; i++) {
      final segment = valid[i];
      final segmentSteps = i == valid.length - 1
          ? steps - assignedSteps
          : (totalKm > 0 ? (steps * distances[i] / totalKm).round() : 0);
      assignedSteps += segmentSteps;

      // 軌跡の ID は座標から作る（同じ区間を保存し直しても同じ ID になり、重複しない）
      await TrajectoryStore.add(Trajectory(
        id: generateGroupId(segment),
        source: TrajectorySource.gps,
        points: segment,
        distanceKm: distances[i],
        steps: segmentSteps,
      ));
    }
  }

  double _segmentDistanceKm(List<Position> segment) {
    double meters = 0.0;
    for (int i = 1; i < segment.length; i++) {
      meters += Geolocator.distanceBetween(
        segment[i - 1].latitude,
        segment[i - 1].longitude,
        segment[i].latitude,
        segment[i].longitude,
      );
    }
    return meters / 1000.0;
  }

  // ── ロック画面通知の更新 ────────────────────────────────────

  Future<void> _showRecordingNotification() async {
    final ok = await FlutterBackground.initialize(
      androidConfig: FlutterBackgroundAndroidConfig(
        notificationTitle: '🚶 GPStroke 記録中',
        notificationText: _isSpeedSuspended
            ? '高速移動中のため記録を一時停止しています'
            : '歩数: $_stepCount 歩  |  距離: ${_totalDistance.toStringAsFixed(2)} km',
        notificationImportance: AndroidNotificationImportance.normal,
      ),
    );
    if (ok && _isRecording) {
      await FlutterBackground.enableBackgroundExecution();
    }
  }

  /// 記録中の歩数・距離をロック画面通知（Android: フォアグラウンドサービス通知）に反映する。
  /// 距離更新（100m移動ごと）・歩数更新（50歩ごと）・高速移動による一時停止の切り替え時に呼ばれる。
  /// iOS はシステムが背面位置情報更新を管理するため常駐通知の概念がなく、対象外。
  void _updateLockScreenNotification() {
    if (_isRecording && Platform.isAndroid) {
      _showRecordingNotification();
    }
  }

  /// 記録中の位置情報更新
  Future<void> _onPositionUpdate(Position newPosition) async {
    final filter = _pointFilter;
    if (!mounted || !_isRecording || filter == null) return;

    final recorded = filter.add(newPosition);
    final suspended = filter.isSuspendedForSpeed;
    final suspendedChanged = suspended != _isSpeedSuspended;

    if (recorded.isEmpty) {
      if (suspendedChanged) {
        setState(() => _isSpeedSuspended = suspended);
        _updateLockScreenNotification();
      }
      return;
    }

    setState(() {
      _isSpeedSuspended = suspended;
      for (final point in recorded) {
        if (point.startsNewSegment || _segments.isEmpty) {
          _segments.add([point.position]);
        } else {
          _segments.last.add(point.position);
        }
        // 移動距離をkm単位で累積
        _totalDistance += point.distanceMeters / 1000.0;
      }
    });

    // バックグラウンド強制終了に備えて SharedPreferences にもバックアップ
    for (final point in recorded) {
      _appendPositionToBuffer(point.position,
          segmentStart: point.startsNewSegment);
    }

    // 通知の更新は 100m ごと（毎回更新するとサービスの再設定が頻発する）
    if (suspendedChanged ||
        _totalDistance - _lastNotificationDistance >=
            _distanceNotificationIntervalKm) {
      _lastNotificationDistance = _totalDistance;
      _updateLockScreenNotification();
    }

    // 記録画面が表示されている間は現在地を地図の中央に固定
    if (_isScreenVisible) {
      final last = recorded.last.position;
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(LatLng(last.latitude, last.longitude)),
      );
    }
  }

  // ── SharedPreferences バッファ操作 ──────────────────────────

  /// 位置情報を SharedPreferences バッファに追加する
  /// バックグラウンド中にアプリが強制終了された場合の記録復元に使用。
  /// 全件の書き込みを毎回行うと記録が長くなるほど重くなるため、
  /// 一定件数ごと＋アプリがバックグラウンドに移る時にまとめて書き込む。
  void _appendPositionToBuffer(Position position, {required bool segmentStart}) {
    _bufferCache.add(jsonEncode({
      'latitude': position.latitude,
      'longitude': position.longitude,
      'timestamp': position.timestamp.toIso8601String(),
      if (segmentStart) 'segmentStart': true,
    }));
    _unflushedBufferCount++;
    if (_unflushedBufferCount >= _bufferFlushInterval) {
      _flushPositionsBuffer();
    }
  }

  Future<void> _flushPositionsBuffer() async {
    if (_unflushedBufferCount == 0) return;
    _unflushedBufferCount = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _positionsBufferKey, List<String>.of(_bufferCache));
    } catch (e) {
      print('位置情報バッファの保存に失敗: $e');
    }
  }

  /// SharedPreferences バッファをクリア
  Future<void> _clearPositionsBuffer() async {
    _bufferCache.clear();
    _unflushedBufferCount = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_positionsBufferKey);
    } catch (e) {
      print('位置情報バッファのクリアに失敗: $e');
    }
  }

  /// SharedPreferences バッファから区間ごとの位置情報を復元
  Future<List<List<Position>>> _loadSegmentsFromBuffer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final buffer = prefs.getStringList(_positionsBufferKey) ?? [];
      final segments = <List<Position>>[];
      for (final raw in buffer) {
        final pos = jsonDecode(raw) as Map<String, dynamic>;
        final position = Position(
          latitude: (pos['latitude'] as num).toDouble(),
          longitude: (pos['longitude'] as num).toDouble(),
          timestamp:
              DateTime.tryParse(pos['timestamp'] as String) ?? DateTime.now(),
          accuracy: 0.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );
        if (segments.isEmpty || pos['segmentStart'] == true) {
          segments.add([position]);
        } else {
          segments.last.add(position);
        }
      }
      return segments;
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
    if (!mounted || _isRecording) return;

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
      final segments = await _loadSegmentsFromBuffer();
      // バックグラウンド終了時は歩数不明
      await _saveSegments(segments, 0);
      debugPrint('未保存の記録を復元・保存しました: ${segments.length}区間');
    }

    await _clearPositionsBuffer();
  }

  // アートワーク作成画面に遷移
  void _navigateToArtworkCreationScreen() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkCreationScreen(),
      ),
    );

    if (!mounted) return;

    // ルート提案で「このルートで歩く」が選ばれた場合はルート追従モードにする
    if (result is Map<String, dynamic> && result['routePath'] != null) {
      _applySuggestedRoute(result);
      return;
    }

    // 保存した作品は ArtworkStore に入るため、ギャラリーは開いたときに読み込む
  }

  // アートワークギャラリー画面に遷移
  Future<void> _navigatetoArtworkGalleryScreen() async {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkListScreen(),
      ),
    );
  }

  // Garmin インポート画面に遷移
  // （取り込んだ軌跡は TrajectoryStore に入るため、戻ってから読み込み直す必要はない）
  Future<void> _navigateToGarminImportScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GarminImportScreen(),
      ),
    );
  }

  // 保存したルートの一覧から歩くルートを選択
  Future<void> _navigateToSavedRouteList() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const SavedRouteListScreen(),
      ),
    );

    if (!mounted) return;

    if (result is Map<String, dynamic> && result['routePath'] != null) {
      _applySuggestedRoute(result);
    } else if (_suggestedRoutePath == null || _suggestedRoutePath!.isEmpty) {
      // ルート未設定のまま戻った場合はフリーモードに戻す
      setState(() {
        _recordingMode = RecordingMode.freeMode;
      });
    }
  }

  /// ルート（{'routePath': List<LatLng>, 'metadata': Map}）を設定してルート追従モードにする
  void _applySuggestedRoute(Map<String, dynamic> result) {
    final routePath = result['routePath'] as List<LatLng>;
    final metadata = result['metadata'] as Map<String, dynamic>?;
    setState(() {
      _suggestedRoutePath = routePath;
      _routeMetadata = metadata;
      _recordingMode = RecordingMode.routeFollowMode;
    });

    // ルート全体が見えるようにカメラを移動
    if (routePath.length >= 2) {
      final lats = routePath.map((p) => p.latitude);
      final lons = routePath.map((p) => p.longitude);
      _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(lats.reduce((a, b) => a < b ? a : b),
                lons.reduce((a, b) => a < b ? a : b)),
            northeast: LatLng(lats.reduce((a, b) => a > b ? a : b),
                lons.reduce((a, b) => a > b ? a : b)),
          ),
          60,
        ),
      );
    }

    final distance = (metadata?['distance'] as num?)?.toDouble();
    final name = metadata?['name'] as String?;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'ルートが設定されました'
          '${name != null ? ': $name' : ''}'
          '${distance != null ? ' (${(distance / 1000).toStringAsFixed(2)}km)' : ''}',
        ),
      ),
    );
  }

  /// Polylineを構築（モードに応じて表示内容を分岐）
  Set<Polyline> _buildPolylines() {
    Set<Polyline> polylines = {};

    // 現在記録中の軌跡（青色）。高速移動で分割された区間は別の線として描く
    for (var i = 0; i < _segments.length; i++) {
      polylines.add(
        Polyline(
          polylineId: PolylineId("current_route_$i"),
          points: _segments[i]
              .map((pos) => LatLng(pos.latitude, pos.longitude))
              .toList(),
          color: Colors.blue,
          width: 5,
        ),
      );
    }

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
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _flushPositionsBuffer();
    _stopLocationAndSensors();
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
            // 記録画面が最前面のときのみ現在地を表示（他画面では位置情報を使わない）
            myLocationEnabled: _isMapLocationEnabled,
            myLocationButtonEnabled: _isMapLocationEnabled,
          ),
          // 高速移動（自動車等）を検知して記録を一時停止している旨の表示
          if (_isRecording && _isSpeedSuspended)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.orange[700],
                borderRadius: BorderRadius.circular(12),
                elevation: 2,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.directions_car, color: Colors.white),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '高速移動を検知したため記録を一時停止中です。\n歩き始めてしばらくすると自動で再開します',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                          });
                          // 記録中でなければ保存したルートから選ぶ
                          if (!_isRecording) {
                            _navigateToSavedRouteList();
                          }
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
                            ? _navigateToSavedRouteList
                            : _startRecording,
                    icon: Icon(
                      _isRecording
                          ? Icons.stop_rounded
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? Icons.list
                              : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      _isRecording
                          ? '記録停止'
                          : (_recordingMode == RecordingMode.routeFollowMode &&
                                  (_suggestedRoutePath == null ||
                                      _suggestedRoutePath!.isEmpty))
                              ? 'ルートを選択'
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

  /// 地図の初期表示位置を現在地に合わせる（1 回だけの測位。常時の追跡はしない）
  Future<void> _setInitialCameraPosition() async {
    if (!_hasLocationPermission || _mapController == null) return;
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      if (!mounted) return;

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
