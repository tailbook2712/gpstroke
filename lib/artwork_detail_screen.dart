import 'dart:math' as math;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'artwork.dart';
import 'artwork_creation_screen.dart';
import 'artwork_share_service.dart';
import 'trajectory.dart';
import 'trajectory_store.dart';
import 'utils/slideshow_order.dart';
import 'utils/utils.dart';
import 'polyline_painter.dart';

class ArtworkDetailScreen extends StatefulWidget {
  final Artwork artwork;

  ArtworkDetailScreen({required this.artwork});

  @override
  _ArtworkDetailScreenState createState() => _ArtworkDetailScreenState();
}

class _ArtworkDetailScreenState extends State<ArtworkDetailScreen>
    with TickerProviderStateMixin {
  List<TransformablePolyline> _trajectories = [];
  // 再生順の候補（いずれも _trajectories のインデックスの並び）
  List<int> _recordedOrder = [];
  List<int> _distanceOrder = [];
  List<int> _placementOrder = [];
  List<Map<String, dynamic>> _trajectoryMetadata = []; // 軌跡のメタデータを保持
  // 各軌跡の記録日時（先頭座標の時刻。取り出せない場合は null）
  List<DateTime?> _firstPointTimes = [];

  String _artworkName = "作品の詳細";
  String _artworkSummary = "";
  final double canvasPadding = 20.0;

  List<Color> _trajectoryColors = [];

  final double trajectorySize = 100.0;

  double? savedCanvasWidth;
  double? savedCanvasHeight;

  // スライドショー機能の状態管理
  bool _isSlideshowPlaying = false;
  bool _isControlPanelVisible = false;
  int _currentTrajectoryIndex = -1;
  late AnimationController _highlightController;
  late AnimationController _mapTransitionController;
  late AnimationController _mapAlignmentController;

  // 地図表示関連の状態
  bool _isShowingMap = false;
  GoogleMapController? _mapController;
  Set<Polyline> _mapPolylines = {};
  LatLng _mapCenter = LatLng(35.0, 135.0);
  Map<String, dynamic>? _currentTrajectoryDetails;

  // スライドショーの設定
  final Duration _highlightDuration = Duration(milliseconds: 1200);
  final Duration _mapTransitionDuration = Duration(milliseconds: 800);
  final Duration _mapAlignmentDuration = Duration(milliseconds: 1000);
  final Duration _mapDisplayDuration = Duration(seconds: 3);
  final Duration _transitionDuration = Duration(milliseconds: 600);

  // スライドショーの速度制御（共有ページと同じ 1倍速 → 2倍速 → 3倍速 の循環）
  int _playbackSpeed = 1;
  final List<int> _speedOptions = [1, 2, 3];

  // スライドショーの世代番号。停止・一時停止・シークで増やし、
  // 古い再生チェーンが await 後に UI を更新しないようにする
  int _slideshowRun = 0;

  // 再生バーと設定シートの背景色（共有ページの再生バーと同じ）
  static const Color _panelColor = Color(0xFF111318);

  // 再生順と再生方法（前回の選択を端末に保存して引き継ぐ）
  static const String _orderPrefKey = 'slideshow_order';
  static const String _stylePrefKey = 'slideshow_style';
  SlideshowOrder _slideshowOrder = SlideshowOrder.recorded;
  SlideshowStyle _slideshowStyle = SlideshowStyle.highlight;

  // 選択中の再生順（_trajectories のインデックスの並び）
  List<int> get _playOrder => switch (_slideshowOrder) {
        SlideshowOrder.recorded => _recordedOrder,
        SlideshowOrder.distance => _distanceOrder,
        SlideshowOrder.placement => _placementOrder,
      };

  // 「一つずつ出現」の再生中は、まだ再生していない軌跡を隠す。
  // 再生順をまだ計算できていない間は隠さない（何も再生されず真っ白になるため）
  bool get _isRevealing =>
      _isControlPanelVisible &&
      _slideshowStyle == SlideshowStyle.reveal &&
      _playOrder.isNotEmpty;

  // デバッグフラグ
  final bool _debugMode = true;

  // 地図整列の状態管理
  bool _isMapAligned = false;
  CameraPosition? _alignedCameraPosition;

  // 作品共有（共有リンク生成中フラグ）
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();

    _highlightController = AnimationController(
      vsync: this,
      duration: _highlightDuration,
    );

    _mapTransitionController = AnimationController(
      vsync: this,
      duration: _mapTransitionDuration,
    );

    _mapAlignmentController = AnimationController(
      vsync: this,
      duration: _mapAlignmentDuration,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCanvasState();
    });
    _loadSlideshowPreferences();
  }

  Future<void> _loadSlideshowPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _slideshowOrder = SlideshowOrder.fromName(prefs.getString(_orderPrefKey));
      _slideshowStyle = SlideshowStyle.fromName(prefs.getString(_stylePrefKey));
    });
  }

  // 再生順・再生方法を切り替え、先頭から再生し直す
  Future<void> _changeSlideshowSettings(
      {SlideshowOrder? order, SlideshowStyle? style}) async {
    final bool changed = (order != null && order != _slideshowOrder) ||
        (style != null && style != _slideshowStyle);
    if (!changed) return;

    _stopSlideshow();
    setState(() {
      _slideshowOrder = order ?? _slideshowOrder;
      _slideshowStyle = style ?? _slideshowStyle;
    });
    _startSlideshow();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_orderPrefKey, _slideshowOrder.name);
    await prefs.setString(_stylePrefKey, _slideshowStyle.name);
  }

  @override
  void dispose() {
    _highlightController.dispose();
    _mapTransitionController.dispose();
    _mapAlignmentController.dispose();
    _mapController?.dispose();
    _cachedCameraPosition = null;
    super.dispose();
  }

  // 軌跡を記録日時順・距離順にソートするメソッド
  Future<void> _sortTrajectoriesByRecordTime() async {
    final List<DateTime?> recordTimes = [];
    final List<double> distances = [];

    for (int i = 0; i < _trajectories.length; i++) {
      TransformablePolyline trajectory = _trajectories[i];

      // メタデータから直接groupIdを取得（保存時に使用されたgroupIdと一致）
      String? groupId;
      if (i < _trajectoryMetadata.length &&
          _trajectoryMetadata[i].containsKey('groupId')) {
        groupId = _trajectoryMetadata[i]['groupId'] as String?;
      }

      // メタデータにgroupIdがない場合は、生成IDをフォールバックとして使用
      if (groupId == null || groupId.isEmpty) {
        groupId = generateGroupId(trajectory.polyline);
      }

      Trajectory? stored;
      try {
        stored = await TrajectoryStore.get(groupId);
        if (stored == null) {
          print("⚠️  軌跡 $i (groupId: $groupId) が見つかりません");
        }
      } catch (e) {
        print("❌ 軌跡 $i (groupId: $groupId) の取得に失敗: $e");
      }

      // 記録日時と距離は 1 本につき必ず 1 つずつ追加する
      // （2 つのリストの長さがずれると、再生順に存在しないインデックスが混ざる）
      //
      // 記録日時は、記録カードや共有ページと同じく先頭座標の時刻を使う
      final DateTime? recordTime =
          (i < _firstPointTimes.length ? _firstPointTimes[i] : null) ??
              stored?.startedAt;
      recordTimes.add(recordTime);
      distances.add(_trajectoryDistanceKm(i, stored?.distanceKm));
    }

    if (!mounted) return;
    setState(() {
      _recordedOrder = orderByRecordTime(recordTimes);
      _distanceOrder = orderByDistanceDesc(distances);
    });

    print("軌跡を記録順にソート: $_recordedOrder");
    print("軌跡を距離の長い順にソート: $_distanceOrder");

    // 再生順の計算が終わる前に再生 UI を開いていた場合は、ここで再生を始める
    // （_startSlideshow は再生順が空だと何もしないため）
    if (_isControlPanelVisible &&
        !_isSlideshowPlaying &&
        _currentTrajectoryIndex < 0) {
      _startSlideshow();
    }
  }

  // 軌跡の距離（km）。保存されている軌跡 → 作品ファイルのメタデータ → 座標列から計算
  // の順で求める。想定外の型が入っていても例外にせず、次の候補にフォールバックする
  double _trajectoryDistanceKm(int index, double? storedDistanceKm) {
    if (storedDistanceKm != null && storedDistanceKm > 0) {
      return storedDistanceKm;
    }

    final metaDistance = index < _trajectoryMetadata.length
        ? _trajectoryMetadata[index]['distance']
        : null;
    if (metaDistance is num && metaDistance > 0) return metaDistance.toDouble();

    final points = _trajectories[index].polyline;
    double meters = 0;
    for (int i = 1; i < points.length; i++) {
      meters += Geolocator.distanceBetween(points[i - 1].latitude,
          points[i - 1].longitude, points[i].latitude, points[i].longitude);
    }
    return meters / 1000;
  }

  // キャンバスの状態の復元（完全メタデータ対応版）
  Future<void> _loadCanvasState() async {
    try {
      // 作品が参照している軌跡を読み、以前の作品ファイルと同じ形のキャンバスの状態にする
      final trajectories = <String, Trajectory>{};
      for (final stroke in widget.artwork.strokes) {
        final trajectory = await TrajectoryStore.get(stroke.trajectoryId);
        if (trajectory != null) {
          trajectories[trajectory.id] = trajectory;
        } else {
          print("⚠️ 作品の軌跡が見つかりません: ${stroke.trajectoryId}");
        }
      }
      Map<String, dynamic> data = widget.artwork.toCanvasData(trajectories);

      String artworkName = data['meta']['artworkName'] ?? '作品の詳細';

      if (!mounted) return;

      final mediaQuery = MediaQuery.of(context);

      // 保存時のキャンバスサイズを取得
      savedCanvasWidth = data['canvasWidth'];
      savedCanvasHeight = data['canvasHeight'];

      // nullの場合は現在の画面サイズを使用
      if (savedCanvasWidth == null || savedCanvasHeight == null) {
        savedCanvasWidth = mediaQuery.size.width;
        savedCanvasHeight = mediaQuery.size.height -
            mediaQuery.padding.top -
            mediaQuery.padding.bottom -
            AppBar().preferredSize.height;
      }

      // 現在のbodyサイズを計算
      double currentBodyHeight = mediaQuery.size.height -
          mediaQuery.padding.top -
          mediaQuery.padding.bottom -
          AppBar().preferredSize.height;
      double currentBodyWidth = mediaQuery.size.width;

      // スケーリング比率を計算（保存時→現在）
      double scaleRatioX = currentBodyWidth / savedCanvasWidth!;
      double scaleRatioY = currentBodyHeight / savedCanvasHeight!;

      // デバッグ出力
      if (_debugMode) {
        print('=== キャンバス状態読み込み（完全メタデータ版） ===');
        print('保存時サイズ: ${savedCanvasWidth}x${savedCanvasHeight}');
        print('現在のbodyサイズ: ${currentBodyWidth}x${currentBodyHeight}');
        print('スケーリング比率: X=${scaleRatioX}, Y=${scaleRatioY}');
        print('メタデータバージョン: ${data['meta']['version'] ?? '1.0'}');
      }

      setState(() {
        _artworkName = artworkName;

        _trajectories = (data['trajectories'] as List<dynamic>).map((item) {
          List<Position> positions = (item['positions'] as List).map((pos) {
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

          // 座標復元方法を判定（新形式 vs 旧形式）
          double restoredX, restoredY;

          if (item['position'].containsKey('absoluteX') &&
              item['position'].containsKey('absoluteY')) {
            // 新形式：絶対座標が保存されている場合
            double savedAbsoluteX = item['position']['absoluteX'];
            double savedAbsoluteY = item['position']['absoluteY'];

            // 保存時の絶対座標を現在のキャンバスサイズに合わせてスケーリング
            restoredX = savedAbsoluteX * scaleRatioX;
            restoredY = savedAbsoluteY * scaleRatioY;

            if (_debugMode) {
              print(
                  '新形式復元: 保存時絶対座標(${savedAbsoluteX}, ${savedAbsoluteY}) → 現在座標(${restoredX}, ${restoredY})');
            }
          } else {
            // 旧形式：相対座標のみの場合
            double relativeX = item['position']['dx'];
            double relativeY = item['position']['dy'];

            restoredX = relativeX * currentBodyWidth;
            restoredY = relativeY * currentBodyHeight;

            if (_debugMode) {
              print(
                  '旧形式復元: 相対座標(${relativeX}, ${relativeY}) → 現在座標(${restoredX}, ${restoredY})');
            }
          }

          return TransformablePolyline(
            positions,
            Offset(restoredX, restoredY),
          )
            ..scale = item['scale'] ?? 1.0
            ..rotation = item['rotation'] ?? 0.0;
        }).toList();

        // メタデータを保存
        _trajectoryMetadata = (data['trajectories'] as List<dynamic>)
            .map((item) => (item['details'] as Map<String, dynamic>? ?? {}))
            .toList();

        // 配置順（配置日時が無い古い作品はファイル内の並び＝レイヤー順）
        _placementOrder = orderByPlacement((data['trajectories'] as List)
            .map((item) => DateTime.tryParse(item['placedAt'] as String? ?? ''))
            .toList());

        // 記録日時（先頭座標の時刻）。Position に変換した値は、時刻を読めないと
        // 読み込んだ日時で埋められてしまうため、元の文字列から読み取る
        _firstPointTimes = (data['trajectories'] as List).map((item) {
          final positions = item['positions'];
          if (positions is! List || positions.isEmpty) return null;
          final first = positions.first;
          final timestamp = first is Map ? first['timestamp'] : null;
          return timestamp is String ? DateTime.tryParse(timestamp) : null;
        }).toList();

        _trajectoryColors = List.generate(
          _trajectories.length,
          (_) => Colors.blue,
        );

        // 作品名の下に表示するサマリー（共有ページのヘッダーと同じ）
        final meta = (data['meta'] as Map<String, dynamic>?) ?? {};
        final int totalSteps = (meta['totalSteps'] as num?)?.round() ?? 0;
        final double totalDistance =
            (meta['totalDistance'] as num?)?.toDouble() ?? 0.0;
        _artworkSummary =
            '${_trajectories.length} ストローク · ${NumberFormat('#,###').format(totalSteps)} 歩 · ${totalDistance.toStringAsFixed(2)} km';
      });

      // 軌跡を記録順にソート
      await _sortTrajectoriesByRecordTime();
    } catch (e) {
      print("キャンバス状態の読み込みエラー: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("キャンバス状態の読み込みに失敗しました: $e")),
      );
    }
  }


  Future<void> _showTrajectoryDetails(TransformablePolyline trajectory) async {
    // 既にアニメーション中の場合は無視
    if (_isSlideshowPlaying) return;

    // 軌跡のインデックスを取得
    int trajectoryIndex = _trajectories.indexOf(trajectory);
    if (trajectoryIndex == -1) return;

    // 個別軌跡アニメーションを開始
    await _playIndividualTrajectoryAnimation(trajectoryIndex);
  }

  // 個別軌跡のアニメーション
  Future<void> _playIndividualTrajectoryAnimation(int trajectoryIndex) async {
    try {
      // アニメーション状態を設定
      setState(() {
        _isSlideshowPlaying = true; // 他のタップを無効にするため
_currentTrajectoryIndex = trajectoryIndex;
        _isShowingMap = false;
        _isMapAligned = false;
        // 対象軌跡を赤色にハイライト
        _trajectoryColors[trajectoryIndex] = Colors.red;
        // キャッシュをクリア
        _cachedCameraPosition = null;
        _alignedCameraPosition = null;
      });

      // ハイライトアニメーション（固定速度）
      _highlightController.duration = _highlightDuration;
      _highlightController.reset();
      await _highlightController.forward();

      // 地図データを準備
      await _prepareMapData(trajectoryIndex);

      // 地図アニメーションを表示（固定速度）
      await _showMapAnimationFixed();

      // 軌跡の色を元に戻す
      setState(() {
        _trajectoryColors[trajectoryIndex] =
            Colors.blue;
        _isSlideshowPlaying = false; // アニメーション終了
_currentTrajectoryIndex = -1;
        _isShowingMap = false;
      });
    } catch (e) {
      setState(() {
        _isSlideshowPlaying = false;
        _currentTrajectoryIndex = -1;
        _isShowingMap = false;
        if (trajectoryIndex < _trajectoryColors.length) {
          _trajectoryColors[trajectoryIndex] =
              Colors.blue;
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("アニメーションエラーが発生しました: $e")),
      );
    }
  }

  // 作品のスライドショーを再生できる共有リンクを生成し、OS の共有シートを開く
  Future<void> _shareArtwork() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final result = await ArtworkShareService().shareArtwork(widget.artwork);
      if (!mounted) return;

      // iPad では共有シートの表示位置が必要
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : null;

      await SharePlus.instance.share(
        ShareParams(
          text: result.shareText,
          subject: '「${result.artworkName}」- GPStroke',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      print("❌ 作品の共有リンク生成に失敗: $e");
      if (!mounted) return;
      final message = e is FirebaseException && e.code == 'permission-denied'
          ? '共有データの保存が許可されていません。Firestore のセキュリティルール（firestore.rules）が反映されているか確認してください。'
          : '共有リンクの生成に失敗しました: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  void _startSlideshow() async {
    if (_trajectories.isEmpty || _playOrder.isEmpty) return;

    _slideshowRun++;
    setState(() {
      _isSlideshowPlaying = true;
_currentTrajectoryIndex = -1;
      _isShowingMap = false;
      _isMapAligned = false;
    });

    _showNextTrajectory();
  }

  void _stopSlideshow() {
    _slideshowRun++;
    setState(() {
      _isSlideshowPlaying = false;
_currentTrajectoryIndex = -1;
      _isShowingMap = false;
      _isMapAligned = false;
      _cachedCameraPosition = null;
      _alignedCameraPosition = null;
      // 記録日時・歩数・距離の表示を再生前の状態（非表示）に戻す
      _currentTrajectoryDetails = null;
      _mapPolylines = {};
    });

    _highlightController.reset();
    _mapTransitionController.reset();
    _mapAlignmentController.reset();

    setState(() {
      _trajectoryColors = List.generate(
        _trajectories.length,
        (_) => Colors.blue,
      );
    });
  }

  // 一時停止（共有ページと同様、現在のストロークのハイライトは残す）。
  // 地図を表示していたときは、地図と記録カードも表示したまま止める
  void _pauseSlideshow() {
    _slideshowRun++;
    _highlightController.stop();
    _mapTransitionController.stop();
    _mapAlignmentController.stop();

    final bool keepMap = _isShowingMap && _currentTrajectoryDetails != null;
    if (keepMap) {
      // フェードや整列の途中で止めた場合も、地図と記録カードをはっきり表示する
      _mapTransitionController.value = 1.0;
      _mapAlignmentController.value = 1.0;
    }

    setState(() {
      _isSlideshowPlaying = false;
      if (!keepMap) {
        _isShowingMap = false;
        _isMapAligned = false;
        _cachedCameraPosition = null;
        _alignedCameraPosition = null;
      }
    });
  }

  // 地図を表示したまま一時停止しているか
  bool get _isPausedOnMap =>
      !_isSlideshowPlaying &&
      _isShowingMap &&
      _currentTrajectoryIndex >= 0 &&
      _currentTrajectoryIndex < _playOrder.length;

  // 最後まで再生し終えて止まっているか
  bool get _hasFinished =>
      _playOrder.isNotEmpty && _currentTrajectoryIndex >= _playOrder.length;

  // 再生／一時停止ボタン
  void _togglePlayback() {
    if (_isSlideshowPlaying) {
      _pauseSlideshow();
    } else if (_isPausedOnMap) {
      // 地図の表示から続ける
      _resumeFromMap();
    } else if (_currentTrajectoryIndex >= 0 && !_hasFinished) {
      // 現在のストロークから再開する
      _seekToTrajectory(_currentTrajectoryIndex);
    } else {
      // 再生前、または最後まで再生した後は先頭から
      _startSlideshow();
    }
  }

  // 地図を表示したまま一時停止していた場合の再開。
  // 地図をもう一度表示時間ぶん見せてから、次のストロークへ進む
  void _resumeFromMap() async {
    _slideshowRun++;
    final int run = _slideshowRun;
    bool alive() => mounted && run == _slideshowRun && _isSlideshowPlaying;
    final int actualTrajectoryIndex = _playOrder[_currentTrajectoryIndex];

    setState(() => _isSlideshowPlaying = true);

    await Future.delayed(_getScaledDuration(_mapDisplayDuration));
    if (!alive()) return;

    await _finishStroke(actualTrajectoryIndex, alive);
  }

  // 前のストロークへ（先頭では先頭のまま）
  void _showPrevStroke() {
    _seekToTrajectory(
        (_currentTrajectoryIndex - 1).clamp(0, _playOrder.length - 1));
  }

  // 次のストロークへ（末尾では先頭に戻る）
  void _showNextStroke() {
    final next = _currentTrajectoryIndex + 1;
    _seekToTrajectory(next >= _playOrder.length ? 0 : next);
  }

  void _seekToTrajectory(int index) {
    if (_playOrder.isEmpty) return;
    index = index.clamp(0, _playOrder.length - 1);

    _slideshowRun++;
    _highlightController.stop();
    _mapTransitionController.stop();
    _mapAlignmentController.stop();

    setState(() {
      _isSlideshowPlaying = true;
      _isShowingMap = false;
      _isMapAligned = false;
      _cachedCameraPosition = null;
      _alignedCameraPosition = null;
      _currentTrajectoryIndex = index - 1;
      _trajectoryColors = List.generate(
        _trajectories.length,
        (_) => Colors.blue,
      );
    });

    _showNextTrajectory();
  }

  // 速度制御メソッド
  void _increaseSpeed() {
    setState(() {
      int currentIndex = _speedOptions.indexOf(_playbackSpeed);
      if (currentIndex < _speedOptions.length - 1) {
        _playbackSpeed = _speedOptions[currentIndex + 1];
      } else {
        _playbackSpeed = 1; // 3倍速の次は1倍速に戻る
      }
    });
  }

  // 速度に応じたDurationを計算
  Duration _getScaledDuration(Duration baseDuration) {
    if (_playbackSpeed == 0) return baseDuration;
    double speedMultiplier = _playbackSpeed.abs().toDouble();
    return Duration(
        milliseconds: (baseDuration.inMilliseconds / speedMultiplier).round());
  }

  // 速度表示のテキストを取得
  String _getSpeedText() => '$_playbackSpeed倍速';

  // Web Mercator対応の地図データ準備
  Future<void> _prepareMapData(int actualTrajectoryIndex) async {
    TransformablePolyline trajectory = _trajectories[actualTrajectoryIndex];

    // メタデータから直接groupIdを取得（保存時と同じgroupIdを使用）
    String groupId = '';
    if (actualTrajectoryIndex < _trajectoryMetadata.length &&
        _trajectoryMetadata[actualTrajectoryIndex].containsKey('groupId')) {
      groupId = _trajectoryMetadata[actualTrajectoryIndex]['groupId'];
    } else {
      // フォールバック: メタデータがない場合は計算（古い形式のファイル対応）
      groupId = generateGroupId(trajectory.polyline);
    }

    try {
      // 地図に出す座標と記録（歩数・距離）は、保存されている軌跡から読む。
      // 見つからない場合は、作品にコピーされている座標とメタデータを使う
      final stored = await TrajectoryStore.get(groupId);
      if (stored == null) {
        print("軌跡が見つからないため、作品にコピーされている座標を使います: $groupId");
      }
      final List<Position> points = stored?.points ?? trajectory.polyline;
      if (points.isEmpty) {
        print("位置情報が見つかりません: $groupId");
        return;
      }

      final metadata = actualTrajectoryIndex < _trajectoryMetadata.length
          ? _trajectoryMetadata[actualTrajectoryIndex]
          : const <String, dynamic>{};
      final String actualGroupId = groupId;
      // 記録日時は先頭座標の時刻
      final String actualRecordDate =
          points.first.timestamp.toUtc().toIso8601String();
      final Map<String, dynamic> recordData = {
        'steps': stored?.steps ?? metadata['steps'],
        'distance': stored?.distanceKm ?? metadata['distance'],
      };

      List<LatLng> polylinePoints =
          points.map((p) => LatLng(p.latitude, p.longitude)).toList();

      // 地理的境界を計算
      double minLat = polylinePoints.map((p) => p.latitude).reduce(math.min);
      double maxLat = polylinePoints.map((p) => p.latitude).reduce(math.max);
      double minLng = polylinePoints.map((p) => p.longitude).reduce(math.min);
      double maxLng = polylinePoints.map((p) => p.longitude).reduce(math.max);

      double centerLat = (minLat + maxLat) / 2;
      double centerLng = (minLng + maxLng) / 2;
      LatLng center = LatLng(centerLat, centerLng);

      // 軌跡のポリラインの太さは固定
      double baseLineWidth = 4.0;

      Set<Polyline> polylines = {
        Polyline(
          polylineId: PolylineId('route_$actualTrajectoryIndex'),
          points: polylinePoints,
          color: Colors.red.withOpacity(0.4), // 透明度を0.9から0.4に変更してより薄く
          width: baseLineWidth.round(),
        )
      };

      setState(() {
        _mapCenter = center;
        _mapPolylines = polylines;

        _currentTrajectoryDetails = {
          'groupId': actualGroupId,
          'date': actualRecordDate,
          'steps': recordData['steps'],
          'distance': recordData['distance'],
          'polylinePoints': polylinePoints,
          'trajectory': trajectory,
          'actualTrajectoryIndex': actualTrajectoryIndex,
          'geoCenter': center,
          'minLat': minLat,
          'maxLat': maxLat,
          'minLng': minLng,
          'maxLng': maxLng,
        };

        if (_debugMode) {
          print('=== 軌跡詳細データ設定完了 ===');
          print('軌跡グループID: $actualGroupId');
          print('軌跡インデックス: $actualTrajectoryIndex');
          print('使用中の記録日時: $actualRecordDate');
          print('歩数: ${recordData['steps']}, 距離: ${recordData['distance']}');
          print('地理的境界: lat($minLat, $maxLat), lng($minLng, $maxLng)');
        }
      });

      // Web Mercator対応の地図整列計算
      _calculateWebMercatorMapAlignment(trajectory, actualTrajectoryIndex);
    } catch (e) {
      print("マップデータの準備中にエラー: $e");
    }
  }

  // 完全Web Mercator地図整列計算（絶対座標系統一版）
  void _calculateWebMercatorMapAlignment(
      TransformablePolyline trajectory, int trajectoryIndex) {
    if (_currentTrajectoryDetails == null) return;

    final mediaQuery = MediaQuery.of(context);
    // 注意: Scaffold の body（地図・軌跡を描画している Stack）は SafeArea で
    // 下端を避けていないため、実際の描画領域は画面下部のセーフエリア
    // （ホームインジケーター等、iOSでは約34pt）まで広がる。ここで
    // padding.bottom を差し引いてしまうと、画面中心とみなす位置が実際の
    // 描画領域の中心よりも上にずれてしまい、地図とオーバーレイの間に
    // padding.bottom / 2 分の一定の縦方向のズレが生じる
    // （iOSで平均誤差17px前後として観測されたのがこれ。Androidは
    // padding.bottom がほぼ0のため顕在化しなかった）。
    double currentBodyHeight = mediaQuery.size.height -
        mediaQuery.padding.top -
        AppBar().preferredSize.height;
    double currentBodyWidth = mediaQuery.size.width;

    // === 1. 基本情報の取得 ===
    double minLat = _currentTrajectoryDetails!['minLat'];
    double maxLat = _currentTrajectoryDetails!['maxLat'];
    double minLng = _currentTrajectoryDetails!['minLng'];
    double maxLng = _currentTrajectoryDetails!['maxLng'];

    // === 2. 始点基準の整列方式（高精度版） ===
    // 軌跡の始点を基準点として使用
    if (trajectory.polyline.isEmpty) return;
    Position startPoint = trajectory.polyline.first;
    double startPointLat = startPoint.latitude;
    double startPointLng = startPoint.longitude;

    // === 3. 描画パラメータの取得 ===
    final painter = PolylinePainter(
      positions: trajectory.polyline,
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLng,
      maxLon: maxLng,
      color: Colors.blue,
      preserveAspectRatio: true,
      strokeWidth: 4.0,
    );

    final drawingParams =
        painter.getDrawingParameters(Size(trajectorySize, trajectorySize));

    // === 4. 統一座標変換関数の定義 ===
    Offset transformPointToOverlayScreen(double lat, double lng) {
      // A) 地理座標 → Web Mercator
      double mercatorX = PolylinePainter.longitudeToWebMercatorX(lng);
      double mercatorY = PolylinePainter.latitudeToWebMercatorY(lat);

      // B) Web Mercator → 正規化座標
      double minMercatorX = drawingParams['minMercatorX'];
      double maxMercatorX = drawingParams['maxMercatorX'];
      double minMercatorY = drawingParams['minMercatorY'];
      double maxMercatorY = drawingParams['maxMercatorY'];
      double mercatorXRange = maxMercatorX - minMercatorX;
      double mercatorYRange = maxMercatorY - minMercatorY;

      double normalizedX = (mercatorX - minMercatorX) / mercatorXRange;
      double normalizedY = (mercatorY - minMercatorY) / mercatorYRange;

      // C) 正規化座標 → 基本ピクセル座標（コンテナ内）
      double scaleX = drawingParams['scaleX'];
      double scaleY = drawingParams['scaleY'];
      double drawingOffsetX = drawingParams['drawingOffsetX'];
      double drawingOffsetY = drawingParams['drawingOffsetY'];

      double basePixelX = normalizedX * scaleX + drawingOffsetX;
      double basePixelY =
          trajectorySize - (normalizedY * scaleY + drawingOffsetY);

      // D) スケール適用（コンテナ中心基準）
      double containerCenterX = trajectorySize / 2;
      double containerCenterY = trajectorySize / 2;
      double relativeX = basePixelX - containerCenterX;
      double relativeY = basePixelY - containerCenterY;
      double scaledRelativeX = relativeX * trajectory.scale;
      double scaledRelativeY = relativeY * trajectory.scale;

      // E) 回転適用（コンテナ中心基準）
      double rotatedRelativeX, rotatedRelativeY;
      if (trajectory.rotation != 0.0) {
        double cosAngle = math.cos(trajectory.rotation);
        double sinAngle = math.sin(trajectory.rotation);
        rotatedRelativeX =
            scaledRelativeX * cosAngle - scaledRelativeY * sinAngle;
        rotatedRelativeY =
            scaledRelativeX * sinAngle + scaledRelativeY * cosAngle;
      } else {
        rotatedRelativeX = scaledRelativeX;
        rotatedRelativeY = scaledRelativeY;
      }

      // F) 最終画面座標
      // trajectory.position はコンテナの中心座標を表すため、
      // コンテナ中心からの相対座標（rotatedRelativeX/Y）を加算するだけでよい
      double screenX = trajectory.position.dx + rotatedRelativeX;
      double screenY = trajectory.position.dy + rotatedRelativeY;

      return Offset(screenX, screenY);
    }

    // transformPointToOverlayScreen の逆変換：画面座標 → 地理座標
    // （軌跡はキャンバス上で自由に移動・拡大縮小・回転されるため、始点が
    //   画面中心に描画されるとは限らない。そのため「画面中心に描画される
    //   地理座標」を逆算し、それを地図中心にすることで地図と重ねる）
    LatLng inverseTransformScreenToLatLng(double screenX, double screenY) {
      double minMercatorX = drawingParams['minMercatorX'];
      double maxMercatorX = drawingParams['maxMercatorX'];
      double minMercatorY = drawingParams['minMercatorY'];
      double maxMercatorY = drawingParams['maxMercatorY'];
      double mercatorXRange = maxMercatorX - minMercatorX;
      double mercatorYRange = maxMercatorY - minMercatorY;

      double scaleX = drawingParams['scaleX'];
      double scaleY = drawingParams['scaleY'];
      double drawingOffsetX = drawingParams['drawingOffsetX'];
      double drawingOffsetY = drawingParams['drawingOffsetY'];

      // F) の逆変換
      double rotatedRelativeX = screenX - trajectory.position.dx;
      double rotatedRelativeY = screenY - trajectory.position.dy;

      // E) の逆変換（回転行列の逆＝転置を適用）
      double scaledRelativeX, scaledRelativeY;
      if (trajectory.rotation != 0.0) {
        double cosAngle = math.cos(trajectory.rotation);
        double sinAngle = math.sin(trajectory.rotation);
        scaledRelativeX =
            rotatedRelativeX * cosAngle + rotatedRelativeY * sinAngle;
        scaledRelativeY =
            -rotatedRelativeX * sinAngle + rotatedRelativeY * cosAngle;
      } else {
        scaledRelativeX = rotatedRelativeX;
        scaledRelativeY = rotatedRelativeY;
      }

      // D) の逆変換
      double relativeX = scaledRelativeX / trajectory.scale;
      double relativeY = scaledRelativeY / trajectory.scale;

      // C) の逆変換
      double containerCenterX = trajectorySize / 2;
      double containerCenterY = trajectorySize / 2;
      double basePixelX = relativeX + containerCenterX;
      double basePixelY = relativeY + containerCenterY;

      // B) の逆変換
      double normalizedX = (basePixelX - drawingOffsetX) / scaleX;
      double normalizedY =
          (trajectorySize - basePixelY - drawingOffsetY) / scaleY;

      double mercatorX = normalizedX * mercatorXRange + minMercatorX;
      double mercatorY = normalizedY * mercatorYRange + minMercatorY;

      // A) の逆変換
      double lat = PolylinePainter.webMercatorYToLatitude(mercatorY);
      double lng = PolylinePainter.webMercatorXToLongitude(mercatorX);

      return LatLng(lat, lng);
    }

    // === 5. オーバーレイの始点位置を正確に計算 ===
    Offset overlayStartPointScreen =
        transformPointToOverlayScreen(startPointLat, startPointLng);

    // === 6. 地図の適切な設定計算 ===
    // A) ズームレベルの計算（地理的範囲から）
    double latRange = maxLat - minLat;
    double lngRange = maxLng - minLng;

    // 軌跡の実際の描画サイズ（変形適用後）
    double actualDrawingWidth = drawingParams['scaleX'] * trajectory.scale;
    double actualDrawingHeight = drawingParams['scaleY'] * trajectory.scale;

    // より安定したズーム計算
    double pixelsPerDegreeLat = actualDrawingHeight / latRange;
    double pixelsPerDegreeLng = actualDrawingWidth / lngRange;
    double pixelsPerDegree = math.min(pixelsPerDegreeLat, pixelsPerDegreeLng);

    // 経験的なズームレベル計算（Google Maps基準）
    double zoom = math.log(pixelsPerDegree * 360 / 256) / math.log(2);
    zoom = zoom.clamp(10.0, 19.0);

    // B) 地図中心の計算
    // オーバーレイは始点が画面中心に描画されるとは限らない（キャンバス上で
    // 自由に配置・拡大縮小・回転されるため）。「画面中心に描画される地理座標」を
    // オーバーレイ変換の逆算で求め、それを地図中心にすることで、地図とオーバーレイの
    // 道路が正しく重なるようにする。
    double screenCenterX = currentBodyWidth / 2;
    double screenCenterY = currentBodyHeight / 2;

    LatLng mapCenterLatLng =
        inverseTransformScreenToLatLng(screenCenterX, screenCenterY);
    double mapCenterLat = mapCenterLatLng.latitude;
    double mapCenterLng = mapCenterLatLng.longitude;

    // C) 回転角度の設定
    double bearing = 0.0;
    if (trajectory.rotation != 0.0) {
      bearing = -(trajectory.rotation * 180 / math.pi); // ラジアン→度、方向反転
      bearing = bearing % 360;
      if (bearing < 0) bearing += 360;
    }

    // === 7. 最終的な地図カメラ位置 ===
    _alignedCameraPosition = CameraPosition(
      target: LatLng(mapCenterLat, mapCenterLng),
      zoom: zoom,
      bearing: bearing,
      tilt: 0,
    );

    if (_debugMode) {
      print('=== 始点基準による精密地図整列計算 ===');
      print('軌跡インデックス: $trajectoryIndex');
      print('軌跡コンテナ位置: (${trajectory.position.dx}, ${trajectory.position.dy})');
      print(
          '軌跡変形: スケール=${trajectory.scale}, 回転=${trajectory.rotation} rad (${trajectory.rotation * 180 / math.pi}°)');
      print('--- 始点基準 ---');
      print(
          '軌跡始点（地理座標）: (${startPointLat.toStringAsFixed(8)}, ${startPointLng.toStringAsFixed(8)})');
      print(
          'オーバーレイ始点画面座標: (${overlayStartPointScreen.dx.toStringAsFixed(1)}, ${overlayStartPointScreen.dy.toStringAsFixed(1)})');
      print('--- オーバーレイ描画 ---');
      print('基本描画サイズ: ${drawingParams['scaleX']} x ${drawingParams['scaleY']}');
      print('実際の描画サイズ: ${actualDrawingWidth} x ${actualDrawingHeight}');
      print('--- 地図設定 ---');
      print(
          '地理的範囲: 緯度=${latRange.toStringAsFixed(6)}°, 経度=${lngRange.toStringAsFixed(6)}°');
      print('ピクセル密度: ${pixelsPerDegree.toStringAsFixed(2)} px/degree');
      print('ズームレベル: ${zoom.toStringAsFixed(2)}');
      print('画面中心: (${screenCenterX}, ${screenCenterY})');
      print('画面中心に描画される地理座標を逆算して地図中心に設定');
      print(
          '最終地図中心: (${mapCenterLat.toStringAsFixed(8)}, ${mapCenterLng.toStringAsFixed(8)})');
      print('地図回転: ${bearing.toStringAsFixed(1)}°');
    }
  }

  // 個別軌跡用の地図表示アニメーション（固定速度）
  Future<void> _showMapAnimationFixed() async {
    setState(() {
      _isShowingMap = true;
      _isMapAligned = false;
    });

    // 地図の初期化待機（固定速度）
    await Future.delayed(Duration(milliseconds: 300));

    // フェードイン（固定速度）
    _mapTransitionController.duration = _mapTransitionDuration;
    _mapTransitionController.reset();
    await _mapTransitionController.forward();

    // 地図を精密に整列（固定速度）
    await Future.delayed(Duration(milliseconds: 200));
    await _alignMapPreciselyFixed();

    // 整列表示時間（固定速度）
    await Future.delayed(_mapDisplayDuration);

    // フェードアウト（固定速度）
    _mapTransitionController.duration = _mapTransitionDuration;
    await _mapTransitionController.reverse();

    setState(() {
      _isShowingMap = false;
      _isMapAligned = false;
    });
  }

  // 地図表示アニメーション（フェードイン → 整列 → 表示時間だけ待つ）。
  // 一時停止・シークで [alive] が false になったら、そこで止める
  // （止めた後に地図を消したり、次の再生の地図を操作したりしないため）
  Future<void> _showMapAnimation(bool Function() alive) async {
    // 一時停止で不透明のまま残した値で、新しい地図が一瞬見えないよう先に巻き戻す
    _mapTransitionController.reset();
    setState(() {
      _isShowingMap = true;
      _isMapAligned = false;
    });

    // 地図の初期化待機（速度適用）
    await Future.delayed(_getScaledDuration(Duration(milliseconds: 300)));
    if (!alive()) return;

    // フェードイン（速度調整）
    _mapTransitionController.duration =
        _getScaledDuration(_mapTransitionDuration);
    await _mapTransitionController.forward();
    if (!alive()) return;

    // 地図を精密に整列（速度適用）
    await Future.delayed(_getScaledDuration(Duration(milliseconds: 200)));
    if (!alive()) return;
    await _alignMapPrecisely();
    if (!alive()) return;

    // 整列表示時間（速度適用）
    await Future.delayed(_getScaledDuration(_mapDisplayDuration));
  }

  // 地図をフェードアウトして閉じる
  Future<void> _hideMapAnimation(bool Function() alive) async {
    _mapTransitionController.duration =
        _getScaledDuration(_mapTransitionDuration);
    await _mapTransitionController.reverse();
    if (!alive()) return;

    setState(() {
      _isShowingMap = false;
      _isMapAligned = false;
    });
  }

  // 精密地図整列の実行
  Future<void> _alignMapPrecisely() async {
    if (_mapController == null || _alignedCameraPosition == null) return;

    setState(() {
      _isMapAligned = true;
    });

    // 地図の整列アニメーション（速度調整）
    _mapAlignmentController.duration =
        _getScaledDuration(_mapAlignmentDuration);
    _mapAlignmentController.reset();
    await _mapAlignmentController.forward();

    // カメラを精密位置に移動（速度調整されたアニメーション）
    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(_alignedCameraPosition!),
    );

    // 整列完了の待機時間（速度調整）
    await Future.delayed(_getScaledDuration(Duration(milliseconds: 200)));

    // 座標比較・検証を実行（デバッグ用ログ出力のみ。カメラは動かさない）
    if (_currentTrajectoryDetails != null) {
      int trajectoryIndex =
          _currentTrajectoryDetails!['actualTrajectoryIndex'] ?? 0;
      await _validateTrajectoryAlignment(trajectoryIndex);
      await _autoCorrectOverlayPosition(trajectoryIndex);
    }
  }

  // 個別軌跡用の精密地図整列の実行（固定速度）
  Future<void> _alignMapPreciselyFixed() async {
    if (_mapController == null || _alignedCameraPosition == null) return;

    setState(() {
      _isMapAligned = true;
    });

    // 地図の整列アニメーション（固定速度）
    _mapAlignmentController.duration = _mapAlignmentDuration;
    _mapAlignmentController.reset();
    await _mapAlignmentController.forward();

    // カメラを精密位置に移動
    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(_alignedCameraPosition!),
    );

    // 整列完了の待機時間（固定速度）
    await Future.delayed(Duration(milliseconds: 200));

    // 座標比較・検証を実行（デバッグ用ログ出力のみ。カメラは動かさない）
    if (_currentTrajectoryDetails != null) {
      int trajectoryIndex =
          _currentTrajectoryDetails!['actualTrajectoryIndex'] ?? 0;
      await _validateTrajectoryAlignment(trajectoryIndex);
      await _autoCorrectOverlayPosition(trajectoryIndex);
    }
  }

  // 次の軌跡を表示
  void _showNextTrajectory() async {
    if (!_isSlideshowPlaying) return;
    final int run = _slideshowRun;
    bool alive() => mounted && run == _slideshowRun && _isSlideshowPlaying;

    int nextStepIndex = _currentTrajectoryIndex + 1;

    if (nextStepIndex >= _playOrder.length) {
      // すべて再生し終えたら、作品全体を表示したまま止める（ループしない）。
      // 位置を末尾の次にしておくと、「一つずつ出現」でも全軌跡が表示されたままになり、
      // 進行バーもすべて再生済みになる。再生ボタンを押すと先頭から再生する
      setState(() {
        _isSlideshowPlaying = false;
        _currentTrajectoryIndex = _playOrder.length;
        _currentTrajectoryDetails = null;
        _trajectoryColors = List.generate(
          _trajectories.length,
          (_) => Colors.blue,
        );
      });
      return;
    }

    // 「一つずつ出現」は、何も描かれていないキャンバスを一瞬見せてから始める
    if (nextStepIndex == 0 && _slideshowStyle == SlideshowStyle.reveal) {
      await Future.delayed(_getScaledDuration(_transitionDuration));
      if (!alive()) return;
    }

    // 実際の軌跡インデックス（選択中の再生順に従う）
    int actualTrajectoryIndex = _playOrder[nextStepIndex];

    // 出現する軌跡が前の軌跡のアニメーション終了状態（不透明）で
    // 一瞬描かれないよう、表示を切り替える前に巻き戻しておく
    _highlightController.duration = _getScaledDuration(_highlightDuration);
    _highlightController.reset();

    setState(() {
      _currentTrajectoryIndex = nextStepIndex;
      // ハイライトする軌跡を赤色に変更
      _trajectoryColors[actualTrajectoryIndex] = Colors.red;
      // 新しい軌跡に変わったのでキャッシュをクリア
      _cachedCameraPosition = null;
      _alignedCameraPosition = null;
    });

    // ハイライトアニメーション（速度調整）
    await _highlightController.forward();
    if (!alive()) return;

    // 地図データを準備
    await _prepareMapData(actualTrajectoryIndex);
    if (!alive()) return;

    // 地図アニメーションを表示
    await _showMapAnimation(alive);
    if (!alive()) return;

    await _finishStroke(actualTrajectoryIndex, alive);
  }

  // 地図を閉じて軌跡の色を戻し、次の軌跡へ進む
  Future<void> _finishStroke(
      int actualTrajectoryIndex, bool Function() alive) async {
    await _hideMapAnimation(alive);
    if (!alive()) return;

    // 軌跡の色を元に戻す
    setState(() {
      _trajectoryColors[actualTrajectoryIndex] = Colors.blue;
    });

    // 速度に応じた次の軌跡への遷移の待機
    await Future.delayed(_getScaledDuration(_transitionDuration));
    if (!alive()) return;

    _showNextTrajectory();
  }

  // 現在のカメラ位置をキャッシュ
  CameraPosition? _cachedCameraPosition;

  // 現在のカメラ位置を計算するメソッド
  CameraPosition _getCurrentCameraPosition() {
    if (_currentTrajectoryDetails == null || _currentTrajectoryIndex < 0) {
      return CameraPosition(target: _mapCenter, zoom: 16.0);
    }

    // 整列用カメラ位置が計算済みの場合はそれを使用
    if (_alignedCameraPosition != null) {
      return _alignedCameraPosition!;
    }

    // キャッシュが存在し、同じ軌跡の場合はキャッシュを返す
    if (_cachedCameraPosition != null) {
      return _cachedCameraPosition!;
    }

    // 基本的なカメラ位置を返す
    double geoCenterLat = (_currentTrajectoryDetails!['minLat'] +
            _currentTrajectoryDetails!['maxLat']) /
        2;
    double geoCenterLng = (_currentTrajectoryDetails!['minLng'] +
            _currentTrajectoryDetails!['maxLng']) /
        2;

    _cachedCameraPosition = CameraPosition(
      target: LatLng(geoCenterLat, geoCenterLng),
      zoom: 16.0,
      bearing: 0,
      tilt: 0,
    );

    return _cachedCameraPosition!;
  }

  // Android の GoogleMapController.getScreenCoordinate / getLatLng はネイティブ側で
  // 物理ピクセル基準の座標を扱う（google_maps_flutter_android が dp→px 変換を行わないため）。
  // 一方 Flutter 側のオーバーレイ座標（trajectory.position 等）は論理ピクセル(dp)であり、
  // iOS は逆に論理ピクセル基準で動作するため変換不要。
  double get _mapPixelRatio => defaultTargetPlatform == TargetPlatform.android
      ? MediaQuery.of(context).devicePixelRatio
      : 1.0;

  // ネイティブから得たScreenCoordinate（Android=物理px, iOS=論理px）を
  // Flutterのオーバーレイ座標系（論理px）に変換
  Offset _toLogicalOffset(ScreenCoordinate coordinate) {
    final ratio = _mapPixelRatio;
    return Offset(coordinate.x / ratio, coordinate.y / ratio);
  }

  void _onMapCreated(GoogleMapController controller) async {
    _mapController = controller;

    // 地図の準備が完了したら、カメラ位置を更新
    if (_currentTrajectoryDetails != null && _currentTrajectoryIndex >= 0) {
      // 地図の初期化をより確実に待つ
      await Future.delayed(Duration(milliseconds: 300));

      // 初期位置設定
      CameraPosition initialPosition = _getCurrentCameraPosition();
      await _mapController?.moveCamera(
        CameraUpdate.newCameraPosition(initialPosition),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _artworkName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            if (_artworkSummary.isNotEmpty)
              Text(
                _artworkSummary,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (_trajectories.isNotEmpty)
            IconButton(
              icon: _isSharing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              tooltip: '作品を共有',
              onPressed: _isSharing ? null : _shareArtwork,
            ),
          if (_trajectories.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.animation),
              tooltip: 'スライドショー',
              onPressed: () {
                setState(() =>
                    _isControlPanelVisible = !_isControlPanelVisible);
                if (_isControlPanelVisible) {
                  if (!_isSlideshowPlaying) _startSlideshow();
                } else {
                  // 再生 UI を閉じたらスライドショーを終了して作品全体の表示に戻す
                  _stopSlideshow();
                }
              },
            ),
        ],
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.grey[200],
        child: Stack(
          children: [
            // 背景地図表示（Web Mercator対応版）
            if (_isShowingMap && _currentTrajectoryDetails != null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: Listenable.merge([
                    _mapTransitionController,
                    _mapAlignmentController,
                  ]),
                  builder: (context, child) {
                    // より自然なアニメーション計算
                    double opacity = _mapTransitionController.value * 0.85;

                    // 地図整列の微細なスケールエフェクト
                    double scale = 1.0;
                    if (_isMapAligned) {
                      // より滑らかなスケールアニメーション
                      double progress = Curves.easeOutCubic
                          .transform(_mapAlignmentController.value);
                      scale = 0.98 + (progress * 0.02);
                    }

                    return ClipRect(
                      child: Transform.scale(
                        scale: scale,
                        child: Opacity(
                          opacity: opacity,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    key: ValueKey(
                        'map_${_currentTrajectoryIndex}_${_currentTrajectoryDetails?['groupId']}'),
                    child: GoogleMap(
                      initialCameraPosition: _getCurrentCameraPosition(),
                      onMapCreated: _onMapCreated,
                      polylines: _mapPolylines,
                      myLocationEnabled: false,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      compassEnabled: false,
                      rotateGesturesEnabled: false,
                      scrollGesturesEnabled: false,
                      zoomGesturesEnabled: false,
                      tiltGesturesEnabled: false,
                      liteModeEnabled: false,
                      mapType: MapType.normal,
                    ),
                  ),
                ),
              ),

            // 軌跡の表示（Web Mercator対応版）
            ..._trajectories.asMap().entries.map((entry) {
              int index = entry.key;
              TransformablePolyline item = entry.value;

              // 再生順での位置（スライドショー中のみ意味を持つ）
              final int playPosition = _playOrder.indexOf(index);

              // 「一つずつ出現」では、まだ順番が来ていない軌跡を描かない
              if (_isRevealing &&
                  (playPosition < 0 ||
                      playPosition > _currentTrajectoryIndex)) {
                return const SizedBox.shrink();
              }

              // ハイライト効果
              bool isCurrentlyHighlighted = _isSlideshowPlaying &&
                  _currentTrajectoryIndex >= 0 &&
                  (_isControlPanelVisible
                      // スライドショーの場合
                      ? playPosition == _currentTrajectoryIndex
                      // 個別軌跡アニメーションの場合
                      : _currentTrajectoryIndex == index);

              // 「一つずつ出現」で今まさに現れる軌跡はフェードインさせる
              final bool isAppearing = _isRevealing &&
                  _isSlideshowPlaying &&
                  playPosition == _currentTrajectoryIndex;

              // ハイライト中も大きさは変えない（赤色と線の太さだけで示す）。
              // 大きさを変えると、元の大きさで位置合わせした地図上のルートと
              // 軌跡がずれてしまう
              Widget stroke = Transform.rotate(
                angle: item.rotation,
                alignment: Alignment.center,
                child: Transform.scale(
                  scale: item.scale,
                  alignment: Alignment.center,
                  child: CustomPaint(
                    size: Size(trajectorySize, trajectorySize),
                    painter: PolylinePainter(
                      positions: item.polyline,
                      minLat: item.minLat,
                      maxLat: item.maxLat,
                      minLon: item.minLon,
                      maxLon: item.maxLon,
                      color: _trajectoryColors[index],
                      preserveAspectRatio: true,
                      strokeWidth:
                          (isCurrentlyHighlighted ? 5.0 : 4.0) / item.scale,
                    ),
                  ),
                ),
              );

              if (isAppearing) {
                // ハイライト時間の前半で、少し縮んだ状態から浮かび上がる
                stroke = AnimatedBuilder(
                  animation: _highlightController,
                  builder: (context, child) {
                    final double t = Curves.easeOutCubic.transform(
                        (_highlightController.value / 0.6).clamp(0.0, 1.0));
                    return Opacity(
                      opacity: t,
                      child: Transform.scale(
                        scale: 0.92 + 0.08 * t,
                        child: child,
                      ),
                    );
                  },
                  child: stroke,
                );
              }

              return Positioned(
                left: item.position.dx - trajectorySize / 2,
                top: item.position.dy - trajectorySize / 2,
                child: GestureDetector(
                  // スライドショーの再生 UI を開いている間は個別再生しない
                  onTap: _isSlideshowPlaying || _isControlPanelVisible
                      ? null
                      : () => _showTrajectoryDetails(item),
                  child: SizedBox(
                    width: trajectorySize,
                    height: trajectorySize,
                    child: stroke,
                  ),
                ),
              );
            }).toList(),

            // 記録日時・歩数・距離カードと再生コントロール（共有ページと同じ UI）
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isShowingMap && _currentTrajectoryDetails != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: _buildInfoCard(),
                    ),
                  if (_trajectories.isNotEmpty && _isControlPanelVisible)
                    _buildControlPanel(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const TextStyle _infoTextStyle =
      TextStyle(color: Colors.white70, fontSize: 12);

  // 記録日時・歩数・距離カード（共有ページの info-card と同じ見た目）
  Widget _buildInfoCard() {
    final details = _currentTrajectoryDetails!;
    final int steps = (details['steps'] as num?)?.round() ?? 0;
    final double distance = (details['distance'] as num?)?.toDouble() ?? 0.0;
    return AnimatedBuilder(
      animation: _mapTransitionController,
      builder: (context, child) => Opacity(
        opacity: _mapTransitionController.value,
        child: child,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.72),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Text(
              _formatDate(details['date']),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.directions_walk,
                    size: 14, color: Color(0xFF64B5F6)),
                const SizedBox(width: 4),
                Text('${NumberFormat('#,###').format(steps)} 歩',
                    style: _infoTextStyle),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.straighten,
                    size: 14, color: Color(0xFF81C784)),
                const SizedBox(width: 4),
                Text('${distance.toStringAsFixed(2)} km',
                    style: _infoTextStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 再生コントロールパネル（共有ページの controls と同じ構成）
  Widget _buildControlPanel() {
    final int strokeCount = _playOrder.length;
    final int current = _currentTrajectoryIndex;
    return Container(
      width: double.infinity,
      color: _panelColor,
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 14 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 進行バー（ストロークごとのセグメント。タップでそのストロークへ移動）
          Row(
            children: List.generate(strokeCount, (i) {
              final Color color = i < current
                  ? Colors.white
                  : i == current
                      ? const Color(0xFFFF5252)
                      : Colors.white.withOpacity(0.22);
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _seekToTrajectory(i),
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: i == 0 ? 0 : 2,
                      right: i == strokeCount - 1 ? 0 : 2,
                      top: 6,
                      bottom: 6,
                    ),
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 4),
          // 狭い画面ではみ出さないよう、ボタン列ごと縮めて収める
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildRoundButton(Icons.chevron_left, _showPrevStroke),
                const SizedBox(width: 6),
                _buildRoundButton(
                  _isSlideshowPlaying ? Icons.pause : Icons.play_arrow,
                  _togglePlayback,
                ),
                const SizedBox(width: 6),
                _buildRoundButton(Icons.chevron_right, _showNextStroke),
                const SizedBox(width: 6),
                SizedBox(
                  width: 56,
                  child: Text(
                    // 最後まで再生した後は「N / N」と表示する
                    '${current < 0 ? '-' : math.min(current + 1, strokeCount)} / $strokeCount',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _buildPillButton(
                    label: _getSpeedText(), onPressed: _increaseSpeed),
                const SizedBox(width: 6),
                // 再生順・再生方法の設定
                _buildRoundButton(Icons.settings, _openSlideshowSettings),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 再生順・再生方法を選ぶシート（再生バーと同じ色・同じ形のボタン）。
  // 選ぶとすぐに反映して先頭から再生し直す。両方まとめて変えられるよう、
  // 選んでもシートは閉じない
  // 再生順・再生方法の設定シート。
  // シートを開いている間は再生を止め、選んだ内容はシートを閉じたときに反映する
  // （選ぶたびに最初から再生し直さないため）
  Future<void> _openSlideshowSettings() async {
    final bool wasPlaying = _isSlideshowPlaying;
    if (wasPlaying) _pauseSlideshow();

    SlideshowOrder order = _slideshowOrder;
    SlideshowStyle style = _slideshowStyle;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.22),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildOptionGroup<SlideshowOrder>(
                    title: '再生順',
                    values: SlideshowOrder.values,
                    selected: order,
                    labelOf: (o) => o.label,
                    onSelected: (o) => setSheetState(() => order = o),
                  ),
                  const SizedBox(height: 18),
                  _buildOptionGroup<SlideshowStyle>(
                    title: '再生方法',
                    values: SlideshowStyle.values,
                    selected: style,
                    labelOf: (st) => st.label,
                    onSelected: (st) => setSheetState(() => style = st),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted) return;

    if (order != _slideshowOrder || style != _slideshowStyle) {
      // 設定が変わったら、新しい設定で最初から再生する
      await _changeSlideshowSettings(order: order, style: style);
    } else if (wasPlaying) {
      // 変わっていなければ、止めたところから続ける
      _togglePlayback();
    }
  }

  // 設定シート内の選択肢の一群（選択中は白地）
  Widget _buildOptionGroup<T>({
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required void Function(T) onSelected,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: values
              .map((v) => _buildPillButton(
                    label: labelOf(v),
                    selected: v == selected,
                    onPressed: () => onSelected(v),
                  ))
              .toList(),
        ),
      ],
    );
  }

  // 再生バーの文字ボタン（速度ボタン・設定シートの選択肢）。selected は白地で示す
  Widget _buildPillButton({
    required String label,
    required VoidCallback onPressed,
    bool selected = false,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected ? _panelColor : Colors.white,
        backgroundColor:
            selected ? Colors.white : Colors.white.withOpacity(0.12),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        minimumSize: const Size(0, 40),
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildRoundButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white.withOpacity(0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  String _formatDate(String? dateString) {
    if (dateString == null) return '不明';
    try {
      DateTime? date = DateTime.tryParse(dateString)?.toLocal();
      if (date != null) {
        return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      }
    } catch (_) {}
    return '不明';
  }

  // 地図上の軌跡座標とオーバーレイ座標を比較・検証する機能
  Future<void> _validateTrajectoryAlignment(int trajectoryIndex) async {
    if (_mapController == null || _currentTrajectoryDetails == null) return;

    TransformablePolyline trajectory = _trajectories[trajectoryIndex];

    if (_debugMode) {
      print('=== 始点基準による地図オーバーレイ座標比較 ===');
      print('軌跡インデックス: $trajectoryIndex');
    }

    // === 統一座標変換関数の定義 ===
    final painter = PolylinePainter(
      positions: trajectory.polyline,
      minLat: trajectory.minLat,
      maxLat: trajectory.maxLat,
      minLon: trajectory.minLon,
      maxLon: trajectory.maxLon,
      color: Colors.blue,
      preserveAspectRatio: true,
      strokeWidth: 4.0,
    );

    final drawingParams =
        painter.getDrawingParameters(Size(trajectorySize, trajectorySize));

    Offset transformPointToOverlayScreen(double lat, double lng) {
      // A) 地理座標 → Web Mercator
      double mercatorX = PolylinePainter.longitudeToWebMercatorX(lng);
      double mercatorY = PolylinePainter.latitudeToWebMercatorY(lat);

      // B) Web Mercator → 正規化座標
      double minMercatorX = drawingParams['minMercatorX'];
      double maxMercatorX = drawingParams['maxMercatorX'];
      double minMercatorY = drawingParams['minMercatorY'];
      double maxMercatorY = drawingParams['maxMercatorY'];
      double mercatorXRange = maxMercatorX - minMercatorX;
      double mercatorYRange = maxMercatorY - minMercatorY;

      double normalizedX = (mercatorX - minMercatorX) / mercatorXRange;
      double normalizedY = (mercatorY - minMercatorY) / mercatorYRange;

      // C) 正規化座標 → 基本ピクセル座標（コンテナ内）
      double scaleX = drawingParams['scaleX'];
      double scaleY = drawingParams['scaleY'];
      double drawingOffsetX = drawingParams['drawingOffsetX'];
      double drawingOffsetY = drawingParams['drawingOffsetY'];

      double basePixelX = normalizedX * scaleX + drawingOffsetX;
      double basePixelY =
          trajectorySize - (normalizedY * scaleY + drawingOffsetY);

      // D) スケール適用（コンテナ中心基準）
      double containerCenterX = trajectorySize / 2;
      double containerCenterY = trajectorySize / 2;
      double relativeX = basePixelX - containerCenterX;
      double relativeY = basePixelY - containerCenterY;
      double scaledRelativeX = relativeX * trajectory.scale;
      double scaledRelativeY = relativeY * trajectory.scale;

      // E) 回転適用（コンテナ中心基準）
      double rotatedRelativeX, rotatedRelativeY;
      if (trajectory.rotation != 0.0) {
        double cosAngle = math.cos(trajectory.rotation);
        double sinAngle = math.sin(trajectory.rotation);
        rotatedRelativeX =
            scaledRelativeX * cosAngle - scaledRelativeY * sinAngle;
        rotatedRelativeY =
            scaledRelativeX * sinAngle + scaledRelativeY * cosAngle;
      } else {
        rotatedRelativeX = scaledRelativeX;
        rotatedRelativeY = scaledRelativeY;
      }

      // F) 最終画面座標
      // trajectory.position はコンテナの中心座標を表すため、
      // コンテナ中心からの相対座標（rotatedRelativeX/Y）を加算するだけでよい
      double screenX = trajectory.position.dx + rotatedRelativeX;
      double screenY = trajectory.position.dy + rotatedRelativeY;

      return Offset(screenX, screenY);
    }

    // === 検証する代表点の選択 ===
    List<Position> samplePoints = [];
    List<String> pointLabels = [];

    // データ重心を追加
    if (trajectory.polyline.isNotEmpty) {
      double totalLat = 0, totalLng = 0;
      for (Position pos in trajectory.polyline) {
        totalLat += pos.latitude;
        totalLng += pos.longitude;
      }
      double centroidLat = totalLat / trajectory.polyline.length;
      double centroidLng = totalLng / trajectory.polyline.length;

      samplePoints.add(Position(
        latitude: centroidLat,
        longitude: centroidLng,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ));
      pointLabels.add('重心');
    }

    // 軌跡の開始点、中間点、終了点も追加
    if (trajectory.polyline.isNotEmpty) {
      samplePoints.add(trajectory.polyline.first);
      pointLabels.add('開始点');

      if (trajectory.polyline.length > 2) {
        samplePoints.add(trajectory.polyline[trajectory.polyline.length ~/ 2]);
        pointLabels.add('中間点');
      }

      samplePoints.add(trajectory.polyline.last);
      pointLabels.add('終了点');
    }

    // === 座標比較の実行 ===
    List<double> mapScreenX = [];
    List<double> mapScreenY = [];
    List<Offset> overlayScreenCoords = [];

    for (int i = 0; i < samplePoints.length; i++) {
      Position point = samplePoints[i];
      LatLng latLng = LatLng(point.latitude, point.longitude);

      // 地図上の画面座標を取得
      try {
        ScreenCoordinate screenCoord =
            await _mapController!.getScreenCoordinate(latLng);
        Offset logicalScreenCoord = _toLogicalOffset(screenCoord);
        mapScreenX.add(logicalScreenCoord.dx);
        mapScreenY.add(logicalScreenCoord.dy);

        if (_debugMode) {
          print(
              '${pointLabels[i]} - 地理座標: (${point.latitude.toStringAsFixed(8)}, ${point.longitude.toStringAsFixed(8)})');
          print(
              '${pointLabels[i]} - 地図スクリーン座標(論理px): (${logicalScreenCoord.dx.toStringAsFixed(1)}, ${logicalScreenCoord.dy.toStringAsFixed(1)})');
        }
      } catch (e) {
        if (_debugMode) {
          print('${pointLabels[i]} - 座標変換エラー: $e');
        }
        mapScreenX.add(0);
        mapScreenY.add(0);
      }

      // 統一座標変換関数でオーバーレイ座標を計算
      Offset overlayCoord =
          transformPointToOverlayScreen(point.latitude, point.longitude);
      overlayScreenCoords.add(overlayCoord);

      if (_debugMode) {
        print(
            '${pointLabels[i]} - オーバーレイ座標: (${overlayCoord.dx.toStringAsFixed(1)}, ${overlayCoord.dy.toStringAsFixed(1)})');
      }
    }

    // === 座標差の計算と表示 ===
    if (_debugMode && mapScreenX.isNotEmpty) {
      print('--- 座標差分析 ---');
      double totalError = 0;
      int validComparisons = 0;

      for (int i = 0; i < samplePoints.length && i < mapScreenX.length; i++) {
        if (mapScreenX[i] != 0 || mapScreenY[i] != 0) {
          double deltaX = mapScreenX[i] - overlayScreenCoords[i].dx;
          double deltaY = mapScreenY[i] - overlayScreenCoords[i].dy;
          double distance = math.sqrt(deltaX * deltaX + deltaY * deltaY);

          print(
              '${pointLabels[i]} - 座標差: (${deltaX.toStringAsFixed(1)}, ${deltaY.toStringAsFixed(1)}) 距離: ${distance.toStringAsFixed(1)}px');

          totalError += distance;
          validComparisons++;
        }
      }

      if (validComparisons > 0) {
        double averageError = totalError / validComparisons;
        print('平均座標誤差: ${averageError.toStringAsFixed(1)}px');

        if (averageError > 50) {
          print('状態: 大きな位置ずれが検出されました');
        } else if (averageError > 20) {
          print('状態: 軽微な位置ずれがあります');
        } else if (averageError > 5) {
          print('状態: 微小な位置ずれがあります');
        } else {
          print('状態: 良好な位置精度です');
        }
      }
    }
  }

  // 統一座標系による自動補正計算
  Future<void> _autoCorrectOverlayPosition(int trajectoryIndex) async {
    if (_mapController == null || _currentTrajectoryDetails == null) return;

    TransformablePolyline trajectory = _trajectories[trajectoryIndex];

    // === 統一座標変換関数の定義 ===
    final painter = PolylinePainter(
      positions: trajectory.polyline,
      minLat: trajectory.minLat,
      maxLat: trajectory.maxLat,
      minLon: trajectory.minLon,
      maxLon: trajectory.maxLon,
      color: Colors.blue,
      preserveAspectRatio: true,
      strokeWidth: 4.0,
    );

    final drawingParams =
        painter.getDrawingParameters(Size(trajectorySize, trajectorySize));

    Offset transformPointToOverlayScreen(double lat, double lng) {
      // A) 地理座標 → Web Mercator
      double mercatorX = PolylinePainter.longitudeToWebMercatorX(lng);
      double mercatorY = PolylinePainter.latitudeToWebMercatorY(lat);

      // B) Web Mercator → 正規化座標
      double minMercatorX = drawingParams['minMercatorX'];
      double maxMercatorX = drawingParams['maxMercatorX'];
      double minMercatorY = drawingParams['minMercatorY'];
      double maxMercatorY = drawingParams['maxMercatorY'];
      double mercatorXRange = maxMercatorX - minMercatorX;
      double mercatorYRange = maxMercatorY - minMercatorY;

      double normalizedX = (mercatorX - minMercatorX) / mercatorXRange;
      double normalizedY = (mercatorY - minMercatorY) / mercatorYRange;

      // C) 正規化座標 → 基本ピクセル座標（コンテナ内）
      double scaleX = drawingParams['scaleX'];
      double scaleY = drawingParams['scaleY'];
      double drawingOffsetX = drawingParams['drawingOffsetX'];
      double drawingOffsetY = drawingParams['drawingOffsetY'];

      double basePixelX = normalizedX * scaleX + drawingOffsetX;
      double basePixelY =
          trajectorySize - (normalizedY * scaleY + drawingOffsetY);

      // D) スケール適用（コンテナ中心基準）
      double containerCenterX = trajectorySize / 2;
      double containerCenterY = trajectorySize / 2;
      double relativeX = basePixelX - containerCenterX;
      double relativeY = basePixelY - containerCenterY;
      double scaledRelativeX = relativeX * trajectory.scale;
      double scaledRelativeY = relativeY * trajectory.scale;

      // E) 回転適用（コンテナ中心基準）
      double rotatedRelativeX, rotatedRelativeY;
      if (trajectory.rotation != 0.0) {
        double cosAngle = math.cos(trajectory.rotation);
        double sinAngle = math.sin(trajectory.rotation);
        rotatedRelativeX =
            scaledRelativeX * cosAngle - scaledRelativeY * sinAngle;
        rotatedRelativeY =
            scaledRelativeX * sinAngle + scaledRelativeY * cosAngle;
      } else {
        rotatedRelativeX = scaledRelativeX;
        rotatedRelativeY = scaledRelativeY;
      }

      // F) 最終画面座標
      // trajectory.position はコンテナの中心座標を表すため、
      // コンテナ中心からの相対座標（rotatedRelativeX/Y）を加算するだけでよい
      double screenX = trajectory.position.dx + rotatedRelativeX;
      double screenY = trajectory.position.dy + rotatedRelativeY;

      return Offset(screenX, screenY);
    }

    // === データ重心の正確な計算 ===
    double totalLat = 0, totalLng = 0;
    for (Position pos in trajectory.polyline) {
      totalLat += pos.latitude;
      totalLng += pos.longitude;
    }
    double exactCentroidLat = totalLat / trajectory.polyline.length;
    double exactCentroidLng = totalLng / trajectory.polyline.length;

    try {
      // 地図上の重心位置を取得
      LatLng centroidLatLng = LatLng(exactCentroidLat, exactCentroidLng);
      ScreenCoordinate mapCentroidScreen =
          await _mapController!.getScreenCoordinate(centroidLatLng);
      Offset logicalMapCentroidScreen = _toLogicalOffset(mapCentroidScreen);

      // 統一座標変換でオーバーレイの重心位置を計算
      Offset overlayCentroidScreen =
          transformPointToOverlayScreen(exactCentroidLat, exactCentroidLng);

      // === 座標ずれの計算 ===
      double deltaX = logicalMapCentroidScreen.dx - overlayCentroidScreen.dx;
      double deltaY = logicalMapCentroidScreen.dy - overlayCentroidScreen.dy;
      double errorMagnitude = math.sqrt(deltaX * deltaX + deltaY * deltaY);

      if (_debugMode) {
        print('=== 始点基準による自動補正計算 ===');
        print(
            'データ重心（地理座標）: (${exactCentroidLat.toStringAsFixed(8)}, ${exactCentroidLng.toStringAsFixed(8)})');
        print(
            '地図重心スクリーン座標(論理px): (${logicalMapCentroidScreen.dx.toStringAsFixed(1)}, ${logicalMapCentroidScreen.dy.toStringAsFixed(1)})');
        print(
            'オーバーレイ重心座標: (${overlayCentroidScreen.dx.toStringAsFixed(1)}, ${overlayCentroidScreen.dy.toStringAsFixed(1)})');
        print(
            '座標ずれ: (${deltaX.toStringAsFixed(1)}, ${deltaY.toStringAsFixed(1)})');
        print('ずれの大きさ: ${errorMagnitude.toStringAsFixed(1)} ピクセル');

        // 精度評価
        if (errorMagnitude > 50) {
          print('評価: 大きな位置ずれが検出されました');
        } else if (errorMagnitude > 20) {
          print('評価: 軽微な位置ずれがあります');
        } else if (errorMagnitude > 5) {
          print('評価: 微小な位置ずれがあります');
        } else {
          print('評価: 優秀な位置精度です');
        }

        // 追加の診断情報
        print('--- 診断情報 ---');
        print(
            '軌跡変形: スケール=${trajectory.scale.toStringAsFixed(3)}, 回転=${(trajectory.rotation * 180 / math.pi).toStringAsFixed(1)}°');
        print(
            '軌跡コンテナ位置: (${trajectory.position.dx.toStringAsFixed(1)}, ${trajectory.position.dy.toStringAsFixed(1)})');

        // 座標変換の各段階での値も表示
        double mercatorX =
            PolylinePainter.longitudeToWebMercatorX(exactCentroidLng);
        double mercatorY =
            PolylinePainter.latitudeToWebMercatorY(exactCentroidLat);
        print(
            'Web Mercator座標: (${mercatorX.toStringAsFixed(6)}, ${mercatorY.toStringAsFixed(6)})');
      }
    } catch (e) {
      if (_debugMode) {
        print('統一座標系自動補正計算エラー: $e');
      }
    }
  }
}
