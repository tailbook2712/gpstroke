import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/route_service.dart';

void main() {
  group('RouteService.convertCanvasSketchToLatLngs', () {
    const origin = LatLng(41.8418, 140.7669); // 函館

    test('スケッチの始点が現在地になる', () {
      final path = RouteService.convertCanvasSketchToLatLngs(
        const [Offset(120, 300), Offset(200, 300)],
        origin,
        10.0,
      );
      expect(path.first.latitude, closeTo(origin.latitude, 1e-12));
      expect(path.first.longitude, closeTo(origin.longitude, 1e-12));
    });

    test('スケールバーの縮尺で実寸に換算される', () {
      // 100px × 10m/px = 1000m 東へ
      final path = RouteService.convertCanvasSketchToLatLngs(
        const [Offset(0, 0), Offset(100, 0)],
        origin,
        10.0,
      );
      final meters = RouteService.calculateDistance(path[0], path[1]);
      expect(meters, closeTo(1000, 5));
      expect(path[1].longitude, greaterThan(origin.longitude));
      expect(path[1].latitude, closeTo(origin.latitude, 1e-9));
    });

    test('キャンバスの上方向が北になる', () {
      final path = RouteService.convertCanvasSketchToLatLngs(
        const [Offset(50, 200), Offset(50, 100)],
        origin,
        5.0,
      );
      expect(path[1].latitude, greaterThan(origin.latitude));
      expect(RouteService.calculateDistance(path[0], path[1]),
          closeTo(500, 3));
    });

    test('空のスケッチは空リストを返す', () {
      expect(
        RouteService.convertCanvasSketchToLatLngs(const [], origin, 10.0),
        isEmpty,
      );
    });
  });
}
