import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'draft_list_screen.dart';
import 'route_service.dart';

class RouteGenerationScreen extends StatefulWidget {
  final LatLng startingPoint;
  final LatLng destination;
  final List<LatLng> tracedPath;
  final Map<String, dynamic>? initialCanvasData;

  RouteGenerationScreen({
    required this.startingPoint,
    required this.destination,
    required this.tracedPath,
    this.initialCanvasData,
  });

  @override
  _RouteGenerationScreenState createState() => _RouteGenerationScreenState();
}

class _RouteGenerationScreenState extends State<RouteGenerationScreen> {
  // ignore: unused_field
  late GoogleMapController _mapController;

  List<LatLng>? _generatedRoute;
  Map<String, dynamic>? _routeMetadata;
  bool _isLoading = true;
  bool _showSketch = false;

  // 作品キャンバスプレビュー表示フラグ
  bool _showPreview = false;

  // プレビューに重ねる下書きキャンバスデータ
  Map<String, dynamic>? _draftCanvasData;

  // プレビューでのルート移動・回転用状態
  final GlobalKey _previewKey = GlobalKey();
  Offset? _routePreviewPosition; // null = キャンバス中央に初期化
  double _routePreviewRotation = 0.0;
  double _routePreviewLastRotation = 0.0;
  double? _rotationStartAngle;
  bool _isRotationHandleDragging = false;
  bool _isRouteRotating = false;

  // ─── スケールバー（作品制作画面と同一設定） ───
  static const List<double> _scaleDistanceOptions = [
    50, 100, 200, 300, 500, 1000, 2000, 3000, 5000, 10000,
  ];
  static const double _scaleBarPixelLength = 80.0;
  static const double _trajectorySize = 100.0;
  double _scaleBarDistanceMeters = 500.0;

  @override
  void initState() {
    super.initState();
    _draftCanvasData = widget.initialCanvasData;
    _generateRoute();
  }

