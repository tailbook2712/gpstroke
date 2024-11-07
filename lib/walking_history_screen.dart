import 'package:flutter/material.dart';
import 'walking_detail_screen.dart';
import 'database_helper.dart';
import 'firestore_service.dart';

class WalkingHistoryScreen extends StatefulWidget {
  @override
  _WalkingHistoryScreenState createState() => _WalkingHistoryScreenState();
}

class _WalkingHistoryScreenState extends State<WalkingHistoryScreen> {
  late DatabaseHelper _dbHelper;
  late FirestoreService _firestoreService;
  late Future<List<Map<String, dynamic>>> _walkingRecords; // 歩行記録を表示する

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();
    _walkingRecords = _dbHelper.getAllRecords(); // ローカルの全ての歩行記録を取得
  }

  // グループを削除する関数
  Future<void> _deleteGroup(int groupId) async {
    await _dbHelper.deletePositionGroup(groupId); // ローカルデータベースから削除
    await _firestoreService.deletePositionGroup(groupId); // Firestoreから削除
    setState(() {
      _walkingRecords = _dbHelper.getAllRecords(); // リストを更新
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('グループ $groupId を削除しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('記録された歩行履歴'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _walkingRecords,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          } else if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            return ListView.builder(
              itemCount: snapshot.data!.length,
              itemBuilder: (context, index) {
                final record = snapshot.data![index];
                final groupId = record['group_id'];
                final date = record['date'];
                final steps = record['steps'];
                final distance = (record['distance'] / 1000).toStringAsFixed(2);

                return ListTile(
                  title: Text('日付: $date'),
                  subtitle: Text('歩数: $steps 歩 | 距離: $distance km'),
                  trailing: IconButton(
                    icon: Icon(Icons.delete),
                    onPressed: () => _deleteGroup(groupId), // グループ削除
                  ),
                  onTap: () {
                    // WalkingDetailScreenへの遷移
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => WalkingDetailScreen(
                          groupId: groupId,
                          date: date,
                          steps: steps,
                          distance: distance,
                        ), // タップされたデータを渡す
                      ),
                    );
                  },
                );
              },
            );
          } else {
            return Center(child: Text('記録されたグループがありません'));
          }
        },
      ),
    );
  }
}