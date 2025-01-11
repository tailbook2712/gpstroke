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

    // 緯度・経度の範囲を計算
    final latRange = (maxLat - minLat).abs() > 0 ? maxLat - minLat : 1.0;
    final lonRange = (maxLon - minLon).abs() > 0 ? maxLon - minLon : 1.0;

    // 中心座標を基準とした変換
    final centerLat = (maxLat + minLat) / 2;
    final centerLon = (maxLon + minLon) / 2;

    // 座標を中心基準で画面上にスケーリング
    final List<Offset> scaledPoints = positions.map((position) {
      final dx = (position.longitude - centerLon) / lonRange * size.width;
      final dy = (position.latitude - centerLat) / latRange * size.height;
      return Offset(dx + size.width / 2, size.height / 2 - dy); // 中心補正
    }).toList();

    // ポリラインを描画
    if (scaledPoints.length > 1) {
      final path = Path()..moveTo(scaledPoints.first.dx, scaledPoints.first.dy);
      for (final point in scaledPoints.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true; // データ変更時に再描画
  }
}