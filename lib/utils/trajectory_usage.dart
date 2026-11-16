import 'package:geolocator/geolocator.dart';

/// 軌跡が下書きや完成作品に使われているかを、保存データの中身から求める
///
/// 軌跡の使用は一度きりにする。「使用済み」を消せない印として記録するのではなく、
/// いま存在する下書き・完成作品が参照している軌跡を使用中とみなすことで、
/// 下書きや作品を削除すれば、その軌跡が自動的に軌跡リストへ戻るようにする。
class TrajectoryUsage {
  TrajectoryUsage._();

  /// 軌跡の同一性を照合するための署名（点の数と、最初・中間・最後の点の座標）
  ///
  /// groupId を保存していなかった頃の下書き・作品の軌跡を、手持ちの軌跡と
  /// 突き合わせるために使う
  static String? _signature(
      int length, List<double> Function(int index) latLonAt) {
    if (length == 0) return null;
    final points = [0, length ~/ 2, length - 1].map(latLonAt);
    return '$length|${points.map((p) => '${p[0]},${p[1]}').join('|')}';
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

  /// 下書き・作品に保存された軌跡 1本から考えられる groupId をすべて返す
  ///
  /// - 下書きは `groupId`、作品は `details.groupId` に保存している
  /// - 保存されていない古いデータや、保存時に groupId が分からなかった軌跡は、
  ///   [groupIdBySignature]（手持ちの軌跡の署名 → groupId）と座標を照合する
  static Set<String> groupIdsOfSavedTrajectory(
    Map<dynamic, dynamic> trajectory,
    Map<String, String> groupIdBySignature,
  ) {
    final groupIds = <String>{};

    final saved = trajectory['groupId'];
    if (saved is String && saved.isNotEmpty) groupIds.add(saved);

    final details = trajectory['details'];
    if (details is Map) {
      final savedInDetails = details['groupId'];
      if (savedInDetails is String && savedInDetails.isNotEmpty) {
        groupIds.add(savedInDetails);
      }
    }

    final signature = signatureOfSavedPositions(trajectory['positions']);
    final matched = signature == null ? null : groupIdBySignature[signature];
    if (matched != null) groupIds.add(matched);

    return groupIds;
  }

  /// 下書きの軌跡をキャンバスに復元するときの groupId（特定できなければ null）
  static String? groupIdOfDraftTrajectory(
    Map<dynamic, dynamic> trajectory,
    Map<String, String> groupIdBySignature,
  ) {
    final saved = trajectory['groupId'];
    if (saved is String && saved.isNotEmpty) return saved;
    final signature = signatureOfSavedPositions(trajectory['positions']);
    return signature == null ? null : groupIdBySignature[signature];
  }

  /// 下書き・作品のキャンバスデータ（`trajectories` を持つ Map）の集まりから、
  /// 使われている軌跡の groupId の集合を求める
  static Set<String> usedGroupIds(
    Iterable<Map<dynamic, dynamic>> canvases,
    Map<String, String> groupIdBySignature,
  ) {
    final groupIds = <String>{};
    for (final canvas in canvases) {
      final trajectories = canvas['trajectories'];
      if (trajectories is! List) continue;
      for (final trajectory in trajectories.whereType<Map>()) {
        groupIds
            .addAll(groupIdsOfSavedTrajectory(trajectory, groupIdBySignature));
      }
    }
    return groupIds;
  }

  /// 完成作品に使われている軌跡 [usedByArtworks] から、使用済みの表を決め直す
  ///
  /// 作品の一覧をサーバーから確かに取得できた（[confirmedByServer]）ときは、
  /// 表を作品の内容で置き換える。削除された作品の軌跡や、過去に誤って付いた印は
  /// ここで外れ、軌跡リストに戻る。
  /// オフラインなどでキャッシュしか読めなかったときは、一覧が欠けているおそれが
  /// あるので、[current] に足すだけにして何も外さない
  static Set<String> reconcile({
    required Set<String> current,
    required Set<String> usedByArtworks,
    required bool confirmedByServer,
  }) {
    return confirmedByServer
        ? {...usedByArtworks}
        : {...current, ...usedByArtworks};
  }
}
