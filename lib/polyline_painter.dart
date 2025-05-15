import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;

class PolylinePainter extends CustomPainter {
  final List<Position> positions;
  final double minLat, maxLat, minLon, maxLon;
  final Color color;
  final bool preserveAspectRatio; // アスペクト比を保持するかどうかのフラグを追加
  final double strokeWidth; // 線の太さを調整するためのパラメータを追加

  PolylinePainter({
    required this.positions,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    this.color = Colors.blue,
    this.preserveAspectRatio = true, // デフォルトでアスペクト比を保持する
    this.strokeWidth = 4.0, // デフォルトの線の太さ
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    // 緯度・経度の範囲を計算
    final latRange = (maxLat - minLat).abs() > 0 ? maxLat - minLat : 1.0;
    final lonRange = (maxLon - minLon).abs() > 0 ? maxLon - minLon : 1.0;

    // 中心座標を基準とした変換
    final centerLat = (maxLat + minLat) / 2;
    final centerLon = (maxLon + minLon) / 2;

    // アスペクト比を保持するためのスケーリング係数を計算
    double scaleX, scaleY;
    double padding = 0.1; // 10%のパディングを追加
    
    if (preserveAspectRatio) {
      // 緯度と経度の地球上での比率を考慮（経度1度は緯度に応じて距離が変わる）
      // 簡易的にコサイン補正を適用（緯度に応じて経度の縮尺を調整）
      double latCosCorrection = math.cos(centerLat * math.pi / 180.0);
      
      // 緯度と経度のレンジをキャンバスサイズに合わせて調整
      double correctedLonRange = lonRange * latCosCorrection;
      
      // キャンバスのアスペクト比
      double canvasAspect = size.width / size.height;
      
      // データのアスペクト比（経度/緯度）
      double dataAspect = correctedLonRange / latRange;
      
      if (dataAspect > canvasAspect) {
        // データが横長の場合は幅に合わせる
        scaleX = size.width * (1 - padding * 2);
        scaleY = (size.width / dataAspect) * (1 - padding * 2);
      } else {
        // データが縦長の場合は高さに合わせる
        scaleY = size.height * (1 - padding * 2);
        scaleX = (size.height * dataAspect) * (1 - padding * 2);
      }
    } else {
      // 従来の方法（アスペクト比を保持しない）
      scaleX = size.width * (1 - padding * 2);
      scaleY = size.height * (1 - padding * 2);
    }

    // 座標変換とパス描画
    final List<Offset> scaledPoints = positions.map((position) {
      // 正規化座標（0〜1の範囲）
      double normalizedX = (position.longitude - minLon) / lonRange;
      double normalizedY = (position.latitude - minLat) / latRange;
      
      // キャンバス座標に変換（Y軸は上下反転）
      double x = normalizedX * scaleX + (size.width - scaleX) / 2;
      double y = size.height - (normalizedY * scaleY + (size.height - scaleY) / 2);
      
      return Offset(x, y);
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
    if (oldDelegate is PolylinePainter) {
      return color != oldDelegate.color || 
             preserveAspectRatio != oldDelegate.preserveAspectRatio ||
             strokeWidth != oldDelegate.strokeWidth ||
             positions != oldDelegate.positions;
    }
    return true;
  }
}