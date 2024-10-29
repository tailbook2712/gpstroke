import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:path_provider/path_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:walk_tracker_app/artwork_list_screen.dart';
import 'package:walk_tracker_app/artwork_creation_screen.dart';
import 'database_helper.dart';
import 'firestore_service.dart';

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

  final double distanceThreshold = 3.0;
  final double speedThreshold = 0.3;
  final double noiseThreshold = 2.0;

  late DatabaseHelper _dbHelper;
  List<List<Position>> trajectories = [];
  late FirestoreService _firestoreService;
  int _currentGroupId = 0;
  List<File> savedArtworks = [];

  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();
    _checkPermissionAndStartTracking();
    _initializeBackgroundGeolocation();
    _restoreDataFromFirestore();
    _loadTrajectories();
    _loadSavedArtworks();
    _setInitialCameraPosition();

    _polylines.add(Polyline(
      polylineId: PolylineId("current_route"),
      points: [],
      color: Colors.blue,
      width: 5,
    ));
  }

  // 絵の作成画面から戻ってきたときに、保存されたアートワークをリロードする
  Future<void> _loadSavedArtworks() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');

      if (await artworksDirectory.exists()) {
        List<FileSystemEntity> files = artworksDirectory.listSync();
        List<File> artworkFiles = files
            .whereType<File>()
            .where((file) => file.path.endsWith('.png'))
            .toList();

        setState(() {
          savedArtworks = artworkFiles;
        });
      } else {
        print("アートワークディレクトリが存在しません");
      }
    } catch (e) {
      print("アートワークのロード中にエラーが発生しました: $e");
    }
  }

  // 位置情報の取得
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

  void _startTracking() {
    setState(() {
      _isTracking = true;
    });
    bg.BackgroundGeolocation.start();
  }

  void _startRecording() async {
    setState(() {
      _isRecording = true;
      _positions.clear();
    });
    _currentGroupId = await _dbHelper.getNewGroupId();
  }

  void _stopRecording() async {
    setState(() {
      _isRecording = false;
    });

    List<Map<String, dynamic>> positionData = _positions.map((position) {
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp!.toIso8601String(),
      };
    }).toList();

    for (var position in _positions) {
      await _dbHelper.insertPosition(
        _currentGroupId,
        position.latitude,
        position.longitude,
        position.timestamp!.toIso8601String(),
      );
    }
    await _firestoreService.savePositionGroup(_currentGroupId, positionData);
  }

  void _initializeBackgroundGeolocation() {
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      _checkIfUserIsMoving(Position(
        latitude: location.coords.latitude,
        longitude: location.coords.longitude,
        timestamp: DateTime.now(),
        accuracy: location.coords.accuracy,
        altitude: location.coords.altitude,
        altitudeAccuracy: location.coords.altitudeAccuracy ?? 0.0,
        heading: location.coords.heading,
        speed: location.coords.speed,
        speedAccuracy: location.coords.speedAccuracy ?? 0.0,
        headingAccuracy: location.coords.headingAccuracy ?? 0.0,
      ));
    }, (bg.LocationError error) {
      print("[onLocation] ERROR: ${error.code}, ${error.message}");
    });

    bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 5.0,
      stopOnTerminate: false,
      startOnBoot: true,
      enableHeadless: true,
    )).then((bg.State state) {
      if (!state.enabled) {
        bg.BackgroundGeolocation.start();
      }
    });
  }

  Future<void> _checkIfUserIsMoving(Position newPosition) async {
    if (_previousPosition != null) {
      double distance = Geolocator.distanceBetween(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      if (_isNoise(distance)) {
        return;
      }

      // 速度に基づく遅延間隔を計算
      int recordingInterval;
      if (newPosition.speed < 1) {
        recordingInterval = 5000; // ゆっくり歩く場合は5秒間隔
      } else if (newPosition.speed < 5) {
        recordingInterval = 3000; // 中程度の速度の場合は3秒間隔
      } else {
        recordingInterval = 1000; // 速い速度の場合は1秒間隔
      }

      if (_isRecording) {
        _positions.add(newPosition);

        _polylines = {
          Polyline(
            polylineId: PolylineId("current_route"),
            points: _positions.map((pos) => LatLng(pos.latitude, pos.longitude)).toList(),
            color: Colors.blue,
            width: 5,
          ),
        };
        setState(() {});

        // 記録の頻度を速度に応じて調整
        await Future.delayed(Duration(milliseconds: recordingInterval));
      }

      if (newPosition.speed > speedThreshold) {
        setState(() {
          _isMoving = true;
          _currentPosition = newPosition;
        });
      } else {
        setState(() {
          _isMoving = false;
        });
      }
    } else {
      _currentPosition = newPosition;
    }

    _previousPosition = newPosition;
  }

  bool _isNoise(double distance) {
    return distance < noiseThreshold;
  }

  Future<void> _restoreDataFromFirestore() async {
    try {
      List<Map<String, dynamic>> allPositions =
          await _firestoreService.getAllPositions();
      for (var position in allPositions) {
        await _dbHelper.insertPosition(
          position['groupId'],
          position['latitude'],
          position['longitude'],
          position['timestamp'],
        );
      }
      print("Firestoreからローカルデータベースにデータを復元しました");

      // ローカルDBからデータを`trajectories`に反映
      await _loadTrajectories();
      setState(() {}); // trajectoriesの更新を反映
    } catch (e) {
      print("データの復元に失敗しました: $e");
    }
  }

  Future<void> _loadTrajectories() async {
    List<int> groupIds = await _dbHelper.getAllGroupIds();
    List<List<Position>> loadedTrajectories = [];

    for (int groupId in groupIds) {
      List<Position> positions =
          await _dbHelper.getPositionsAsPositionsByGroupId(groupId);
      loadedTrajectories.add(positions);
    }

    setState(() {
      trajectories = loadedTrajectories;
    });
  }

  void _navigateToArtworkCreationScreen() async {
    await _restoreDataFromFirestore(); // データ復元を完了してから
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => ArtworkCreationScreen(trajectories: trajectories),
        ),
    );
  }

  @override
  void dispose() {
    bg.BackgroundGeolocation.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('軌跡の記録'),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(35.0, 135.0), // 初期カメラ位置は適当な位置に設定
              zoom: 16,
            ),
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              _setInitialCameraPosition(); // マップが作成されたときにカメラを現在位置に移動
            },
            polylines: _polylines,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80.0), // ボトムナビゲーションと重ならないよう調整
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
              // 軌跡の記録画面（現在の画面）
              break;
            case 1:
              _navigateToArtworkCreationScreen();
              break;
            case 2:
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      ArtworkListScreen(savedArtworks: savedArtworks),
                ),
              );
              break;
          }
        },
      ),
    );
  }

  // 現在位置を取得してGoogle Mapのカメラ位置を設定する関数
  Future<void> _setInitialCameraPosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentPosition = position;
      });

      // Google Mapのカメラ位置を現在位置に移動
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
