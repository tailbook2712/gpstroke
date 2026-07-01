import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_design_canvas_screen.dart';
import 'route_service.dart';

class RouteDestinationSelectionScreen extends StatefulWidget {
  @override
  _RouteDestinationSelectionScreenState createState() =>
      _RouteDestinationSelectionScreenState();
}

class _RouteDestinationSelectionScreenState
    extends State<RouteDestinationSelectionScreen> {
  late GoogleMapController _mapController;

  // 出発地
  LatLng? _startingPoint;

  // 目的地
  LatLng? _destination;

  // ローディング状態
  bool _isLoading = true;

  // 地図の中心座標（現在のカメラ位置）
  LatLng _centerPoint = LatLng(35.0, 135.0);

  // 選択ステップ: 1=出発地選択中, 2=目的地選択中, 3=完了
  int _selectionStep = 0;

  // マーカーセット
  Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _initializeStartingPoint();
  }

  /// 出発地（現在地）を初期化
  Future<void> _initializeStartingPoint() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      );

      // 現在地を最寄りの道路にスナップ
      final rawLocation = LatLng(position.latitude, position.longitude);
      final snappedLocation =
          await RouteService.snapPointToNearestRoad(rawLocation);
      print('📍 出発地を道路にスナップしました');
      print('   元の位置: ${rawLocation.latitude}, ${rawLocation.longitude}');
      print(
          '   スナップ後: ${snappedLocation.latitude}, ${snappedLocation.longitude}');

      setState(() {
        // 出発地をスナップ後の位置に設定
        _startingPoint = snappedLocation;
        // カメラも現在地に移動
        _centerPoint = _startingPoint!;
        _isLoading = false;
        _selectionStep = 2; // いきなり目的地選択モードから開始
        _updateMarkers();
      });

      // カメラを現在地に移動（地図がロードされた後）
      await Future.delayed(Duration(milliseconds: 800));
      if (mounted) {
        _mapController.animateCamera(
          CameraUpdate.newLatLngZoom(_centerPoint, 16),
        );
      }
    } catch (e) {
      print('現在地取得エラー: $e');
      setState(() {
        _isLoading = false;
        // エラー時はデフォルト位置を使用
        _centerPoint = LatLng(35.0, 135.0);
        // エラーでもとりあえず目的地選択へ
        _selectionStep = 2;
      });
    }
  }

  /// マップがドラッグされた時、中心座標を更新
  void _onCameraMove(CameraPosition position) {
    setState(() {
      _centerPoint = position.target;
    });
  }

  /// マーカーを更新
  void _updateMarkers() {
    _markers.clear();

    // 出発地マーカー（青）
    if (_startingPoint != null) {
      _markers.add(
        Marker(
          markerId: MarkerId('starting_point'),
          position: _startingPoint!,
          infoWindow: InfoWindow(title: '出発地'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueBlue,
          ),
        ),
      );
    }

    // 目的地マーカー（赤）
    if (_destination != null) {
      _markers.add(
        Marker(
          markerId: MarkerId('destination'),
          position: _destination!,
          infoWindow: InfoWindow(title: '目的地'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueRed,
          ),
        ),
      );
    }
  }

  /// FAB が押された時、目的地を設定してキャンバス画面へ遷移
  void _registerCenterPoint() {
    if (_selectionStep == 2) {
      // 目的地を設定
      setState(() {
        _destination = _centerPoint;
        _updateMarkers();
      });
      // すぐにキャンバス画面へ遷移
      _proceedToCanvasScreen();
    }
  }

  /// 次のステップ（キャンバス描画）に進む
  Future<void> _proceedToCanvasScreen() async {
    if (_startingPoint == null || _destination == null) {
      return;
    }

    // RouteDesignCanvasScreen へナビゲート
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteDesignCanvasScreen(),
      ),
    );

    if (!mounted) return;

    if (result != null) {
      // ルート生成結果が返ってくる
      // walking_tracker_screen に戻す時、戻る値を返す
      Navigator.pop(context, result);
    }
  }

  /// ステップ説明テキストを取得
  String _getStepText() {
    if (_selectionStep == 2) {
      return '地図を動かして、中央のピンを目的地に合わせてください';
    }
    return '目的地が設定されました';
  }

  /// 出発地・目的地情報パネル
  Widget _buildLocationInfoPanel() {
    return Container(
      padding: EdgeInsets.all(12),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_startingPoint != null)
            if (_startingPoint != null)
              Row(
                children: [
                  Icon(Icons.my_location, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('出発地（現在位置）',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue)),
                        Text(
                          '${_startingPoint!.latitude.toStringAsFixed(6)}, ${_startingPoint!.longitude.toStringAsFixed(6)}',
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          if (_startingPoint != null && _destination != null)
            SizedBox(height: 8),
          if (_destination != null)
            GestureDetector(
              onTap: () {
                // 目的地を変更するモードに戻す
                setState(() {
                  _selectionStep = 2;
                  _updateMarkers();
                });
              },
              child: Row(
                children: [
                  Icon(Icons.location_on, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('目的地（タップで変更）',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.red)),
                        Text(
                          '${_destination!.latitude.toStringAsFixed(6)}, ${_destination!.longitude.toStringAsFixed(6)}',
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.edit, color: Colors.red, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('目的地を選択'),
          centerTitle: true,
          elevation: 0,
        ),
        body: _isLoading
            ? Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 出発地・目的地情報パネル
                  if (_startingPoint != null || _destination != null)
                    _buildLocationInfoPanel(),
                  // Map と操作パネルの Stack
                  Expanded(
                    child: Stack(
                      children: [
                        // Google Map
                        GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: _centerPoint,
                            zoom: 16,
                          ),
                          onMapCreated: (GoogleMapController controller) {
                            _mapController = controller;
                            // マップが作成された後、現在地へ移動
                            if (_startingPoint != null) {
                              _mapController.animateCamera(
                                CameraUpdate.newLatLng(_startingPoint!),
                              );
                            }
                          },
                          onCameraMove: _onCameraMove,
                          markers: _markers,
                          myLocationEnabled: true,
                          myLocationButtonEnabled: true,
                        ),

                        // 中央にピンのアイコン
                        if (_selectionStep < 3)
                          Center(
                            child: Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 40,
                            ),
                          ),

                        // 上部: ステップ説明
                        Positioned(
                          top: 12,
                          left: 12,
                          right: 12,
                          child: Container(
                            padding: EdgeInsets.all(12),
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
                            child: Text(
                              _getStepText(),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        // 下部: 目的地設定ボタン
                        Positioned(
                          bottom: 80,
                          left: 16,
                          right: 16,
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _registerCenterPoint,
                              icon: Icon(Icons.arrow_forward),
                              label: Text('この場所を目的地にする'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                padding: EdgeInsets.symmetric(vertical: 12),
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
