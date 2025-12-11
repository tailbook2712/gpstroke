import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'firestore_service.dart';

class DatabaseHelper {
  static final _databaseName = "walking_tracker.db";
  static final _databaseVersion = 1;

  static final tableWalkingData = 'walking_data';
  static final usedTrajectoriesTable = 'used_trajectories';
  static final usedGarminActivitiesTable = 'used_garmin_activities';

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

  static Database? _database;
  final FirestoreService _firestoreService = FirestoreService();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  _initDatabase() async {
    String path = join(await getDatabasesPath(), _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
    );
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
  }

  // 歩行データを保存
  Future<int> insertWalkingData({
    required String groupId,
    required String date,
    required int steps,
    required double distance,
    required List<Map<String, dynamic>> positions,
  }) async {
    Database db = await database;

    // groupIdが既に存在するか確認
    List<Map<String, dynamic>> existingData = await db.query(
      tableWalkingData,
      where: '$columnGroupId = ?',
      whereArgs: [groupId],
    );

    if (existingData.isNotEmpty) {
      print("データ重複のため挿入をスキップ: groupId = $groupId");
      return 0; // 既存データがある場合は挿入をスキップ
    }

    final result = await db.insert(
      tableWalkingData,
      {
        columnGroupId: groupId,
        columnDate: date,
        columnSteps: steps,
        columnDistance: distance,
        columnPositions: jsonEncode(positions),
        columnIsFromGarmin: 0,
      },
    );

    return result;
  }

