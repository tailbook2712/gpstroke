import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:geolocator/geolocator.dart';

class DatabaseHelper {
  static final _databaseName = "walking_tracker.db";
  static final _databaseVersion = 1;

  static final tableWalkingData = 'walking_data';
  static final usedTrajectoriesTable = 'used_trajectories';

  // walking_data テーブルのカラム
  static final columnId = '_id';
  static final columnGroupId = 'group_id';
  static final columnDate = 'date';
  static final columnSteps = 'steps';
  static final columnDistance = 'distance';
  static final columnPositions = 'positions'; // JSON形式で位置情報を保存

  // used_trajectories テーブルのカラム
  static final columnTrajectoryIndex = 'trajectory_index';

  static Database? _database;

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
        $columnPositions TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $usedTrajectoriesTable (
        $columnTrajectoryIndex INTEGER PRIMARY KEY
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

    return await db.insert(
      tableWalkingData,
      {
        columnGroupId: groupId,
        columnDate: date,
        columnSteps: steps,
        columnDistance: distance,
        columnPositions: jsonEncode(positions),
      },
    );
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
  Future<void> insertUsedTrajectory(int trajectoryIndex) async {
    Database db = await database;
    await db.insert(
      usedTrajectoriesTable,
      {columnTrajectoryIndex: trajectoryIndex},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // 使用済み軌跡インデックスの取得
  Future<List<int>> getUsedTrajectories() async {
    Database db = await database;
    final result = await db.query(usedTrajectoriesTable);
    return result.map((row) => row[columnTrajectoryIndex] as int).toList();
  }

  // すべての記録を取得するメソッド（日付の降順で並べ替え）
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
    await db.delete(tableWalkingData, where: '$columnGroupId = ?', whereArgs: [groupId]);
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

  Future<List<Map<String, dynamic>>> getPositionsByGroupId(String groupId) async {
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
    Database db = await database;
    List<Map<String, dynamic>> allData = await db.query(tableWalkingData);
    // print("All walking data: $allData");
  }
}