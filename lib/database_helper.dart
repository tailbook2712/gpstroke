import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:geolocator/geolocator.dart';

class DatabaseHelper {
  static final _databaseName = "walking_tracker.db";
  static final _databaseVersion = 1;

  static final tablePositions = 'walking_positions';
  static final tableRecords = 'walking_records';
  static final usedTrajectoriesTable = 'used_trajectories';

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
      CREATE TABLE $tablePositions (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnGroupId INTEGER,
        $columnLatitude REAL NOT NULL,
        $columnLongitude REAL NOT NULL,
        $columnTimestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableRecords (
        $columnRecordId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnRecordGroupId INTEGER NOT NULL,
        $columnDate TEXT NOT NULL,
        $columnSteps INTEGER NOT NULL,
        $columnDistance REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $usedTrajectoriesTable (
        $columnTrajectoryIndex INTEGER PRIMARY KEY
      )
    ''');
  }

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

  Future<int> insertRecord(Map<String, dynamic> record) async {
    Database db = await database;
    return await db.insert(tableRecords, record);
  }

  Future<void> insertUsedTrajectory(int trajectoryIndex) async {
    Database db = await database;
    await db.insert(
      usedTrajectoriesTable,
      {columnTrajectoryIndex: trajectoryIndex},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<int>> getUsedTrajectories() async {
    Database db = await database;
    final result = await db.query(usedTrajectoriesTable);
    return result.map((row) => row[columnTrajectoryIndex] as int).toList();
  }

  Future<List<Map<String, dynamic>>> getAllPositions() async {
    Database db = await database;
    return await db.query(tablePositions);
  }

  Future<int> getNewGroupId() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT MAX($columnGroupId) as maxId FROM $tablePositions');
    int? groupId = result.first['maxId'] as int?;
    return (groupId != null ? groupId + 1 : 1);
  }

  Future<List<int>> getAllGroupIds() async {
    Database db = await database;
    var result = await db.rawQuery('SELECT DISTINCT $columnGroupId FROM $tablePositions');
    return result.map((row) => row[columnGroupId] as int).toList();
  }

  Future<List<Map<String, dynamic>>> getPositionsByGroupId(int groupId) async {
    Database db = await database;
    return await db.query(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
  }

  Future<List<Position>> getPositionsAsPositionsByGroupId(int groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
    
    return result.map((row) {
      return Position(
        latitude: row[columnLatitude],
        longitude: row[columnLongitude],
        timestamp: DateTime.parse(row[columnTimestamp]),
        accuracy: 0.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );
    }).toList();
  }

  Future<void> deletePositionGroup(int groupId) async {
    Database db = await database;
    await db.delete(tablePositions, where: '$columnGroupId = ?', whereArgs: [groupId]);
    await db.delete(tableRecords, where: '$columnRecordGroupId = ?', whereArgs: [groupId]);
  }

  Future<List<Map<String, dynamic>>> getAllRecords() async {
    Database db = await database;
    return await db.query(
      tableRecords,
      orderBy: '$columnDate DESC',
    );
  }

  // 指定したグループIDの記録を取得するメソッド
  Future<Map<String, dynamic>?> getRecordByGroupId(int groupId) async {
    Database db = await database;
    List<Map<String, dynamic>> result = await db.query(
      tableRecords,
      where: '$columnRecordGroupId = ?',
      whereArgs: [groupId],
    );
    return result.isNotEmpty ? result.first : null;
  }
}