import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artwork.dart';
import 'artwork_share_service.dart';
import 'auth_service.dart';
import 'legacy_canvas_conversion.dart';
import 'trajectory_store.dart';

/// 完成作品の保存・読み込み・削除
///
/// 作品は Firestore の `users/{userId}/artworks/{artworkId}` に保存する（形は Artwork）。
/// 作品は軌跡を参照（Stroke.trajectoryId）で持ち、座標は TrajectoryStore から読む。
/// 作品画像（ギャラリーのサムネイル）は `users/{userId}/artwork_images/{artworkId}`
/// に別に保存し（作品の一覧を読むときに画像まで読まないため）、端末内にもキャッシュする。
///
/// 作品は件数が少なく 1 件が小さいため、アプリの起動時に [refresh] でサーバーから
/// すべて読み、以降はメモリに持った一覧を使う（別の端末で削除した作品も起動時に反映される）。
/// 画像は端末内にないものだけを取りに行く（[loadImage]）。
///
/// 以前の形式（軌跡の座標をコピーで持ち、画像を base64 で持っていた作品）は、読み込んだ
/// ときに新しい形式に変換して書き足す。以前のフィールドは消さずに残す。
class ArtworkStore {
  ArtworkStore._();

  /// オフラインのとき、サーバーへの反映を待たずに先へ進むまでの時間
  static const Duration _serverAckTimeout = Duration(seconds: 3);

  /// サーバーから読み込むときに待つ時間
  static const Duration _serverReadTimeout = Duration(seconds: 20);

  /// 作品画像の大きさの上限（Firestore の 1 ドキュメントの上限 1 MiB に余裕を持たせる）
  static const int maxImageBytes = 900 * 1024;

  /// 作品画像の長辺の上限
  static const int maxImageSide = 1600;

  /// 端末内の作品ファイル（以前の形式）を移し終えた印（ユーザーごと）
  static const String _localFilesMigratedKeyPrefix =
      'artworkLocalFilesMigrated_';

  /// 読み込んだ作品（ID → 作品）。[_memoryUserId] のユーザーのもの
  static String? _memoryUserId;
  static Future<Map<String, Artwork>>? _memory;

  /// このアプリの起動中に、サーバーからすべて読み込めたか
  static bool _refreshedFromServer = false;

  static String get _userId {
    final userId = AuthService().userId;
    if (userId == null) {
      throw StateError('ログインしていないため、作品を扱えません');
    }
    return userId;
  }

  static DocumentReference<Map<String, dynamic>> _userDoc(String userId) =>
      FirebaseFirestore.instance.collection('users').doc(userId);

  static CollectionReference<Map<String, dynamic>> _collection(
          String userId) =>
      _userDoc(userId).collection('artworks');

  static DocumentReference<Map<String, dynamic>> _imageDoc(
          String userId, String artworkId) =>
      _userDoc(userId).collection('artwork_images').doc(artworkId);