  Future<void> _generateRoute() async {
    try {
      print('📍 Roads API でスケッチをスナップ中...');
      List<LatLng> snappedRoute = await RouteService.snapSketchToRoads(
        designPath: widget.tracedPath,
        startingPoint: widget.startingPoint,
        destination: widget.destination,
      );

      setState(() {
        _generatedRoute = snappedRoute;
        _isLoading = false;
      });

      print('✅ ルート生成完了');
      print('  - ルート上のポイント数: ${snappedRoute.length}');
      double routeDistance = RouteService.calculatePathDistance(snappedRoute);
      print('  - ルート距離: ${(routeDistance / 1000).toStringAsFixed(2)}km');
    } catch (e) {
      print('❌ ルート生成エラー: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ルート生成に失敗しました: $e')),
        );
      }
    }
  }

  // ─── スケールバー関連 ─────────────────────────────────────

  String _formatScaleDistance(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      return '${km % 1 == 0 ? km.toInt() : km.toStringAsFixed(1)}km';
    }
    return '${meters.toInt()}m';
  }

  void _increaseScaleDistance() {
    final idx = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    if (idx < _scaleDistanceOptions.length - 1) {
      setState(() => _scaleBarDistanceMeters = _scaleDistanceOptions[idx + 1]);
    }
  }

  void _decreaseScaleDistance() {
    final idx = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    if (idx > 0) {
      setState(() => _scaleBarDistanceMeters = _scaleDistanceOptions[idx - 1]);
    }
  }

  /// ルートの実世界最大寸法（メートル）を計算
  double _computeRouteExtentMeters(List<LatLng> route) {
    final lats = route.map((p) => p.latitude);
    final lons = route.map((p) => p.longitude);
    final minLat = lats.reduce(math.min);
    final maxLat = lats.reduce(math.max);
    final minLon = lons.reduce(math.min);
    final maxLon = lons.reduce(math.max);
    final meanLat = (minLat + maxLat) / 2.0;
    final latExtent = (maxLat - minLat) * 111320.0;
    final lonExtent =
        (maxLon - minLon) * 111320.0 * math.cos(meanLat * math.pi / 180.0);
    return math.max(latExtent, lonExtent);
  }

  /// スケールバー設定に基づくルートの表示スケール係数
  double _computeRouteScale(List<LatLng> route) {
    final extentMeters = _computeRouteExtentMeters(route);
    if (extentMeters <= 0) return 1.0;
    final metersPerPixel = _scaleBarDistanceMeters / _scaleBarPixelLength;
    return extentMeters / (metersPerPixel * _trajectorySize * 0.8);
  }

  /// スケールバーウィジェット（作品制作画面と同一デザイン）
  Widget _buildScaleBar() {
    final idx = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    final canDecrease = idx > 0;
    final canIncrease = idx < _scaleDistanceOptions.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: canDecrease ? _decreaseScaleDistance : null,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.remove,
                      size: 20,
                      color: canDecrease ? Colors.black54 : Colors.grey[400]),
                ),
              ),
              Container(
                width: _scaleBarPixelLength,
                height: 8,
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(width: 1.5, color: Colors.black54),
                    right: BorderSide(width: 1.5, color: Colors.black54),
                    bottom: BorderSide(width: 1.5, color: Colors.black54),
                  ),
                ),
              ),
              GestureDetector(
                onTap: canIncrease ? _increaseScaleDistance : null,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.add,
                      size: 20,
                      color: canIncrease ? Colors.black54 : Colors.grey[400]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          SizedBox(
            width: _scaleBarPixelLength + 64,
            child: Center(
              child: Text(
                _formatScaleDistance(_scaleBarDistanceMeters),
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startWalkingWithRoute() {
    if (_generatedRoute == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ルートが生成されていません')),
      );
      return;
    }

    Navigator.pop(context, {
      'routePath': _generatedRoute,
      'metadata': _routeMetadata,
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ルート提案'),
          centerTitle: true,
          elevation: 0,
          actions: [
            if (!_isLoading && _generatedRoute != null) ...[
              // スケッチ表示切替（地図ビュー時のみ有効）
              if (!_showPreview)
                IconButton(
                  icon: Icon(
                    _showSketch ? Icons.visibility : Icons.visibility_off,
                    color: Colors.black,
                  ),
                  onPressed: () => setState(() => _showSketch = !_showSketch),
                  tooltip: 'スケッチの表示/非表示',
                ),
              // プレビュー切り替えボタン
              IconButton(
                icon: Icon(
                  _showPreview ? Icons.map : Icons.art_track,
                  color: _showPreview ? Colors.blue : Colors.black,
                ),
                onPressed: () => setState(() => _showPreview = !_showPreview),
                tooltip: _showPreview ? '地図に戻る' : '作品プレビュー',
              ),
            ],
          ],
        ),
        body: _isLoading
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('ルートを生成中...'),
                  ],
                ),
              )
            : _showPreview
                ? _buildArtworkPreview()
                : _buildMapView(),
      ),
    );
  }

  // ─── 地図ビュー ──────────────────────────────────────────

  Widget _buildMapView() {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(
              (widget.startingPoint.latitude + widget.destination.latitude) / 2,
              (widget.startingPoint.longitude + widget.destination.longitude) /
                  2,
            ),
            zoom: 14,
          ),
          onMapCreated: (controller) => _mapController = controller,
          polylines: _buildPolylines(),
          markers: _buildMarkers(),
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
        ),

        // 上部: ルート情報パネル
        if (_generatedRoute != null)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.straighten, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text('距離: ', style: TextStyle(fontSize: 14)),
                  Text(
                    '${(RouteService.calculatePathDistance(_generatedRoute!) / 1000).toStringAsFixed(2)} km',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 下部: 歩く開始ボタン
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _startWalkingWithRoute,
              icon: const Icon(Icons.play_arrow),
              label: const Text('このルートで歩く'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── 作品キャンバスプレビュー ─────────────────────────────

  /// 下書きキャンバスを選択して _draftCanvasData を更新
  Future<void> _selectDraftCanvas() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => DraftListScreen(
          onDraftSelected: (draft) => Navigator.pop(context, draft),
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _draftCanvasData = result;
        final savedScale = result['scaleBarDistance'];
        if (savedScale != null) {
          _scaleBarDistanceMeters = (savedScale as num).toDouble();
        }
      });
    }
  }

  Widget _buildArtworkPreview() {
    final route = _generatedRoute!;
    final routeScale = _computeRouteScale(route);
    final displaySize = _trajectorySize * routeScale;
    // 回転ハンドルを含むタッチ領域（四隅をカバーするため対角線以上）
    final touchArea = displaySize * math.sqrt(2) + 40.0;

    final draftTrajectories = (_draftCanvasData?['trajectories'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];

    // 下書き保存時のスケールバー値。ない場合は現在値と同一（倍率 1.0）
    final savedScaleBarDistance =
        (_draftCanvasData?['scaleBarDistance'] as num?)?.toDouble() ??
            _scaleBarDistanceMeters;
    final scaleMultiplier = savedScaleBarDistance / _scaleBarDistanceMeters;

    return LayoutBuilder(builder: (context, constraints) {
      // 初回レンダリング時にルートをキャンバス中央に配置
      final position = _routePreviewPosition ??
          Offset(constraints.maxWidth / 2, constraints.maxHeight / 2);

      // 回転ハンドルの座標（右上コーナー、回転角度を反映）
      const double handleSize = 28.0;
      final double radius = displaySize / 2 * math.sqrt(2);
      final double handleAngle = -math.pi / 4 + _routePreviewRotation;
      final double handleX =
          touchArea / 2 + radius * math.cos(handleAngle) - handleSize / 2;
      final double handleY =
          touchArea / 2 + radius * math.sin(handleAngle) - handleSize / 2;

      return Stack(
        key: _previewKey,
        children: [
          // グレー背景
          Container(color: Colors.grey[200]),

          // 下書きキャンバスの軌跡をスケール反映して背景描画
          if (draftTrajectories.isNotEmpty)
            Positioned.fill(
              child: CustomPaint(
                painter: DraftCanvasOverlayPainter(
                  trajectories: draftTrajectories,
                  scaleMultiplier: scaleMultiplier,
                ),
              ),
            ),

          // 移動・回転可能な新しいルート
          Positioned(
            left: position.dx - touchArea / 2,
            top: position.dy - touchArea / 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                if (!_isRotationHandleDragging) {
                  setState(() {
                    _routePreviewPosition = position + details.delta;
                  });
                }
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 透明なヒットエリア
                  SizedBox(width: touchArea, height: touchArea),

                  // ルートボックス（回転・スケール適用）
                  Positioned(
                    left: (touchArea - displaySize) / 2,
                    top: (touchArea - displaySize) / 2,
                    child: Transform.rotate(
                      angle: _routePreviewRotation,
                      child: Container(
                        width: displaySize,
                        height: displaySize,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _isRouteRotating
                                ? Colors.deepOrange
                                : Colors.orange,
                            width: 2,
                          ),
                        ),
                        child: CustomPaint(
                          size: Size(displaySize, displaySize),
                          painter: RoutePreviewPainter(route: route),
                        ),
                      ),
                    ),
                  ),

                  // 回転ハンドル
                  Positioned(
                    left: handleX,
                    top: handleY,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        final canvasBox = _previewKey.currentContext
                            ?.findRenderObject() as RenderBox?;
                        if (canvasBox != null) {
                          final canvasOrigin =
                              canvasBox.localToGlobal(Offset.zero);
                          final touchInCanvas =
                              details.globalPosition - canvasOrigin;
                          _rotationStartAngle = math.atan2(
                            touchInCanvas.dy - position.dy,
                            touchInCanvas.dx - position.dx,
                          );
                          _routePreviewLastRotation = _routePreviewRotation;
                        }
                        setState(() {
                          _isRotationHandleDragging = true;
                          _isRouteRotating = true;
                        });
                      },
                      onPanUpdate: (details) {
                        if (!_isRotationHandleDragging ||
                            _rotationStartAngle == null) return;
                        final canvasBox = _previewKey.currentContext
                            ?.findRenderObject() as RenderBox?;
                        if (canvasBox == null) return;
                        final canvasOrigin =
                            canvasBox.localToGlobal(Offset.zero);
                        final touchInCanvas =
                            details.globalPosition - canvasOrigin;
                        final currentAngle = math.atan2(
                          touchInCanvas.dy - position.dy,
                          touchInCanvas.dx - position.dx,
                        );
                        setState(() {
                          _routePreviewRotation = _routePreviewLastRotation +
                              (currentAngle - _rotationStartAngle!);
                        });
                      },
                      onPanEnd: (_) {
                        setState(() {
                          _isRotationHandleDragging = false;
                          _isRouteRotating = false;
                          _rotationStartAngle = null;
                          _routePreviewLastRotation = _routePreviewRotation;
                        });
                      },
                      child: Container(
                        width: handleSize,
                        height: handleSize,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _isRouteRotating
                                ? Colors.deepOrange
                                : Colors.orange,
                            width: 2.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.rotate_right,
                          size: 18,
                          color: _isRouteRotating
                              ? Colors.deepOrange
                              : Colors.orange,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // スケールバー（左上）
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _buildScaleBar(),
            ),
          ),

          // 下書きキャンバス選択ボタン（右上）
          Positioned(
            top: 8,
            right: 8,
            child: ElevatedButton.icon(
              onPressed: _selectDraftCanvas,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(
                _draftCanvasData != null ? 'キャンバス変更' : 'キャンバス選択',
                style: const TextStyle(fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
            ),
          ),

          // 下部: 歩く開始ボタン
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startWalkingWithRoute,
                icon: const Icon(Icons.play_arrow),
                label: const Text('このルートで歩く'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  // ─── Polylines / Markers ─────────────────────────────────

  Set<Polyline> _buildPolylines() {
    Set<Polyline> polylines = {};

    if (_generatedRoute != null) {
      polylines.add(Polyline(
        polylineId: const PolylineId('generated_route'),
        points: _generatedRoute!,
        color: Colors.blue,
        width: 5,
        geodesic: true,
      ));
    }

    if (_showSketch) {
      polylines.add(Polyline(
        polylineId: const PolylineId('sketch_route'),
        points: widget.tracedPath,
        color: Colors.red.withValues(alpha: 0.5),
        width: 3,
        zIndex: -1,
      ));
    }

    return polylines;
  }

  Set<Marker> _buildMarkers() {
    return {
      Marker(
        markerId: const MarkerId('starting_point'),
        position: widget.startingPoint,
        infoWindow: const InfoWindow(title: '出発地'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      ),
      Marker(
        markerId: const MarkerId('destination'),
        position: widget.destination,
        infoWindow: const InfoWindow(title: '目的地'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    };
  }
}

// ─── ルートプレビュー用 Painter ───────────────────────────────
// PolylinePainter と同じ Web Mercator 射影を LatLng で直接使う

class RoutePreviewPainter extends CustomPainter {
  final List<LatLng> route;

  RoutePreviewPainter({required this.route});

  static double _latToMercatorY(double lat) {
    final rad = lat * math.pi / 180.0;
    return math.log(math.tan(math.pi / 4.0 + rad / 2.0));
  }

  static double _lonToMercatorX(double lon) => lon * math.pi / 180.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (route.length < 2) return;

    final coords = route
        .map((p) => MapEntry(_lonToMercatorX(p.longitude), _latToMercatorY(p.latitude)))
        .toList();

    final minX = coords.map((c) => c.key).reduce(math.min);
    final maxX = coords.map((c) => c.key).reduce(math.max);
    final minY = coords.map((c) => c.value).reduce(math.min);
    final maxY = coords.map((c) => c.value).reduce(math.max);

    final xRange = (maxX - minX) > 0 ? maxX - minX : 0.001;
    final yRange = (maxY - minY) > 0 ? maxY - minY : 0.001;

    const padding = 0.1;
    final mercatorAspect = xRange / yRange;
    final canvasAspect = size.width / size.height;

    double scaleX, scaleY;
    if (mercatorAspect > canvasAspect) {
      scaleX = size.width * (1 - padding * 2);
      scaleY = scaleX / mercatorAspect;
    } else {
      scaleY = size.height * (1 - padding * 2);
      scaleX = scaleY * mercatorAspect;
    }

    final offsetX = (size.width - scaleX) / 2;
    final offsetY = (size.height - scaleY) / 2;

    final pixels = coords.map((c) {
      final nx = (c.key - minX) / xRange;
      final ny = (c.value - minY) / yRange;
      return Offset(
        nx * scaleX + offsetX,
        size.height - (ny * scaleY + offsetY),
      );
    }).toList();

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()..moveTo(pixels.first.dx, pixels.first.dy);
    for (final pt in pixels.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(path, paint);

    // 始点（緑）・終点（赤）
    canvas.drawCircle(pixels.first, 4.0, Paint()..color = Colors.green);
    canvas.drawCircle(pixels.last, 4.0, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(RoutePreviewPainter oldDelegate) =>
      route != oldDelegate.route;
}

// ─── 下書きキャンバスオーバーレイ用 Painter ───────────────────────
// 下書きに保存された軌跡をキャンバス上の正規化位置に描画する

class DraftCanvasOverlayPainter extends CustomPainter {
  final List<Map<String, dynamic>> trajectories;
  final double scaleMultiplier;
  static const double _trajectorySize = 100.0;

  DraftCanvasOverlayPainter({
    required this.trajectories,
    this.scaleMultiplier = 1.0,
  });

  static double _latToMercatorY(double lat) {
    final rad = lat * math.pi / 180.0;
    return math.log(math.tan(math.pi / 4.0 + rad / 2.0));
  }

  static double _lonToMercatorX(double lon) => lon * math.pi / 180.0;

  @override
  void paint(Canvas canvas, Size size) {
    for (final traj in trajectories) {
      final positions = (traj['positions'] as List<dynamic>?) ?? [];
      if (positions.length < 2) continue;

      final normX = (traj['position']?['dx'] as num?)?.toDouble() ?? 0.5;
      final normY = (traj['position']?['dy'] as num?)?.toDouble() ?? 0.5;
      final savedScale = (traj['scale'] as num?)?.toDouble() ?? 1.0;
      final scale = savedScale * scaleMultiplier;
      final rotation = (traj['rotation'] as num?)?.toDouble() ?? 0.0;

      final coords = positions
          .map((p) => MapEntry(
                _lonToMercatorX((p['longitude'] as num).toDouble()),
                _latToMercatorY((p['latitude'] as num).toDouble()),
              ))
          .toList();

      final minX = coords.map((c) => c.key).reduce(math.min);
      final maxX = coords.map((c) => c.key).reduce(math.max);
      final minY = coords.map((c) => c.value).reduce(math.min);
      final maxY = coords.map((c) => c.value).reduce(math.max);

      final xRange = (maxX - minX) > 0 ? maxX - minX : 0.001;
      final yRange = (maxY - minY) > 0 ? maxY - minY : 0.001;

      const padding = 0.1;
      final mercatorAspect = xRange / yRange;

      double scaleX, scaleY;
      if (mercatorAspect > 1.0) {
        scaleX = _trajectorySize * (1 - padding * 2);
        scaleY = scaleX / mercatorAspect;
      } else {
        scaleY = _trajectorySize * (1 - padding * 2);
        scaleX = scaleY * mercatorAspect;
      }

      final drawOffsetX = (_trajectorySize - scaleX) / 2;
      final drawOffsetY = (_trajectorySize - scaleY) / 2;

      final pixels = coords.map((c) {
        final nx = (c.key - minX) / xRange;
        final ny = (c.value - minY) / yRange;
        return Offset(
          nx * scaleX + drawOffsetX,
          _trajectorySize - (ny * scaleY + drawOffsetY),
        );
      }).toList();

      canvas.save();
      canvas.translate(normX * size.width, normY * size.height);
      canvas.rotate(rotation);
      canvas.scale(scale, scale);
      canvas.translate(-_trajectorySize / 2, -_trajectorySize / 2);

      final paint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.6)
        ..strokeWidth = 2.0 / scale
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path()..moveTo(pixels.first.dx, pixels.first.dy);
      for (final pt in pixels.skip(1)) {
        path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(DraftCanvasOverlayPainter oldDelegate) => true;
}
