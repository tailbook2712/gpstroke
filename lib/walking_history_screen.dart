import 'package:flutter/material.dart';
import 'walking_detail_screen.dart';  // WalkingDetailScreenをインポート
import 'database_helper.dart';
import 'firestore_service.dart';

class WalkingHistoryScreen extends StatefulWidget {
  @override
  _WalkingHistoryScreenState createState() => _WalkingHistoryScreenState();
}

class _WalkingHistoryScreenState extends State<WalkingHistoryScreen> {
  late DatabaseHelper _dbHelper;
  late FirestoreService _firestoreService;
  late Future<List<int>> _groupIds; // グループIDを表示する

  @override
  void initState() {
    super.initState();
    _dbHelper = DatabaseHelper();
    _firestoreService = FirestoreService();
    _groupIds = _dbHelper.getAllGroupIds(); // ローカルの全てのグループIDを取得
  }

  // グループを削除する関数
  Future<void> _deleteGroup(int groupId) async {
    await _dbHelper.deletePositionGroup(groupId); // ローカルデータベースから削除
    await _firestoreService.deletePositionGroup(groupId); // Firestoreから削除
    setState(() {
      _groupIds = _dbHelper.getAllGroupIds(); // リストを更新
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
      body: FutureBuilder<List<int>>(
        future: _groupIds,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          } else if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            return ListView.builder(
              itemCount: snapshot.data!.length,
              itemBuilder: (context, index) {
                int groupId = snapshot.data![index];
                return ListTile(
                  title: Text('グループID: $groupId'),
                  trailing: IconButton(
                    icon: Icon(Icons.delete),
                    onPressed: () => _deleteGroup(groupId), // グループ削除
                  ),
                  onTap: () {
                    // WalkingDetailScreenへの遷移
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => WalkingDetailScreen(groupId: groupId), // タップされたグループIDを渡す
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