import 'package:geolocator/geolocator.dart';

import '../artwork.dart';

/// 軌跡が下書きや完成作品に使われているかを、保存データの中身から求める
///
/// 軌跡の使用は一度きりにする。「使用済み」を消せない印として記録するのではなく、
/// いま存在する下書き・完成作品が参照している軌跡（strokes）を使用中とみなすことで、
/// 下書きや作品を削除すれば、その軌跡が自動的に軌跡リストへ戻るようにする。
/// 座標の署名は、軌跡を参照で持つ前の古いデータを手持ちの軌跡と照合するときに使う
/// （LegacyStrokeResolver）。
class TrajectoryUsage {
  TrajectoryUsage._();

  /// 軌跡の同一性を照合するための署名（点の数と、最初・中間・最後の点の座標）
  ///
  /// groupId を保存していなかった頃の下書き・作品の軌跡を、手持ちの軌跡と
  /// 突き合わせるために使う。
  /// 手持ちの軌跡は緯度経度を小数 6 桁で保存している（Trajectory）ため、
  /// 下書き・作品にコピーされている座標とそろうよう、6 桁に丸めて比べる
  static String? _signature(
      int length, List<double> Function(int index) latLonAt) {
    if (length == 0) return null;
    final points = [0, length ~/ 2, length - 1].map(latLonAt);
    return '$length|${points.map((p) => '${p[0].toStringAsFixed(6)},${p[1].toStringAsFixed(6)}').join('|')}';
  }

  /// 手持ちの軌跡の署名
  static String? signatureOfPositions(List<Position> positions) {
    return _signature(positions.length,
        (i) => [positions[i].latitude, positions[i].longitude]);
  }

  /// 保存データ上の位置情報（latitude / longitude を持つ Map のリスト）の署名
  ///
  /// 形式が壊れている場合は null
  static String? signatureOfSavedPositions(Object? positions) {
    if (positions is! List) return null;
    try {
      return _signature(positions.length, (i) {
        final point = positions[i] as Map;
        return [
          (point['latitude'] as num).toDouble(),
          (point['longitude'] as num).toDouble(),
        ];
      });
    } catch (e) {
      return null;
    }
  }

  /// 作品・下書きの strokes に使われている軌跡の ID
  ///
  /// いま存在する作品・下書きが参照している軌跡を使用中とみなす
  static Set<String> usedTrajectoryIds(Iterable<Iterable<Stroke>> strokeLists) {
    return {
      for (final strokes in strokeLists)
        for (final stroke in strokes) stroke.trajectoryId,
    };
  }
}
