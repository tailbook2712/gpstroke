/// スライドショーで軌跡を再生する順番
enum SlideshowOrder {
  /// 軌跡を記録した日時の古い順
  recorded('記録順'),

  /// 距離の長い順
  distance('距離の長い順'),

  /// キャンバスに配置した順
  placement('配置順');

  const SlideshowOrder(this.label);
  final String label;

  static SlideshowOrder fromName(String? name) => SlideshowOrder.values
      .firstWhere((o) => o.name == name, orElse: () => SlideshowOrder.recorded);
}

/// スライドショーの再生方法
enum SlideshowStyle {
  /// 作品全体を表示したまま、1 本ずつ赤くハイライトする
  highlight('ハイライト'),

  /// 何も無いキャンバスから、1 本ずつ軌跡が浮かび上がる
  reveal('一つずつ出現');

  const SlideshowStyle(this.label);
  final String label;

  static SlideshowStyle fromName(String? name) => SlideshowStyle.values
      .firstWhere((s) => s.name == name, orElse: () => SlideshowStyle.highlight);
}

/// 値でインデックスを並べ替える。値が同じ（または null 同士の）場合は元の
/// インデックス順を保つ（List.sort は安定ソートが保証されないため明示する）。
List<int> _sortIndices<T>(
  List<T> values,
  int Function(T a, T b) compare,
) {
  final indices = List<int>.generate(values.length, (i) => i);
  indices.sort((a, b) {
    final c = compare(values[a], values[b]);
    return c != 0 ? c : a.compareTo(b);
  });
  return indices;
}

/// 記録日時の古い順。日時が不明な軌跡は末尾に回す。
List<int> orderByRecordTime(List<DateTime?> recordTimes) =>
    _sortIndices<DateTime?>(recordTimes, (a, b) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return a.compareTo(b);
    });

/// 距離の長い順
List<int> orderByDistanceDesc(List<double> distances) =>
    _sortIndices<double>(distances, (a, b) => b.compareTo(a));

/// 配置した順。
///
/// 配置日時を持たない軌跡（配置日時の記録を始める前に作った作品・下書き）は
/// 先頭に置き、作品ファイル内の並び（レイヤーの奥から手前）を配置順とみなす。
List<int> orderByPlacement(List<DateTime?> placedAts) =>
    _sortIndices<DateTime?>(placedAts, (a, b) {
      if (a == null && b == null) return 0;
      if (a == null) return -1;
      if (b == null) return 1;
      return a.compareTo(b);
    });
