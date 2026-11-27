import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artwork.dart';
import 'artwork_store.dart';
import 'auth_service.dart';
import 'database_helper.dart';
import 'trajectory_store.dart';

/// Firestore への書き込み 1 件（ログに出すパスと、バッチに積む処理）
typedef _Write = ({String path, void Function(WriteBatch batch) apply});

/// 以前の形式のデータの片付け
///
/// 軌跡・作品・下書きを新しい形式に移した後（#148・#149）に残っている、
/// 以前の形式のデータを消す。アプリの起動時、移行の後に呼ぶ（[run]）。
///
/// - Firestore（アカウントのデータ）: 新しい形式のデータがサーバーにあることを
///   確かめたものだけを消す
///   - `walking_data/{id}`（以前の軌跡）: 同じ ID の `trajectories/{id}` がある
///   - 作品の以前のフィールド: 作品が新しい形式（schemaVersion 2）になっている。
///     画像（`imageData`）は、`artwork_images/{id}` があるときだけ消す
///   - 下書きの以前のフィールド: 下書きが `strokes` を持っている
///   - 使用済みの記録（`used_trajectories/`、`app_data/`、作品の
///     `used_trajectories/`）: もう読み書きしていないので、そのまま消す
/// - 端末: その端末で軌跡と作品ファイルの移行が終わっていれば、SQLite の以前の表と
///   以前の作品ファイル（`canvas_states/`・`artworks/`）を消す
///
/// どちらも端末ごとに 1 回行い、終わったら印を付ける。サーバーに接続できない
/// ときなどは印を付けず、次回の起動でやり直す。
/// 移行のコードは残してあるため、以前の形式のデータしかないアカウントでも、
/// 新しい版を初めて開いたときに移行してから片付ける
class LegacyDataCleanup {
  LegacyDataCleanup._();

  /// サーバーとのやり取りを待つ時間
  static const Duration _serverTimeout = Duration(seconds: 20);

  /// 1 回の書き込みにまとめる件数
  ///
  /// 以前の軌跡は座標を配列で持ち、インデックスの量が多い。大きなドキュメントを
  /// まとめて消すと、1 回の書き込みの上限を超えて invalid-argument になるため、
  /// 件数の上限（500）よりずっと小さく区切る
  static const int _batchSize = 20;

  static const String _firestoreDoneKeyPrefix = 'legacyFirestoreDataCleanedUp_';
  static const String _deviceDoneKeyPrefix = 'legacyDeviceDataCleanedUp_';

  static const GetOptions _server = GetOptions(source: Source.server);

  /// 作品ドキュメントの、以前の形式のフィールド
  static const List<String> legacyArtworkFields = [
    'imageData',
    'trajectories',
    'meta',
    'timestamp',
    'artworkId',
  ];

  /// 下書きの、以前の形式のフィールド
  static const List<String> legacyDraftFields = ['trajectories', 'timestamp'];

  /// 以前の形式のデータを片付ける（アプリの起動時、移行の後に呼ぶ）
  static Future<void> run() async {
    final userId = AuthService().userId;
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _cleanUpFirestore(userId, prefs);
    await _cleanUpDevice(userId, prefs);
  }

  /// 消してよい `walking_data` の ID（同じ ID の軌跡が trajectories にあるもの）
  static List<String> walkingDataIdsToDelete(
    Iterable<String> walkingDataIds,
    Set<String> trajectoryIds,
  ) {
    return [
      for (final id in walkingDataIds)
        if (trajectoryIds.contains(id)) id,
    ];
  }

  /// 作品ドキュメントから消す、以前の形式のフィールド
  ///
  /// 新しい形式になっていない作品からは消さない。画像（`imageData`）は、
  /// 作品画像のドキュメントがある（[hasImageDocument]）ときだけ消す
  static List<String> artworkFieldsToDelete(
    Map<String, dynamic> data, {
    required bool hasImageDocument,
  }) {
    if (!Artwork.isCurrentFormat(data)) return const [];
    return [
      for (final field in legacyArtworkFields)
        if (data.containsKey(field) &&
            (field != 'imageData' || hasImageDocument))
          field,
    ];
  }

