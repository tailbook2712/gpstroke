import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
  final GlobalKey _boundaryKey = GlobalKey(); // 保存用のRepaintBoundaryのキー
  final double canvasPadding = 20.0;
  List<List<Position>> recordedTrajectories = [];

  // 拡大・縮小の制限
  final double minScale = 0.5;
  final double maxScale = 1.5;

  bool isScaling = false;
  bool isRotating = false;

  // 拡大縮小のスピード調整用の係数
  final double scaleFactor = 0.05;
  final double rotationFactor = 0.1;
  bool rotateMode = false;

  @override
  void initState() {
    super.initState();
    _loadRecordTrajectories(); // 記録された移動軌跡を読み込む
  }

  Future<void> _loadRecordTrajectories() async {
    setState(() {
      recordedTrajectories = widget.trajectories; // 最新の移動軌跡を反映
    });
  }

  // アートワークを保存する関数
  Future<void> _saveArtwork() async {
    try {
      // RepaintBoundaryの画像を取得
      RenderRepaintBoundary boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      var image = await boundary.toImage();
      ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      // 保存ディレクトリを作成
      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');
      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true); // ディレクトリを作成
      }

      // ファイル名を現在の日時に基づいて作成
      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      File imgFile = File('${artworksDirectory.path}/artwork_$timestamp.png');

      // ファイルに画像データを書き込む
      await imgFile.writeAsBytes(pngBytes);

      print("アートワークが保存されました: ${imgFile.path}");

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークが保存されました!')),
      );

      // 保存したファイルを返す
      Navigator.pop(context, imgFile);
        
    } catch (e) {
      print("アートワーク保存中にエラーが発生しました: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークの保存に失敗しました。')),
      );
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
            onPressed: _saveArtwork, // 保存ボタンを押すとアートワークが保存される
          ),
        ],
      ),
      body: Column(
        children: [
          // キャンバス部分（RepaintBoundaryでラップ）
          Flexible(
            flex: 3,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  selectedItem = null;
                });
              },
              child: RepaintBoundary(
                key: _boundaryKey, // キャンバスをキャプチャするためのキー
                child: DragTarget<List<Position>>(
                  onAcceptWithDetails: (details) {
                    RenderBox renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox;

                    // ドロップされた位置をキャンバスのローカル座標に変換
                    Offset localPosition = renderBox.globalToLocal(details.offset);

                    setState(() {
                      selectedTrajectories.add(
                        TransformablePolyline(details.data, localPosition - Offset(75, 75)),
                      );
                    });
                  },
                  builder: (context, candidateData, rejectedData) {
                    return Container(
                      key: _canvasKey,
                      color: Colors.white,
                      child: Stack(
                        children: selectedTrajectories.map((item) {
                          return Positioned(
                            left: item.position.dx.clamp(canvasPadding, screenWidth - canvasPadding),
                            top: item.position.dy.clamp(canvasPadding, screenHeight - canvasPadding),
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
                                      // 回転の処理（スピード調整）
                                      if (details.rotation.abs() > 0.01) {
                                        item.rotation += details.rotation * rotationFactor;
                                      }
                                    } else {
                                      // 拡大・縮小のスピードを調整
                                      if (details.scale != 1.0) {
                                        item.scale = (item.scale + (details.scale - 1) * scaleFactor)
                                            .clamp(minScale, maxScale);
                                      }
                                    }
                                    item.position += details.focalPointDelta; // ドラッグ（パン）ジェスチャーとして移動
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
                                      ..translate(item.position.dx, item.position.dy)
                                      ..scale(item.scale)
                                      ..rotateZ(item.rotation),
                                    origin: Offset(75, 75),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: selectedItem == item
                                            ? Border.all(color: Colors.red, width: 2.0)
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
                                        icon: Icon(rotateMode ? Icons.rotate_right : Icons.open_with),
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
              ),
            ),
          ),
          SizedBox(height: 5),
          Container(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: recordedTrajectories.length,
              itemBuilder: (context, index) {
                return Draggable<List<Position>>(
                  data: recordedTrajectories[index],
                  feedback: Material(
                    child: CustomPaint(
                      size: Size(60, 60),
                      painter: PolylinePainter(
                        positions: widget.trajectories[index],
                        minLat: widget.trajectories[index].map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
                        maxLat: widget.trajectories[index].map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
                        minLon: widget.trajectories[index].map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
                        maxLon: widget.trajectories[index].map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
                      ),
                    ),
                  ),
                  child: Container(
                    width: 70,
                    height: 70,
                    margin: EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blue),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: CustomPaint(
                      painter: PolylinePainter(
                        positions: widget.trajectories[index],
                        minLat: widget.trajectories[index].map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
                        maxLat: widget.trajectories[index].map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
                        minLon: widget.trajectories[index].map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
                        maxLon: widget.trajectories[index].map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
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