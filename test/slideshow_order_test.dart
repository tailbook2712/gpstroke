import 'package:flutter_test/flutter_test.dart';
import 'package:walk_tracker_app/utils/slideshow_order.dart';

void main() {
  group('orderByRecordTime', () {
    test('記録日時の古い順に並べ、日時不明は末尾に回す', () {
      final order = orderByRecordTime([
        DateTime(2026, 3, 1),
        null,
        DateTime(2026, 1, 1),
        DateTime(2026, 2, 1),
      ]);
      expect(order, [2, 3, 0, 1]);
    });
  });

  group('orderByDistanceDesc', () {
    test('距離の長い順に並べ、同じ距離は元の並びを保つ', () {
      final order = orderByDistanceDesc([1.2, 3.5, 1.2, 0.4, 3.5]);
      expect(order, [1, 4, 0, 2, 3]);
    });
  });

  group('orderByPlacement', () {
    test('配置日時の古い順に並べる（レイヤー順に左右されない）', () {
      final order = orderByPlacement([
        DateTime(2026, 11, 25, 10, 2),
        DateTime(2026, 11, 25, 10, 0),
        DateTime(2026, 11, 25, 10, 1),
      ]);
      expect(order, [1, 2, 0]);
    });

    test('配置日時の無い古い軌跡は先頭に、ファイル内の並びのまま置く', () {
      final order = orderByPlacement([
        DateTime(2026, 11, 25, 10, 0),
        null,
        null,
      ]);
      expect(order, [1, 2, 0]);
    });
  });

  test('保存された名前から設定を復元し、不明な値は既定値にする', () {
    expect(SlideshowOrder.fromName('distance'), SlideshowOrder.distance);
    expect(SlideshowOrder.fromName(null), SlideshowOrder.recorded);
    expect(SlideshowStyle.fromName('reveal'), SlideshowStyle.reveal);
    expect(SlideshowStyle.fromName('unknown'), SlideshowStyle.highlight);
  });
}
