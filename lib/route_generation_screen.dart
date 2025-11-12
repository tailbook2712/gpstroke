import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_service.dart';

class RouteGenerationScreen extends StatefulWidget {
  final LatLng startingPoint;
  final LatLng destination;
  final List<List<Offset>> designShape;

  RouteGenerationScreen({
    required this.startingPoint,
    required this.destination,
    required this.designShape,
  });

  @override
  _RouteGenerationScreenState createState() => _RouteGenerationScreenState();
}

class _RouteGenerationScreenState extends State<RouteGenerationScreen> {
  // ignore: unused_field
  late GoogleMapController _mapController;

  // 生成されたルート
  List<LatLng>? _generatedRoute;

  // ルートのメタデータ
  Map<String, dynamic>? _routeMetadata;

  // ローディング状態
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _generateRoute();
  }

  /// ルート生成処理
  Future<void> _generateRoute() async {
    try {
      // 設計パスをLatLngに変換
      List<LatLng> designPath = RouteService.convertDesignShapeToLatLngs(
        widget.designShape,
        widget.startingPoint,
        widget.destination,
      );

      // デフォルト距離を5kmに設定
      const double defaultTargetDistance = 5000.0;

      // ルート候補を生成
      List<LatLng> candidateRoute = await RouteService.generateRouteCandidates(
        widget.startingPoint,
        widget.destination,
        designPath,
        defaultTargetDistance,
      );

      // ルートを評価
      Map<String, dynamic> evaluation = RouteService.evaluateRoute(
        route: candidateRoute,
        designPath: designPath,
        targetDistance: defaultTargetDistance,
      );

      setState(() {
        _generatedRoute = evaluation['route'];
        _routeMetadata = evaluation;
        _isLoading = false;
      });

      print('ルート生成完了:');
      print('  - 距離: ${(evaluation["distance"] / 1000).toStringAsFixed(2)}km');
      print(
          '  - 形状類似度: ${(evaluation["shapeSimilarity"] * 100).toStringAsFixed(1)}%');
      print('  - スコア: ${(evaluation["totalScore"] * 100).toStringAsFixed(1)}%');
    } catch (e) {
      print('ルート生成エラー: $e');
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ルート生成に失敗しました: $e')),
      );
    }
  }

  /// このルートで歩行開始
  void _startWalkingWithRoute() {
    if (_generatedRoute == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ルートが生成されていません')),
      );
      return;
    }

    // WalkingTrackerScreen へ戻る
    Navigator.pop(context, {
      'routePath': _generatedRoute,
      'metadata': _routeMetadata,
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('ルート提案'),
          centerTitle: true,
          elevation: 0,
        ),
        body: _isLoading
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('ルートを生成中...'),
                  ],
                ),
              )
            : Stack(
                children: [
                  // Google Map
                  GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(
                        (widget.startingPoint.latitude +
                                widget.destination.latitude) /
                            2,
                        (widget.startingPoint.longitude +
                                widget.destination.longitude) /
                            2,
                      ),
                      zoom: 14,
                    ),
                    onMapCreated: (GoogleMapController controller) {
                      _mapController = controller;
                    },
                    polylines: _buildPolylines(),
                    markers: _buildMarkers(),
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                  ),

                  // 上部: ルート情報パネル
                  if (_routeMetadata != null)
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '提案ルート',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('距離', style: TextStyle(fontSize: 12)),
                                    SizedBox(height: 4),
                                    Text(
                                      '${(_routeMetadata!["distance"] / 1000).toStringAsFixed(2)} km',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue,
                                      ),
                                    ),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('形状類似度',
                                        style: TextStyle(fontSize: 12)),
                                    SizedBox(height: 4),
                                    Text(
                                      '${(_routeMetadata!["shapeSimilarity"] * 100).toStringAsFixed(0)}%',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 下部: アクションボタン
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _startWalkingWithRoute,
                        icon: Icon(Icons.play_arrow),
                        label: Text('このルートで歩く'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          padding: EdgeInsets.symmetric(vertical: 14),
                          textStyle: TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// Polylines を構築
  Set<Polyline> _buildPolylines() {
    Set<Polyline> polylines = {};

    if (_generatedRoute != null) {
      polylines.add(
        Polyline(
          polylineId: PolylineId('generated_route'),
          points: _generatedRoute!,
          color: Colors.blue,
          width: 5,
          geodesic: true,
        ),
      );
    }

    return polylines;
  }

  /// Markers を構築
  Set<Marker> _buildMarkers() {
    Set<Marker> markers = {};

    // 出発地マーカー
    markers.add(
      Marker(
        markerId: MarkerId('starting_point'),
        position: widget.startingPoint,
        infoWindow: InfoWindow(title: '出発地'),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueBlue,
        ),
      ),
    );

    // 目的地マーカー
    markers.add(
      Marker(
        markerId: MarkerId('destination'),
        position: widget.destination,
        infoWindow: InfoWindow(title: '目的地'),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueRed,
        ),
      ),
    );

    return markers;
  }
}
