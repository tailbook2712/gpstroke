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

import 'auth_service.dart';

/// 途中保存した作品（下書き）の保存・読み込み・削除
///
/// 下書きは Firestore の `users/{userId}/drafts/{draftId}` に保存する。
/// アカウントに紐づくため、アプリを再インストールしても復元できる。
///
/// 以前は端末内（アプリのドキュメント領域の `drafts/`）に JSON ファイルとして
/// 保存していた。そうした下書きは読み込み時に Firestore へ移し、
/// 移し終えたらファイルを削除する。下書きの ID はファイル名（拡張子を除く）を引き継ぐ。
///
/// 下絵画像は JPEG に縮小・圧縮して `users/{userId}/draft_guide_images/{draftId}`
/// に保存し（下書きの一覧を読むときに画像まで読まないよう、別のドキュメントにする）、
/// 端末内にもキャッシュする。下絵がある下書きには `hasGuideImage: true` が入る。
///
/// 各下書きの Map には、下書きを識別する `draftId` が入る。
class DraftStore {
  DraftStore._();

  /// オフラインのとき、サーバーへの反映を待たずに先へ進むまでの時間
  ///
  /// Firestore は書き込みを端末内のキャッシュに即座に反映し、オンラインに
  /// なったときにサーバーへ送る。サーバーの応答を待ち続けると、オフラインでは
  /// 保存が終わらなくなるため、一定時間で打ち切る（書き込み自体は取り消されない）
  static const Duration _serverAckTimeout = Duration(seconds: 3);

  /// 端末内の下書きファイルを Firestore に移している最中の ID
  static final Set<String> _migratingIds = {};

  /// 下絵画像の大きさの上限（Firestore の 1ドキュメントの上限 1 MiB に余裕を持たせる）
  static const int maxGuideImageBytes = 900 * 1024;

  /// 下絵画像の長辺の上限（キャンバスは画面幅に合わせて表示するので、これで十分）
  static const int maxGuideImageSide = 1600;

  static DocumentReference<Map<String, dynamic>> _userDoc() {
    final userId = AuthService().userId;
    if (userId == null) {
      throw StateError('ログインしていないため、下書きを扱えません');
    }
    return FirebaseFirestore.instance.collection('users').doc(userId);
  }

  static CollectionReference<Map<String, dynamic>> _collection() =>
      _userDoc().collection('drafts');

  static DocumentReference<Map<String, dynamic>> _guideImageDoc(
          String draftId) =>
      _userDoc().collection('draft_guide_images').doc(draftId);

  /// 新しい下書きの ID
  static String newDraftId() =>
      'draft_${DateTime.now().toIso8601String().replaceAll(':', '-')}';

  /// 保存されている下書きをすべて読み込む
  static Future<List<Map<String, dynamic>>> loadAll() async {
    final drafts = <String, Map<String, dynamic>>{};

    // Firestore の下書き（オフライン時は端末内のキャッシュから読まれる）
    CollectionReference<Map<String, dynamic>>? collection;
    try {
      collection = _collection();
      final snapshot = await collection.get();
      for (final doc in snapshot.docs) {
        final data = Map<String, dynamic>.from(doc.data());
        data['draftId'] = doc.id;
        data['timestamp'] ??= '不明な日時';
        drafts[doc.id] = data;
      }
    } catch (e) {
      // 読み込めなかった場合も、端末内に残っている下書きは表示する
      print('❌ Firestoreからの下書き読み込みエラー: $e');
      collection = null;
    }

    // 以前の形式で端末内に保存されている下書き
    for (final legacy in await _loadLegacyFiles()) {
      final draftId = legacy.draftId;
      if (drafts.containsKey(draftId)) {
        // すでに Firestore に移してある（ファイルの削除だけ残っていた）
        if (collection != null) unawaited(_deleteLegacyFile(legacy.file));
        continue;
      }
      drafts[draftId] = legacy.data;
      if (collection != null && legacy.readable) {
        unawaited(_migrate(collection, legacy));
      }
    }

    return drafts.values.toList();
  }

  /// 下書きを保存し、保存した下書き（`draftId` 付き）を返す
  ///
  /// [draftId] を指定した場合はその下書きを上書きし、null の場合は新しく作る。
  /// [guideImage] は下絵画像（ない場合は null。上書き時は保存済みの下絵を消す）。
  /// [keepStoredGuideImage] が true の場合は、[guideImage] が null でも
  /// 保存済みの下絵を残す（下絵をまだ取得できていない下書きを上書きするとき）。
  /// 下絵だけ保存できなかった場合は、下絵なしで下書きを保存し、
  /// 返す Map の `guideImageError` に理由を入れる
  static Future<Map<String, dynamic>> save(
    Map<String, dynamic> draftState, {
    String? draftId,
    File? guideImage,
    bool keepStoredGuideImage = false,
  }) async {
    final id = draftId ?? newDraftId();
    final data = Map<String, dynamic>.from(draftState)
      ..remove('draftId')
      // 端末内のパスは再インストールやアップデートで変わるため保存しない
      ..remove('guideImagePath');

    String? guideImageError;
    var hasGuideImage = false;
    if (guideImage != null) {
      try {
        await _saveGuideImage(id, guideImage);
        hasGuideImage = true;
      } catch (e) {
        print('❌ 下絵の保存エラー ($id): $e');
        guideImageError = '$e';
      }
    } else if (draftId != null && keepStoredGuideImage) {
      hasGuideImage = true;
    } else if (draftId != null) {
      await _deleteGuideImage(id);
    }
    data['hasGuideImage'] = hasGuideImage;

    await _waitForServer(
      _collection().doc(id).set(data),
      description: '下書きの保存 ($id)',
    );
    print('✅ 下書きをFirestoreに保存しました: $id');

    return {
      ...data,
      'draftId': id,
      if (guideImageError != null) 'guideImageError': guideImageError,
    };
  }

