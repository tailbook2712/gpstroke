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
  final GlobalKey _canvasKey = GlobalKey();
  final double canvasPadding = 20.0; // 横方向の境界制限用

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      appBar: AppBar(
        title: Text('アート作成'),
      ),
      body: Column(
        children: [
          Flexible(
            flex: 3,
            child: DragTarget<List<Position>>(
              onAcceptWithDetails: (details) {
                RenderBox renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox;
                Offset localPosition = renderBox.globalToLocal(details.offset);
                setState(() {
                  selectedTrajectories.add(
                    TransformablePolyline(details.data, localPosition),
                  );
                });
              },
              builder: (context, candidateData, rejectedData) {
                return Container(
                  key: _canvasKey,
                  color: Colors.white,
                  margin: EdgeInsets.only(bottom: 150), // 下部スクロールリストより上に配置
                  child: Stack(
                    children: selectedTrajectories.map((item) {
                      return Positioned(
                        left: item.position.dx.clamp(canvasPadding, screenWidth - canvasPadding), // 横方向の境界制限
                        top: item.position.dy,
                        child: GestureDetector(
                          onScaleUpdate: (details) {
                            setState(() {
                              item.scale *= details.scale;
                              item.rotation += details.rotation;
                              item.position += details.focalPointDelta;

                              // 横方向の境界チェック
                              item.position = Offset(
                                item.position.dx.clamp(canvasPadding, screenWidth - canvasPadding),
                                item.position.dy,
                              );
                            });
                          },
                          child: Transform(
                            transform: Matrix4.identity()
                              ..translate(item.position.dx, item.position.dy)
                              ..scale(item.scale)
                              ..rotateZ(item.rotation),
                            child: Padding(
                              padding: const EdgeInsets.all(40.0), // タッチ範囲を拡大
                              child: CustomPaint(
                                size: Size(200, 200),
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
                      );
                    }).toList(),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: 10),
          Container(
            height: 150,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.trajectories.length,
              itemBuilder: (context, index) {
                return Draggable<List<Position>>(
                  data: widget.trajectories[index],
                  feedback: Material(
                    child: CustomPaint(
                      size: Size(100, 100),
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
                    width: 100,
                    height: 100,
                    margin: EdgeInsets.symmetric(horizontal: 10),
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
      : scale = 1.0,
        rotation = 0.0,
        minLat = polyline.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        maxLat = polyline.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        minLon = polyline.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
        maxLon = polyline.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
}