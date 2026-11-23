import 'package:geolocator/geolocator.dart';

/// 記録として確定した 1 点
class RecordedPoint {
  final Position position;

  /// 新しい区間（セグメント）の始点か。
  /// 乗り物での移動を挟んだ場合などに軌跡を分割するために使う。
  final bool startsNewSegment;

  /// 同じ区間内の直前の点からの距離（m）。区間の始点では 0。
  final double distanceMeters;

  const RecordedPoint({
    required this.position,
    required this.startsNewSegment,
    required this.distanceMeters,
  });
}

/// GPS の生の測位結果から、軌跡として記録すべき点を選別するフィルタ。
///
/// - 精度の悪い測位（[maxAccuracyMeters] 超）は捨てる
/// - 移動速度が [maxSpeedMps] を超えた測位（自動車・電車など）は捨てる
/// - 高速移動を検知した後は、[resumeAfter] の間高速移動が無いことを確認してから
///   記録を再開する（信号待ち・渋滞で一時的に遅くなった区間を記録しないため）。
///   保留中の点は、再開が確定した時点でまとめて記録される
/// - 高速移動を挟んで [segmentGapMeters] 以上離れた場合は、直線で繋がないよう
///   新しい区間として記録する
class TrajectoryPointFilter {
  /// 記録対象とする最大速度（m/s）。既定は 20 km/h（速めのランニング程度）
  final double maxSpeedMps;

  /// 許容する水平精度（m）
  final double maxAccuracyMeters;

  /// これ未満の移動はノイズとして捨てる（m）
  final double noiseThresholdMeters;

  /// 高速移動を挟んでこれ以上離れていたら区間を分ける（m）
  final double segmentGapMeters;

  /// 高速移動を検知してから記録を再開するまでに必要な低速状態の継続時間
  final Duration resumeAfter;

  TrajectoryPointFilter({
    this.maxSpeedMps = 20 / 3.6,
    this.maxAccuracyMeters = 50,
    this.noiseThresholdMeters = 2,
    this.segmentGapMeters = 50,
    this.resumeAfter = const Duration(seconds: 60),
  });

  Position? _lastFix;
  Position? _lastCommitted;
  DateTime? _lastTooFastAt;
  bool _hadSpeedGap = false;
  final List<Position> _pending = [];

  /// 高速移動を検知して記録を一時停止しているか
  bool get isSuspendedForSpeed => _lastTooFastAt != null;

  /// 測位結果を 1 件処理し、記録として確定した点を返す（0 件以上）
  List<RecordedPoint> add(Position fix) {
    // accuracy <= 0 は「不明」扱いで受け入れる
    if (fix.accuracy > maxAccuracyMeters) return const [];

    final speed = _estimateSpeed(fix, _lastFix);
    _lastFix = fix;

    if (speed != null && speed > maxSpeedMps) {
      _lastTooFastAt = fix.timestamp;
      _pending.clear();
      _hadSpeedGap = true;
      return const [];
    }

    if (_lastTooFastAt != null) {
      _pending.add(fix);
      if (fix.timestamp.difference(_lastTooFastAt!) < resumeAfter) {
        return const [];
      }
      // 一定時間高速移動が無かったので記録を再開
      _lastTooFastAt = null;
      final pending = List<Position>.of(_pending);
      _pending.clear();
      return [for (final p in pending) ..._commit(p)];
    }

    return _commit(fix);
  }

  List<RecordedPoint> _commit(Position p) {
    final last = _lastCommitted;
    if (last == null) {
      _lastCommitted = p;
      _hadSpeedGap = false;
      return [
        RecordedPoint(position: p, startsNewSegment: true, distanceMeters: 0)
      ];
    }

    final d = Geolocator.distanceBetween(
        last.latitude, last.longitude, p.latitude, p.longitude);

    if (_hadSpeedGap && d > segmentGapMeters) {
      _lastCommitted = p;
      _hadSpeedGap = false;
      return [
        RecordedPoint(position: p, startsNewSegment: true, distanceMeters: 0)
      ];
    }

    if (d < noiseThresholdMeters) return const [];

    _lastCommitted = p;
    _hadSpeedGap = false;
    return [
      RecordedPoint(position: p, startsNewSegment: false, distanceMeters: d)
    ];
  }

  /// 速度（m/s）を推定する。推定できない場合は null。
  /// 端末が報告するドップラー速度を優先し（iOS は無効時 -1, Android は 0）、
  /// 無い場合は前回の測位からの移動距離÷経過時間で求める。
  /// 経過時間が短いと測位誤差で速度が過大になるため 2 秒未満では推定しない。
  double? _estimateSpeed(Position fix, Position? prev) {
    if (fix.speed > 0) return fix.speed;
    if (prev == null) return null;
    final dtSec =
        fix.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
    if (dtSec < 2) return null;
    final d = Geolocator.distanceBetween(
        prev.latitude, prev.longitude, fix.latitude, fix.longitude);
    return d / dtSec;
  }
}
