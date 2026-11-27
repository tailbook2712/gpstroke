import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'auth_service.dart';
import 'firestore_service.dart';
import 'trajectory_store.dart';
import 'utils/trajectory_usage.dart';

class DatabaseHelper {
  // v2: saved_routes テーブルを追加
  static final _databaseVersion = 2;

  static final tableWalkingData = 'walking_data';
  static final usedTrajectoriesTable = 'used_trajectories';
  static final usedGarminActivitiesTable = 'used_garmin_activities';
  static final savedRoutesTable = 'saved_routes';

  // walking_data テーブルのカラム
  static final columnId = '_id';
  static final columnGroupId = 'group_id';
  static final columnDate = 'date';
  static final columnSteps = 'steps';
  static final columnDistance = 'distance';
  static final columnPositions = 'positions'; // JSON形式で位置情報を保存
  static final columnIsFromGarmin = 'is_from_garmin'; // Garminからのインポート判定

  // used_trajectories テーブルのカラム
  static final columnUsedTrajectoryGroupId = 'group_id';

  // used_garmin_activities テーブルのカラム
  static final columnUsedGarminGroupId = 'group_id';

  // saved_routes テーブルのカラム
  static final columnRouteId = '_id';
  static final columnRouteName = 'name';
  static final columnRouteCreatedAt = 'created_at';
  static final columnRouteDistance = 'distance'; // メートル単位
  static final columnRoutePoints = 'points'; // JSON形式でルート座標を保存

  // ユーザーIDごとにDBインスタンスをキャッシュ
  static final Map<String, Database> _databases = {};

  final AuthService _authService = AuthService();
  final FirestoreService _firestoreService = FirestoreService();

  String get _userId {
    final uid = _authService.userId;
    if (uid == null) throw Exception('ユーザーがログインしていません');
    return uid;
  }

  Future<Database> get database async {
    final userId = _userId;
    if (_databases[userId] != null) return _databases[userId]!;
    _databases[userId] = await _initDatabase(userId);
    return _databases[userId]!;
  }

