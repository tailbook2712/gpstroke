import 'package:flutter_test/flutter_test.dart';
import 'package:walk_tracker_app/utils/polyline_codec.dart';

void main() {
  group('encodePolyline / decodePolyline', () {
    test('Google の仕様書にある例と一致する', () {
      // https://developers.google.com/maps/documentation/utilities/polylinealgorithm
      final points = [
        {'latitude': 38.5, 'longitude': -120.2},
        {'latitude': 40.7, 'longitude': -120.95},
        {'latitude': 43.252, 'longitude': -126.453},
      ];
      expect(encodePolyline(points), '_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    });

    test('エンコード→デコードで元の座標に戻る（小数点以下 5 桁）', () {
      final points = [
        {'latitude': 35.68123, 'longitude': 139.76712},
        {'latitude': 35.68130, 'longitude': 139.76700},
        {'latitude': 35.68099, 'longitude': 139.76655},
        {'latitude': -33.86882, 'longitude': 151.20930},
      ];
      final decoded = decodePolyline(encodePolyline(points));
      expect(decoded.length, points.length);
      for (int i = 0; i < points.length; i++) {
        expect(decoded[i]['latitude'], closeTo(points[i]['latitude']!, 1e-9));
        expect(
            decoded[i]['longitude'], closeTo(points[i]['longitude']!, 1e-9));
      }
    });

    test('空のリストは空文字列になる', () {
      expect(encodePolyline([]), '');
      expect(decodePolyline(''), isEmpty);
    });

    test('余分な精度は丸められる', () {
      final decoded = decodePolyline(encodePolyline([
        {'latitude': 35.123456789, 'longitude': 139.987654321},
      ]));
      expect(decoded.single['latitude'], closeTo(35.12346, 1e-9));
      expect(decoded.single['longitude'], closeTo(139.98765, 1e-9));
    });
  });
}
