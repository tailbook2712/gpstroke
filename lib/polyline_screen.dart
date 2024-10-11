import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'polyline_painter.dart'; // PolylinePainterをインポート

class PolylineScreen extends StatelessWidget {
  final List<Position> positions;

  PolylineScreen({required this.positions});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('歩行軌跡のポリライン'),
      ),
      body: Center(
        child: CustomPaint(
          size: Size(MediaQuery.of(context).size.width, MediaQuery.of(context).size.height), // 画面サイズを指定
          painter: PolylinePainter(positions: positions), // ポリライン描画
        ),
      ),
    );
  }
}