import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'database_helper.dart';
import 'polyline_painter.dart';

class ArtworkCreationScreen extends StatefulWidget {
  final List<List<Position>> trajectories;

  ArtworkCreationScreen({required this.trajectories});

  @override
  _ArtworkCreationScreenState createState() => _ArtworkCreationScreenState();
}

class _ArtworkCreationScreenState extends State<ArtworkCreationScreen> {
  List<TransformablePolyline> selectedTrajectories = [];
  TransformablePolyline? selectedItem;
  final GlobalKey _canvasKey = GlobalKey();
  final GlobalKey _boundaryKey = GlobalKey();
  final double canvasPadding = 20.0;
  List<List<Position>> recordedTrajectories = [];
  Set<int> usedTrajectoryIndices = {}; // 保存済みの軌跡インデックスを保持
  Set<int> temporarilyUsedIndices = {}; // 一時的に使用された軌跡インデックス
  final DatabaseHelper _dbHelper = DatabaseHelper();

  final double minScale = 0.5; // 縮小の下限
  final double maxScale = 1.3; // 拡大の上限
  bool isScaling = false;
  bool isRotating = false;
  final double scaleFactor = 0.05;
  final double rotationFactor = 0.1;
  bool rotateMode = false;

  @override
  void initState() {
    super.initState();
    _loadRecordTrajectories();
  }

