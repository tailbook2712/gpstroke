import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 位置情報と歩行データをFirestoreに保存するメソッド
  Future<void> saveWalkingData({
    required String groupId,
    required List<Map<String, dynamic>> positions,
    required String date,
    required int steps,
    required double distance,
  }) async {
    try {
      // Firestoreにデータを保存
      await _db.collection('walking_data').doc(groupId).set({
        'groupId': groupId,
        'positions': positions, // リストとして保存
        'date': date,
        'steps': steps,
        'distance': distance,
      });
      print("位置情報と歩行データをFirestoreに保存しました: GroupID $groupId");
    } catch (e) {
      print("Firestoreへの保存エラー: $e");
    }
  }

  // GroupIDごとの歩行データと位置情報を取得するメソッド
  Future<Map<String, dynamic>?> getWalkingDataByGroupId(String groupId) async {
    try {
      // groupIdに対応するドキュメントからデータを取得
      QuerySnapshot querySnapshot = await _db
          .collection('walking_data')
          .where('groupId', isEqualTo: groupId)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        return querySnapshot.docs.first.data() as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return null;
    }
  }

  // Firestoreからすべての歩行データを取得するメソッド
  Future<List<Map<String, dynamic>>> getAllWalkingData() async {
    try {
      QuerySnapshot snapshot = await _db.collection('walking_data').get();
      return snapshot.docs.map((doc) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        data['groupId'] = doc.id; // ドキュメント ID を groupId として追加
        return data;
      }).toList();
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return [];
    }
  }

  // 特定のGroupIDの歩行データをFirestoreから削除するメソッド
  Future<void> deleteWalkingDataByGroupId(String groupId) async {
    try {
      QuerySnapshot querySnapshot = await _db
          .collection('walking_data')
          .where('groupId', isEqualTo: groupId.toString())
          .get();

      for (var doc in querySnapshot.docs) {
        await _db.collection('walking_data').doc(doc.id).delete();
      }

      print("FirestoreからGroupID $groupId の歩行データを削除しました");
    } catch (e) {
      print("Firestoreから削除エラー: $e");
    }
  }
}