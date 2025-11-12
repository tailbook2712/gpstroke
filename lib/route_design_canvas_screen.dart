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
  // 描画データ: List<Offset> のリスト（複数ストロークを管理）
  List<List<Offset>> _strokes = [];

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

    // ルート生成画面へナビゲート（距離選択をスキップ）
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteGenerationScreen(
          startingPoint: widget.startingPoint,
          destination: widget.destination,
          designShape: _strokes,
        ),
      ),
    );

    if (result != null) {
      // ルート生成結果が返ってくる
      Navigator.pop(context, result);
    }
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
          title: Text('形を描く'),
          centerTitle: true,
          elevation: 0,
        ),
        body: Column(
          children: [
            // 描画キャンバス
            Expanded(
              child: GestureDetector(
                onPanStart: (details) {
                  setState(() {
                    // 新しいストロークを開始
                    _strokes.add([details.localPosition]);
                  });
                },
                onPanUpdate: (details) {
                  setState(() {
                    // 現在のストロークにポイントを追加
                    if (_strokes.isNotEmpty) {
                      _strokes.last.add(details.localPosition);
                    }
                  });
                },
                onPanEnd: (details) {
                  // ストローク終了
                },
                child: Container(
                  color: Colors.white,
                  child: CustomPaint(
                    painter: CanvasPainter(_strokes),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),

            // 下部: 操作ボタン
            Container(
              padding: EdgeInsets.all(16),
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
                    '※ キャンバス上の線は実際のルート生成の参考になります',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                    ),
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
    // 背景グリッドを描画（オプション）
    _drawGrid(canvas, size);

    // ストロークを描画
    for (int strokeIndex = 0; strokeIndex < strokes.length; strokeIndex++) {
      final stroke = strokes[strokeIndex];
      if (stroke.isEmpty) continue;

      // ストロークの線を描画
      final linePaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      for (int i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(stroke[i], stroke[i + 1], linePaint);
      }

      // ポイントを描画（リアルタイム軌跡の視認性向上）
      final pointPaint = Paint()
        ..color = Colors.blue.withOpacity(0.7)
        ..strokeWidth = 1.5;

      for (int i = 0; i < stroke.length; i++) {
        final radius = (i == 0 || i == stroke.length - 1) ? 4.0 : 2.0;
        canvas.drawCircle(stroke[i], radius, pointPaint);
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

    // ストロークカウントを描画
    _drawStrokeCount(canvas, size);
  }

  /// グリッドを描画
  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.1)
      ..strokeWidth = 0.5;

    const gridSize = 20.0;

    // 縦線
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    // 横線
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  /// ストロークカウントを描画
  void _drawStrokeCount(Canvas canvas, Size size) {
    final completedStrokes = strokes.where((s) => s.isNotEmpty).length;
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'ストローク: $completedStrokes',
        style: TextStyle(
          color: Colors.grey[700],
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(size.width - textPainter.width - 12, 12),
    );
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) {
    // 常に再描画（状態が変わる度に描画）
    return true;
  }
}
