import 'package:flutter/material.dart';
import 'database_helper.dart';
import 'polyline_screen.dart'; // ポリライン描画用の画面
import 'package:geolocator/geolocator.dart'; // Position型を扱うために必要

class PolylineHistoryScreen extends StatefulWidget {
  @override
  _PolylineHistoryScreenState createState() => _PolylineHistoryScreenState();
}

class _PolylineHistoryScreenState extends State<PolylineHistoryScreen> {
  late DatabaseHelper _dbHelper;
  List<int> _groupIds = []; // グループIDリスト

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _loadGroupIds();
  }

  // グループIDを取得する
  Future<void> _loadGroupIds() async {
    List<int> groupIds = await _dbHelper.getAllGroupIds();
    setState(() {
      _groupIds = groupIds;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('記録履歴一覧'),
      ),
      body: ListView.builder(
        itemCount: _groupIds.length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text('記録グループID: ${_groupIds[index]}'),
            onTap: () async {
              // グループIDに基づいて位置情報を取得し、ポリラインを表示
              List<Position> positions = await _dbHelper.getPositionsAsPositionsByGroupId(_groupIds[index]);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PolylineScreen(positions: positions), // ポリライン表示画面へ
                ),
              );
            },
          );
        },
      ),
    );
  }
}