  // 指定したグループIDのデータを取得
  Future<Map<String, dynamic>?> getWalkingDataByGroupId(String groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(
      tableWalkingData,
      where: '$columnGroupId = ?',
      whereArgs: [groupId],
    );
    return result.isNotEmpty ? result.first : null;
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

  /// 使用済み軌跡をFirestoreと同期（統一スキーマ対応）
  Future<void> syncUsedTrajectoriesFromFirestore() async {
    try {
      // Firestoreから使用済み軌跡をすべて取得（新統一スキーマ）
      List<Map<String, dynamic>> remoteTrajectories =
          await _firestoreService.getUsedTrajectoriesFromFirestore();

      if (remoteTrajectories.isEmpty) {
        print("📌 Firestore上に使用済み軌跡がありません");
        return;
      }

      // ローカルDBから既存の使用済みgroupIdを取得
      List<String> localGroupIds = await getUsedTrajectories();

      // Firestoreから取得した新たなgroupIdをローカルDBに追加
      Database db = await database;
      Batch batch = db.batch();

      for (final remote in remoteTrajectories) {
        final groupId = remote['groupId'] as String;
        if (!localGroupIds.contains(groupId)) {
          batch.insert(
            usedTrajectoriesTable,
            {columnUsedTrajectoryGroupId: groupId},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      await batch.commit();
      print(
          "✅ Firestoreから新たに同期した使用済み軌跡: ${remoteTrajectories.length - localGroupIds.length}件");
    } catch (e) {
      print("❌ 使用済みローカル軌跡の同期エラー: $e");
    }
  }

  /// 指定インデックスのローカル軌跡のgroupIdを取得
  Future<String?> getGroupIdByIndex(int index) async {
    List<Map<String, dynamic>> allData = await getAllWalkingData();
    if (index >= 0 && index < allData.length) {
      return allData[index][columnGroupId] as String;
    }
    return null;
  }

  /// すべての記録を取得するメソッド（日付の降順で並べ替え）
  Future<List<Map<String, dynamic>>> getAllWalkingData() async {
    Database db = await database;
    return await db.query(
      tableWalkingData,
      orderBy: '$columnDate DESC',
    );
  }

  // データ削除 (指定したグループIDのデータを削除)
  Future<void> deleteWalkingDataByGroupId(String groupId) async {
    Database db = await database;
    await db.delete(tableWalkingData,
        where: '$columnGroupId = ?', whereArgs: [groupId]);
  }

  // 指定したグループIDに対応する記録を取得
  Future<Map<String, dynamic>?> getRecordByGroupId(String groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(
      tableWalkingData, // 正しいテーブル名を指定
      where: '$columnGroupId = ?', // 条件
      whereArgs: [groupId.toString()], // 条件の引数
    );

    // デバッグログ
    print("getRecordByGroupId: groupId = $groupId, result = $result");

    // 結果が存在する場合は最初のレコードを返す。ない場合は null を返す
    return result.isNotEmpty ? result.first : null;
  }

  Future<List<Map<String, dynamic>>> getPositionsByGroupId(
      String groupId) async {
    Database db = await database;

    // groupId に対応するデータを取得
    List<Map<String, dynamic>> result = await db.query(
      tableWalkingData,
      columns: [columnPositions],
      where: '$columnGroupId = ?',
      whereArgs: [groupId.toString()],
    );

    // データが空の場合は空のリストを返す
    if (result.isEmpty) {
      return [];
    }

    // positions を JSON デコードしてリストに変換
    String positionsJson = result.first[columnPositions] as String;

    return (jsonDecode(positionsJson) as List)
        .cast<Map<String, dynamic>>(); // Map<String, dynamic> のリストにキャスト
  }

  Future<void> debugPrintAllWalkingData() async {
    // デバッグ用メソッド - 将来の使用に備えて保持
    // List<Map<String, dynamic>> allData = await database.then((db) => db.query(tableWalkingData));
    // print("All walking data: $allData");
  }

  /// Garmin データソースのデータを取得
  Future<List<Map<String, dynamic>>> getGarminActivities() async {
    Database db = await database;
    // ローカルDBから取得
    List<Map<String, dynamic>> localResult = await db.query(
      tableWalkingData,
      where: '$columnIsFromGarmin = ?',
      whereArgs: [1],
      orderBy: '$columnDate DESC',
    );

    print('📌 ローカルDB Garmin軌跡: ${localResult.length}件');
    for (final r in localResult) {
      print('   - group_id: ${r['group_id']}, date: ${r['date']}');
    }

    // Firestoreからも取得（アプリ再インストール後の復元用）
    // is_from_garmin: true の軌跡をすべて取得
    List<Map<String, dynamic>> firestoreResult =
        await _firestoreService.getAllWalkingData();
    firestoreResult = firestoreResult
        .where((activity) => activity['is_from_garmin'] == true)
        .toList();

    // ローカルDBのgroupIdセットを作成
    final localGroupIds =
        Set<String>.from(localResult.map((r) => r['group_id'] as String));

    print('📌 Firestore merge処理開始');
    // Firebaseにのみ存在するものを追加
    for (final activity in firestoreResult) {
      if (!localGroupIds.contains(activity['groupId'])) {
        print('   ✅ Firebase only: ${activity['groupId']} を追加');
        // Firebase形式からDB形式に変換
        activity['group_id'] = activity['groupId'];
        activity['is_from_garmin'] = 1;
        localResult.add(activity);
      } else {
        print('   ⏭️  既存: ${activity['groupId']} はスキップ');
      }
    }

    // 日付でソート（最新順）
    localResult.sort((a, b) {
      final dateA = DateTime.tryParse(a['date'] as String) ?? DateTime.now();
      final dateB = DateTime.tryParse(b['date'] as String) ?? DateTime.now();
      return dateB.compareTo(dateA);
    });

    print('📌 Garmin軌跡取得完了: 合計=${localResult.length}件');
    return localResult;
  }

  /// 特定のデータソースを持つデータをすべて取得
  Future<List<Map<String, dynamic>>> getActivitiesBySource(
      String source) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(
      tableWalkingData,
      where: '$columnGroupId LIKE ?',
      whereArgs: ['${source}_%'],
      orderBy: '$columnDate DESC',
    );
    return result;
  }

  /// 特定のgroupIdでGarmin軌跡を取得
  Future<Map<String, dynamic>?> getGarminActivityByGroupId(
      String groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(
      tableWalkingData,
      where: '$columnGroupId = ? AND $columnIsFromGarmin = ?',
      whereArgs: [groupId, 1],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  /// Garmin軌跡がまだ使用可能かチェック
  Future<bool> isGarminActivityAvailable(String groupId) async {
    Database db = await database;
    final result = await db.query(
      usedGarminActivitiesTable,
      where: '$columnUsedGarminGroupId = ?',
      whereArgs: [groupId],
    );
    return result.isEmpty; // 見つからなければ使用可能
  }

  /// 使用済みGarmin軌跡のリストを取得（ローカルDB + Firebase統一スキーマ）
  Future<List<String>> getUsedGarminActivityGroupIds() async {
    // ローカルDBから使用済み軌跡をすべて取得
    Database db = await database;
    final localUsedResult = await db.query(usedTrajectoriesTable);
    final localUsedGroupIds = localUsedResult
        .map((row) => row[columnUsedTrajectoryGroupId] as String)
        .toList();

    // そのうち、Garmin軌跡である is_from_garmin: true のものをフィルタリング
    List<Map<String, dynamic>> allWalkingData = await getAllWalkingData();
    final localGarminGroupIds = allWalkingData
        .where((data) =>
            localUsedGroupIds.contains(data['group_id']) &&
            data['is_from_garmin'] == 1)
        .map((data) => data['group_id'] as String)
        .toList();

    // Firebaseからも取得（統一スキーマの used_trajectories コレクションから is_from_garmin: true のみ取得）
    final firestoreUsedTrajectories =
        await _firestoreService.getUsedTrajectoriesFromFirestore();
    final firestoreGarminGroupIds = firestoreUsedTrajectories
        .where((t) => t['is_from_garmin'] == true)
        .map((t) => t['groupId'] as String)
        .toList();

    // マージして重複を除去
    final allGroupIds =
        {...localGarminGroupIds, ...firestoreGarminGroupIds}.toList();
    print(
        '使用済みGarmin軌跡: ローカル=${localGarminGroupIds.length}, Firebase=${firestoreGarminGroupIds.length}, マージ後=${allGroupIds.length}');
    return allGroupIds;
  }

  /// Firebase復元時にローカルDBに同期（使用済みGarmin軌跡・統一スキーマ）
  Future<void> syncUsedGarminActivitiesFromFirestore() async {
    Database db = await database;
    // 統一スキーマから使用済み軌跡を取得（is_from_garmin: true のみ）
    final firestoreUsedTrajectories =
        await _firestoreService.getUsedTrajectoriesFromFirestore();
    final firestoreGarminGroupIds = firestoreUsedTrajectories
        .where((t) => t['is_from_garmin'] == true)
        .map((t) => t['groupId'] as String)
        .toList();

    print('📌 Firebase同期開始: 使用済みGarmin軌跡 ${firestoreGarminGroupIds.length}件');

    for (final groupId in firestoreGarminGroupIds) {
      // ローカルDBに既に存在するか確認
      final result = await db.query(
        usedTrajectoriesTable,
        where: '$columnUsedTrajectoryGroupId = ?',
        whereArgs: [groupId],
      );

      if (result.isEmpty) {
        // ローカルDBに追加
        await db.insert(
          usedTrajectoriesTable,
          {columnUsedTrajectoryGroupId: groupId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        print('  ✅ ローカルDB同期: $groupId');
      }
    }
    print('📌 Firebase同期完了');
  }

  /// Firebase復元時にローカルDBに同期（Garmin軌跡本体）
  Future<void> syncGarminActivitiesFromFirestore() async {
    Database db = await database;
    // Firestoreからすべてのwalking_dataを取得し、is_from_garmin: true のもののみフィルタリング
    List<Map<String, dynamic>> allActivities =
        await _firestoreService.getAllWalkingData();
    final firestoreActivities = allActivities
        .where((activity) => activity['is_from_garmin'] == true)
        .toList();

    print('📌 Garmin軌跡Firebase同期開始: ${firestoreActivities.length}件');

    for (final activity in firestoreActivities) {
      final groupId = activity['groupId'] as String;

      // ローカルDBに既に存在するか確認
      final result = await db.query(
        tableWalkingData,
        where: '$columnGroupId = ?',
        whereArgs: [groupId],
      );

      if (result.isEmpty) {
        // ローカルDBに追加
        await db.insert(
          tableWalkingData,
          {
            columnGroupId: groupId,
            columnDate: activity['date'] ?? DateTime.now().toIso8601String(),
            columnSteps: activity['steps'] ?? 0,
            columnDistance: activity['distance'] ?? 0.0,
            columnPositions: jsonEncode(activity['positions'] ?? []),
            columnIsFromGarmin: 1,
          },
        );
        print('  ✅ ローカルDB同期: $groupId');
      }
    }
    print('📌 Garmin軌跡同期完了');
  }
}
