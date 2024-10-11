import 'package:flutter/material.dart';
import 'database_helper.dart'; // データベースヘルパーのインポート
import 'walking_detail_screen.dart'; // 詳細画面のインポート

class WalkingHistoryScreen extends StatefulWidget {
  @override
  _WalkingHistoryScreenState createState() => _WalkingHistoryScreenState();
}

class _WalkingHistoryScreenState extends State<WalkingHistoryScreen> {
  late DatabaseHelper _dbHelper;
  List<int> _groupIds = [];

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _fetchGroupIds(); // データベースからグループIDを取得
  }

  // データベースからすべてのグループIDを取得
  Future<void> _fetchGroupIds() async {
    List<int> groupIds = await _dbHelper.getAllGroupIds();
    setState(() {
      _groupIds = groupIds;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('記録された歩行履歴'),
      ),
      body: ListView.builder(
        itemCount: _groupIds.length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text('グループID: ${_groupIds[index]}'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WalkingDetailScreen(groupId: _groupIds[index]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}