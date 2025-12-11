import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_generation_screen.dart';

class RouteDesignCanvasScreen extends StatefulWidget {
  final LatLng startingPoint;
  final LatLng destination;

  RouteDesignCanvasScreen({
    required this.startingPoint,
    required this.destination,
  });

  @override
  _RouteDesignCanvasScreenState createState() =>
      _RouteDesignCanvasScreenState();
}

class _RouteDesignCanvasScreenState extends State<RouteDesignCanvasScreen> {
  late GoogleMapController _mapController;

  // 描画データ: List<Offset> のリスト（複数ストロークを管理）
  List<List<Offset>> _strokes = [];

  // マップの初期位置計算用
  late LatLng _initialCenter;
  late double _initialZoom;

  // 描画モードかどうか（trueならマップ操作無効・描画有効）
  bool _isDrawingMode = true;

  @override
  void initState() {
    super.initState();
    _calculateInitialMapState();
  }

  /// 出発地と目的地から初期マップ表示位置を計算
  void _calculateInitialMapState() {
    double lat =
        (widget.startingPoint.latitude + widget.destination.latitude) / 2;
    double lng =
        (widget.startingPoint.longitude + widget.destination.longitude) / 2;
    _initialCenter = LatLng(lat, lng);
    _initialZoom = 14.0; // 適当なズームレベル
  }

  /// キャンバスをクリア
  void _clearCanvas() {
    setState(() {
      _strokes.clear();
    });
  }

  /// 描画を確定して次のステップへ
  Future<void> _proceedToGenerationScreen() async {
    if (_strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('形を描いてください')),
      );
      return;
    }

    // スクリーン座標(Offset)をLatLngに変換
    List<LatLng> tracedPath = await _convertStrokesToLatLngs();

    if (tracedPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ルート変換に失敗しました')),
      );
      return;
    }

    // ルート生成画面へナビゲート
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteGenerationScreen(
          startingPoint: widget.startingPoint,
          destination: widget.destination,
          tracedPath: tracedPath, // 変換後のパスを渡す
        ),
      ),
    );

    if (result != null) {
      Navigator.pop(context, result);
    }
  }

  /// スクリーン座標をLatLngに変換
  Future<List<LatLng>> _convertStrokesToLatLngs() async {
    List<LatLng> allPoints = [];

    // 画面のピクセル比率を取得（Retinaディスプレイ対応など）
    // GoogleMapController.getLatLng は論理ピクセル(Offset)を受け取るはずだが、
    // 実装によってはデバイスピクセル比を考慮する必要がある場合がある。
    // 通常、FlutterのOffsetは論理ピクセルなのでそのままで良いはず。

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
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('地図をなぞる'),
          centerTitle: true,
          elevation: 0,
          actions: [
            // 描画モード切り替えボタン
            IconButton(
              icon: Icon(_isDrawingMode ? Icons.map : Icons.edit),
              onPressed: () {
                setState(() {
                  _isDrawingMode = !_isDrawingMode;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_isDrawingMode
                        ? '描画モード: 地図をなぞってください'
                        : 'マップ操作モード: 地図を動かせます'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // 描画キャンバス (Map + CustomPaint)
            Expanded(
              child: Stack(
                children: [
                  // Google Map
                  GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _initialCenter,
                      zoom: _initialZoom,
                    ),
                    onMapCreated: (GoogleMapController controller) {
                      _mapController = controller;
                    },
                    markers: {
                      Marker(
                        markerId: MarkerId('start'),
                        position: widget.startingPoint,
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueBlue),
                      ),
                      Marker(
                        markerId: MarkerId('dest'),
                        position: widget.destination,
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueRed),
                      ),
                    },
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
                      onPanEnd: (details) {
                        // ストローク終了
                      },
                      child: Container(
                        color: Colors.transparent, // タッチイベントを受け取るために透明
                        child: CustomPaint(
                          painter: CanvasPainter(_strokes),
                          size: Size.infinite,
                        ),
                      ),
                    )
                  else
                    // マップ操作モードでも描画内容は表示し続ける（タッチは透過）
                    IgnorePointer(
                      child: CustomPaint(
                        painter: CanvasPainter(_strokes),
                        size: Size.infinite,
                      ),
                    ),
                ],
              ),
            ),

            // 下部: 操作ボタン
            Container(
              padding: EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // 削除ボタン（全削除）
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _clearCanvas,
                          icon: Icon(Icons.delete_sweep),
                          label: Text('全削除'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey[400],
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      // 戻るボタン（最後のストロークを削除）
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _undoLastStroke,
                          icon: Icon(Icons.undo),
                          label: Text('戻る'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange[400],
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      // 決定ボタン
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _proceedToGenerationScreen,
                          icon: Icon(Icons.arrow_forward),
                          label: Text('決定'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    _isDrawingMode
                        ? '地図をなぞってルートを描いてください（右上のボタンでマップ移動切替）'
                        : '地図を動かして位置を調整してください（右上のボタンで描画再開）',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
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
    // ストロークを描画
    for (int strokeIndex = 0; strokeIndex < strokes.length; strokeIndex++) {
      final stroke = strokes[strokeIndex];
      if (stroke.isEmpty) continue;

      // ストロークの線を描画
      final linePaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 4.0 // 少し太く
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      for (int i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(stroke[i], stroke[i + 1], linePaint);
      }

      // 開始点と終了点を強調表示
      if (stroke.isNotEmpty) {
        // 開始点（緑）
        final startPaint = Paint()
          ..color = Colors.green
          ..strokeWidth = 2.0;
        canvas.drawCircle(stroke.first, 5.0, startPaint);

        // 終了点（赤）
        final endPaint = Paint()
          ..color = Colors.red
          ..strokeWidth = 2.0;
        canvas.drawCircle(stroke.last, 5.0, endPaint);
      }
    }
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) {
    return true;
  }
}
