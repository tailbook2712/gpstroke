import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 位置情報グループをFirestoreに保存する
  Future<void> savePositionGroup(int groupId, List<Map<String, dynamic>> positions) async {
    try {
      for (var position in positions) {
        await _db.collection('walking_positions').add({
          'groupId': groupId,
          'latitude': position['latitude'],
          'longitude': position['longitude'],
          'timestamp': position['timestamp'],
        });
      }
      print("位置情報グループをFirestoreに保存しました: GroupID $groupId");
    } catch (e) {
      print("Firestoreへの保存エラー: $e");
    }
  }

  // 特定のグループIDの位置情報をFirestoreから削除する
  Future<void> deletePositionGroup(int groupId) async {
    try {
      var batch = _db.batch();

      // グループIDに一致するドキュメントを削除
      var snapshots = await _db
          .collection('walking_positions')
          .where('groupId', isEqualTo: groupId)
          .get();

      for (var doc in snapshots.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      print("FirestoreからGroupID $groupId の位置情報を削除しました");
    } catch (e) {
      print("Firestoreから削除エラー: $e");
    }
  }
  // Firestoreからすべての位置情報を取得するメソッド
  Future<List<Map<String, dynamic>>> getAllPositions() async {
    try {
      QuerySnapshot snapshot = await _db.collection('walking_positions').get();
      return snapshot.docs.map((doc) {
        return {
          'groupId': doc['groupId'],
          'latitude': doc['latitude'],
          'longitude': doc['longitude'],
          'timestamp': doc['timestamp'],
        };
      }).toList();
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return [];
    }
  }
}