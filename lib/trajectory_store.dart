import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'database_helper.dart';
import 'trajectory.dart';

/// 軌跡の保存・読み込み
///
/// 軌跡は Firestore の `users/{userId}/trajectories/{trajectoryId}` に保存する。
/// 端末内には別に保存せず、Firestore の端末内キャッシュ（オフラインでも読める）を
/// 手元のデータとして使う。オフラインで保存した軌跡も端末内に残り、
/// オンラインになったときにサーバーへ送られる。
///
/// Firestore の読み込みは件数に応じて課金されるため、サーバーから読むのは
/// アプリ起動時の [sync] だけにする（#131）。
/// - その端末で初めて同期するとき: すべての軌跡
/// - 2 回目以降: 前回の同期より後に保存された軌跡だけ
///   （軌跡は追加するだけで、書き換えも削除もしないため、差分だけで足りる）
///
/// 画面で使う軌跡は、端末内のキャッシュから読む（[loadAll]・[get]）。
/// 座標の復元をやり直さないよう、読み込んだ軌跡はメモリにも持っておく。
class TrajectoryStore {
  TrajectoryStore._();

  /// オフラインのとき、サーバーへの反映を待たずに先へ進むまでの時間
  ///
  /// Firestore は書き込みを端末内のキャッシュに即座に反映し、オンラインに
  /// なったときにサーバーへ送る。サーバーの応答を待ち続けると、オフラインでは
  /// 保存が終わらなくなるため、一定時間で打ち切る（書き込み自体は取り消されない）
  static const Duration _serverAckTimeout = Duration(seconds: 3);

  /// 起動時にサーバーから読み込むときに待つ時間
  static const Duration _serverReadTimeout = Duration(seconds: 20);

  /// 以前の形式から移すとき、1 回の書き込みにまとめる件数
  /// （軌跡 1 本は大きいもので 100 KB 程度になるため、少なめにする）
  static const int _migrationBatchSize = 20;

  /// 前回の同期で読み込んだ軌跡のうち、最も新しい保存日時（ユーザーごと）
  static const String _syncedUntilKeyPrefix = 'trajectoriesSyncedUntil_';

  /// 以前の形式の軌跡を移し終えた印（ユーザーごと）
  static const String _migratedKeyPrefix = 'trajectoriesMigrated_';

  /// 読み込んだ軌跡（ID → 軌跡）。[_memoryUserId] のユーザーのもの
  static String? _memoryUserId;
  static Future<Map<String, Trajectory>>? _memory;

  /// サーバーにもなかった ID（同じ画面で何度もサーバーに問い合わせないため）
  static final Set<String> _missingIds = {};

  static String get _userId {
    final userId = AuthService().userId;
    if (userId == null) {
      throw StateError('ユーザーがログインしていません');
    }
    return userId;
  }

  static CollectionReference<Map<String, dynamic>> _collection(
          String userId) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('trajectories');

