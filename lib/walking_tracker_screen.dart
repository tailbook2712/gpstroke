import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/artwork_list_screen.dart';
import 'package:walk_tracker_app/artwork_creation_screen.dart';
import 'database_helper.dart';
import 'firestore_service.dart';
import 'package:pedometer/pedometer.dart';

import 'utils/utils.dart';

class WalkingTrackerScreen extends StatefulWidget {
  @override
  _WalkingTrackerScreenState createState() => _WalkingTrackerScreenState();
}

class _WalkingTrackerScreenState extends State<WalkingTrackerScreen> {
  Position? _currentPosition;
  Position? _previousPosition;
  List<Position> _positions = [];
  bool _isMoving = false;
  bool _isTracking = false;
  bool _isRecording = false;
  double _totalDistance = 0.0;
  int _stepCount = 0;
  int _initialStepCount = 0; // 記録開始時の初期歩数

  final double distanceThreshold = 3.0;
  final double speedThreshold = 0.3;
  final double noiseThreshold = 2.0;

  late DatabaseHelper _dbHelper;
  List<List<Position>> trajectories = [];
  late FirestoreService _firestoreService;
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<StepCount>? _stepStream;
  List<Map<String, dynamic>> savedArtworks = []; // スクリーンショットとキャンバス状態のリスト

  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();

    _initializeScreen(); // 非同期初期化処理をまとめたメソッド
    _loadSavedArtworks();
    _checkPermissionAndStartTracking();
    _setInitialCameraPosition();