  /// 下書きの下絵画像を返す（下絵がない・取得できない場合は null）
  ///
  /// 端末内のキャッシュにあればそれを、なければ Firestore から取得してキャッシュする
  static Future<File?> loadGuideImage(Map<String, dynamic> draft) async {
    final draftId = draft['draftId'] as String?;
    if (draftId == null) return null;

    if (draft['hasGuideImage'] != true) {
      // 端末内に保存していた頃の下書き（下絵のパスをそのまま持っている）
      final legacyPath = draft['guideImagePath'] as String?;
      if (legacyPath == null) return null;
      final legacyFile = File(legacyPath);
      return await legacyFile.exists() ? legacyFile : null;
    }

    final cacheFile = await _guideImageCacheFile(draftId);
    if (await cacheFile.exists()) return cacheFile;

    try {
      final snapshot = await _guideImageDoc(draftId).get();
      final blob = snapshot.data()?['image'];
      if (blob is! Blob) {
        print('❌ 下絵が見つかりません: $draftId');
        return null;
      }
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(blob.bytes, flush: true);
      print('✅ 下絵をFirestoreから取得しました: $draftId');
      return cacheFile;
    } catch (e) {
      print('❌ 下絵の取得エラー ($draftId): $e');
      return null;
    }
  }

  /// 下書きを削除する
  static Future<void> delete(String draftId) async {
    await _waitForServer(
      _collection().doc(draftId).delete(),
      description: '下書きの削除 ($draftId)',
    );
    await _deleteGuideImage(draftId);
    // 以前の形式の下書きであれば、端末内のファイルも消す
    final file = await _legacyFileOf(draftId);
    if (file != null) await _deleteLegacyFile(file);
    print('🗑️ 下書きを削除しました: $draftId');
  }

