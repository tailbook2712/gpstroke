import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'auth_service.dart';

class DatabaseHelper {
  // v2: saved_routes テーブルを追加
  static final _databaseVersion = 2;

  static final savedRoutesTable = 'saved_routes';

  /// 以前の形式で軌跡を保存していた表（軌跡は Firestore の trajectories に移した）
  static final tableWalkingData = 'walking_data';

  /// 以前の形式の表（軌跡と使用済みの記録）。移行が終わった端末では削除する
  static const List<String> legacyTables = [
    'walking_data',
    'used_trajectories',
    'used_garmin_activities',
  ];

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

  // 新しく作る DB には、保存ルートの表だけを作る
  // （軌跡・使用済みの記録の表は以前の形式。以前からある DB には残っているが、
  // 移行の前に消すとデータを失うため、onUpgrade では消さず dropLegacyTables で消す）
  Future _onCreate(Database db, int version) async {
    await _createSavedRoutesTable(db);
  }

  /// 以前の形式で端末に保存していた軌跡（walking_data テーブルの行）をすべて返す
  ///
  /// 軌跡は Firestore の trajectories に保存するようになったため、
  /// TrajectoryStore.migrateLegacy が移行のために読むだけに使う。表がなければ空
  Future<List<Map<String, dynamic>>> getLegacyWalkingRows() async {
    Database db = await database;
    if (!await _tableExists(db, tableWalkingData)) return [];
    return await db.query(tableWalkingData);
  }

  /// 以前の形式の表を削除する（軌跡の移行が終わった端末で、LegacyDataCleanup が呼ぶ）
  Future<void> dropLegacyTables() async {
    Database db = await database;
    for (final table in legacyTables) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
  }

  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
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
