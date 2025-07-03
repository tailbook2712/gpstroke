import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;

class PolylinePainter extends CustomPainter {
  final List<Position> positions;
  final double minLat, maxLat, minLon, maxLon;
  final Color color;
  final bool preserveAspectRatio;
  final double strokeWidth;

  PolylinePainter({
    required this.positions,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    this.color = Colors.blue,
    this.preserveAspectRatio = true,
    this.strokeWidth = 4.0,
  });

  // Web Mercator投影: 緯度をY座標に変換（Google Maps互換）
  static double latitudeToWebMercatorY(double latitude) {
    // 緯度をラジアンに変換
    double latRad = latitude * math.pi / 180.0;
    // Web Mercator投影（Google Maps準拠）
    return math.log(math.tan(math.pi / 4.0 + latRad / 2.0));
  }

  // Web Mercator投影: 経度をX座標に変換（Google Maps互換）
  static double longitudeToWebMercatorX(double longitude) {
    // 経度をラジアンに変換してそのまま返す
    return longitude * math.pi / 180.0;
  }

  // Web Mercator逆投影: Y座標を緯度に変換
  static double webMercatorYToLatitude(double mercatorY) {
    double latRad = 2 * (math.atan(math.exp(mercatorY)) - math.pi / 4);
    return latRad * 180.0 / math.pi;
  }

  // Web Mercator逆投影: X座標を経度に変換
  static double webMercatorXToLongitude(double mercatorX) {
    return mercatorX * 180.0 / math.pi;
  }