  /// 作品を新しい順に返す
  static Future<List<Artwork>> loadAll() async {
    final memory = await _loadMemory(_userId);
    return memory.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 作品を 1 件返す（見つからない場合は null）
  static Future<Artwork?> get(String artworkId) async {
    return (await _loadMemory(_userId))[artworkId];
  }

  /// サーバーからすべての作品を読み込む（アプリの起動時に呼ぶ）
  ///
  /// 読み込めなかったときは、端末内のキャッシュのまま進む
  static Future<void> refresh() async {
    final userId = _userId;
    try {
      final snapshot = await _collection(userId)
          .get(const GetOptions(source: Source.server))
          .timeout(_serverReadTimeout);
      final artworks = await _readDocuments(userId, snapshot.docs);
      _memoryUserId = userId;
      _memory = Future.value(artworks);
      _refreshedFromServer = true;
      print('✅ 作品をサーバーから読み込みました: ${artworks.length}件');
    } on TimeoutException {
      print('⏳ 作品の読み込み: サーバーに接続できないため、端末内のデータを使います');
    } catch (e) {
      print('❌ 作品の読み込みエラー: $e');
    }
  }

  /// 作品を保存する（[png] は作品画像）
  static Future<void> save(Artwork artwork, Uint8List png) async {
    final userId = _userId;
    final image = await Isolate.run(() => compressArtworkImage(png));
    await _saveImage(userId, artwork.id, image.bytes);
    await _waitForServer(
      _collection(userId).doc(artwork.id).set(artwork.toFirestore()),
      description: '作品の保存 (${artwork.id})',
    );
    (await _loadMemory(userId))[artwork.id] = artwork;
    print('✅ 作品を保存しました: ${artwork.id}'
        '（ストローク ${artwork.strokes.length}本・画像 ${image.bytes.length} bytes）');
  }

  /// 共有したときの共有 ID を作品に保存する
  static Future<void> setShareId(String artworkId, String shareId) async {
    final userId = _userId;
    final memory = await _loadMemory(userId);
    final artwork = memory[artworkId];
    if (artwork == null || artwork.shareId == shareId) return;

    final updated = artwork.copyWith(shareId: shareId, updatedAt: DateTime.now());
    memory[artworkId] = updated;
    await _waitForServer(
      _collection(userId).doc(artworkId).set({
        'shareId': shareId,
        'updatedAt': Timestamp.fromDate(updated.updatedAt),
      }, SetOptions(merge: true)),
      description: '共有 ID の保存 ($artworkId)',
    );
  }

  /// 作品を削除する
  ///
  /// 作品画像と、共有していれば共有データ（位置情報を含む公開データ）も削除する。
  /// 作品に使っていた軌跡は、作品がなくなることで軌跡リストに戻る
  static Future<void> delete(Artwork artwork) async {
    final userId = _userId;

    await _deleteSharedArtwork(userId, artwork);

    // 以前の形式の作品が持っていた「使った軌跡の記録」（サブコレクション）
    try {
      final records = await _collection(userId)
          .doc(artwork.id)
          .collection('used_trajectories')
          .get()
          .timeout(_serverReadTimeout);
      if (records.docs.isNotEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in records.docs) {
          batch.delete(doc.reference);
        }
        await _waitForServer(batch.commit(),
            description: '使った軌跡の記録の削除 (${artwork.id})');
      }
    } catch (e) {
      print('❌ 使った軌跡の記録の削除エラー (${artwork.id}): $e');
    }

    try {
      await _waitForServer(_imageDoc(userId, artwork.id).delete(),
          description: '作品画像の削除 (${artwork.id})');
    } catch (e) {
      print('❌ 作品画像の削除エラー (${artwork.id}): $e');
    }

    await _waitForServer(_collection(userId).doc(artwork.id).delete(),
        description: '作品の削除 (${artwork.id})');
    (await _loadMemory(userId)).remove(artwork.id);

    // 端末内のキャッシュと、以前の形式で端末に保存していたファイル
    for (final file in [
      await _imageCacheFile(userId, artwork.id),
      ...await _legacyFilesOf(userId, artwork.id),
    ]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        print('❌ 端末内の作品ファイルの削除エラー (${file.path}): $e');
      }
    }
    print('🗑️ 作品を削除しました: ${artwork.id}');
  }

  /// 作品画像を返す（ない・取得できない場合は null）
  ///
  /// 端末内にあればそれを使い、なければ Firestore から取得してキャッシュする
  static Future<File?> loadImage(String artworkId) async {
    final userId = _userId;
    final cacheFile = await _imageCacheFile(userId, artworkId);
    if (await cacheFile.exists()) return cacheFile;

    // 以前の形式で端末に保存していた画像
    final legacyImage = await _legacyImageFile(userId, artworkId);
    if (await legacyImage.exists()) return legacyImage;

    try {
      final snapshot =
          await _imageDoc(userId, artworkId).get().timeout(_serverReadTimeout);
      final blob = snapshot.data()?['image'];
      if (blob is! Blob) {
        print('❌ 作品画像が見つかりません: $artworkId');
        return null;
      }
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(blob.bytes, flush: true);
      return cacheFile;
    } catch (e) {
      print('❌ 作品画像の取得エラー ($artworkId): $e');
      return null;
    }
  }

  /// 端末内にだけある作品（以前の形式のファイル）を移す
  ///
  /// 端末ごとに 1 回行う（終わったら印を付ける）。[refresh] でサーバーの作品を
  /// すべて読めたときだけ行い、サーバーにない作品（Firestore への保存に失敗していた作品）
  /// を新しい形式で保存する。サーバーにある作品には、端末のファイルにだけ残っていた
  /// 共有 ID を書き足す。ファイルは消さない
  static Future<void> migrateLocalFiles() async {
    final userId = _userId;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_localFilesMigratedKeyPrefix$userId';
    if (prefs.getBool(key) == true) return;
    if (!_refreshedFromServer) {
      print('⏳ サーバーの作品を読めていないため、端末内の作品の移行は次回の起動で行います');
      return;
    }

    final directory = await getApplicationDocumentsDirectory();
    final canvasDirectory =
        Directory('${directory.path}/canvas_states/$userId');
    if (!await canvasDirectory.exists()) {
      await prefs.setBool(key, true);
      return;
    }

    final memory = await _loadMemory(userId);
    LegacyStrokeResolver? resolver;
    final pending = <(Artwork, File)>[];
    final shareIds = <String, String>{};

    final files = canvasDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'));
    for (final file in files) {
      final Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map);
      } catch (e) {
        print('❌ 端末内の作品ファイルを読めませんでした (${file.path}): $e');
        continue;
      }
      final meta = data['meta'] is Map ? data['meta'] as Map : const {};
      final artworkId = (meta['artworkId'] as String?) ??
          'artwork_${file.uri.pathSegments.last.replaceAll(RegExp(r'^canvas_|\.json$'), '')}';

      final existing = memory[artworkId];
      if (existing != null) {
        final shareId = meta['shareId'];
        if (existing.shareId == null && shareId is String && shareId.isNotEmpty) {
          shareIds[artworkId] = shareId;
        }
        continue;
      }

      try {
        resolver ??= LegacyStrokeResolver(await TrajectoryStore.loadAll());
        final artwork = convertLegacyArtwork(artworkId, data, resolver);
        pending.add((artwork, await _legacyImageFile(userId, artworkId)));
      } catch (e) {
        print('❌ 端末内の作品を変換できませんでした ($artworkId): $e');
      }
    }

    for (final trajectory in resolver?.created ?? const []) {
      await TrajectoryStore.add(trajectory);
    }
    for (final (artwork, imageFile) in pending) {
      try {
        if (await imageFile.exists()) {
          final original = await imageFile.readAsBytes();
          final image = await Isolate.run(() => compressArtworkImage(original));
          await _saveImage(userId, artwork.id, image.bytes);
        }
        await _waitForServer(
          _collection(userId).doc(artwork.id).set(artwork.toFirestore()),
          description: '端末内の作品の移行 (${artwork.id})',
        );
        memory[artwork.id] = artwork;
      } catch (e) {
        print('❌ 端末内の作品の移行エラー (${artwork.id}): $e');
      }
    }
    for (final entry in shareIds.entries) {
      await setShareId(entry.key, entry.value);
    }

    await prefs.setBool(key, true);
    print('✅ 端末内の作品を移しました: ${pending.length}件'
        '（共有 ID の書き足し ${shareIds.length}件）');
  }

  /// 作品画像を、Firestore に収まる大きさの PNG にする（別の Isolate で実行する）
  @visibleForTesting
  static ({Uint8List bytes, int width, int height}) compressArtworkImage(
      Uint8List original) {
    final decoded = img.decodeImage(original);
    if (decoded == null) {
      if (original.length <= maxImageBytes) {
        return (bytes: original, width: 0, height: 0);
      }
      throw const FormatException('作品画像の形式に対応していません');
    }

    var image = decoded;
    var longestSide = math.max(image.width, image.height);
    if (longestSide > maxImageSide) {
      longestSide = maxImageSide;
      image = _resizeLongestSide(image, longestSide);
    }
    while (true) {
      final encoded = img.encodePng(image);
      if (encoded.length <= maxImageBytes) {
        return (bytes: encoded, width: image.width, height: image.height);
      }
      if (longestSide <= 400) {
        throw const FormatException('作品画像を小さくできませんでした');
      }
      longestSide = (longestSide * 0.75).round();
      image = _resizeLongestSide(image, longestSide);
    }
  }

  static img.Image _resizeLongestSide(img.Image image, int longestSide) {
    return image.width >= image.height
        ? img.copyResize(image, width: longestSide)
        : img.copyResize(image, height: longestSide);
  }

  // ─── 内部処理 ───

  static Future<Map<String, Artwork>> _loadMemory(String userId) {
    if (_memoryUserId != userId) {
      _memoryUserId = userId;
      _memory = null;
      _refreshedFromServer = false;
    }
    return _memory ??= _readCache(userId);
  }

  /// 端末内のキャッシュにある作品を読む（サーバーには問い合わせない）
  static Future<Map<String, Artwork>> _readCache(String userId) async {
    try {
      final snapshot = await _collection(userId)
          .get(const GetOptions(source: Source.cache));
      return await _readDocuments(userId, snapshot.docs);
    } catch (e) {
      print('❌ 端末内の作品の読み込みエラー: $e');
      return {};
    }
  }

  /// 作品ドキュメントを読む。以前の形式の作品は新しい形式に変換して書き足す
  static Future<Map<String, Artwork>> _readDocuments(
    String userId,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    final artworks = <String, Artwork>{};
    final legacyDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final doc in docs) {
      final data = doc.data();
      if (!Artwork.isCurrentFormat(data)) {
        legacyDocs.add(doc);
        continue;
      }
      try {
        artworks[doc.id] = Artwork.fromFirestore(doc.id, data);
      } catch (e) {
        print('❌ 作品を読めませんでした (${doc.id}): $e');
      }
    }
    if (legacyDocs.isEmpty) return artworks;

    final resolver = LegacyStrokeResolver(await TrajectoryStore.loadAll());
    final converted = <(Artwork, Object?)>[];
    for (final doc in legacyDocs) {
      try {
        converted.add((
          convertLegacyArtwork(doc.id, doc.data(), resolver),
          doc.data()['imageData'],
        ));
      } catch (e) {
        print('❌ 以前の形式の作品を変換できませんでした (${doc.id}): $e');
      }
    }

    // 作品が参照する軌跡を先に保存する
    for (final trajectory in resolver.created) {
      await TrajectoryStore.add(trajectory);
    }
    for (final (artwork, imageData) in converted) {
      artworks[artwork.id] = artwork;
      try {
        if (imageData is String && imageData.isNotEmpty) {
          final original = base64Decode(imageData);
          final image = await Isolate.run(() => compressArtworkImage(original));
          await _saveImage(userId, artwork.id, image.bytes);
        }
        // 以前のフィールドは残したまま、新しい形式のフィールドを書き足す
        await _waitForServer(
          _collection(userId)
              .doc(artwork.id)
              .set(artwork.toFirestore(), SetOptions(merge: true)),
          description: '以前の形式の作品の変換 (${artwork.id})',
        );
        print('✅ 以前の形式の作品を変換しました: ${artwork.id}'
            '（ストローク ${artwork.strokes.length}本）');
      } catch (e) {
        print('❌ 以前の形式の作品の書き込みエラー (${artwork.id}): $e');
      }
    }
    if (resolver.created.isNotEmpty) {
      print('   作品にコピーされていた座標から作った軌跡: ${resolver.created.length}本');
    }
    return artworks;
  }

  static Future<void> _saveImage(
      String userId, String artworkId, Uint8List bytes) async {
    final cacheFile = await _imageCacheFile(userId, artworkId);
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsBytes(bytes, flush: true);
    await _waitForServer(
      _imageDoc(userId, artworkId).set({
        'image': Blob(bytes),
        'updatedAt': Timestamp.now(),
      }),
      description: '作品画像の保存 ($artworkId)',
    );
  }

  /// 共有データを削除する
  ///
  /// 共有 ID を作品に保存していなかった頃に共有した作品は、作品 ID から導いた
  /// 共有 ID（ArtworkShareService.deriveShareId）で探し、あれば削除する
  static Future<void> _deleteSharedArtwork(
      String userId, Artwork artwork) async {
    final shared = FirebaseFirestore.instance
        .collection(ArtworkShareService.collectionName);
    try {
      if (artwork.shareId != null) {
        await _waitForServer(shared.doc(artwork.shareId).delete(),
            description: '共有データの削除 (${artwork.shareId})');
        print('🗑️ 共有データを削除しました: ${artwork.shareId}');
        return;
      }
      final derived = ArtworkShareService.deriveShareId(
          ownerUid: userId, artworkKey: artwork.id);
      final snapshot = await shared
          .doc(derived)
          .get(const GetOptions(source: Source.server))
          .timeout(_serverReadTimeout);
      if (snapshot.exists) {
        await _waitForServer(shared.doc(derived).delete(),
            description: '共有データの削除 ($derived)');
        print('🗑️ 共有データを削除しました: $derived');
      }
    } catch (e) {
      print('❌ 共有データの削除エラー (${artwork.id}): $e');
    }
  }

  static Future<File> _imageCacheFile(String userId, String artworkId) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/artwork_images/$userId/$artworkId.png');
  }

  /// 以前の形式で端末に保存していた作品画像
  static Future<File> _legacyImageFile(String userId, String artworkId) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/artworks/$userId/$artworkId.png');
  }

  /// 以前の形式で端末に保存していた作品のファイル（画像とキャンバスの状態）
  static Future<List<File>> _legacyFilesOf(
      String userId, String artworkId) async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = artworkId.split('_').last;
    return [
      await _legacyImageFile(userId, artworkId),
      File('${directory.path}/canvas_states/$userId/canvas_$timestamp.json'),
    ];
  }

  /// Firestore への書き込みを、サーバーに届くまで（オフラインなら一定時間）待つ
  ///
  /// 権限エラーなどの失敗は例外として返す。時間切れの場合は端末内のキャッシュに
  /// 反映済みで、オンラインになったときに送られるため、成功として扱う
  static Future<void> _waitForServer(
    Future<void> write, {
    required String description,
  }) async {
    try {
      await write.timeout(_serverAckTimeout);
    } on TimeoutException {
      print('⏳ $description: オフラインのため、オンラインになったら同期します');
      unawaited(write.catchError((Object e) {
        print('❌ $description の同期に失敗しました: $e');
      }));
    }
  }
}
