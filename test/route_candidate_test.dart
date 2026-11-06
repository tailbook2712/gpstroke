import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/route_service.dart';

void main() {
  const origin = LatLng(41.8418, 140.7669); // 函館
  const metersPerDegreeLat = 111320.0;

  group('RouteService.rotatePathAroundStart', () {
    test('始点は動かず、反時計回り90°で東の点が北に移る', () {
      // 始点から東へ約 1000m の点
      final east = LatLng(
        origin.latitude,
        origin.longitude + 1000 / (metersPerDegreeLat * 0.7450),
      );
      final rotated = RouteService.rotatePathAroundStart([origin, east], 90);

      expect(rotated.first, origin);
      expect(rotated[1].latitude, greaterThan(origin.latitude));
      expect(rotated[1].longitude, closeTo(origin.longitude, 1e-6));
      // 回転しても始点からの距離は変わらない
      expect(
        RouteService.calculateDistance(origin, rotated[1]),
        closeTo(RouteService.calculateDistance(origin, east), 2),
      );
    });

    test('時計回り（負の角度）では東の点が南に移る', () {
      final east = LatLng(origin.latitude, origin.longitude + 0.01);
      final rotated = RouteService.rotatePathAroundStart([origin, east], -90);
      expect(rotated[1].latitude, lessThan(origin.latitude));
    });
  });

  group('RouteService.calculateShapeMatchScore', () {
    // 一辺約 500m の正方形
    final square = [
      origin,
      LatLng(origin.latitude + 0.0045, origin.longitude),
      LatLng(origin.latitude + 0.0045, origin.longitude + 0.006),
      LatLng(origin.latitude, origin.longitude + 0.006),
      origin,
    ];

    test('同じ形なら 100%', () {
      expect(RouteService.calculateShapeMatchScore(square, square),
          closeTo(1.0, 1e-9));
    });

    test('ずれが大きいほど一致度が下がる', () {
      List<LatLng> shifted(double dLat) => square
          .map((p) => LatLng(p.latitude + dLat, p.longitude))
          .toList();
      final near = RouteService.calculateShapeMatchScore(
          square, shifted(0.0002)); // 約 22m
      final far = RouteService.calculateShapeMatchScore(
          square, shifted(0.0008)); // 約 89m
      expect(near, lessThan(1.0));
      expect(far, lessThan(near));
    });
  });
}
