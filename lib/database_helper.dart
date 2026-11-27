import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'auth_service.dart';

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
