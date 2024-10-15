import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // 位置情報をFirestoreに保存
  Future<void> savePosition(
      int groupId, double latitude, double longitude, String timestamp) async {
    try {
      // 位置情報グループコレクションの参照
      DocumentReference groupRef = _firestore
          .collection('location_groups') // 位置情報グループコレクション
          .doc(groupId.toString()); // グループIDでドキュメントを取得

      // グループが存在しない場合は作成
      await groupRef.set({'created_at': FieldValue.serverTimestamp()},
          SetOptions(merge: true));

      // 位置情報をサブコレクションに追加
      await groupRef.collection('positions').add({
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
      });
    } catch (e) {
      print("Firestoreへの保存中にエラーが発生しました: $e");
    }
  }

  // 位置情報グループの取得
  Future<List<Map<String, dynamic>>> getPositionsByGroupId(int groupId) async {
    try {
      // グループの位置情報サブコレクションを取得
      QuerySnapshot snapshot = await _firestore
          .collection('location_groups')
          .doc(groupId.toString())
          .collection('positions')
          .get();

      return snapshot.docs.map((doc) => doc.data() as Map<String, dynamic>).toList();
    } catch (e) {
      print("Firestoreからの取得中にエラーが発生しました: $e");
      return [];
    }
  }

  // 全ての位置情報グループIDを取得
  Future<List<int>> getAllGroupIds() async {
    try {
      QuerySnapshot snapshot = await _firestore.collection('location_groups').get();
      return snapshot.docs.map((doc) => int.parse(doc.id)).toList();
    } catch (e) {
      print("FirestoreからのグループID取得中にエラーが発生しました: $e");
      return [];
    }
  }
}