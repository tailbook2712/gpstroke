import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'database_helper.dart';

class WalkingDetailScreen extends StatefulWidget {
  final int groupId;
  final String date;
  final int steps;
  final String distance;

  WalkingDetailScreen({
    required this.groupId,
    required this.date,
    required this.steps,
    required this.distance,
  });

  @override
  _WalkingDetailScreenState createState() => _WalkingDetailScreenState();
}

class _WalkingDetailScreenState extends State<WalkingDetailScreen> {
  late DatabaseHelper _dbHelper;
  late GoogleMapController _mapController;
  List<LatLng> _polylinePoints = [];
  LatLng? _initialPosition;
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _fetchPositions();
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
  }

  Future<void> _fetchPositions() async {
    List<Map<String, dynamic>> positions = await _dbHelper.getPositionsByGroupId(widget.groupId);
    setState(() {
      _polylinePoints = positions.map((position) {
        return LatLng(position['latitude'], position['longitude']);
      }).toList();

      if (_polylinePoints.isNotEmpty) {
        _initialPosition = _polylinePoints.first;
      }

      _polylines.add(
        Polyline(
          polylineId: PolylineId('walking_route'),
          points: _polylinePoints,
          color: Colors.blue,
          width: 4,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.date), // 日付を表示
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '歩数: ${widget.steps} 歩',
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 8),
                Text(
                  '距離: ${widget.distance} km',
                  style: TextStyle(fontSize: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: _initialPosition == null
                ? Center(child: CircularProgressIndicator())
                : GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _initialPosition!,
                      zoom: 15.0,
                    ),
                    polylines: _polylines,
                    onMapCreated: _onMapCreated,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    zoomGesturesEnabled: true,
                    scrollGesturesEnabled: true,
                    rotateGesturesEnabled: true,
                    tiltGesturesEnabled: true,
                  ),
          ),
        ],
      ),
    );
  }
}