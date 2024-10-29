import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 位置情報グループをFirestoreに保存するメソッド (位置情報を1つの配列としてまとめて保存)
  Future<void> savePositionGroup(int groupId, List<Map<String, dynamic>> positions) async {
    try {
      // groupIdに対応するドキュメントに位置情報をまとめて保存
      await _db.collection('walking_groups').doc(groupId.toString()).set({
        'positions': positions,
      });
      print("位置情報グループをFirestoreに保存しました: GroupID $groupId");
    } catch (e) {
      print("Firestoreへの保存エラー: $e");
    }
  }

  // GroupIDごとの位置情報を取得するメソッド
  Future<List<Map<String, dynamic>>> getPositionsByGroupId(int groupId) async {
    try {
      // groupIdに対応するドキュメントから位置情報を取得
      DocumentSnapshot doc = await _db.collection('walking_groups').doc(groupId.toString()).get();
      List<Map<String, dynamic>> positions = List<Map<String, dynamic>>.from(doc['positions']);
      return positions;
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return [];
    }
  }

  // Firestoreからすべての位置情報を取得するメソッド
  Future<List<Map<String, dynamic>>> getAllPositions() async {
    try {
      QuerySnapshot snapshot = await _db.collection('walking_groups').get();
      List<Map<String, dynamic>> allPositions = [];

      for (var doc in snapshot.docs) {
        List<dynamic> positions = doc['positions'];
        for (var position in positions) {
          allPositions.add({
            'groupId': int.parse(doc.id),
            'latitude': position['latitude'],
            'longitude': position['longitude'],
            'timestamp': position['timestamp'],
          });
        }
      }
      return allPositions;
    } catch (e) {
      print("Firestoreからのデータ取得エラー: $e");
      return [];
    }
  }

  // 特定のGroupIDの位置情報をFirestoreから削除するメソッド
  Future<void> deletePositionGroup(int groupId) async {
    try {
      // groupIdに対応するドキュメントを削除
      await _db.collection('walking_groups').doc(groupId.toString()).delete();
      print("FirestoreからGroupID $groupId の位置情報を削除しました");
    } catch (e) {
      print("Firestoreから削除エラー: $e");
    }
  }
}