  Future<Database> _initDatabase(String userId) async {
    final path = join(await getDatabasesPath(), 'walking_tracker_$userId.db');
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSavedRoutesTable(db);
    }
  }

  Future _createSavedRoutesTable(Database db) async {
    await db.execute('''
      CREATE TABLE $savedRoutesTable (
        $columnRouteId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnRouteName TEXT NOT NULL,
        $columnRouteCreatedAt TEXT NOT NULL,
        $columnRouteDistance REAL NOT NULL,
        $columnRoutePoints TEXT NOT NULL
      )
    ''');
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableWalkingData (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnGroupId TEXT NOT NULL,
        $columnDate TEXT NOT NULL,
        $columnSteps INTEGER NOT NULL,
        $columnDistance REAL NOT NULL,
        $columnPositions TEXT NOT NULL,
        $columnIsFromGarmin INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE $usedTrajectoriesTable (
        $columnUsedTrajectoryGroupId TEXT PRIMARY KEY
      )
    ''');

    await db.execute('''
      CREATE TABLE $usedGarminActivitiesTable (
        $columnUsedGarminGroupId TEXT PRIMARY KEY
      )
    ''');

    await _createSavedRoutesTable(db);
  }

  // 使用済み軌跡インデックスを保存
  /// ローカル軌跡をgroupIdで使用済みマーク
  /// 軌跡を使用済みとしてマーク（統一メソッド）
  Future<void> markTrajectoryAsUsed(String groupId) async {
    Database db = await database;

    // ローカルDBに保存
    await db.insert(
      usedTrajectoriesTable,
      {columnUsedTrajectoryGroupId: groupId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Firestoreにも同期
    await _firestoreService.markTrajectoryAsUsedInFirestore(groupId);

    print("✅ 軌跡を使用済みとしてマーク: $groupId");
  }

  /// ローカルDBのみに使用済み軌跡を保存（Firestore同期なし）
  Future<void> markTrajectoryAsUsedLocally(String groupId) async {
    Database db = await database;

    await db.insert(
      usedTrajectoriesTable,
      {columnUsedTrajectoryGroupId: groupId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    print("✅ 軌跡をローカルDBに使用済みとしてマーク: $groupId");
  }

  /// レガシーメソッド（後方互換性のため）
  @deprecated
  Future<void> insertUsedTrajectory(String groupId) async {
    await markTrajectoryAsUsed(groupId);
  }

  /// レガシーメソッド（後方互換性のため）
  @deprecated
  Future<void> markGarminActivityAsUsed(String groupId) async {
    await markTrajectoryAsUsed(groupId);
  }

  /// 複数の使用済みローカル軌跡を一括で保存
  @deprecated
  Future<void> insertUsedTrajectories(List<String> groupIds) async {
    if (groupIds.isEmpty) return;

    Database db = await database;
    Batch batch = db.batch();

    for (String groupId in groupIds) {
      batch.insert(
        usedTrajectoriesTable,
        {columnUsedTrajectoryGroupId: groupId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    await batch.commit();

    // Firestoreにも同期
    for (String groupId in groupIds) {
      await _firestoreService.markTrajectoryAsUsedInFirestore(groupId);
    }
  }

  /// 使用済みローカル軌跡のgroupIdを取得
  Future<List<String>> getUsedTrajectories() async {
    Database db = await database;
    final result = await db.query(usedTrajectoriesTable);
    return result
        .map((row) => row[columnUsedTrajectoryGroupId] as String)
        .toList();
  }

  /// 使用済みの軌跡の表を、いま存在する完成作品の内容に合わせ直す
  ///
  /// 作品に使われている軌跡は、次の 3つを合わせて求める。
  /// - 作品ごとの記録（Firestore の used_trajectories サブコレクション）
  /// - Firestore 上の作品のキャンバスデータに含まれる軌跡
  ///   （記録ができる前に保存された作品のため）
  /// - 端末内の作品のキャンバスファイル [localCanvasFiles]
  ///   （Firestore への保存に失敗した作品のため）
  ///
  /// 作品の一覧をサーバーから確かに取得できたときは、表をこの内容で置き換える。
  /// 削除された作品の軌跡や、過去に誤って付いた印はここで外れ、軌跡リストに戻る。
  /// 取得に失敗したとき・キャッシュしか読めなかったときは、何も外さない。
  ///
  /// 下書きに使われている軌跡はこの表に入れない（下書きファイルの中身から求める）
  Future<void> syncUsedTrajectoriesFromFirestore({
    Iterable<File> localCanvasFiles = const [],
  }) async {
    try {
      final usage = await _firestoreService.getArtworkTrajectoryUsage();
      if (usage == null) {
        print("📌 作品の情報を取得できなかったため、使用済み軌跡の表は変更しません");
        return;
      }

      // 端末内の作品のキャンバスファイル
      final localCanvases = <Map<dynamic, dynamic>>[];
      for (final file in localCanvasFiles) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) localCanvases.add(decoded);
        } catch (e) {
          // 読めないファイルは対象から外す
        }
      }

      final usedByArtworks = {
        ...usage.recordedGroupIds,
        ...TrajectoryUsage.usedGroupIds(
          [...usage.canvases, ...localCanvases],
          await _groupIdBySignature(),
        ),
      };

      final current = (await getUsedTrajectories()).toSet();
      final next = TrajectoryUsage.reconcile(
        current: current,
        usedByArtworks: usedByArtworks,
        confirmedByServer: usage.confirmedByServer,
      );

      final toAdd = next.difference(current);
      final toRemove = current.difference(next);
      if (toAdd.isEmpty && toRemove.isEmpty) {
        print("✅ 使用済み軌跡の表は作品の内容と一致しています: ${current.length}件");
        return;
      }

      final db = await database;
      final batch = db.batch();
      for (final groupId in toRemove) {
        batch.delete(
          usedTrajectoriesTable,
          where: '$columnUsedTrajectoryGroupId = ?',
          whereArgs: [groupId],
        );
      }
      for (final groupId in toAdd) {
        batch.insert(
          usedTrajectoriesTable,
          {columnUsedTrajectoryGroupId: groupId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      print("✅ 使用済み軌跡の表を作品の内容に合わせました: "
          "追加 ${toAdd.length}件, 解除 ${toRemove.length}件");
      // 解除した軌跡は後から確認できるよう、ID を残す
      if (toRemove.isNotEmpty) print("   解除した軌跡: $toRemove");
    } catch (e) {
      print("❌ 使用済み軌跡の同期エラー: $e");
    }
  }

  /// 手持ちの軌跡（記録・取り込み）の署名 → groupId
  ///
  /// groupId を持たない古い作品の軌跡を、座標で照合するための索引
  Future<Map<String, String>> _groupIdBySignature() async {
    final index = <String, String>{};
    for (final trajectory in await TrajectoryStore.loadAll()) {
      final signature = TrajectoryUsage.signatureOfPositions(trajectory.points);
      if (signature != null) index[signature] = trajectory.id;
    }
    return index;
  }

  /// 以前の形式で端末に保存していた軌跡（walking_data テーブルの行）をすべて返す
  ///
  /// 軌跡は Firestore の trajectories に保存するようになったため、
  /// TrajectoryStore.migrateLegacy が移行のために読むだけに使う
  Future<List<Map<String, dynamic>>> getLegacyWalkingRows() async {
    Database db = await database;
    return await db.query(tableWalkingData);
  }

  // ルート提案で生成したルートを保存
  Future<int> insertSavedRoute({
    required String name,
    required double distance,
    required List<Map<String, double>> points,
  }) async {
    Database db = await database;
    return await db.insert(savedRoutesTable, {
      columnRouteName: name,
      columnRouteCreatedAt: DateTime.now().toIso8601String(),
      columnRouteDistance: distance,
      columnRoutePoints: jsonEncode(points),
    });
  }

  // 保存済みルートを新しい順に取得（points はデコード済み）
  Future<List<Map<String, dynamic>>> getSavedRoutes() async {
    Database db = await database;
    final rows = await db.query(
      savedRoutesTable,
      orderBy: '$columnRouteCreatedAt DESC',
    );
    return rows.map((row) {
      return {
        ...row,
        columnRoutePoints: (jsonDecode(row[columnRoutePoints] as String)
                as List<dynamic>)
            .cast<Map<String, dynamic>>(),
      };
    }).toList();
  }

  // 保存済みルートを削除
  Future<void> deleteSavedRoute(int id) async {
    Database db = await database;
    await db.delete(savedRoutesTable,
        where: '$columnRouteId = ?', whereArgs: [id]);
  }
}
