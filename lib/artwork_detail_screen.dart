import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'artwork_creation_screen.dart';
import 'database_helper.dart';
import 'utils/utils.dart';
import 'polyline_painter.dart';

class ArtworkDetailScreen extends StatefulWidget {
  final File canvasFile;

  ArtworkDetailScreen({required this.canvasFile});

  @override
  _ArtworkDetailScreenState createState() => _ArtworkDetailScreenState();
}

class _ArtworkDetailScreenState extends State<ArtworkDetailScreen>
    with TickerProviderStateMixin {
  List<TransformablePolyline> _trajectories = [];
  List<int> _recordedOrder = [];
  List<Map<String, dynamic>> _trajectoryMetadata = []; // 軌跡のメタデータを保持
  late DatabaseHelper _dbHelper;

  String _artworkName = "作品の詳細";
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

  // スライドショーの速度制御
  int _playbackSpeed = 1; // 1倍速、2倍速、3倍速、または負の値で早戻し
  final List<int> _speedOptions = [-3, -2, -1, 1, 2, 3]; // 利用可能な速度オプション

  // デバッグフラグ
  final bool _debugMode = true;

  // 地図整列の状態管理
  bool _isMapAligned = false;
  CameraPosition? _alignedCameraPosition;

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();

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

  // 軌跡を記録日時順にソートするメソッド
  Future<void> _sortTrajectoriesByRecordTime() async {
    List<MapEntry<int, DateTime>> trajectoriesWithTime = [];

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

      try {
        Map<String, dynamic>? record =
            await _dbHelper.getWalkingDataByGroupId(groupId);

        // ローカル軌跡が見つからない場合、Garmin軌跡を確認
        if (record == null) {
          record = await _dbHelper.getGarminActivityByGroupId(groupId);
        }

        if (record != null) {
          DateTime recordTime =
              DateTime.tryParse(record['date']) ?? DateTime.now();
          trajectoriesWithTime.add(MapEntry(i, recordTime));
          print("✅ 軌跡 $i (groupId: $groupId) の記録時間を取得: $recordTime");
        } else {
          print("⚠️  軌跡 $i (groupId: $groupId) のレコードが見つかりません");
          trajectoriesWithTime.add(MapEntry(i, DateTime.now()));
        }
      } catch (e) {
        print("❌ 軌跡 $i (groupId: $groupId) の記録時間の取得に失敗: $e");
        trajectoriesWithTime.add(MapEntry(i, DateTime.now()));
      }
    }

    // 記録時間でソート（古い順）
    trajectoriesWithTime.sort((a, b) => a.value.compareTo(b.value));

    // ソートされた順序を保存
    setState(() {
      _recordedOrder = trajectoriesWithTime.map((entry) => entry.key).toList();
    });

    print("軌跡を記録順にソート: $_recordedOrder");
  }

  // キャンバスの状態の復元（完全メタデータ対応版）
  Future<void> _loadCanvasState() async {
    try {
      String jsonString = await widget.canvasFile.readAsString();
      Map<String, dynamic> data = jsonDecode(jsonString);

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

        _trajectoryColors = List.generate(
          _trajectories.length,
          (_) => Colors.blue,
        );
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

  void _startSlideshow() async {
    if (_trajectories.isEmpty || _recordedOrder.isEmpty) return;

    setState(() {
      _isSlideshowPlaying = true;
_currentTrajectoryIndex = -1;
      _isShowingMap = false;
      _isMapAligned = false;
    });

    _showNextTrajectory();
  }

  void _stopSlideshow() {
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

  void _seekToTrajectory(int index) {
    if (_recordedOrder.isEmpty) return;
    index = index.clamp(0, _recordedOrder.length - 1);

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
  String _getSpeedText() {
    if (_playbackSpeed > 0) {
      return '${_playbackSpeed}倍速';
    } else {
      return '${_playbackSpeed.abs()}倍速(早戻し)';
    }
  }

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
      List<Map<String, dynamic>> positions =
          await _dbHelper.getPositionsByGroupId(groupId);
      Map<String, dynamic>? record =
          await _dbHelper.getWalkingDataByGroupId(groupId);

      // ローカル軌跡が見つからない場合、Garmin軌跡を確認
      String actualGroupId = groupId;
      if ((positions.isEmpty || record == null)) {
        print("ローカル軌跡が見つかりません: $groupId。Garmin軌跡を確認中...");

        // Garmin軌跡を取得してみる
        Map<String, dynamic>? garminRecord =
            await _dbHelper.getGarminActivityByGroupId(groupId);

        if (garminRecord != null) {
          print("✅ Garmin軌跡が見つかりました: $groupId");
          actualGroupId = groupId;
          record = garminRecord;

          // Garmin軌跡の座標を復元
          try {
            final positionsJson = jsonDecode(garminRecord['positions']) as List;
            positions = positionsJson
                .map((pos) {
                  return {
                    'latitude': pos['latitude'],
                    'longitude': pos['longitude'],
                    'timestamp':
                        pos['timestamp'] ?? DateTime.now().toIso8601String(),
                  };
                })
                .cast<Map<String, dynamic>>()
                .toList();
          } catch (e) {
            print("❌ Garmin軌跡の座標復元エラー: $e");
          }
        } else {
          print("Garmin軌跡も見つかりません。座標検索を試みます...");

          // 座標の境界から最も近いGarmin軌跡を見つける
          final garminActivities = await _dbHelper.getGarminActivities();

          if (garminActivities.isNotEmpty) {
            double minLat =
                trajectory.polyline.map((p) => p.latitude).reduce(math.min);
            double maxLat =
                trajectory.polyline.map((p) => p.latitude).reduce(math.max);
            double minLng =
                trajectory.polyline.map((p) => p.longitude).reduce(math.min);
            double maxLng =
                trajectory.polyline.map((p) => p.longitude).reduce(math.max);

            // すべてのGarmin軌跡を確認
            for (final activity in garminActivities) {
              final positions_garmin =
                  jsonDecode(activity['positions']) as List;
              if (positions_garmin.isNotEmpty) {
                final firstPos = positions_garmin.first as Map<String, dynamic>;
                final lastPos = positions_garmin.last as Map<String, dynamic>;

                final minLatDB = math.min(
                    (firstPos['latitude'] as num).toDouble(),
                    (lastPos['latitude'] as num).toDouble());
                final maxLatDB = math.max(
                    (firstPos['latitude'] as num).toDouble(),
                    (lastPos['latitude'] as num).toDouble());
                final minLngDB = math.min(
                    (firstPos['longitude'] as num).toDouble(),
                    (lastPos['longitude'] as num).toDouble());
                final maxLngDB = math.max(
                    (firstPos['longitude'] as num).toDouble(),
                    (lastPos['longitude'] as num).toDouble());

                // 座標範囲が重なっているか確認
                if (minLat <= maxLatDB &&
                    maxLat >= minLatDB &&
                    minLng <= maxLngDB &&
                    maxLng >= minLngDB) {
                  print('✅ 座標が一致しました。Garmin軌跡を使用: ${activity['group_id']}');
                  actualGroupId = activity['group_id'] as String;
                  positions = positions_garmin
                      .map((pos) {
                        return {
                          'latitude': pos['latitude'],
                          'longitude': pos['longitude'],
                          'timestamp': pos['timestamp'] ??
                              DateTime.now().toIso8601String(),
                        };
                      })
                      .cast<Map<String, dynamic>>()
                      .toList();
                  record =
                      await _dbHelper.getWalkingDataByGroupId(actualGroupId);
                  break;
                }
              }
            }
          }
        }
      }

      if (positions.isEmpty || record == null) {
        print("位置情報または記録が見つかりません: $groupId");
        print("メタデータから取得したgroupId: $groupId");
        print(
            "インデックス: $actualTrajectoryIndex, メタデータ数: ${_trajectoryMetadata.length}");
        return;
      }

      final recordData = record;
      String actualRecordDate = recordData['date'];
      if (positions.isNotEmpty && positions.first.containsKey('timestamp')) {
        actualRecordDate = positions.first['timestamp'];
      }

      List<LatLng> polylinePoints = positions.map((pos) {
        return LatLng(pos['latitude'], pos['longitude']);
      }).toList();

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

  // 地図表示アニメーション
  Future<void> _showMapAnimation() async {
    setState(() {
      _isShowingMap = true;
      _isMapAligned = false;
    });

    // 地図の初期化待機（速度適用）
    await Future.delayed(_getScaledDuration(Duration(milliseconds: 300)));

    // フェードイン（速度調整）
    _mapTransitionController.duration =
        _getScaledDuration(_mapTransitionDuration);
    _mapTransitionController.reset();
    await _mapTransitionController.forward();

    // 地図を精密に整列（速度適用）
    await Future.delayed(_getScaledDuration(Duration(milliseconds: 200)));
    await _alignMapPrecisely();

    // 整列表示時間（速度適用）
    await Future.delayed(_getScaledDuration(_mapDisplayDuration));

    // フェードアウト（速度調整）
    _mapTransitionController.duration =
        _getScaledDuration(_mapTransitionDuration);
    await _mapTransitionController.reverse();

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

  // 前の軌跡を表示
  void _showPreviousTrajectory() async {
    if (!_isSlideshowPlaying) return;

    int prevStepIndex = _currentTrajectoryIndex - 1;

    if (prevStepIndex < 0) {
      // 最初の軌跡より前に戻ろうとした場合、スライドショーを終了
      _stopSlideshow();
      return;
    }

    // 実際の軌跡インデックス（記録順序に従う）
    int actualTrajectoryIndex = _recordedOrder[prevStepIndex];

    setState(() {
      _currentTrajectoryIndex = prevStepIndex;
      // ハイライトする軌跡を赤色に変更
      _trajectoryColors[actualTrajectoryIndex] = Colors.red;
      // 新しい軌跡に変わったのでキャッシュをクリア
      _cachedCameraPosition = null;
      _alignedCameraPosition = null;
    });

    // ハイライトアニメーション（速度調整）
    _highlightController.duration = _getScaledDuration(_highlightDuration);
    _highlightController.reset();
    await _highlightController.forward();

    // 地図データを準備
    await _prepareMapData(actualTrajectoryIndex);

    // 地図アニメーションを表示
    await _showMapAnimation();

    // 軌跡の色を元に戻す
    setState(() {
      _trajectoryColors[actualTrajectoryIndex] =
          Colors.blue;
    });

    // 速度に応じた次の軌跡への遷移の待機
    await Future.delayed(_getScaledDuration(_transitionDuration));

    // 続行（早戻しの場合は前の軌跡に進む）
    if (_isSlideshowPlaying) {
      if (_playbackSpeed < 0) {
        _showPreviousTrajectory();
      } else {
        _showNextTrajectory();
      }
    }
  }

  // 次の軌跡を表示
  void _showNextTrajectory() async {
    if (!_isSlideshowPlaying) return;

    int nextStepIndex = _currentTrajectoryIndex + 1;

    if (nextStepIndex >= _recordedOrder.length) {
      _stopSlideshow();
      return;
    }

    // 実際の軌跡インデックス（記録順序に従う）
    int actualTrajectoryIndex = _recordedOrder[nextStepIndex];

    setState(() {
      _currentTrajectoryIndex = nextStepIndex;
      // ハイライトする軌跡を赤色に変更
      _trajectoryColors[actualTrajectoryIndex] = Colors.red;
      // 新しい軌跡に変わったのでキャッシュをクリア
      _cachedCameraPosition = null;
      _alignedCameraPosition = null;
    });

    // ハイライトアニメーション（速度調整）
    _highlightController.duration = _getScaledDuration(_highlightDuration);
    _highlightController.reset();
    await _highlightController.forward();

    // 地図データを準備
    await _prepareMapData(actualTrajectoryIndex);

    // 地図アニメーションを表示
    await _showMapAnimation();

    // 軌跡の色を元に戻す
    setState(() {
      _trajectoryColors[actualTrajectoryIndex] =
          Colors.blue;
    });

    // 速度に応じた次の軌跡への遷移の待機
    await Future.delayed(_getScaledDuration(_transitionDuration));

    // 続行（早戻しの場合は前の軌跡に進む）
    if (_isSlideshowPlaying) {
      if (_playbackSpeed < 0) {
        _showPreviousTrajectory();
      } else {
        _showNextTrajectory();
      }
    }
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
  // （route_design_canvas_screen.dart の _convertStrokesToLatLngs と同じ対応）
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
        title: Text(_artworkName),
        actions: [
          if (_trajectories.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.animation),
              onPressed: () {
                setState(() =>
                    _isControlPanelVisible = !_isControlPanelVisible);
                if (_isControlPanelVisible && !_isSlideshowPlaying) {
                  _startSlideshow();
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

              // ハイライト効果
              bool isCurrentlyHighlighted = _isSlideshowPlaying &&
                  _currentTrajectoryIndex >= 0 &&
                  (
                      // スライドショーの場合
                      (_recordedOrder.isNotEmpty &&
                              _currentTrajectoryIndex < _recordedOrder.length &&
                              _recordedOrder[_currentTrajectoryIndex] ==
                                  index) ||
                          // 個別軌跡アニメーションの場合
                          _currentTrajectoryIndex == index);

              // シンプルなハイライト効果
              double pulseScale = 1.0;

              if (isCurrentlyHighlighted) {
                // 軽いパルス効果のみ
                double pulseProgress = Curves.easeInOut.transform(
                    (sin(_highlightController.value * 2 * pi) + 1) / 2);
                pulseScale = 1.0 + (pulseProgress * 0.05);
              }

              return Positioned(
                left: item.position.dx - trajectorySize / 2,
                top: item.position.dy - trajectorySize / 2,
                child: GestureDetector(
                  onTap: _isSlideshowPlaying
                      ? null
                      : () => _showTrajectoryDetails(item),
                  child: Container(
                    width: trajectorySize,
                    height: trajectorySize,
                    child: Transform.rotate(
                      angle: item.rotation,
                      alignment: Alignment.center,
                      child: Transform.scale(
                        scale: item.scale * pulseScale,
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
                            strokeWidth: (isCurrentlyHighlighted ? 5.0 : 4.0) /
                                (item.scale * pulseScale),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),

            // 個別軌跡の記録日時・歩数・距離表示（スライドショーの再生バーが
            // 非表示のときに軌跡タップで地図が表示されるケース向け）
            if (_isShowingMap &&
                _currentTrajectoryDetails != null &&
                !_isControlPanelVisible)
              Positioned(
                bottom: 24,
                left: 16,
                right: 16,
                child: AnimatedBuilder(
                  animation: _mapTransitionController,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _mapTransitionController.value,
                      child: child,
                    );
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text(
                          _formatDate(_currentTrajectoryDetails!['date']),
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.directions_walk,
                                size: 14, color: Colors.blue[300]),
                            SizedBox(width: 4),
                            Text(
                              '${_currentTrajectoryDetails!['steps']} 歩',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.straighten,
                                size: 14, color: Colors.green[300]),
                            SizedBox(width: 4),
                            Text(
                              '${(_currentTrajectoryDetails!['distance'] as double).toStringAsFixed(2)} km',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 再生コントロールパネル
            if (_trajectories.isNotEmpty && _isControlPanelVisible)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 閉じるハンドル
                      GestureDetector(
                        onTap: () =>
                            setState(() => _isControlPanelVisible = false),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Icon(Icons.keyboard_arrow_down,
                              color: Colors.white54, size: 20),
                        ),
                      ),
                      // 上段：情報表示エリア
                      if (_currentTrajectoryDetails != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Text(
                              '記録日時: ${_formatDate(_currentTrajectoryDetails!['date'])}',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.directions_walk,
                                    size: 14, color: Colors.blue[300]),
                                SizedBox(width: 4),
                                Text(
                                  '${_currentTrajectoryDetails!['steps']} 歩',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.straighten,
                                    size: 14, color: Colors.green[300]),
                                SizedBox(width: 4),
                                Text(
                                  '${(_currentTrajectoryDetails!['distance'] as double).toStringAsFixed(2)} km',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                      ],
                      // 下段：再生コントロールエリア（停止ボタン + シークバー）
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              _isSlideshowPlaying
                                  ? Icons.stop
                                  : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed: _isSlideshowPlaying
                                ? _stopSlideshow
                                : _startSlideshow,
                            padding: EdgeInsets.all(4),
                            constraints:
                                BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.0,
                                thumbShape: RoundSliderThumbShape(
                                    enabledThumbRadius: 7),
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white30,
                                thumbColor: Colors.white,
                                overlayColor: Colors.white24,
                              ),
                              child: Slider(
                                value: _recordedOrder.isEmpty
                                    ? 0.0
                                    : _currentTrajectoryIndex
                                        .clamp(0, _recordedOrder.length - 1)
                                        .toDouble(),
                                min: 0,
                                max: _recordedOrder.length <= 1
                                    ? 1.0
                                    : (_recordedOrder.length - 1).toDouble(),
                                divisions: _recordedOrder.length > 1
                                    ? _recordedOrder.length - 1
                                    : null,
                                onChanged: _recordedOrder.length > 1
                                    ? (value) =>
                                        _seekToTrajectory(value.round())
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // ストローク操作エリア（コマ送り + ストローク番号 + 速度）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: Icon(Icons.navigate_before,
                                color: Colors.white),
                            onPressed: () => _seekToTrajectory(
                                (_currentTrajectoryIndex - 1)
                                    .clamp(0, _recordedOrder.length - 1)),
                            padding: EdgeInsets.all(4),
                            constraints:
                                BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                          Text(
                            '${(_currentTrajectoryIndex + 1).clamp(1, _recordedOrder.length)} / ${_recordedOrder.length}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.white70,
                            ),
                          ),
                          IconButton(
                            icon:
                                Icon(Icons.navigate_next, color: Colors.white),
                            onPressed: () => _seekToTrajectory(
                                (_currentTrajectoryIndex + 1)
                                    .clamp(0, _recordedOrder.length - 1)),
                            padding: EdgeInsets.all(4),
                            constraints:
                                BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                          SizedBox(width: 8),
                          TextButton(
                            onPressed: _increaseSpeed,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              minimumSize: Size(0, 36),
                            ),
                            child: Text(
                              _getSpeedText(),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
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