    // ポリラインを初期化
    _polylines.add(Polyline(
      polylineId: PolylineId("current_route"),
      points: [],
      color: Colors.blue,
      width: 5,
    ));
  }

  // 非同期初期化処理をまとめたメソッド
  Future<void> _initializeScreen() async {
    await _restoreDataFromFirestore(); // FirestoreからローカルDBにデータを復元
    await _loadTrajectories(); // 復元後にローカルDBから軌跡をロード
  }

  // 保存された作品をロード
  Future<void> _loadSavedArtworks() async {
    final directory = await getApplicationDocumentsDirectory();
    final artworksDirectory = Directory('${directory.path}/artworks');
    final canvasDirectory = Directory('${directory.path}/canvas_states');

    // 両ディレクトリが存在しない場合は空リストのまま返す
    if (!await artworksDirectory.exists() || !await canvasDirectory.exists()) {
      savedArtworks = [];
      return;
    }

    // スクリーンショットとキャンバス状態を対応付けてロード
    final artworkFiles = artworksDirectory.listSync().whereType<File>();
    final canvasFiles = canvasDirectory.listSync().whereType<File>();

    savedArtworks = artworkFiles
        .map((artworkFile) {
          // 対応するキャンバス状態ファイルを取得
          final timestamp = artworkFile.path.split('_').last.split('.').first;
          final canvasFile = canvasFiles.firstWhere(
            (file) => file.path.contains(timestamp),
            orElse: () => File(''), // 見つからなければ空ファイル（スキップ）
          );

          if (canvasFile.existsSync()) {
            return {
              'imageFile': artworkFile,
              'canvasFile': canvasFile,
            };
          }
          return null; // キャンバスファイルがない場合スキップ
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // 位置情報の許可を確認してトラッキングを開始
  Future<void> _checkPermissionAndStartTracking() async {
    LocationPermission permission;
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("位置情報の許可が拒否されました。");
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      print("位置情報の許可が永久に拒否されています。設定から変更してください。");
      return;
    }
    _startTracking();
  }

  // 位置情報のトラッキングを開始
  void _startTracking() {
    setState(() {
      _isTracking = true;
    });

    int distanceFilter = 5; // 初期の距離フィルタ(5m)
    // geolocatorのストリーミングで位置情報を取得
    _positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter, // 5mごとに位置情報を取得
      ),
    ).listen((Position position) {
      if (_isRecording) {
        _checkIfUserIsMoving(position);
        _adjustTrackingInterval(position.speed);
      }
    });
  }

  // 位置情報の記録を開始
  void _startRecording() async {
    setState(() {
      _isRecording = true;
      _totalDistance = 0.0;
      _stepCount = 0;
      _positions.clear();
    });

    // 歩数のstreamを監視
    _stepStream = Pedometer.stepCountStream.listen((StepCount event) {
      if (_isRecording) {
        setState(() {
          if (_initialStepCount == 0) {
            _initialStepCount = event.steps; // 記録開始時の歩数を保存
          }
          _stepCount = event.steps - _initialStepCount; // 初期歩数を差し引いて0からカウント
        });
      }
    });

    // 位置情報のstreamを監視
    _positionStream =
        Geolocator.getPositionStream().listen((Position position) {
      if (_isRecording) {
        _updateDistance(position);
      }
    });
  }

  // 位置情報の記録を停止
  Future<void> _stopRecording() async {
    setState(() {
      _isRecording = false;
      _initialStepCount = 0;
    });

    _positionStream?.cancel();
    _stepStream?.cancel();

    if (_positions.isEmpty) return;

    final positionData = _positions.map((position) {
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp!.toIso8601String(),
      };
    }).toList();

    final currentDate = DateTime.now().toIso8601String();
    // generateGroupId を使って groupId を生成
    String groupId = generateGroupId(_positions);

    await _dbHelper.insertWalkingData(
      groupId: groupId,
      date: currentDate,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    // Firestore に保存
    await _firestoreService.saveWalkingData(
      groupId: groupId,
      date: currentDate,
      steps: _stepCount,
      distance: _totalDistance,
      positions: positionData,
    );

    print("保存した groupId: $groupId");

    _positions.clear();
  }

  // ユーザーが移動しているかどうかをチェック
  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    if (_previousPosition != null) {
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // ノイズチェック
      if (_isNoise(distance)) {
        return; // ノイズは無視
      }

      // 記録中の場合、位置情報を追加
      if (_isRecording) {
        _updateDistance(newPosition); // 累積距離を更新
      }

      // ユーザの移動状態の更新
      setState(() {
        _isMoving = newPosition.speed > speedThreshold;
        _currentPosition = newPosition;
      });
    } else {
      _currentPosition = newPosition; // 初回の位置設定
    }
    _previousPosition = newPosition;
  }

  // ノイズの判定
  bool _isNoise(double distance) {
    return distance < noiseThreshold; // 2m以下をノイズとして判定
  }

  // 位置情報の距離を更新
  void _updateDistance(Position newPosition) {
    if (_previousPosition != null) {
      final double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // ノイズを無視し倍場合のみ距離を累積
      if (distance > noiseThreshold) {
        _totalDistance += distance;

        // ポリラインを更新
        setState(() {
          _positions.add(newPosition);
          _polylines = {
            Polyline(
              polylineId: PolylineId("current_route"),
              points: _positions
                  .map((pos) => LatLng(pos.latitude, pos.longitude))
                  .toList(),
              color: Colors.blue,
              width: 5,
            ),
          };
        });
      }
    }

    _previousPosition = newPosition;
  }

  void _adjustTrackingInterval(double speed) {
    int newDistanceFilter;

    if (speed < 1.5) {
      newDistanceFilter = 7; // ゆっくり歩行（7mごとに取得）
    } else if (speed < 3.5) {
      newDistanceFilter = 5; // 速歩（5mごとに取得）
    } else if (speed < 10.0) {
      newDistanceFilter = 3; // 走る（3mごとに取得）
    } else {
      newDistanceFilter = 2; // 速い移動（2mごとに取得）
    }

    // 現在の設定が異なる場合のみ再設定
    if (_positionStream != null) {
      _positionStream?.cancel(); // 既存のストリームを停止

      _positionStream = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: newDistanceFilter,
        ),
      ).listen((Position position) {
        if (_isRecording) {
          _checkIfUserIsMoving(position);
          _adjustTrackingInterval(position.speed); // 再度速度をチェック
        }
      });
    }
  }

  // Firestoreからデータを復元
  Future<void> _restoreDataFromFirestore() async {
    try {
      List<Map<String, dynamic>> allWalkingData =
          await _firestoreService.getAllWalkingData();
      for (var data in allWalkingData) {
        // 各フィールドを取得
        String groupId = data['groupId'] ?? 0;
        String date = data['timestamp'] ?? DateTime.now().toIso8601String();
        int steps = data['steps'] ?? 0;
        double distance = data['distance'] ?? 0.0;

        // positionsがリスト型かを確認
        if (data['positions'] is List) {
          List<Map<String, dynamic>> positions =
              List<Map<String, dynamic>>.from(data['positions']);

          // データをローカルデータベースに保存
          await _dbHelper.insertWalkingData(
            groupId: groupId,
            date: date,
            steps: steps,
            distance: distance,
            positions: positions,
          );
        } else {
          print("予期しないpositionsの形式: ${data['positions']}");
        }
      }
      print("Firestoreからローカルデータベースにデータを復元しました");
    } catch (e) {
      print("データの復元に失敗しました: $e");
    }
  }

  // ローカルデータベースから軌跡を読み込む
  Future<void> _loadTrajectories() async {
    try {
      List<Map<String, dynamic>> walkingData =
          await _dbHelper.getAllWalkingData();
      List<List<Position>> loadedTrajectories = [];

      for (var data in walkingData) {
        // positions フィールドを JSON デコード
        List<dynamic> positionsData = jsonDecode(data['positions']);

        // Position オブジェクトに変換
        List<Position> positions = positionsData.map((pos) {
          return Position(
            latitude: pos['latitude'],
            longitude: pos['longitude'],
            timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
            accuracy: 0.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          );
        }).toList();

        loadedTrajectories.add(positions);
      }

      setState(() {
        trajectories = loadedTrajectories;
      });
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  // アートワーク作成画面に遷移
  void _navigateToArtworkCreationScreen() async {
    await _loadTrajectories();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkCreationScreen(trajectories: trajectories),
      ),
    );
  }

  // アートワークギャラリー画面に遷移
  Future<void> _navigatetoArtworkGalleryScreen() async {
    await _loadSavedArtworks();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtworkListScreen(savedArtworks: savedArtworks),
      ),
    );
  }

  @override
  void dispose() {
    _positionStream?.cancel(); // Geolocatorのストリームを停止
    _stepStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('軌跡の記録', style: TextStyle(fontSize: 20)),
            SizedBox(height: 4),
            Text(
              '歩数: $_stepCount 歩  距離: ${(_totalDistance / 1000).toStringAsFixed(2)}km',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(35.0, 135.0),
              zoom: 16,
            ),
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              _setInitialCameraPosition();
            },
            polylines: _polylines,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80.0),
        child: FloatingActionButton(
          onPressed: _isRecording ? _stopRecording : _startRecording,
          child: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: [
          BottomNavigationBarItem(
            icon: Icon(Icons.location_on),
            label: '軌跡の記録',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.brush),
            label: 'アートの作成',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.collections),
            label: '絵の閲覧',
          ),
        ],
        onTap: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              _navigateToArtworkCreationScreen();
              break;
            case 2:
              _navigatetoArtworkGalleryScreen();
              break;
          }
        },
      ),
    );
  }

  Future<void> _setInitialCameraPosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentPosition = position;
      });

      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 16,
          ),
        ),
      );
    } catch (e) {
      print("現在位置を取得できませんでした: $e");
    }
  }
}