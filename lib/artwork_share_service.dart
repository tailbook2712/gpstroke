import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import 'auth_service.dart';
import 'database_helper.dart';
import 'utils/polyline_codec.dart';
import 'utils/utils.dart';

/// 作品共有機能
///
/// 作品のスライドショーをアプリ未使用者でもブラウザで再生できるように、
/// 作品データを Firestore のトップレベルコレクション `shared_artworks` に
/// 書き出し、GitHub Pages 上の閲覧ページ（docs/share/index.html）への
/// リンクを生成する。
///
/// 閲覧ページは Firestore REST API で `shared_artworks/{shareId}` を
/// 匿名で読み取るため、Firestore のセキュリティルールで当該コレクションの
/// 公開読み取りを許可しておく必要がある（firestore.rules を参照）。
class ArtworkShareService {
  /// 閲覧ページのベース URL（GitHub Pages の docs/share/）
  static const String shareBaseUrl =
      'https://tailbook2712.github.io/gpstroke/share/';

  /// 共有データを保存する Firestore コレクション名
  static const String collectionName = 'shared_artworks';

  /// 共有データのスキーマバージョン（閲覧ページ側と合わせる）
  static const int payloadVersion = 1;

  final DatabaseHelper _dbHelper;
  final FirebaseFirestore _db;
  final AuthService _authService;

  ArtworkShareService({
    DatabaseHelper? dbHelper,
    FirebaseFirestore? firestore,
    AuthService? authService,
  })  : _dbHelper = dbHelper ?? DatabaseHelper(),
        _db = firestore ?? FirebaseFirestore.instance,
        _authService = authService ?? AuthService();

  /// 共有 ID から閲覧ページの URL を組み立てる
  static String buildShareUrl(String shareId) => '$shareBaseUrl?id=$shareId';

