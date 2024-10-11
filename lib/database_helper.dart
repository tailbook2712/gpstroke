import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:geolocator/geolocator.dart'; // Positionクラスをインポート

// データベースクラス
class DatabaseHelper {
  static final _databaseName = "walking_tracker.db";
  static final _databaseVersion = 1;

  static final table = 'walking_positions';
  
  static final columnId = '_id';
  static final columnGroupId = 'group_id';
  static final columnLatitude = 'latitude';
  static final columnLongitude = 'longitude';
  static final columnTimestamp = 'timestamp';

  static Database? _database;

  // データベースを初期化するメソッド
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // データベースを初期化
  _initDatabase() async {
    String path = join(await getDatabasesPath(), _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
    );
  }

  // テーブルを作成
  Future _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $table (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnGroupId INTEGER,
        $columnLatitude REAL NOT NULL,
        $columnLongitude REAL NOT NULL,
        $columnTimestamp TEXT NOT NULL
      )
    ''');
  }

  // 新しい位置情報を挿入
  Future<int> insertPosition(int groupId, double latitude, double longitude, String timestamp) async {
    Database db = await database;
    return await db.insert(
      table,
      {
        columnGroupId: groupId,
        columnLatitude: latitude,
        columnLongitude: longitude,
        columnTimestamp: timestamp,
      },
    );
  }

  // 新しい位置情報グループIDを取得
  Future<int> getNewGroupId() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT MAX($columnGroupId) as maxId FROM $table');
    int? groupId = result.first['maxId'] as int?;
    return (groupId != null ? groupId + 1 : 1);
  }

  // グループIDをすべて取得するメソッド
  Future<List<int>> getAllGroupIds() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT DISTINCT $columnGroupId FROM $table');
    return result.map((row) => row[columnGroupId] as int).toList();
  }

  // 指定したグループの位置情報を取得するメソッド
  Future<List<Map<String, dynamic>>> getPositionsByGroupId(int groupId) async {
    Database db = await database;
    return await db.query(table, where: '$columnGroupId = ?', whereArgs: [groupId]);
  }

  // 指定したグループIDの位置情報をPositionオブジェクトとして取得
  Future<List<Position>> getPositionsAsPositionsByGroupId(int groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(table, where: '$columnGroupId = ?', whereArgs: [groupId]);
    
    return result.map((row) {
      return Position(
        latitude: row[columnLatitude],
        longitude: row[columnLongitude],
        timestamp: DateTime.parse(row[columnTimestamp]),
        accuracy: 0.0, // デフォルト値
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );
    }).toList();
  }
}