  /// 下書きから消す、以前の形式のフィールド（新しい形式の `strokes` を持つ下書きだけ）
  static List<String> draftFieldsToDelete(Map<String, dynamic> data) {
    if (data['strokes'] is! List) return const [];
    return [
      for (final field in legacyDraftFields)
        if (data.containsKey(field)) field,
    ];
  }

  static Future<void> _cleanUpFirestore(
      String userId, SharedPreferences prefs) async {
    final key = '$_firestoreDoneKeyPrefix$userId';
    if (prefs.getBool(key) == true) return;

    final db = FirebaseFirestore.instance;
    final userDoc = db.collection('users').doc(userId);
    // 失敗したときに、どの段階で失敗したかをログに出す
    var step = '移行の書き込みの完了待ち';
    try {
      // 移行で書き込んだ内容がサーバーに届いてから、新しい形式があるかを確かめる
      await db.waitForPendingWrites().timeout(_serverTimeout);

      final deletes = <DocumentReference<Map<String, dynamic>>>[];
      final fieldDeletes =
          <DocumentReference<Map<String, dynamic>>, List<String>>{};
      final kept = <String>[];

      // 以前の軌跡
      step = '以前の軌跡の確認';
      final walkingData = await userDoc
          .collection('walking_data')
          .get(_server)
          .timeout(_serverTimeout);
      if (walkingData.docs.isNotEmpty) {
        final trajectories = await userDoc
            .collection('trajectories')
            .get(_server)
            .timeout(_serverTimeout);
        final ids = walkingDataIdsToDelete(
          walkingData.docs.map((doc) => doc.id),
          {for (final doc in trajectories.docs) doc.id},
        );
        deletes.addAll(ids.map(userDoc.collection('walking_data').doc));
        kept.addAll(walkingData.docs
            .map((doc) => doc.id)
            .where((id) => !ids.contains(id))
            .map((id) => 'walking_data/$id'));
      }

      // 作品の以前のフィールドと、作品ごとの使用済みの記録
      step = '作品の確認';
      final artworks =
          await userDoc.collection('artworks').get(_server).timeout(_serverTimeout);
      for (final doc in artworks.docs) {
        final data = doc.data();
        var hasImageDocument = false;
        if (Artwork.isCurrentFormat(data) && data.containsKey('imageData')) {
          final image = await userDoc
              .collection('artwork_images')
              .doc(doc.id)
              .get(_server)
              .timeout(_serverTimeout);
          hasImageDocument = image.exists;
        }
        final fields =
            artworkFieldsToDelete(data, hasImageDocument: hasImageDocument);
        if (fields.isNotEmpty) fieldDeletes[doc.reference] = fields;
        if (!Artwork.isCurrentFormat(data) ||
            (data.containsKey('imageData') && !hasImageDocument)) {
          kept.add('artworks/${doc.id}');
        }

        final records = await doc.reference
            .collection('used_trajectories')
            .get(_server)
            .timeout(_serverTimeout);
        deletes.addAll(records.docs.map((record) => record.reference));
      }

      // 下書きの以前のフィールド
      step = '下書きの確認';
      final drafts =
          await userDoc.collection('drafts').get(_server).timeout(_serverTimeout);
      for (final doc in drafts.docs) {
        final fields = draftFieldsToDelete(doc.data());
        if (fields.isNotEmpty) fieldDeletes[doc.reference] = fields;
      }

      // 使用済みの記録（もう読み書きしていない）
      step = '使用済みの記録の確認';
      final used = await userDoc
          .collection('used_trajectories')
          .get(_server)
          .timeout(_serverTimeout);
      deletes.addAll(used.docs.map((doc) => doc.reference));
      for (final name in ['used_trajectories', 'used_garmin_activities']) {
        final ref = userDoc.collection('app_data').doc(name);
        final snapshot = await ref.get(_server).timeout(_serverTimeout);
        if (snapshot.exists) deletes.add(ref);
      }

      // 少しずつまとめて書き込む
      step = '書き込み';
      final writes = <_Write>[
        for (final ref in deletes)
          (path: ref.path, apply: (batch) => batch.delete(ref)),
        for (final entry in fieldDeletes.entries)
          (
            path: '${entry.key.path}（${entry.value.join('・')}）',
            apply: (batch) => batch.update(entry.key, {
                  for (final field in entry.value) field: FieldValue.delete(),
                }),
          ),
      ];
      print('🧹 以前の形式のデータを片付けます: '
          'ドキュメントの削除 ${deletes.length}件, フィールドの削除 ${fieldDeletes.length}件');
      final failures = await _commitInSmallBatches(db, writes);
      if (failures.isNotEmpty) {
        print('❌ 片付けられなかったもの（次回の起動でやり直します）: '
            '${failures.length}件 $failures');
        return;
      }

      await prefs.setBool(key, true);
      print('✅ 以前の形式のデータを Firestore から消しました: '
          'ドキュメント ${deletes.length}件, フィールドを消したドキュメント ${fieldDeletes.length}件');
      if (kept.isNotEmpty) {
        print('   新しい形式が見つからないため残したもの: ${kept.length}件 $kept');
      }
    } on TimeoutException {
      print('⏳ 以前の形式のデータの片付け（$step）: '
          'サーバーに接続できないため、次回の起動で行います');
    } catch (e) {
      print('❌ 以前の形式のデータの片付けエラー（$step。次回の起動でやり直します）: $e');
    }
  }