  /// 軌跡を保存する。同じ ID の軌跡が既にあれば何もしない（軌跡は書き換えない）
  ///
  /// 保存した場合は true
  static Future<bool> add(Trajectory trajectory) async {
    final userId = _userId;
    final memory = await _loadMemory(userId);
    if (memory.containsKey(trajectory.id)) {
      print('⏭️ 同じ軌跡が保存済みのため、保存しません: ${trajectory.id}');
      return false;
    }

    final write = _collection(userId).doc(trajectory.id).set({
      ...trajectory.toFirestore(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    memory[trajectory.id] = trajectory;
    _missingIds.remove(trajectory.id);
    await _waitForServer(write, description: '軌跡の保存 (${trajectory.id})');
    print('✅ 軌跡を保存しました: ${trajectory.id}');
    return true;
  }

  /// 同じ ID の軌跡が保存済みか
  static Future<bool> contains(String id) async {
    return (await _loadMemory(_userId)).containsKey(id);
  }

  /// ログイン中のユーザーの軌跡を、新しい順（最後の点の時刻の降順）に返す
  static Future<List<Trajectory>> loadAll() async {
    final memory = await _loadMemory(_userId);
    return memory.values.toList()
      ..sort((a, b) => b.endedAt.compareTo(a.endedAt));
  }

  /// 軌跡を 1 本返す。見つからない場合は null
  ///
  /// 端末内にない場合（起動時の同期より前など）は、サーバーに問い合わせる
  static Future<Trajectory?> get(String id) async {
    if (id.isEmpty) return null;
    final userId = _userId;
    final memory = await _loadMemory(userId);
    final cached = memory[id];
    if (cached != null || _missingIds.contains(id)) return cached;

    try {
      final doc = await _collection(userId)
          .doc(id)
          .get()
          .timeout(_serverReadTimeout);
      final data = doc.data();
      if (data == null) {
        _missingIds.add(id);
        return null;
      }
      final trajectory = Trajectory.fromFirestore(doc.id, data);
      memory[id] = trajectory;
      return trajectory;
    } catch (e) {
      print('❌ 軌跡の取得エラー ($id): $e');
      return null;
    }
  }

  /// サーバーから軌跡を読み込む（アプリの起動時に 1 回呼ぶ）
  ///
  /// その端末で初めてのときはすべて、2 回目以降は前回より後に保存された軌跡だけを読む。
  /// オフラインなどで読めなかったときは、端末内のキャッシュのまま進む
  static Future<void> sync() async {
    final userId = _userId;
    final memory = await _loadMemory(userId);
    final prefs = await SharedPreferences.getInstance();
    final key = '$_syncedUntilKeyPrefix$userId';
    final syncedUntil = DateTime.tryParse(prefs.getString(key) ?? '');

    Query<Map<String, dynamic>> query = _collection(userId);
    if (syncedUntil != null) {
      query = query.where('createdAt',
          isGreaterThan: Timestamp.fromDate(syncedUntil));
    }

    try {
      final snapshot = await query
          .get(const GetOptions(source: Source.server))
          .timeout(_serverReadTimeout);

      DateTime? newest = syncedUntil;
      for (final doc in snapshot.docs) {
        _addDocument(memory, doc);
        final createdAt = doc.data()['createdAt'];
        if (createdAt is Timestamp) {
          final time = createdAt.toDate();
          if (newest == null || time.isAfter(newest)) newest = time;
        }
      }
      if (newest != null) {
        await prefs.setString(key, newest.toUtc().toIso8601String());
      }
      print('✅ 軌跡をサーバーから同期しました'
          '（${syncedUntil == null ? 'すべて' : '前回以降の分'}）: ${snapshot.docs.length}件');
    } on TimeoutException {
      print('⏳ 軌跡の同期: サーバーに接続できないため、端末内のデータを使います');
    } catch (e) {
      print('❌ 軌跡の同期エラー: $e');
    }
  }

  /// その端末で、以前の形式の軌跡の移行（[migrateLegacy]）が終わっているか
  static Future<bool> hasMigratedLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_migratedKeyPrefix$_userId') == true;
  }

  /// 以前の形式の軌跡（Firestore の `walking_data` と端末の SQLite）を移す
  ///
  /// 端末ごとに 1 回行う（終わったら印を付ける）。[sync] の後に呼び、
  /// trajectories にまだない軌跡だけを書き込むので、何度実行しても結果は変わらない。
  /// 端末の SQLite も読むのは、Firestore への保存に失敗して端末にしかない軌跡が
  /// ありうるため。以前のデータはここでは消さない（LegacyDataCleanup が、
  /// 新しい形式がサーバーにあることを確かめてから消す）
  static Future<void> migrateLegacy() async {
    final userId = _userId;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_migratedKeyPrefix$userId';
    if (prefs.getBool(key) == true) return;

    // サーバーの walking_data をすべて読めなかったときは、次回の起動でやり直す
    final List<Map<String, dynamic>> remoteRows;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('walking_data')
          .get(const GetOptions(source: Source.server))
          .timeout(_serverReadTimeout);
      remoteRows = [
        for (final doc in snapshot.docs) {...doc.data(), 'groupId': doc.id},
      ];
    } catch (e) {
      print('⏳ 以前の形式の軌跡を読めなかったため、移行は次回の起動で行います: $e');
      return;
    }

    List<Map<String, dynamic>> localRows = const [];
    try {
      localRows = await DatabaseHelper().getLegacyWalkingRows();
    } catch (e) {
      print('❌ 端末内の以前の形式の軌跡を読めませんでした: $e');
    }

    final memory = await _loadMemory(userId);
    final pending = <Trajectory>[];
    final seen = <String>{};
    var unreadable = 0;
    for (final row in [...remoteRows, ...localRows]) {
      final trajectory = Trajectory.fromLegacy(row);
      if (trajectory == null) {
        unreadable++;
        continue;
      }
      if (memory.containsKey(trajectory.id) || !seen.add(trajectory.id)) {
        continue;
      }
      pending.add(trajectory);
    }

    for (var i = 0; i < pending.length; i += _migrationBatchSize) {
      final chunk = pending.sublist(
          i, math.min(i + _migrationBatchSize, pending.length));
      final batch = FirebaseFirestore.instance.batch();
      for (final trajectory in chunk) {
        batch.set(_collection(userId).doc(trajectory.id), {
          ...trajectory.toFirestore(),
          'createdAt': FieldValue.serverTimestamp(),
        });
        memory[trajectory.id] = trajectory;
        _missingIds.remove(trajectory.id);
      }
      await _waitForServer(batch.commit(), description: '以前の形式の軌跡の移行');
    }

    await prefs.setBool(key, true);
    print('✅ 以前の形式の軌跡を移しました: ${pending.length}件'
        '（Firestore ${remoteRows.length}件・端末 ${localRows.length}件を確認、'
        '読めなかった軌跡 $unreadable件）');
  }

  static Future<Map<String, Trajectory>> _loadMemory(String userId) {
    if (_memoryUserId != userId) {
      _memoryUserId = userId;
      _memory = null;
      _missingIds.clear();
    }
    return _memory ??= _readCache(userId);
  }

  /// 端末内のキャッシュにある軌跡を読む（サーバーには問い合わせない）
  static Future<Map<String, Trajectory>> _readCache(String userId) async {
    final memory = <String, Trajectory>{};
    try {
      final snapshot = await _collection(userId)
          .get(const GetOptions(source: Source.cache));
      for (final doc in snapshot.docs) {
        _addDocument(memory, doc);
      }
    } catch (e) {
      print('❌ 端末内の軌跡の読み込みエラー: $e');
    }
    print('📂 端末内の軌跡: ${memory.length}件');
    return memory;
  }

  static void _addDocument(Map<String, Trajectory> memory,
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return;
    try {
      memory[doc.id] = Trajectory.fromFirestore(doc.id, data);
    } catch (e) {
      print('❌ 軌跡を読めませんでした (${doc.id}): $e');
    }
  }

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
}
