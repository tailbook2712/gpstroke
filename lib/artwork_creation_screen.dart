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
import 'package:intl/intl.dart';

import 'utils/utils.dart';

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
  List<List<Position>> recordedTrajectories = [];
  Set<int> usedTrajectoryIndices = {}; // 保存済みの軌跡インデックスを保持
  Set<int> temporarilyUsedIndices = {}; // 一時的に使用された軌跡インデックス
  final DatabaseHelper _dbHelper = DatabaseHelper();

  bool isScaling = false;
  bool isRotating = false;
  final double scaleFactor = 0.05; // 拡大縮小の係数
  final double rotationFactor = 0.3; // 回転の係数
  bool rotateMode = false;
  final double canvasPadding = 10.0;

  @override
  void initState() {
    super.initState();
    _loadRecordTrajectories();
  }

  // データベースから保存済みの軌跡を読み込む
  Future<void> _loadRecordTrajectories() async {
    try {
      recordedTrajectories.clear();

      // ローカルデータベースからデータを取得
      List<Map<String, dynamic>> allWalkingData =
          await _dbHelper.getAllWalkingData();

      // データを一意にするためSetを使用（groupIdベース）
      Set<String> uniqueGroupIds = {};
      List<List<Position>> uniqueTrajectoryList = [];

      for (var data in allWalkingData) {
        String groupId = data['group_id'];

        if (!uniqueGroupIds.contains(groupId)) {
          uniqueGroupIds.add(groupId);

          // positionsをデコード
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

          uniqueTrajectoryList.add(trajectory);
        }
      }

      setState(() {
        recordedTrajectories = uniqueTrajectoryList;
      });

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
    String artworkName = await _promptForArtworkName(); // 作品名を入力
    if (artworkName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('作品名を入力してください。')),
      );
      return;
    }

    try {
      RenderRepaintBoundary boundary = _boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
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

      final canvasSize = _boundaryKey.currentContext!.size!; // キャンバスのサイズを取得

      // 軌跡の数、総距離、総歩数を計算
      int trajectoryCount = selectedTrajectories.length;
      double totalDistance = 0.0;
      int totalSteps = 0;

      for (var item in selectedTrajectories) {
        final groupId = generateGroupId(item.polyline);
        final trajectoryDetails =
            await _dbHelper.getWalkingDataByGroupId(groupId);
        totalDistance += (trajectoryDetails?['distance'] as double? ?? 0.0);
        totalSteps += (trajectoryDetails?['steps'] as int? ?? 0);
      }
      // 保存時の軌跡を記録する部分
      final canvasState = {
        'canvasWidth': canvasSize.width, // キャンバスの幅
        'canvasHeight': canvasSize.height, // キャンバスの高さ
        'trajectories': selectedTrajectories.map((item) {
          // 保存時のデバッグ出力
          print(
              '保存時 - dx: ${item.position.dx}, dy: ${item.position.dy}, scale: ${item.scale}, rotation: ${item.rotation}');
          return {
            'positions': item.polyline
                .map((p) => {
                      'latitude': p.latitude,
                      'longitude': p.longitude,
                      'timestamp': p.timestamp?.toIso8601String() ?? "",
                    })
                .toList(),
            'position': {
              'dx': item.position.dx / canvasSize.width, // 相対位置として保存
              'dy': item.position.dy / canvasSize.height,
            },
            'scale': item.scale,
            'rotation': item.rotation,
          };
        }).toList(),
        'meta': {
          'trajectoryCount': trajectoryCount,
          'totalDistance': totalDistance,
          'totalSteps': totalSteps,
          'artworkName': artworkName, // 作品名を保存
        },
      };
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

  Future<String> _promptForArtworkName() async {
    String artworkName = '';
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('作品名を入力'),
          content: TextField(
            onChanged: (value) {
              artworkName = value;
            },
            decoration: InputDecoration(hintText: '作品名'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('保存'),
            ),
          ],
        );
      },
    );
    return artworkName;
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

        // 軌跡を最新の順にソート
        availableTrajectories.sort((a, b) {
          final DateTime latestA = a!.map((p) => p.timestamp).reduce(
              (value, element) => value.isAfter(element) ? value : element);
          final DateTime latestB = b!.map((p) => p.timestamp).reduce(
              (value, element) => value.isAfter(element) ? value : element);
          return latestB.compareTo(latestA); // 新しい順
        });

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
              DateTime date = trajectory!.first.timestamp;
              String formattedDate = DateFormat('MM/dd').format(date);
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
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size(60, 60),
                      painter: PolylinePainter(
                        positions: trajectory!,
                        minLat: trajectory
                            .map((p) => p.latitude)
                            .reduce((a, b) => a < b ? a : b),
                        maxLat: trajectory
                            .map((p) => p.latitude)
                            .reduce((a, b) => a > b ? a : b),
                        minLon: trajectory
                            .map((p) => p.longitude)
                            .reduce((a, b) => a < b ? a : b),
                        maxLon: trajectory
                            .map((p) => p.longitude)
                            .reduce((a, b) => a > b ? a : b),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: EdgeInsets.all(4),
                        color: Colors.white.withOpacity(0.8),
                        child:
                            Text(formattedDate, style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
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
        title: Text('作品の制作'),
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
      body: Stack(
        children: [
          Container(
            width: screenWidth,
            height: screenHeight,
            color: Colors.grey[200],
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                // キャンバスの白い部分をタップした場合、選択状態を解除
                setState(() {
                  selectedItem = null;
                });
              },
              child: RepaintBoundary(
                key: _boundaryKey,
                child: Stack(
                  children: [
                    ...selectedTrajectories.map((item) {
                      return Positioned(
                        left: item.position.dx.clamp(
                            canvasPadding,
                            screenWidth -
                                canvasPadding -
                                item.scale * 150), // 150はPolylinePainterのサイズ
                        top: item.position.dy.clamp(canvasPadding,
                            screenHeight - canvasPadding - item.scale * 150),
                        child: GestureDetector(
                          behavior: HitTestBehavior
                              .translucent, // タップイベントを透明な領域でも発生するようにtranslucentに変更
                          onTap: () {
                            // 軌跡をタップした場合、選択状態を設定
                            setState(() {
                              selectedItem = item;
                            });
                          },
                          onScaleStart: (_) {
                            if (selectedItem == item) {
                              setState(() {
                                isRotating = true;
                              });
                            }
                          },
                          onScaleUpdate: (details) {
                            if (selectedItem == item) {
                              setState(() {
                                if (details.rotation.abs() > 0.01) {
                                  item.rotation +=
                                      details.rotation * rotationFactor;
                                }
                                item.position += details.focalPointDelta;
                              });
                            }
                          },
                          onScaleEnd: (_) {
                            if (selectedItem == item) {
                              setState(() {
                                isRotating = false;
                              });
                            }
                          },
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width:
                                    150 * item.scale + 80, // タップ範囲を拡張 (80は余白)
                                height: 150 * item.scale + 80,
                                color: Colors.transparent, // 透明な領域を追加
                              ),
                              Transform(
                                transform: Matrix4.identity()
                                  ..translate(75 * item.scale, 75 * item.scale)
                                  ..rotateZ(item.rotation)
                                  ..translate(
                                      -75 * item.scale, -75 * item.scale)
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
                                    padding:
                                        const EdgeInsets.all(20.0), // 余白を20に変更
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
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
          // 削除ボタンの表示
          if (selectedItem != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: IconButton(
                  icon: Icon(Icons.delete, size: 30, color: Colors.red),
                  onPressed: _removeSelectedTrajectory,
                ),
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
        minLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        maxLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        minLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
        maxLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
}