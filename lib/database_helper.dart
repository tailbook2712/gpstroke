import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:geolocator/geolocator.dart';

// データベースクラス
class DatabaseHelper {
  static final _databaseName = "walking_tracker.db";
  static final _databaseVersion = 1;

  static final tablePositions = 'walking_positions';
  static final tableRecords = 'walking_records';

  // walking_positions テーブルのカラム
  static final columnId = '_id';
  static final columnGroupId = 'group_id';
  static final columnLatitude = 'latitude';
  static final columnLongitude = 'longitude';
  static final columnTimestamp = 'timestamp';

  // walking_records テーブルのカラム
  static final columnRecordId = '_id';
  static final columnRecordGroupId = 'group_id';
  static final columnDate = 'date';
  static final columnSteps = 'steps';
  static final columnDistance = 'distance';

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
    // walking_positions テーブル
    await db.execute('''
      CREATE TABLE $tablePositions (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnGroupId INTEGER,
        $columnLatitude REAL NOT NULL,
        $columnLongitude REAL NOT NULL,
        $columnTimestamp TEXT NOT NULL
      )
    ''');

    // walking_records テーブル
    await db.execute('''
      CREATE TABLE $tableRecords (
        $columnRecordId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnRecordGroupId INTEGER NOT NULL,
        $columnDate TEXT NOT NULL,
        $columnSteps INTEGER NOT NULL,
        $columnDistance REAL NOT NULL
      )
    ''');
  }

  // 新しい位置情報を挿入
  Future<int> insertPosition(int groupId, double latitude, double longitude, String timestamp) async {
    Database db = await database;
    return await db.insert(
      tablePositions,
      {
        columnGroupId: groupId,
        columnLatitude: latitude,
        columnLongitude: longitude,
        columnTimestamp: timestamp,
      },
    );
  }

  // 新しい歩行記録を挿入 (group_id, date, steps, distance)
  Future<int> insertRecord(Map<String, dynamic> record) async {
    Database db = await database;
    return await db.insert(tableRecords, record);
  }

  // すべての位置情報を取得
  Future<List<Map<String, dynamic>>> getAllPositions() async {
    Database db = await database;
    return await db.query(tablePositions);
  }

  // 新しい位置情報グループIDを取得
  Future<int> getNewGroupId() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT MAX($columnGroupId) as maxId FROM $tablePositions');
    int? groupId = result.first['maxId'] as int?;
    return (groupId != null ? groupId + 1 : 1);
  }

  // グループIDをすべて取得するメソッド
  Future<List<int>> getAllGroupIds() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT DISTINCT $columnGroupId FROM $tablePositions');
    return result.map((row) => row[columnGroupId] as int).toList();
  }

  // 指定したグループの位置情報を取得するメソッド
  Future<List<Map<String, dynamic>>> getPositionsByGroupId(int groupId) async {
    Database db = await database;
    return await db.query(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
  }

  // 指定したグループIDの位置情報をPositionオブジェクトとして取得
  Future<List<Position>> getPositionsAsPositionsByGroupId(int groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
    
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
  
  // 指定したグループを削除するメソッド
  Future<void> deletePositionGroup(int groupId) async {
    Database db = await database;
    await db.delete(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
    await db.delete(tableRecords, where: '$columnRecordGroupId = ?', whereArgs: [groupId]);
  }
}