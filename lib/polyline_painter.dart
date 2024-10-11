import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class PolylinePainter extends CustomPainter {
  final List<Position> positions;
  final double minLat, maxLat, minLon, maxLon; // 指定範囲を追加

  PolylinePainter({required this.positions, required this.minLat, required this.maxLat, required this.minLon, required this.maxLon});

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.isEmpty) return;

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    // 緯度・経度をスケール変換するための範囲
    double latRange = maxLat - minLat == 0 ? 1 : maxLat - minLat; // 0除算を避ける
    double lonRange = maxLon - minLon == 0 ? 1 : maxLon - minLon;

    // 座標リストを画面上に描画できる座標に変換
    List<Offset> scaledPoints = positions.map((position) {
      double x = (position.longitude - minLon) / lonRange * size.width;
      double y = (position.latitude - minLat) / latRange * size.height;
      return Offset(x, size.height - y); // y座標を反転して描画
    }).toList();

    // ポリラインを描画
    for (int i = 0; i < scaledPoints.length - 1; i++) {
      canvas.drawLine(scaledPoints[i], scaledPoints[i + 1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true; // データが変更された場合に再描画
  }
}