  /// 書き込みを少しずつまとめて送り、書き込めなかったもの（パスと理由）を返す
  ///
  /// まとめて書き込めなかったときは、そのまとまりを 1 件ずつ送り直す
  /// （どのドキュメントで失敗したかを残し、ほかのものは片付けられるように）
  static Future<List<String>> _commitInSmallBatches(
      FirebaseFirestore db, List<_Write> writes) async {
    final failures = <String>[];
    for (var i = 0; i < writes.length; i += _batchSize) {
      final chunk = writes.skip(i).take(_batchSize).toList();
      try {
        final batch = db.batch();
        for (final write in chunk) {
          write.apply(batch);
        }
        await batch.commit().timeout(_serverTimeout);
      } on FirebaseException catch (e) {
        print('⚠️ まとめて書き込めなかったため、1 件ずつ書き込みます（${e.code}）');
        for (final write in chunk) {
          try {
            final batch = db.batch();
            write.apply(batch);
            await batch.commit().timeout(_serverTimeout);
          } on FirebaseException catch (e) {
            failures.add('${write.path}: ${e.code}');
          }
        }
      }
    }
    return failures;
  }

  static Future<void> _cleanUpDevice(
      String userId, SharedPreferences prefs) async {
    final key = '$_deviceDoneKeyPrefix$userId';
    if (prefs.getBool(key) == true) return;

    // 移行の前に消すと、端末にしかないデータを失う
    if (!await TrajectoryStore.hasMigratedLegacy() ||
        !await ArtworkStore.hasMigratedLocalFiles()) {
      print('⏳ この端末の移行が終わっていないため、端末内の以前のデータは次回の起動で消します');
      return;
    }

    try {
      await DatabaseHelper().dropLegacyTables();
      final directory = await getApplicationDocumentsDirectory();
      for (final name in ['canvas_states', 'artworks']) {
        final legacyDirectory = Directory('${directory.path}/$name/$userId');
        if (await legacyDirectory.exists()) {
          await legacyDirectory.delete(recursive: true);
        }
      }
      await prefs.setBool(key, true);
      print('✅ 端末内の以前の形式のデータを消しました（SQLite の表・作品ファイル）');
    } catch (e) {
      print('❌ 端末内の以前のデータの片付けエラー（次回の起動でやり直します）: $e');
    }
  }
}