  /// 推測されにくいランダムな共有 ID を生成する（英数字 20 文字）
  static String generateShareId({Random? random}) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = random ?? Random.secure();
    return List.generate(20, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// 作品の共有リンクを生成する。
  ///
  /// 1. 作品ファイル（キャンバス状態 JSON）を読み込む
  /// 2. 各ストロークの記録日時・歩数・距離を補完し、記録順に並べた共有データを作る
  /// 3. Firestore の `shared_artworks/{shareId}` に保存する
  /// 4. 生成した shareId を作品ファイルの meta に書き戻す（再共有時に同じリンクを使うため）
  Future<ArtworkShareResult> shareArtwork(File canvasFile) async {
    final uid = _authService.userId;
    if (uid == null) {
      throw StateError('作品を共有するにはログインが必要です');
    }

    final Map<String, dynamic> data =
        jsonDecode(await canvasFile.readAsString()) as Map<String, dynamic>;

    final meta = (data['meta'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final existingShareId = meta['shareId'] as String?;
    final shareId = (existingShareId != null && existingShareId.isNotEmpty)
        ? existingShareId
        : generateShareId();

    final payload = await buildSharePayload(
      data,
      shareId: shareId,
      ownerUid: uid,
      detailsLookup: _lookupTrajectoryDetails,
    );
    payload['sharedAt'] = FieldValue.serverTimestamp();

    await _db.collection(collectionName).doc(shareId).set(payload);

    // 共有 ID を作品ファイルに保存して、再共有時に同じリンクを再利用する
    if (existingShareId != shareId) {
      meta['shareId'] = shareId;
      data['meta'] = meta;
      await canvasFile.writeAsString(jsonEncode(data));
    }

    return ArtworkShareResult(
      shareId: shareId,
      url: buildShareUrl(shareId),
      artworkName: payload['artworkName'] as String,
    );
  }

  /// 共有リンクを削除する（Firestore のドキュメントを削除）
  Future<void> unshareArtwork(String shareId) async {
    await _db.collection(collectionName).doc(shareId).delete();
  }

  /// 作品ファイルの meta に記録されたストローク情報が不完全な場合に、
  /// ローカル DB（通常軌跡 → Garmin 軌跡の順）から記録日時・歩数・距離を補完する
  Future<Map<String, dynamic>?> _lookupTrajectoryDetails(String groupId) async {
    try {
      final record = await _dbHelper.getWalkingDataByGroupId(groupId) ??
          await _dbHelper.getGarminActivityByGroupId(groupId);
      if (record == null) return null;
      return {
        'date': record['date'],
        'steps': record['steps'],
        'distance': record['distance'],
      };
    } catch (e) {
      print('❌ 共有用ストローク情報の取得に失敗: $groupId, $e');
      return null;
    }
  }

  /// キャンバス状態 JSON から共有データ（Firestore ドキュメント）を組み立てる。
  ///
  /// Firestore や DB に依存しない純粋な変換処理として切り出してあり、
  /// [detailsLookup] で記録日時・歩数・距離の補完手段を差し替えられる。
  ///
  /// 生成されるデータ:
  /// ```
  /// {
  ///   version, shareId, ownerUid, artworkId, artworkName, createdAt,
  ///   canvasWidth, canvasHeight, strokeCount, totalSteps, totalDistance,
  ///   strokes: [
  ///     { polyline (encoded), pointCount, x, y, scale, rotation,
  ///       groupId, date, steps, distance }
  ///   ]  // 記録日時の古い順
  /// }
  /// ```
  static Future<Map<String, dynamic>> buildSharePayload(
    Map<String, dynamic> data, {
    required String shareId,
    required String ownerUid,
    Future<Map<String, dynamic>?> Function(String groupId)? detailsLookup,
    DateTime? now,
  }) async {
    final meta = (data['meta'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    final canvasWidth = _toDouble(data['canvasWidth']) ??
        _toDouble((data['actualCanvasSize'] as Map?)?['width']);
    final canvasHeight = _toDouble(data['canvasHeight']) ??
        _toDouble((data['actualCanvasSize'] as Map?)?['height']);
    if (canvasWidth == null || canvasHeight == null) {
      throw const FormatException('作品ファイルにキャンバスサイズが含まれていません');
    }

    final trajectories = (data['trajectories'] as List<dynamic>? ?? const []);
    if (trajectories.isEmpty) {
      throw const FormatException('作品にストロークが含まれていません');
    }

    final strokes = <Map<String, dynamic>>[];
    for (final item in trajectories.cast<Map<String, dynamic>>()) {
      final positions = (item['positions'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .toList();
      if (positions.isEmpty) continue;

      // キャンバス上の位置（新形式: 絶対座標 / 旧形式: 相対座標）
      final position = (item['position'] as Map<String, dynamic>?) ?? const {};
      double x, y;
      if (position.containsKey('absoluteX') &&
          position.containsKey('absoluteY')) {
        x = _toDouble(position['absoluteX'])!;
        y = _toDouble(position['absoluteY'])!;
      } else {
        x = (_toDouble(position['dx']) ?? 0.5) * canvasWidth;
        y = (_toDouble(position['dy']) ?? 0.5) * canvasHeight;
      }

      // ストロークの詳細情報（groupId / 記録日時 / 歩数 / 距離）
      final details =
          (item['details'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      String groupId = (details['groupId'] as String?) ?? '';
      if (groupId.isEmpty) {
        groupId = generateGroupId(positions.map(_toPosition).toList());
      }

      String date = (details['date'] as String?) ?? '';
      int steps = _toInt(details['steps']) ?? 0;
      double distance = _toDouble(details['distance']) ?? 0.0;

      final needsLookup = date.isEmpty || (steps == 0 && distance == 0.0);
      if (needsLookup && detailsLookup != null) {
        final record = await detailsLookup(groupId);
        if (record != null) {
          if (date.isEmpty) date = (record['date'] as String?) ?? '';
          if (steps == 0) steps = _toInt(record['steps']) ?? 0;
          if (distance == 0.0) distance = _toDouble(record['distance']) ?? 0.0;
        }
      }

      // アプリの詳細画面と同様に、表示用の記録日時は先頭座標のタイムスタンプを優先する
      final firstTimestamp = positions.first['timestamp'] as String?;
      if (firstTimestamp != null && firstTimestamp.isNotEmpty) {
        date = firstTimestamp;
      }

      strokes.add({
        'polyline': encodePolyline(positions),
        'pointCount': positions.length,
        'x': x,
        'y': y,
        'scale': _toDouble(item['scale']) ?? 1.0,
        'rotation': _toDouble(item['rotation']) ?? 0.0,
        'groupId': groupId,
        'date': date,
        'steps': steps,
        'distance': distance,
      });
    }

    // 記録日時の古い順に並べる（日時不明のものは末尾）
    strokes.sort((a, b) {
      final da = DateTime.tryParse(a['date'] as String);
      final db = DateTime.tryParse(b['date'] as String);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });

    final totalSteps =
        strokes.fold<int>(0, (total, s) => total + (s['steps'] as int));
    final totalDistance =
        strokes.fold<double>(
            0.0, (total, s) => total + (s['distance'] as double));

    return {
      'version': payloadVersion,
      'shareId': shareId,
      'ownerUid': ownerUid,
      'artworkId': (meta['artworkId'] as String?) ?? '',
      'artworkName': (meta['artworkName'] as String?)?.trim().isNotEmpty == true
          ? (meta['artworkName'] as String).trim()
          : '無題の作品',
      'createdAt': (meta['createdAt'] as String?) ??
          (now ?? DateTime.now()).toIso8601String(),
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'strokeCount': strokes.length,
      'totalSteps': totalSteps,
      'totalDistance': totalDistance,
      'strokes': strokes,
    };
  }

  static Position _toPosition(Map<String, dynamic> pos) {
    return Position(
      latitude: _toDouble(pos['latitude'])!,
      longitude: _toDouble(pos['longitude'])!,
      timestamp:
          DateTime.tryParse(pos['timestamp'] as String? ?? '') ?? DateTime.now(),
      accuracy: 0.0,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 共有リンク生成の結果
class ArtworkShareResult {
  final String shareId;
  final String url;
  final String artworkName;

  const ArtworkShareResult({
    required this.shareId,
    required this.url,
    required this.artworkName,
  });

  /// SNS 共有用の本文
  String get shareText => '「$artworkName」\n'
      '歩いた軌跡を集めて描いた GPS アートです。\n'
      '各ストロークがいつ・どこで歩いたものかをアニメーションで見られます。\n'
      '$url\n'
      '#GPStroke';
}
