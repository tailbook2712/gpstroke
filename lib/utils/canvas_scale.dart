import 'dart:math' as math;

/// あるスケールのキャンバスで、軌跡を作品の素材（ストローク）として使えるか
enum TrajectoryFit {
  /// 小さすぎる（点のようになり、形が分からない）
  tooSmall,

  /// 使える
  usable,

  /// 大きすぎる（キャンバスに収まらない）
  tooLarge,
}

/// キャンバスのスケール（スケールバーが表す実距離）に関する計算
///
/// スケールは作品制作の開始時に決め、制作中は変更しない（#132）。
/// 作品制作画面とルート提案画面で同じ換算を使うため、ここに集約する。
class CanvasScale {
  CanvasScale._();

  /// 選択できるスケール（スケールバーが表す距離、メートル）
  static const List<double> options = [
    50,
    100,
    200,
    300,
    500,
    1000,
    2000,
    3000,
    5000,
    10000,
  ];

  /// スケールバーの固定ピクセル長
  static const double barPixelLength = 80.0;

  /// スケール未指定時の既定値（スケール固定の導入前の初期値と同じ）
  static const double defaultDistance = 500.0;

  /// 推奨スケールで「標準的な軌跡」がキャンバス短辺に占める割合の目安
  ///
  /// 1本でキャンバスを埋めず、複数の軌跡を組み合わせる余白が残る大きさ
  static const double recommendedFillRatio = 0.4;

  /// キャンバス上でこれより小さく表示される軌跡は「小さすぎる」とみなす（論理ピクセル）
  ///
  /// 軌跡は太さ 4px の線で描くため、差し渡しがその数倍を下回ると形が潰れ、
  /// 指で掴んで動かすのも難しくなる
  static const double minDisplayPixels = 24.0;

  /// キャンバス上の 1px が表す実距離（メートル）
  static double metersPerPixel(double scaleBarDistance) =>
      scaleBarDistance / barPixelLength;

  /// 緯度経度の範囲から、軌跡の差し渡し（縦横の長い方、メートル）を求める
  static double extentMeters({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    final meanLat = (minLat + maxLat) / 2.0;
    final latExtent = (maxLat - minLat) * 111320.0;
    final lonExtent =
        (maxLon - minLon) * 111320.0 * math.cos(meanLat * math.pi / 180.0);
    return math.max(latExtent, lonExtent);
  }

  /// 指定スケールで、軌跡の差し渡しがキャンバス上で何 px になるか
  static double displayPixels(double extentMeters, double scaleBarDistance) =>
      extentMeters / metersPerPixel(scaleBarDistance);

  /// 指定スケールのキャンバスで、軌跡を描く正方形の枠の一辺（px）
  ///
  /// 軌跡は枠の四辺に 10% ずつ余白を取って描かれる（PolylinePainter）ため、
  /// 差し渡しが [displayPixels] になるよう、枠はその 1/0.8 倍の大きさになる。
  /// 差し渡しが 0 の軌跡（1点だけ）は [fallback] の大きさの枠で描く
  static double boxPixels(
    double extentMeters,
    double scaleBarDistance, {
    double fallback = 100.0,
  }) {
    if (extentMeters <= 0) return fallback;
    return displayPixels(extentMeters, scaleBarDistance) / 0.8;
  }

  /// 指定スケールで、軌跡がキャンバスに収まるか
  ///
  /// 差し渡しがキャンバスの短辺を超える軌跡は「大きすぎる」とみなす
  static bool fitsCanvas(
    double extentMeters,
    double scaleBarDistance,
    double canvasShortSide,
  ) =>
      displayPixels(extentMeters, scaleBarDistance) <= canvasShortSide;

  /// 指定スケールで、軌跡を素材として使えるかを判定する
  ///
  /// 差し渡しがキャンバスの短辺を超えれば「大きすぎる」、
  /// 表示が [minDisplayPixels] に満たなければ「小さすぎる」
  static TrajectoryFit classify(
    double extentMeters,
    double scaleBarDistance,
    double canvasShortSide,
  ) {
    final pixels = displayPixels(extentMeters, scaleBarDistance);
    if (pixels > canvasShortSide) return TrajectoryFit.tooLarge;
    if (pixels < minDisplayPixels) return TrajectoryFit.tooSmall;
    return TrajectoryFit.usable;
  }

  /// 指定スケールでの、判定ごとの軌跡の本数
  static Map<TrajectoryFit, int> countByFit(
    Iterable<double> extentsMeters,
    double scaleBarDistance,
    double canvasShortSide,
  ) {
    final counts = {for (final fit in TrajectoryFit.values) fit: 0};
    for (final extent in extentsMeters) {
      final fit = classify(extent, scaleBarDistance, canvasShortSide);
      counts[fit] = counts[fit]! + 1;
    }
    return counts;
  }

  /// 中央値（空の場合は null）
  static double? median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// 手持ちの軌跡の大きさの分布から推奨スケールを求める
  ///
  /// 差し渡しの中央値（＝標準的な軌跡）がキャンバス短辺の
  /// [recommendedFillRatio] 程度になるスケールを [options] から選ぶ。
  /// 中央値を使うので、極端に長い軌跡が1本あっても引きずられない。
  /// 軌跡がない場合は null。
  static double? recommend(
    Iterable<double> extentsMeters,
    double canvasShortSide,
  ) {
    final typical = median(extentsMeters.where((e) => e > 0));
    if (typical == null || canvasShortSide <= 0) return null;

    final idealDistance =
        typical / (canvasShortSide * recommendedFillRatio) * barPixelLength;

    // 段階が等比に近いので、対数上で最も近い選択肢を選ぶ
    return options.reduce((a, b) {
      final da = (math.log(a) - math.log(idealDistance)).abs();
      final db = (math.log(b) - math.log(idealDistance)).abs();
      return db < da ? b : a;
    });
  }

  /// 距離を表示用に整形する（例: 500m, 1km, 1.5km）
  static String format(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      return '${km % 1 == 0 ? km.toInt() : km.toStringAsFixed(1)}km';
    }
    return '${meters.round()}m';
  }

  /// 実測値などの端数がある距離を、目安として丸めて整形する（例: 約2.4km → 2.4km, 487m → 490m）
  static String formatApprox(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)}km';
    return '${(meters / 10).round() * 10}m';
  }
}
