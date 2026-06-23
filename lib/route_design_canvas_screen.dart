import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_generation_screen.dart';

class RouteDesignCanvasScreen extends StatefulWidget {
  final Map<String, dynamic>? initialCanvasData;

  RouteDesignCanvasScreen({this.initialCanvasData});

  @override
  _RouteDesignCanvasScreenState createState() =>
      _RouteDesignCanvasScreenState();
}

class _RouteDesignCanvasScreenState extends State<RouteDesignCanvasScreen> {
  late GoogleMapController _mapController;

  // 描画データ: List<Offset> のリスト（複数ストロークを管理）
  List<List<Offset>> _strokes = [];

  // マップの初期位置
  LatLng _initialCenter = LatLng(35.6812, 139.7671); // デフォルト: 東京
  bool _isLoadingLocation = true;

  // 描画モードかどうか（trueならマップ操作無効・描画有効）
  bool _isDrawingMode = false;

  @override
  void initState() {
    super.initState();
    _initCurrentLocation();
  }

  Future<void> _initCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      );
      setState(() {
        _initialCenter = LatLng(position.latitude, position.longitude);
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingLocation = false;
      });
    }
  }

  /// キャンバスをクリア
  void _clearCanvas() {
    setState(() {
      _strokes.clear();
    });
  }

  /// 描画を確定して次のステップへ
  Future<void> _proceedToGenerationScreen() async {
    if (_strokes.isEmpty || _strokes.every((s) => s.isEmpty)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('形を描いてください')),
      );
      return;
    }

    // スクリーン座標(Offset)をLatLngに変換
    List<LatLng> tracedPath = await _convertStrokesToLatLngs();

    if (!mounted) return;

    if (tracedPath.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ルート変換に失敗しました')),
      );
      return;
    }

    // スケッチの始点・終点を出発地・目的地として使用
    final startingPoint = tracedPath.first;
    final destination = tracedPath.last;

    // ルート生成画面へナビゲート
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteGenerationScreen(
          startingPoint: startingPoint,
          destination: destination,
          tracedPath: tracedPath,
          initialCanvasData: widget.initialCanvasData,
        ),
      ),
    );

    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result);
    }
  }

  /// スクリーン座標をLatLngに変換
  Future<List<LatLng>> _convertStrokesToLatLngs() async {
    List<LatLng> allPoints = [];

    for (final stroke in _strokes) {
      for (final offset in stroke) {
        ScreenCoordinate screenCoordinate = ScreenCoordinate(
          x: offset.dx.round(),
          y: offset.dy.round(),
        );
        LatLng latLng = await _mapController.getLatLng(screenCoordinate);
        allPoints.add(latLng);
      }
    }

    return allPoints;
  }

  /// 最後のストロークを削除
  void _undoLastStroke() {
    setState(() {
      if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      }
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
          title: const Text('地図をなぞる'),
          centerTitle: true,
          elevation: 0,
        ),
        body: _isLoadingLocation
            ? Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 描画キャンバス (Map + CustomPaint)
                  Expanded(
                    child: Stack(
                      children: [
                        // Google Map
                        GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: _initialCenter,
                            zoom: 16.0,
                          ),
                          onMapCreated: (GoogleMapController controller) {
                            _mapController = controller;
                          },
                          myLocationEnabled: true,
                          myLocationButtonEnabled: true,
                          // 描画モード中はマップ操作を無効化
                          scrollGesturesEnabled: !_isDrawingMode,
                          zoomGesturesEnabled: !_isDrawingMode,
                          rotateGesturesEnabled: !_isDrawingMode,
                          tiltGesturesEnabled: !_isDrawingMode,
                        ),

                        // 描画レイヤー
                        if (_isDrawingMode)
                          GestureDetector(
                            onPanStart: (details) {
                              setState(() {
                                _strokes.add([details.localPosition]);
                              });
                            },
                            onPanUpdate: (details) {
                              setState(() {
                                if (_strokes.isNotEmpty) {
                                  _strokes.last.add(details.localPosition);
                                }
                              });
                            },
                            onPanEnd: (details) {},
                            child: Container(
                              color: Colors.transparent,
                              child: CustomPaint(
                                painter: CanvasPainter(_strokes),
                                size: Size.infinite,
                              ),
                            ),
                          )
                        else
                          IgnorePointer(
                            child: CustomPaint(
                              painter: CanvasPainter(_strokes),
                              size: Size.infinite,
                            ),
                          ),

                        // 現在モードを示すバッジ（マップ上部に常時表示）
                        Positioned(
                          top: 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: _isDrawingMode
                                    ? Colors.orange[700]
                                    : Colors.blue[700],
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _isDrawingMode
                                        ? Icons.edit
                                        : Icons.open_with,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isDrawingMode
                                        ? 'スケッチモード'
                                        : '地図移動モード',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
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

                  // 下部: 操作パネル
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    color: Colors.white,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // モード切り替えトグル
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            children: [
                              // 地図移動ボタン
                              Expanded(
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _isDrawingMode = false),
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 200),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                      color: !_isDrawingMode
                                          ? Colors.blue[700]
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.open_with,
                                          size: 18,
                                          color: !_isDrawingMode
                                              ? Colors.white
                                              : Colors.grey[600],
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '地図移動',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: !_isDrawingMode
                                                ? Colors.white
                                                : Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // スケッチボタン
                              Expanded(
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _isDrawingMode = true),
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 200),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    decoration: BoxDecoration(
                                      color: _isDrawingMode
                                          ? Colors.orange[700]
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.edit,
                                          size: 18,
                                          color: _isDrawingMode
                                              ? Colors.white
                                              : Colors.grey[600],
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'スケッチ',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: _isDrawingMode
                                                ? Colors.white
                                                : Colors.grey[600],
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
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            // 全削除ボタン
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _clearCanvas,
                                icon: const Icon(Icons.delete_sweep),
                                label: const Text('全削除'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey[400],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 1つ戻るボタン
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _undoLastStroke,
                                icon: const Icon(Icons.undo),
                                label: const Text('戻る'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange[400],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 決定ボタン
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _proceedToGenerationScreen,
                                icon: const Icon(Icons.arrow_forward),
                                label: const Text('決定'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// キャンバス描画用 CustomPainter
class CanvasPainter extends CustomPainter {
  final List<List<Offset>> strokes;

  CanvasPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    for (int strokeIndex = 0; strokeIndex < strokes.length; strokeIndex++) {
      final stroke = strokes[strokeIndex];
      if (stroke.isEmpty) continue;

      final linePaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      for (int i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(stroke[i], stroke[i + 1], linePaint);
      }

      // 全ストロークの中の最初の点（出発地）と最後の点（目的地）を強調
      final isFirstStroke = strokeIndex == 0;
      final isLastStroke = strokeIndex == strokes.length - 1;

      if (isFirstStroke) {
        final startPaint = Paint()
          ..color = Colors.green
          ..strokeWidth = 2.0;
        canvas.drawCircle(stroke.first, 7.0, startPaint);
      }

      if (isLastStroke) {
        final endPaint = Paint()
          ..color = Colors.red
          ..strokeWidth = 2.0;
        canvas.drawCircle(stroke.last, 7.0, endPaint);
      }
    }
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) {
    return true;
  }
}
