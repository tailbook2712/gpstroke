import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'polyline_painter.dart'; // PolylinePainterをインポート

class PolylineScreen extends StatelessWidget {
  final List<Position> positions;

  PolylineScreen({required this.positions});

  @override
  Widget build(BuildContext context) {
    // 位置座標の最小・最大値を計算して範囲を決定
    double minLat = positions.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    double maxLat = positions.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    double minLon = positions.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    double maxLon = positions.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    return Scaffold(
      appBar: AppBar(
        title: Text('歩行軌跡のポリライン'),
      ),
      body: Center(
        child: CustomPaint(
          size: Size(MediaQuery.of(context).size.width, MediaQuery.of(context).size.height),
          painter: PolylinePainter(
            positions: positions,
            minLat: minLat,
            maxLat: maxLat,
            minLon: minLon,
            maxLon: maxLon,
          ),
        ),
      ),
    );
  }
}