  // データベースから保存済みの軌跡を読み込む
  Future<void> _loadRecordTrajectories() async {
    try {
      // データの重複を避けるため、recordedTrajectoriesをリセット
      recordedTrajectories.clear();

      // ローカルデータベースからデータを取得
      List<Map<String, dynamic>> allWalkingData = await _dbHelper.getAllWalkingData();

      // データを一意にするためSetを使用
      Set<String> uniqueTrajectories = {}; // JSON文字列で一意性を判断
      List<List<Position>> uniqueTrajectoryList = [];

      for (var data in allWalkingData) {
        // データベースからpositionsをデコード
        List<dynamic> positionsJson = jsonDecode(data['positions']);
        List<Position> trajectory = positionsJson.map((pos) {
          return Position(
            latitude: pos['latitude'],
            longitude: pos['longitude'],
            timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
            accuracy: 0.0,
            altitude: 0.0,
            heading: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
            altitudeAccuracy: 0.0,
            headingAccuracy: 0.0,
          );
        }).toList();

        // 軌跡をJSON形式に変換して一意性を確認
        String trajectoryJson = jsonEncode(positionsJson);
        if (!uniqueTrajectories.contains(trajectoryJson)) {
          uniqueTrajectories.add(trajectoryJson);
          uniqueTrajectoryList.add(trajectory);
        }
      }

      // 一意な軌跡をセット
      setState(() {
        recordedTrajectories = uniqueTrajectoryList;
      });

      // 使用済みの軌跡インデックスを取得
      await _loadUsedTrajectories();
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  // データベースから保存済みの軌跡インデックスを読み込む
  Future<void> _loadUsedTrajectories() async {
    try {
      final loadedUsedIndices = await _dbHelper.getUsedTrajectories();
      setState(() {
        usedTrajectoryIndices = loadedUsedIndices.toSet();
      });
    } catch (e) {
      print("使用済み軌跡の読み込みエラー: $e");
    }
  }

  // アートワークを保存する
  Future<void> _saveArtwork() async {
    try {
      RenderRepaintBoundary boundary =
          _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      var image = await boundary.toImage();
      ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');
      final canvasDirectory = Directory('${directory.path}/canvas_states');

      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true);
      }
      if (!(await canvasDirectory.exists())) {
        await canvasDirectory.create(recursive: true);
      }

      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      File imgFile = File('${artworksDirectory.path}/artwork_$timestamp.png');
      File canvasFile = File('${canvasDirectory.path}/canvas_$timestamp.json');

      final canvasState = selectedTrajectories.map((item) => {
            'positions': item.polyline.map((p) => {
                  'latitude': p.latitude,
                  'longitude': p.longitude,
                  'timestamp': p.timestamp?.toIso8601String() ?? "",
                }).toList(),
            'position': {'dx': item.position.dx, 'dy': item.position.dy},
            'scale': item.scale,
            'rotation': item.rotation,
          }).toList();
      await canvasFile.writeAsString(jsonEncode(canvasState));

      await imgFile.writeAsBytes(pngBytes);

      // 使用済みの軌跡を保存
      for (final index in temporarilyUsedIndices) {
        usedTrajectoryIndices.add(index);
        await _dbHelper.insertUsedTrajectory(index);
      }
      temporarilyUsedIndices.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークが保存されました!')),
      );
      Navigator.pop(context, {'imageFile': imgFile, 'canvasFile': canvasFile});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークの保存に失敗しました: $e')),
      );
    }
  }

  // 選択された軌跡を削除する
  void _removeSelectedTrajectory() {
    if (selectedItem != null) {
      int indexToRemove = recordedTrajectories.indexOf(selectedItem!.polyline);
      setState(() {
        selectedTrajectories.remove(selectedItem);
        if (temporarilyUsedIndices.contains(indexToRemove)) {
          temporarilyUsedIndices.remove(indexToRemove);
        }
        selectedItem = null;
      });
    }
  }

  // 使用可能な軌跡を表示するモーダルを表示する
  // 使用可能な軌跡を表示するモーダルを表示する
  void _showTrajectoryModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        // 使用可能な軌跡をフィルタリング
        final availableTrajectories = List.generate(
          recordedTrajectories.length,
          (index) => !usedTrajectoryIndices.contains(index) &&
                  !temporarilyUsedIndices.contains(index)
              ? recordedTrajectories[index]
              : null,
        ).where((trajectory) => trajectory != null).toList();

        return Container(
          height: MediaQuery.of(context).size.height * 0.5,
          padding: EdgeInsets.all(10),
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: availableTrajectories.length,
            itemBuilder: (context, index) {
              final trajectory = availableTrajectories[index];
              return GestureDetector(
                onTap: () {
                  Navigator.pop(context); // モーダルを閉じる
                  setState(() {
                    final trajectoryIndex =
                        recordedTrajectories.indexOf(trajectory!);
                    temporarilyUsedIndices.add(trajectoryIndex);
                    selectedTrajectories.add(
                      TransformablePolyline(
                        trajectory,
                        Offset(
                          MediaQuery.of(context).size.width / 2 - 120,
                          MediaQuery.of(context).size.height / 2 - 280,
                        ),
                      ),
                    );
                  });
                },
                child: CustomPaint(
                  size: Size(60, 60),
                  painter: PolylinePainter(
                    positions: trajectory!,
                    minLat: trajectory.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
                    maxLat: trajectory.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
                    minLon: trajectory.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
                    maxLon: trajectory.map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    double screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        title: Text('アート作成'),
        actions: [
          IconButton(
            icon: Icon(Icons.save),
            onPressed: _saveArtwork,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTrajectoryModal(context),
        child: Icon(Icons.add),
      ),
      body: Column(
        children: [
          Flexible(
            flex: 8,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  selectedItem = null;
                });
              },
              child: RepaintBoundary(
                key: _boundaryKey,
                child: Stack(
                  children: [
                    Stack(
                      children: selectedTrajectories.map((item) {
                        return Positioned(
                          left: item.position.dx.clamp(
                              canvasPadding, screenWidth - canvasPadding),
                          top: item.position.dy.clamp(
                              canvasPadding, screenHeight - canvasPadding),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() {
                                selectedItem = item;
                              });
                            },
                            onScaleStart: (_) {
                              if (selectedItem == item) {
                                setState(() {
                                  isScaling = true;
                                  isRotating = false;
                                });
                              }
                            },
                            onScaleUpdate: (details) {
                              if (selectedItem == item) {
                                setState(() {
                                  if (rotateMode) {
                                    if (details.rotation.abs() > 0.01) {
                                      item.rotation +=
                                          details.rotation * rotationFactor;
                                    }
                                  } else {
                                    if (details.scale != 1.0) {
                                      item.scale = (item.scale +
                                              (details.scale - 1) * scaleFactor)
                                          .clamp(minScale, maxScale);
                                    }
                                  }
                                  item.position += details.focalPointDelta;
                                });
                              }
                            },
                            onScaleEnd: (_) {
                              if (selectedItem == item) {
                                setState(() {
                                  isScaling = false;
                                  isRotating = false;
                                });
                              }
                            },
                            child: Stack(
                              children: [
                                Transform(
                                  transform: Matrix4.identity()
                                    ..translate(item.position.dx,
                                        item.position.dy)
                                    ..translate(75 * item.scale,
                                        75 * item.scale)
                                    ..rotateZ(item.rotation)
                                    ..translate(-75 * item.scale,
                                        -75 * item.scale)
                                    ..scale(item.scale),
                                  origin: Offset(75, 75),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: selectedItem == item
                                          ? Border.all(
                                              color: Colors.red, width: 2.0)
                                          : null,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(40.0),
                                      child: CustomPaint(
                                        size: Size(150, 150),
                                        painter: PolylinePainter(
                                          positions: item.polyline,
                                          minLat: item.minLat,
                                          maxLat: item.maxLat,
                                          minLon: item.minLon,
                                          maxLon: item.maxLon,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (selectedItem == item)
                                  Positioned(
                                    top: (item.scale * 75) - 25,
                                    right: (item.scale * 75) - 25,
                                    child: IconButton(
                                      icon: Icon(rotateMode
                                          ? Icons.rotate_right
                                          : Icons.open_with),
                                      color: Colors.blue,
                                      onPressed: () {
                                        setState(() {
                                          rotateMode = !rotateMode;
                                        });
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (selectedItem != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: IconButton(
                icon: Icon(Icons.delete, size: 30, color: Colors.red),
                onPressed: _removeSelectedTrajectory,
              ),
            ),
        ],
      ),
    );
  }
}

class TransformablePolyline {
  List<Position> polyline;
  Offset position;
  double scale;
  double rotation;

  double minLat;
  double maxLat;
  double minLon;
  double maxLon;

  TransformablePolyline(this.polyline, this.position)
      : scale = 0.6,
        rotation = 0.0,
        minLat = polyline.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        maxLat = polyline.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        minLon = polyline.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
        maxLon = polyline.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
}