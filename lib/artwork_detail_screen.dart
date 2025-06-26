import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'artwork_creation_screen.dart';
import 'database_helper.dart';
import 'utils/utils.dart';
import 'walking_detail_screen.dart';
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
  List<int> _recordedOrder = []; // 記録順序を保持するリスト
  late DatabaseHelper _dbHelper;

  String _artworkName = "作品の詳細";
  final double canvasPadding = 20.0;
  bool _isColorful = false;
  List<Color> _trajectoryColors = [];

  final double trajectorySize = 100.0;

  double? savedCanvasWidth;
  double? savedCanvasHeight;

  // スライドショー機能の状態管理
  bool _isSlideshowPlaying = false;
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

  // スライドショーの設定（改良版）
  final Duration _highlightDuration = Duration(milliseconds: 1200);
  final Duration _mapTransitionDuration = Duration(milliseconds: 800);
  final Duration _mapAlignmentDuration = Duration(milliseconds: 1000);
  final Duration _mapDisplayDuration = Duration(seconds: 3);
  final Duration _transitionDuration = Duration(milliseconds: 600);

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
      String groupId = generateGroupId(trajectory.polyline);

      try {
        Map<String, dynamic>? record =
            await _dbHelper.getWalkingDataByGroupId(groupId);
        if (record != null) {
          DateTime recordTime =
              DateTime.tryParse(record['date']) ?? DateTime.now();
          trajectoriesWithTime.add(MapEntry(i, recordTime));
        }
      } catch (e) {
        print("軌跡 $i の記録時間の取得に失敗: $e");
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

        _trajectoryColors = List.generate(
          _trajectories.length,
          (_) => Colors.blue,
        );
      });

      // 軌跡を記録順にソート
      await _sortTrajectoriesByRecordTime();
    } catch (e) {
      print("キャンバス状態の読み込みエラー: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("キャンバス状態の読み込みに失敗しました: $e")),
      );
    }
  }

  Color _generateRandomColor() {
    Random random = Random();
    return Color.fromARGB(
      255,
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    );
  }

  void _setColorfulMode(bool isColorful) {
    setState(() {
      _isColorful = isColorful;
      _trajectoryColors = isColorful
          ? List.generate(
              _trajectories.length,
              (_) => _generateRandomColor(),
            )
          : List.generate(
              _trajectories.length,
              (_) => Colors.blue,
            );
    });
  }

  Future<void> _showTrajectoryDetails(TransformablePolyline trajectory) async {
    try {
      String groupId = generateGroupId(trajectory.polyline);
      Map<String, dynamic>? record =
          await _dbHelper.getWalkingDataByGroupId(groupId);

      if (record != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WalkingDetailScreen(
              groupId: groupId,
              date: record['date'],
              steps: record['steps'],
              distance: (record['distance'] / 1000).toStringAsFixed(2),
              rotation: trajectory.rotation,
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("記録が見つかりません。")),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("エラーが発生しました: $e")),
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
    });

    _highlightController.reset();
    _mapTransitionController.reset();
    _mapAlignmentController.reset();

    setState(() {
      _trajectoryColors = List.generate(
        _trajectories.length,
        (_) => _isColorful ? _generateRandomColor() : Colors.blue,
      );
    });
  }

  // 地図データの準備（保存メタデータ活用版）
  Future<void> _prepareMapData(int actualTrajectoryIndex) async {
    TransformablePolyline trajectory = _trajectories[actualTrajectoryIndex];
    String groupId = generateGroupId(trajectory.polyline);

    try {
      List<Map<String, dynamic>> positions =
          await _dbHelper.getPositionsByGroupId(groupId);
      Map<String, dynamic>? record =
          await _dbHelper.getWalkingDataByGroupId(groupId);

      if (positions.isEmpty || record == null) {
        print("位置情報または記録が見つかりません: $groupId");
        return;
      }

      // 実際の軌跡記録日時を位置情報から取得（walking_detail_screenと同じ方法）
      String actualRecordDate = record['date']; // フォールバック
      if (positions.isNotEmpty && positions.first.containsKey('timestamp')) {
        actualRecordDate = positions.first['timestamp'];
      }

      List<LatLng> polylinePoints = positions.map((pos) {
        return LatLng(pos['latitude'], pos['longitude']);
      }).toList();

      // 地理的境界を計算（保存メタデータがある場合はそれを優先）
      double minLat, maxLat, minLng, maxLng;

      // 保存されたキャンバス状態から軌跡メタデータを検索
      String canvasJsonString = await widget.canvasFile.readAsString();
      Map<String, dynamic> canvasData = jsonDecode(canvasJsonString);
      List<dynamic> savedTrajectories = canvasData['trajectories'] ?? [];

      Map<String, dynamic>? savedTrajectoryMeta;
      for (var savedTraj in savedTrajectories) {
        if (savedTraj['details'] != null &&
            savedTraj['details']['groupId'] == groupId) {
          savedTrajectoryMeta = savedTraj;
          break;
        }
      }

      if (savedTrajectoryMeta != null &&
          savedTrajectoryMeta['geoBounds'] != null) {
        // 保存されたメタデータから地理的境界を取得
        minLat = savedTrajectoryMeta['geoBounds']['minLat'];
        maxLat = savedTrajectoryMeta['geoBounds']['maxLat'];
        minLng = savedTrajectoryMeta['geoBounds']['minLng'];
        maxLng = savedTrajectoryMeta['geoBounds']['maxLng'];

        if (_debugMode) {
          print(
              '保存メタデータから地理的境界を取得: lat($minLat, $maxLat), lng($minLng, $maxLng)');
        }
      } else {
        // フォールバック：現在の位置データから計算
        minLat = polylinePoints
            .map((p) => p.latitude)
            .reduce((a, b) => a < b ? a : b);
        maxLat = polylinePoints
            .map((p) => p.latitude)
            .reduce((a, b) => a > b ? a : b);
        minLng = polylinePoints
            .map((p) => p.longitude)
            .reduce((a, b) => a < b ? a : b);
        maxLng = polylinePoints
            .map((p) => p.longitude)
            .reduce((a, b) => a > b ? a : b);

        if (_debugMode) {
          print(
              '現在の位置データから地理的境界を計算: lat($minLat, $maxLat), lng($minLng, $maxLng)');
        }
      }

      double centerLat = (minLat + maxLat) / 2;
      double centerLng = (minLng + maxLng) / 2;
      LatLng center = LatLng(centerLat, centerLng);

      // 軌跡のスケールと回転に基づいてポリラインの太さを調整
      double baseLineWidth = 4.0;
      double scaledLineWidth = baseLineWidth * trajectory.scale;
      scaledLineWidth = scaledLineWidth.clamp(2.0, 12.0);

      Set<Polyline> polylines = {
        Polyline(
          polylineId: PolylineId('route_$actualTrajectoryIndex'),
          points: polylinePoints,
          color: Colors.red.withOpacity(0.9),
          width: scaledLineWidth.round(),
        )
      };

      // 座標変換パラメータを計算
      double latRange = maxLat - minLat;
      double lonRange = maxLng - minLng;
      double latCosCorrection = math.cos(centerLat * math.pi / 180.0);

      if (_debugMode) {
        print('=== 軌跡詳細情報 ===');
        print('GroupID: $groupId');
        print('データベースから取得した記録日時: ${record['date']}');
        print('データベースから取得した歩数: ${record['steps']}');
        print('データベースから取得した距離: ${record['distance']}');
        if (savedTrajectoryMeta != null) {
          print('保存メタデータから取得した詳細: ${savedTrajectoryMeta['details']}');
        }
      }

      setState(() {
        _mapCenter = center;
        _mapPolylines = polylines;

        // 日時の優先順位：保存メタデータを優先（実際の軌跡記録日時を使用）
        String displayDate = actualRecordDate; // 位置情報から取得した実際の記録日時を使用
        if (savedTrajectoryMeta != null &&
            savedTrajectoryMeta['details'] != null &&
            savedTrajectoryMeta['details']['date'] != null &&
            savedTrajectoryMeta['details']['date'].toString().isNotEmpty) {
          // 保存メタデータの日時が実際の軌跡記録日時
          displayDate = savedTrajectoryMeta['details']['date'];
        }

        _currentTrajectoryDetails = {
          'groupId': groupId,
          'date': actualRecordDate, // 位置情報から取得した実際の記録日時を使用
          'steps': record['steps'],
          'distance': record['distance'],
          'polylinePoints': polylinePoints,
          'trajectory': trajectory,
          'actualTrajectoryIndex': actualTrajectoryIndex,
          'geoCenter': center,
          'minLat': minLat,
          'maxLat': maxLat,
          'minLng': minLng,
          'maxLng': maxLng,
          'latRange': latRange,
          'lonRange': lonRange,
          'latCosCorrection': latCosCorrection,
          'savedTrajectoryMeta': savedTrajectoryMeta, // 保存メタデータも追加
        };

        if (_debugMode) {
          print('=== 軌跡詳細データ設定完了 ===');
          print('軌跡グループID: $groupId');
          print('軌跡インデックス: $actualTrajectoryIndex');
          print('使用中の記録日時: $actualRecordDate');
          print('歩数: ${record['steps']}, 距離: ${record['distance']}');
          print('地理的境界: lat($minLat, $maxLat), lng($minLng, $maxLng)');
          if (savedTrajectoryMeta != null) {
            print(
                '保存メタデータ: 位置(${savedTrajectoryMeta['position']['absoluteX']}, ${savedTrajectoryMeta['position']['absoluteY']}), スケール=${savedTrajectoryMeta['scale']}, 回転=${savedTrajectoryMeta['rotation']}');
          }
        }
      });

      // 地図位置の精密計算
      _calculatePreciseMapAlignment(trajectory, actualTrajectoryIndex);
    } catch (e) {
      print("マップデータの準備中にエラー: $e");
    }
  }

  // 精密な地図整列計算（修正版 - 軌跡描画位置と完全同期）
  void _calculatePreciseMapAlignment(
      TransformablePolyline trajectory, int trajectoryIndex) {
    if (_currentTrajectoryDetails == null) return;

    final mediaQuery = MediaQuery.of(context);
    double currentBodyHeight = mediaQuery.size.height -
        mediaQuery.padding.top -
        mediaQuery.padding.bottom -
        AppBar().preferredSize.height;
    double currentBodyWidth = mediaQuery.size.width;

    // === 1. 軌跡の実際の描画位置を正確に取得 ===
    Map<String, dynamic>? savedMeta = _currentTrajectoryDetails!['savedTrajectoryMeta'];
    
    // 軌跡の実際の中心位置（Transform.rotate及びTransform.scaleの中心）
    double trajectoryContainerCenterX = trajectory.position.dx + trajectorySize / 2;
    double trajectoryContainerCenterY = trajectory.position.dy + trajectorySize / 2;

    // === 2. PolylinePainterの描画パラメータを取得 ===
    final painter = PolylinePainter(
      positions: trajectory.polyline,
      minLat: _currentTrajectoryDetails!['minLat'],
      maxLat: _currentTrajectoryDetails!['maxLat'],
      minLon: _currentTrajectoryDetails!['minLng'],
      maxLon: _currentTrajectoryDetails!['maxLng'],
      color: Colors.blue,
      preserveAspectRatio: true,
      strokeWidth: 4.0,
    );

    final drawingParams = painter.getDrawingParameters(Size(trajectorySize, trajectorySize));
    
    double scaleX = drawingParams['scaleX'];
    double scaleY = drawingParams['scaleY'];
    double drawingOffsetX = drawingParams['drawingOffsetX'];
    double drawingOffsetY = drawingParams['drawingOffsetY'];
    double centerLat = drawingParams['centerLat'];
    double centerLon = drawingParams['centerLon'];
    double latRange = drawingParams['latRange'];
    double lonRange = drawingParams['lonRange'];

    // === 3. スケール適用後の実際の描画サイズと位置を計算 ===
    double actualScale = trajectory.scale;
    double scaledDrawingWidth = scaleX * actualScale;
    double scaledDrawingHeight = scaleY * actualScale;
    
    // スケール適用後の描画オフセット（正確な計算）
    double scaledDrawingOffsetX = drawingOffsetX + (scaleX - scaledDrawingWidth) / 2;
    double scaledDrawingOffsetY = drawingOffsetY + (scaleY - scaledDrawingHeight) / 2;
    
    // 軌跡コンテナ内での実際の描画中心位置（正確な計算）
    double drawingCenterInContainerX = scaledDrawingOffsetX + scaledDrawingWidth / 2;
    double drawingCenterInContainerY = scaledDrawingOffsetY + scaledDrawingHeight / 2;

    // === 4. 回転を考慮した実際の描画中心位置を計算 ===
    double actualRotation = trajectory.rotation;
    double finalDrawingCenterX, finalDrawingCenterY;

    if (actualRotation != 0.0) {
      // 回転中心（軌跡コンテナの中心）からの相対位置
      double relativeX = drawingCenterInContainerX - trajectorySize / 2;
      double relativeY = drawingCenterInContainerY - trajectorySize / 2;
      
      // 回転変換
      double cosAngle = math.cos(actualRotation);
      double sinAngle = math.sin(actualRotation);
      
      double rotatedRelativeX = relativeX * cosAngle - relativeY * sinAngle;
      double rotatedRelativeY = relativeX * sinAngle + relativeY * cosAngle;
      
      // 絶対位置に変換
      finalDrawingCenterX = trajectoryContainerCenterX + rotatedRelativeX;
      finalDrawingCenterY = trajectoryContainerCenterY + rotatedRelativeY;
    } else {
      // 回転なしの場合
      finalDrawingCenterX = trajectoryContainerCenterX + (drawingCenterInContainerX - trajectorySize / 2);
      finalDrawingCenterY = trajectoryContainerCenterY + (drawingCenterInContainerY - trajectorySize / 2);
    }

    // === 5. 画面中心からのオフセットを計算 ===
    double screenCenterX = currentBodyWidth / 2;
    double screenCenterY = currentBodyHeight / 2;
    
    double pixelOffsetX = finalDrawingCenterX - screenCenterX;
    double pixelOffsetY = finalDrawingCenterY - screenCenterY;

    // === 6. 地理的座標への変換 ===
    // 補正された経度範囲を使用
    double correctedLonRange = lonRange * math.cos(centerLat * math.pi / 180.0);
    
    // ズームレベルの計算
    double avgDisplaySize = (scaledDrawingWidth + scaledDrawingHeight) / 2;
    double avgGeoRange = (latRange + correctedLonRange) / 2;
    double degreesPerPixel = avgGeoRange / avgDisplaySize;
    double zoom = math.log(360 / (degreesPerPixel * 256)) / math.log(2);
    zoom = zoom.clamp(12.0, 18.0);

    // より正確な度数変換
    double metersPerPixel = 156543.03392 * math.cos(centerLat * math.pi / 180) / math.pow(2, zoom);
    double degreesPerMeter = 1 / (111320 * math.cos(centerLat * math.pi / 180));
    double pixelToDegreesX = metersPerPixel * degreesPerMeter;
    double pixelToDegreesY = 1 / (111320 / metersPerPixel);

    // 地理的オフセット
    double lngOffset = pixelOffsetX * pixelToDegreesX;
    double latOffset = -pixelOffsetY * pixelToDegreesY; // Y軸は反転

    // === 7. 回転角度の設定 ===
    double bearing = 0.0;
    if (actualRotation != 0.0) {
      bearing = -(actualRotation * 180 / math.pi);
      bearing = bearing % 360;
      if (bearing < 0) bearing += 360;
    }

    // === 8. 最終的な地図中心座標 ===
    LatLng adjustedCenter = LatLng(
      centerLat + latOffset,
      centerLon + lngOffset,
    );

    // 整列用カメラ位置を保存
    _alignedCameraPosition = CameraPosition(
      target: adjustedCenter,
      zoom: zoom,
      bearing: bearing,
      tilt: 0,
    );

    if (_debugMode) {
      print('=== 修正版軌跡描画同期地図整列計算 ===');
      print('軌跡位置: (${trajectory.position.dx}, ${trajectory.position.dy})');
      print('軌跡コンテナ中心: (${trajectoryContainerCenterX}, ${trajectoryContainerCenterY})');
      print('軌跡スケール: ${actualScale}, 回転: ${actualRotation} rad');
      print('--- 描画パラメータ ---');
      print('基本描画サイズ: ${scaleX} x ${scaleY}');
      print('基本描画オフセット: (${drawingOffsetX}, ${drawingOffsetY})');
      print('スケール後描画サイズ: ${scaledDrawingWidth} x ${scaledDrawingHeight}');
      print('スケール後描画オフセット: (${scaledDrawingOffsetX}, ${scaledDrawingOffsetY})');
      print('コンテナ内描画中心: (${drawingCenterInContainerX}, ${drawingCenterInContainerY})');
      print('最終描画中心: (${finalDrawingCenterX}, ${finalDrawingCenterY})');
      print('--- 地図計算 ---');
      print('画面中心: (${screenCenterX}, ${screenCenterY})');
      print('画面中心からのオフセット: (${pixelOffsetX}, ${pixelOffsetY})');
      print('地理的オフセット: lat=${latOffset}, lng=${lngOffset}');
      print('調整後地図中心: ${adjustedCenter.latitude}, ${adjustedCenter.longitude}');
      print('ズーム: ${zoom}, 回転: ${bearing}°');
    }
  }

  // 改良版地図表示アニメーション（より滑らか）
  Future<void> _showMapAnimation() async {
    setState(() {
      _isShowingMap = true;
      _isMapAligned = false;
    });

    // 地図の初期化待機（短縮）
    await Future.delayed(Duration(milliseconds: 300));

    // フェードイン（より滑らか）
    _mapTransitionController.reset();
    await _mapTransitionController.forward();

    // 地図を精密に整列（待機時間追加）
    await Future.delayed(Duration(milliseconds: 200));
    await _alignMapPrecisely();

    // 整列表示時間
    await Future.delayed(_mapDisplayDuration);

    // フェードアウト
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

    // 地図の整列アニメーション
    _mapAlignmentController.reset();
    await _mapAlignmentController.forward();

    // カメラを精密位置に移動
    await _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(_alignedCameraPosition!),
    );

    // 整列完了の待機時間
    await Future.delayed(Duration(milliseconds: 200));
  }

  // 次の軌跡を表示（改良版）
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

    // ハイライトアニメーション
    _highlightController.reset();
    await _highlightController.forward();

    // 地図データを準備
    await _prepareMapData(actualTrajectoryIndex);

    // 改良版地図アニメーションを表示
    await _showMapAnimation();

    // 軌跡の色を元に戻す
    setState(() {
      _trajectoryColors[actualTrajectoryIndex] =
          _isColorful ? _generateRandomColor() : Colors.blue;
    });

    // 次の軌跡への遷移の待機
    await Future.delayed(_transitionDuration);

    // 続行
    if (_isSlideshowPlaying) {
      _showNextTrajectory();
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
          IconButton(
            icon: Icon(
              _isColorful ? Icons.color_lens : Icons.color_lens_outlined,
            ),
            onPressed: () {
              _setColorfulMode(!_isColorful);
            },
          ),
          IconButton(
            icon: Icon(
              _isSlideshowPlaying ? Icons.stop : Icons.slideshow,
            ),
            onPressed: () {
              if (_isSlideshowPlaying) {
                _stopSlideshow();
              } else {
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
            // 背景地図表示（完全整列版）
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

            // 軌跡の表示（改良版 - より正確な位置制御）
            ..._trajectories.asMap().entries.map((entry) {
              int index = entry.key;
              TransformablePolyline item = entry.value;

              // ハイライト効果（強化版）
              bool isCurrentlyHighlighted = _isSlideshowPlaying &&
                  _currentTrajectoryIndex >= 0 &&
                  _recordedOrder.isNotEmpty &&
                  _currentTrajectoryIndex < _recordedOrder.length &&
                  _recordedOrder[_currentTrajectoryIndex] == index;

              // シンプルなハイライト効果（グロー効果なし）
              double pulseScale = 1.0;

              if (isCurrentlyHighlighted) {
                // 軽いパルス効果のみ
                double pulseProgress = Curves.easeInOut.transform(
                    (sin(_highlightController.value * 2 * pi) + 1) / 2);
                pulseScale = 1.0 + (pulseProgress * 0.05);
              }

              return Positioned(
                left: item.position.dx,
                top: item.position.dy,
                child: GestureDetector(
                  onTap: () => _showTrajectoryDetails(item),
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
                            strokeWidth: isCurrentlyHighlighted ? 5.0 : 4.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),

            // 軌跡情報表示（元のサイズに戻す）
            if (_isShowingMap && _currentTrajectoryDetails != null)
              Positioned(
                bottom: 80,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedBuilder(
                    animation: _mapTransitionController,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _mapTransitionController.value,
                        child: Opacity(
                          opacity: _mapTransitionController.value,
                          child: Container(
                            padding: EdgeInsets.all(16),
                            margin: EdgeInsets.symmetric(horizontal: 20),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.95),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 12,
                                  offset: Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 日時（軌跡の記録日時）
                                Text(
                                  () {
                                    try {
                                      DateTime? recordDate = DateTime.tryParse(
                                          _currentTrajectoryDetails!['date']);
                                      if (recordDate != null) {
                                        String formattedDate =
                                            '${recordDate.year}/${recordDate.month.toString().padLeft(2, '0')}/${recordDate.day.toString().padLeft(2, '0')} ${recordDate.hour.toString().padLeft(2, '0')}:${recordDate.minute.toString().padLeft(2, '0')}';
                                        return '記録日時: $formattedDate';
                                      }
                                    } catch (e) {
                                      print('日時のパースエラー: $e');
                                      print(
                                          '元データ: ${_currentTrajectoryDetails?['date']}');
                                    }
                                    return '記録日時: 不明';
                                  }(),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: 16),
                                // 統計情報
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildStatItem(
                                      Icons.directions_walk,
                                      '${_currentTrajectoryDetails!['steps']} 歩',
                                      Colors.blue,
                                    ),
                                    SizedBox(width: 24),
                                    _buildStatItem(
                                      Icons.straighten,
                                      '${(_currentTrajectoryDetails!['distance'] / 1000).toStringAsFixed(2)} km',
                                      Colors.green,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

            // スライドショーインジケーター（元のデザインに戻す）
            if (_isSlideshowPlaying)
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(25),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_circle_filled,
                          color: Colors.white,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'アニメーション再生中',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(width: 12),
                        Container(
                          padding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_currentTrajectoryIndex + 1} / ${_recordedOrder.length}',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // 統計情報アイテムを構築するヘルパーメソッド（元のサイズに戻す）
  Widget _buildStatItem(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}