import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class PolylinePainter extends CustomPainter {
  final List<Position> positions;
  final double minLat, maxLat, minLon, maxLon;
  final Color color;

  PolylinePainter({
    required this.positions,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    this.color = Colors.blue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    // 緯度・経度をスケール変換するための範囲
    double latRange = maxLat - minLat == 0 ? 1 : maxLat - minLat; // 0除算を避ける
    double lonRange = maxLon - minLon == 0 ? 1 : maxLon - minLon;

    // 座標リストを画面上に描画できる座標に変換
    List<Offset> scaledPoints = [];
    Position? previousPosition;

    for (var position in positions) {
      // 直前の位置と現在位置が異なる場合のみ追加（重複除外）
      if (previousPosition == null ||
          previousPosition.latitude != position.latitude ||
          previousPosition.longitude != position.longitude) {
        double x = (position.longitude - minLon) / lonRange * size.width;
        double y = (position.latitude - minLat) / latRange * size.height;
        scaledPoints.add(Offset(x, size.height - y)); // Y座標の逆転
      }
      previousPosition = position;
    }

    // ポリラインを描画（閉じない）
    if (scaledPoints.length > 1) {
      Path path = Path();
      path.moveTo(scaledPoints.first.dx, scaledPoints.first.dy);
      for (var i = 1; i < scaledPoints.length; i++) {
        path.lineTo(scaledPoints[i].dx, scaledPoints[i].dy);
      }
      // 終点と始点を結ばないようにする（path.close()は使用しない）
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true; // データが変更された場合に再描画
  }
}
