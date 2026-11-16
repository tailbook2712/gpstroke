import 'package:flutter_test/flutter_test.dart';
import 'package:walk_tracker_app/utils/canvas_scale.dart';

void main() {
  group('CanvasScale 換算', () {
    test('スケールバー80pxが表す距離から1pxあたりの実距離を求める', () {
      expect(CanvasScale.metersPerPixel(500), closeTo(6.25, 1e-9));
      expect(CanvasScale.metersPerPixel(80), closeTo(1.0, 1e-9));
    });

    test('緯度経度の範囲から差し渡しを求める（長い方の辺）', () {
      // 緯度0.01度 ≒ 1113.2m、経度0.001度は函館付近で約83m
      final extent = CanvasScale.extentMeters(
        minLat: 41.84,
        maxLat: 41.85,
        minLon: 140.766,
        maxLon: 140.767,
      );
      expect(extent, closeTo(1113.2, 0.1));
    });

    test('キャンバス上で軌跡を描く枠は、余白の分だけ差し渡しより大きい', () {
      // 500m スケール: 1000m は 160px → 枠は 160 / 0.8 = 200px
      expect(CanvasScale.boxPixels(1000, 500), closeTo(200, 1e-9));
      // 1点だけの軌跡は既定の大きさの枠で描く
      expect(CanvasScale.boxPixels(0, 500), 100);
      expect(CanvasScale.boxPixels(0, 500, fallback: 80), 80);
    });

    test('軌跡の差し渡しをキャンバス上のピクセルに換算する', () {
      // 500m スケール: 6.25 m/px → 1000m は 160px
      expect(CanvasScale.displayPixels(1000, 500), closeTo(160, 1e-9));
    });
  });

  group('CanvasScale 軌跡を素材として使えるかの判定', () {
    test('差し渡しが短辺以下なら収まる、超えたら大きすぎる', () {
      // 500m スケール・短辺 400px → キャンバスの短辺は 2500m
      expect(CanvasScale.fitsCanvas(2500, 500, 400), isTrue);
      expect(CanvasScale.fitsCanvas(2501, 500, 400), isFalse);
      expect(CanvasScale.classify(2500, 500, 400), TrajectoryFit.usable);
      expect(CanvasScale.classify(2501, 500, 400), TrajectoryFit.tooLarge);
    });

    test('表示が小さすぎて形が分からない軌跡は使えない', () {
      // 500m スケール: 6.25 m/px → 24px は 150m
      expect(CanvasScale.classify(150, 500, 400), TrajectoryFit.usable);
      expect(CanvasScale.classify(149, 500, 400), TrajectoryFit.tooSmall);
      expect(CanvasScale.classify(0, 500, 400), TrajectoryFit.tooSmall);
    });

    test('スケールを変えると、使える軌跡が入れ替わる', () {
      const extents = [300.0, 1200.0, 6000.0];
      Map<TrajectoryFit, int> count(double scale) =>
          CanvasScale.countByFit(extents, scale, 400);

      // 50m（短辺 250m）: どれも大きすぎる
      expect(count(50)[TrajectoryFit.tooLarge], 3);
      // 500m（短辺 2.5km、下限 150m）: 6km だけが大きすぎる
      expect(count(500), {
        TrajectoryFit.tooSmall: 0,
        TrajectoryFit.usable: 2,
        TrajectoryFit.tooLarge: 1,
      });
      // 2km（短辺 10km、下限 600m）: 300m が小さすぎる
      expect(count(2000), {
        TrajectoryFit.tooSmall: 1,
        TrajectoryFit.usable: 2,
        TrajectoryFit.tooLarge: 0,
      });
      // 10km（短辺 50km、下限 3km）: 6km だけが使える
      expect(count(10000)[TrajectoryFit.usable], 1);
    });
  });

  group('CanvasScale.median', () {
    test('奇数個・偶数個・空', () {
      expect(CanvasScale.median([3.0, 1.0, 2.0]), 2.0);
      expect(CanvasScale.median([4.0, 1.0, 3.0, 2.0]), 2.5);
      expect(CanvasScale.median(<double>[]), isNull);
    });
  });

  group('CanvasScale.recommend（手持ちの軌跡からの推奨スケール）', () {
    const shortSide = 390.0;

    test('軌跡がなければ推奨しない', () {
      expect(CanvasScale.recommend(<double>[], shortSide), isNull);
      expect(CanvasScale.recommend([0.0, 0.0], shortSide), isNull);
    });

    test('標準的な軌跡がキャンバス短辺の4割ほどになるスケールを選ぶ', () {
      // 1km の軌跡 → 理想は 1000 / (390 * 0.4) * 80 ≒ 513m → 500m
      final scale = CanvasScale.recommend([1000.0], shortSide)!;
      expect(scale, 500);
      final ratio = CanvasScale.displayPixels(1000, scale) / shortSide;
      expect(ratio, closeTo(CanvasScale.recommendedFillRatio, 0.05));
    });

    test('極端に長い軌跡が1本あっても引きずられない', () {
      final usual = CanvasScale.recommend([800.0, 1000.0, 1200.0], shortSide);
      final withOutlier =
          CanvasScale.recommend([800.0, 1000.0, 1200.0, 40000.0], shortSide);
      expect(usual, 500);
      // 中央値が 1000 → 1100 に動くだけなので推奨は変わらない
      expect(withOutlier, 500);
    });

    test('推奨スケールでは半数以上の軌跡を素材として使える', () {
      const extents = [150.0, 400.0, 900.0, 2500.0, 7000.0, 12000.0];
      final scale = CanvasScale.recommend(extents, shortSide)!;
      final usable = CanvasScale.countByFit(
          extents, scale, shortSide)[TrajectoryFit.usable]!;
      expect(usable, greaterThanOrEqualTo(extents.length ~/ 2));
    });

    test('選択肢の範囲に丸められる', () {
      expect(
          CanvasScale.recommend([5.0], shortSide), CanvasScale.options.first);
      expect(CanvasScale.recommend([500000.0], shortSide),
          CanvasScale.options.last);
      for (final extent in [30.0, 250.0, 1800.0, 9000.0, 60000.0]) {
        expect(CanvasScale.options,
            contains(CanvasScale.recommend([extent], shortSide)));
      }
    });
  });

  group('CanvasScale 表示', () {
    test('スケールの表記', () {
      expect(CanvasScale.format(50), '50m');
      expect(CanvasScale.format(500), '500m');
      expect(CanvasScale.format(1000), '1km');
      expect(CanvasScale.format(1500), '1.5km');
      expect(CanvasScale.format(10000), '10km');
    });

    test('実測値は目安として丸める', () {
      expect(CanvasScale.formatApprox(487), '490m');
      expect(CanvasScale.formatApprox(2437.5), '2.4km');
    });
  });
}