  /// 下書きを新しい順に並べ替える（日時が分からないものは末尾）
  static List<Map<String, dynamic>> newestFirst(
      Iterable<Map<String, dynamic>> drafts) {
    DateTime? savedAt(Map<String, dynamic> draft) =>
        DateTime.tryParse('${draft['timestamp']}');

    return drafts.toList()
      ..sort((a, b) {
        final timeA = savedAt(a);
        final timeB = savedAt(b);
        if (timeA == null && timeB == null) return 0;
        if (timeA == null) return 1;
        if (timeB == null) return -1;
        return timeB.compareTo(timeA);
      });
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
      // 後から失敗した場合もログに残す
      unawaited(write.catchError((Object e) {
        print('❌ $description の同期に失敗しました: $e');
      }));
    }
  }

  // ─── 下絵画像 ───

  static Future<File> _guideImageCacheFile(String draftId) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/draft_guide_images/$draftId.jpg');
  }

  /// 下絵画像を圧縮して Firestore に保存し、端末内にもキャッシュする
  static Future<void> _saveGuideImage(String draftId, File source) async {
    final cacheFile = await _guideImageCacheFile(draftId);
    // 同じ下書きの下絵を開いたまま保存し直す場合は、保存済みのものをそのまま使う
    // （キャッシュは Firestore に保存したとき、または Firestore から取得したときに作る）
    if (source.absolute.path == cacheFile.absolute.path) return;

    final Uint8List bytes;
    if (source.parent.absolute.path == cacheFile.parent.absolute.path &&
        await source.length() <= maxGuideImageBytes) {
      // 別の下書き用に圧縮済みの下絵は、圧縮し直さずに使う
      bytes = await source.readAsBytes();
    } else {
      final original = await source.readAsBytes();
      bytes = await Isolate.run(() => compressGuideImage(original));
    }

    await _waitForServer(
      _guideImageDoc(draftId).set({
        'image': Blob(bytes),
        'updatedAt': DateTime.now().toIso8601String(),
      }),
      description: '下絵の保存 ($draftId)',
    );

    if (source.absolute.path != cacheFile.absolute.path) {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
    }
    print('✅ 下絵をFirestoreに保存しました: $draftId (${bytes.length} bytes)');
  }

  /// 下絵画像を Firestore に収まる大きさの JPEG にする（別の Isolate で実行する）
  @visibleForTesting
  static Uint8List compressGuideImage(Uint8List original) {
    final decoded = img.decodeImage(original);
    if (decoded == null) {
      // 読めない形式（HEIC など）でも、上限に収まるならそのまま保存する
      if (original.length <= maxGuideImageBytes) return original;
      throw const FormatException('下絵画像の形式に対応していません');
    }

    // 写真の向き（EXIF）を画素に反映する。JPEG に書き直すと向きの情報が消えるため
    var image = img.bakeOrientation(decoded);
    var longestSide = math.max(image.width, image.height);
    if (longestSide > maxGuideImageSide) {
      image = _resizeLongestSide(image, maxGuideImageSide);
      longestSide = maxGuideImageSide;
    }

    var quality = 85;
    while (true) {
      final encoded = img.encodeJpg(image, quality: quality);
      if (encoded.length <= maxGuideImageBytes) return encoded;
      if (quality > 55) {
        quality -= 15;
      } else if (longestSide > 400) {
        longestSide = (longestSide * 0.75).round();
        image = _resizeLongestSide(image, longestSide);
      } else {
        throw const FormatException('下絵画像を小さくできませんでした');
      }
    }
  }

  static img.Image _resizeLongestSide(img.Image image, int longestSide) {
    return image.width >= image.height
        ? img.copyResize(image, width: longestSide)
        : img.copyResize(image, height: longestSide);
  }

  static Future<void> _deleteGuideImage(String draftId) async {
    try {
      await _waitForServer(
        _guideImageDoc(draftId).delete(),
        description: '下絵の削除 ($draftId)',
      );
      final cacheFile = await _guideImageCacheFile(draftId);
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (e) {
      print('❌ 下絵の削除エラー ($draftId): $e');
    }
  }

  // ─── 以前の形式（端末内の JSON ファイル）の下書き ───

  static Future<Directory> _legacyDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    return Directory('${directory.path}/drafts');
  }

  static Future<File?> _legacyFileOf(String draftId) async {
    final file = File('${(await _legacyDirectory()).path}/$draftId.json');
    return await file.exists() ? file : null;
  }

  static Future<List<_LegacyDraft>> _loadLegacyFiles() async {
    try {
      final draftsDirectory = await _legacyDirectory();
      if (!(await draftsDirectory.exists())) return [];

      final files = draftsDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'));
      return Future.wait(files.map(_LegacyDraft.read));
    } catch (e) {
      print('❌ 端末内の下書きの読み込みエラー: $e');
      return [];
    }
  }

  /// 端末内の下書きを Firestore に移し、届いたらファイルを削除する
  ///
  /// サーバーに届いたことを確かめてから消すため、オフラインの間はファイルを残し、
  /// 次に読み込んだときに改めて移す（同じ ID で書くので重複しない）
  static Future<void> _migrate(
    CollectionReference<Map<String, dynamic>> collection,
    _LegacyDraft legacy,
  ) async {
    if (!_migratingIds.add(legacy.draftId)) return;
    try {
      final data = Map<String, dynamic>.from(legacy.data)
        ..remove('draftId')
        ..remove('guideImagePath');

      // 下絵が端末内に残っていれば、一緒に移す
      final legacyImagePath = legacy.data['guideImagePath'] as String?;
      final legacyImage = legacyImagePath == null ? null : File(legacyImagePath);
      data['hasGuideImage'] = false;
      if (legacyImage != null && await legacyImage.exists()) {
        try {
          await _saveGuideImage(legacy.draftId, legacyImage);
          data['hasGuideImage'] = true;
        } catch (e) {
          print('❌ 端末内の下書きの下絵を移せませんでした (${legacy.draftId}): $e');
        }
      }

      await collection.doc(legacy.draftId).set(data);
      await _deleteLegacyFile(legacy.file);
      print('✅ 端末内の下書きをFirestoreに移しました: ${legacy.draftId}');
    } catch (e) {
      print('❌ 端末内の下書きの移行エラー (${legacy.draftId}): $e');
    } finally {
      _migratingIds.remove(legacy.draftId);
    }
  }

  static Future<void> _deleteLegacyFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      print('❌ 端末内の下書きファイルの削除エラー (${file.path}): $e');
    }
  }
}

/// 端末内の JSON ファイルとして保存されている下書き
class _LegacyDraft {
  final File file;
  final Map<String, dynamic> data;

  /// 中身を読めたか（読めないファイルも一覧には出し、削除できるようにする）
  final bool readable;

  _LegacyDraft(this.file, this.data, {required this.readable});

  String get draftId => data['draftId'] as String;

  static String _idOf(File file) {
    final name = file.uri.pathSegments.last;
    return name.substring(0, name.length - '.json'.length);
  }

  static Future<_LegacyDraft> read(File file) async {
    final draftId = _idOf(file);
    try {
      final decoded = jsonDecode(await file.readAsString());
      final data = Map<String, dynamic>.from(decoded as Map);
      data['draftId'] = draftId;
      data['timestamp'] ??= '不明な日時';
      return _LegacyDraft(file, data, readable: true);
    } catch (e) {
      return _LegacyDraft(
        file,
        {'draftId': draftId, 'timestamp': '不明な日時'},
        readable: false,
      );
    }
  }
}