  // Web Mercator投影を使用した座標変換（Google Maps完全互換版）
  List<Offset> _convertToWebMercatorPixels(Size size) {
    if (positions.isEmpty) return [];

    // 全ての位置をWeb Mercator座標に変換
    List<MapEntry<double, double>> mercatorCoords = positions.map((pos) {
      return MapEntry(
        longitudeToWebMercatorX(pos.longitude),
        latitudeToWebMercatorY(pos.latitude),
      );
    }).toList();

    // Web Mercator座標の境界を計算
    double minMercatorX = mercatorCoords.map((c) => c.key).reduce(math.min);
    double maxMercatorX = mercatorCoords.map((c) => c.key).reduce(math.max);
    double minMercatorY = mercatorCoords.map((c) => c.value).reduce(math.min);
    double maxMercatorY = mercatorCoords.map((c) => c.value).reduce(math.max);

    // 範囲を計算（0の場合は最小値を設定）
    double mercatorXRange = (maxMercatorX - minMercatorX).abs() > 0
        ? maxMercatorX - minMercatorX
        : 0.001;
    double mercatorYRange = (maxMercatorY - minMercatorY).abs() > 0
        ? maxMercatorY - minMercatorY
        : 0.001;

    // アスペクト比を保持するためのスケーリング係数を計算
    double scaleX, scaleY;
    double padding = 0.1; // 10%のパディング

    if (preserveAspectRatio) {
      // Web Mercator座標でのアスペクト比を正確に計算
      double mercatorAspect = mercatorXRange / mercatorYRange;
      double canvasAspect = size.width / size.height;

      if (mercatorAspect > canvasAspect) {
        // データが横長：幅を基準にする
        scaleX = size.width * (1 - padding * 2);
        scaleY = scaleX / mercatorAspect;
      } else {
        // データが縦長：高さを基準にする
        scaleY = size.height * (1 - padding * 2);
        scaleX = scaleY * mercatorAspect;
      }
    } else {
      scaleX = size.width * (1 - padding * 2);
      scaleY = size.height * (1 - padding * 2);
    }

    // 描画オフセットを計算（キャンバス中央に配置）
    double drawingOffsetX = (size.width - scaleX) / 2;
    double drawingOffsetY = (size.height - scaleY) / 2;

    // Web Mercator座標をピクセル座標に変換
    return mercatorCoords.map((coord) {
      // 正規化座標（0〜1の範囲）
      double normalizedX = (coord.key - minMercatorX) / mercatorXRange;
      double normalizedY = (coord.value - minMercatorY) / mercatorYRange;

      // ピクセル座標に変換（Y軸は上下反転）
      double x = normalizedX * scaleX + drawingOffsetX;
      double y = size.height - (normalizedY * scaleY + drawingOffsetY);

      return Offset(x, y);
    }).toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    // Web Mercator投影を使用して座標を変換
    final List<Offset> pixelPoints = _convertToWebMercatorPixels(size);

    // ポリラインを描画
    if (pixelPoints.length > 1) {
      final path = Path()..moveTo(pixelPoints.first.dx, pixelPoints.first.dy);
      for (final point in pixelPoints.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  // 描画パラメータを取得するメソッド（Google Maps完全互換版）
  Map<String, dynamic> getDrawingParameters(Size size) {
    if (positions.isEmpty) return {};

    // Web Mercator座標に変換
    List<MapEntry<double, double>> mercatorCoords = positions.map((pos) {
      return MapEntry(
        longitudeToWebMercatorX(pos.longitude),
        latitudeToWebMercatorY(pos.latitude),
      );
    }).toList();

    // Web Mercator座標の境界を計算
    double minMercatorX = mercatorCoords.map((c) => c.key).reduce(math.min);
    double maxMercatorX = mercatorCoords.map((c) => c.key).reduce(math.max);
    double minMercatorY = mercatorCoords.map((c) => c.value).reduce(math.min);
    double maxMercatorY = mercatorCoords.map((c) => c.value).reduce(math.max);

    double mercatorXRange = (maxMercatorX - minMercatorX).abs() > 0
        ? maxMercatorX - minMercatorX
        : 0.001;
    double mercatorYRange = (maxMercatorY - minMercatorY).abs() > 0
        ? maxMercatorY - minMercatorY
        : 0.001;

    // 実際のデータ重心を計算（算術平均）
    double totalMercatorX = 0;
    double totalMercatorY = 0;
    for (final coord in mercatorCoords) {
      totalMercatorX += coord.key;
      totalMercatorY += coord.value;
    }
    final dataCentroidMercatorX = totalMercatorX / mercatorCoords.length;
    final dataCentroidMercatorY = totalMercatorY / mercatorCoords.length;

    // データ重心の地理座標を逆変換
    final dataCentroidLat = webMercatorYToLatitude(dataCentroidMercatorY);
    final dataCentroidLon = webMercatorXToLongitude(dataCentroidMercatorX);

    // 境界ボックスの中心座標（従来通り）
    final centerLat = (maxLat + minLat) / 2;
    final centerLon = (maxLon + minLon) / 2;
    final mercatorCenterX = (minMercatorX + maxMercatorX) / 2;
    final mercatorCenterY = (minMercatorY + maxMercatorY) / 2;

    // アスペクト比を保持するためのスケーリング係数を計算
    double scaleX, scaleY;
    double padding = 0.1;

    if (preserveAspectRatio) {
      double mercatorAspect = mercatorXRange / mercatorYRange;
      double canvasAspect = size.width / size.height;

      if (mercatorAspect > canvasAspect) {
        // データが横長：幅を基準にする
        scaleX = size.width * (1 - padding * 2);
        scaleY = scaleX / mercatorAspect;
      } else {
        // データが縦長：高さを基準にする
        scaleY = size.height * (1 - padding * 2);
        scaleX = scaleY * mercatorAspect;
      }
    } else {
      scaleX = size.width * (1 - padding * 2);
      scaleY = size.height * (1 - padding * 2);
    }

    // 実際の描画領域の計算
    double drawingOffsetX = (size.width - scaleX) / 2;
    double drawingOffsetY = (size.height - scaleY) / 2;

    // データ重心の描画コンテナ内での位置を計算
    double centroidNormalizedX =
        (dataCentroidMercatorX - minMercatorX) / mercatorXRange;
    double centroidNormalizedY =
        (dataCentroidMercatorY - minMercatorY) / mercatorYRange;

    // ピクセル座標での重心位置（描画エリア内）
    double centroidPixelX = centroidNormalizedX * scaleX + drawingOffsetX;
    double centroidPixelY =
        size.height - (centroidNormalizedY * scaleY + drawingOffsetY);

    return {
      'scaleX': scaleX,
      'scaleY': scaleY,
      'drawingOffsetX': drawingOffsetX,
      'drawingOffsetY': drawingOffsetY,
      'centerLat': centerLat,
      'centerLon': centerLon,
      'dataCentroidLat': dataCentroidLat,
      'dataCentroidLon': dataCentroidLon,
      'dataCentroidMercatorX': dataCentroidMercatorX,
      'dataCentroidMercatorY': dataCentroidMercatorY,
      'centroidPixelX': centroidPixelX,
      'centroidPixelY': centroidPixelY,
      'latRange': maxLat - minLat,
      'lonRange': maxLon - minLon,
      'mercatorXRange': mercatorXRange,
      'mercatorYRange': mercatorYRange,
      'mercatorCenterX': mercatorCenterX,
      'mercatorCenterY': mercatorCenterY,
      'minMercatorX': minMercatorX,
      'maxMercatorX': maxMercatorX,
      'minMercatorY': minMercatorY,
      'maxMercatorY': maxMercatorY,
      'padding': padding,
      'dataAspect': mercatorXRange / mercatorYRange,
    };
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