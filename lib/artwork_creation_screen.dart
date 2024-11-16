import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
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

  final double minScale = 0.5;
  final double maxScale = 1.5;
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

  Future<void> _loadRecordTrajectories() async {
    setState(() {
      recordedTrajectories = widget.trajectories;
      _loadUsedTrajectories();
    });
  }

  Future<void> _loadUsedTrajectories() async {
    final dbHelper = DatabaseHelper();
    final loadedUsedIndices = await dbHelper.getUsedTrajectories();
    setState(() {
      usedTrajectoryIndices = loadedUsedIndices.toSet();
    });
  }

  Future<void> _saveArtwork() async {
    try {
      RenderRepaintBoundary boundary = _boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      var image = await boundary.toImage();
      ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');
      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true);
      }

      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      File imgFile = File('${artworksDirectory.path}/artwork_$timestamp.png');
      await imgFile.writeAsBytes(pngBytes);

      // 永続的に使用済みとしてデータベースに保存
      final dbHelper = DatabaseHelper();
      for (final index in temporarilyUsedIndices) {
        usedTrajectoryIndices.add(index);
        dbHelper.insertUsedTrajectory(index);
      }
      temporarilyUsedIndices.clear(); // 一時的な使用インデックスをクリア

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークが保存されました!')),
      );
      Navigator.pop(context, imgFile);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークの保存に失敗しました。')),
      );
    }
  }

  void _removeSelectedTrajectory() {
    if (selectedItem != null) {
      int indexToRemove = recordedTrajectories.indexOf(selectedItem!.polyline);
      setState(() {
        selectedTrajectories.remove(selectedItem);
        // 保存されていない軌跡は一時的使用リストから削除し、再度リストに戻す
        if (temporarilyUsedIndices.contains(indexToRemove)) {
          temporarilyUsedIndices.remove(indexToRemove);
        }
        selectedItem = null;
      });
    }
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
                    // グリッド線を描画
                    CustomPaint(
                      size: Size.infinite,
                      painter: GridPainter(gridSize: 50), // グリッドサイズ調整可能
                    ),
                    // 軌跡を配置するドラッグターゲット
                    DragTarget<List<Position>>(
                      onAcceptWithDetails: (details) {
                        RenderBox renderBox = _canvasKey.currentContext!
                            .findRenderObject() as RenderBox;
                        Offset localPosition =
                            renderBox.globalToLocal(details.offset);

                        final index =
                            recordedTrajectories.indexOf(details.data);

                        setState(() {
                          selectedTrajectories.add(
                            TransformablePolyline(
                                details.data, localPosition - Offset(75, 75)),
                          );
                          temporarilyUsedIndices.add(index); // 一時的に使用リストに追加
                        });
                      },
                      builder: (context, candidateData, rejectedData) {
                        return Container(
                          key: _canvasKey,
                          color: Colors.transparent,
                          child: Stack(
                            children: selectedTrajectories.map((item) {
                              return Positioned(
                                left: item.position.dx.clamp(
                                    canvasPadding, screenWidth - canvasPadding),
                                top: item.position.dy.clamp(
                                    canvasPadding,
                                    screenHeight - canvasPadding),
                                child: GestureDetector(
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
                                            item.rotation += details.rotation *
                                                rotationFactor;
                                          }
                                        } else {
                                          if (details.scale != 1.0) {
                                            item.scale = (item.scale +
                                                    (details.scale - 1) *
                                                        scaleFactor)
                                                .clamp(minScale, maxScale);
                                          }
                                        }
                                        item.position +=
                                            details.focalPointDelta;
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
                                          ..scale(item.scale)
                                          ..rotateZ(item.rotation),
                                        origin: Offset(75, 75),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            border: selectedItem == item
                                                ? Border.all(
                                                    color: Colors.red,
                                                    width: 2.0)
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
                        );
                      },
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
          Container(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: recordedTrajectories.length,
              itemBuilder: (context, index) {
                if (usedTrajectoryIndices.contains(index) ||
                    temporarilyUsedIndices.contains(index)) {
                  return SizedBox.shrink();
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Draggable<List<Position>>(
                    data: recordedTrajectories[index],
                    feedback: Material(
                      child: CustomPaint(
                        size: Size(60, 60),
                        painter: PolylinePainter(
                          positions: widget.trajectories[index],
                          minLat: widget.trajectories[index]
                              .map((p) => p.latitude)
                              .reduce((a, b) => a < b ? a : b),
                          maxLat: widget.trajectories[index]
                              .map((p) => p.latitude)
                              .reduce((a, b) => a > b ? a : b),
                          minLon: widget.trajectories[index]
                              .map((p) => p.longitude)
                              .reduce((a, b) => a < b ? a : b),
                          maxLon: widget.trajectories[index]
                              .map((p) => p.longitude)
                              .reduce((a, b) => a > b ? a : b),
                        ),
                      ),
                    ),
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blue),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: CustomPaint(
                          size: Size(60, 60),
                          painter: PolylinePainter(
                            positions: widget.trajectories[index],
                            minLat: widget.trajectories[index]
                                .map((p) => p.latitude)
                                .reduce((a, b) => a < b ? a : b),
                            maxLat: widget.trajectories[index]
                                .map((p) => p.latitude)
                                .reduce((a, b) => a > b ? a : b),
                            minLon: widget.trajectories[index]
                                .map((p) => p.longitude)
                                .reduce((a, b) => a < b ? a : b),
                            maxLon: widget.trajectories[index]
                                .map((p) => p.longitude)
                                .reduce((a, b) => a > b ? a : b),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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

/// グリッド線を描画するクラス
class GridPainter extends CustomPainter {
  final double gridSize;
  final Color gridColor;

  GridPainter({this.gridSize = 50, this.gridColor = Colors.grey});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor.withOpacity(0.5)
      ..strokeWidth = 0.5;

    // 垂直線
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // 水平線
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}