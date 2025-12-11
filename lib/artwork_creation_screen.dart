import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'database_helper.dart';
import 'draft_list_screen.dart';
import 'polyline_painter.dart';
import 'firestore_service.dart';

import 'utils/utils.dart';

class ArtworkCreationScreen extends StatefulWidget {
  final List<List<Position>> trajectories;

  ArtworkCreationScreen({required this.trajectories});

  @override
  _ArtworkCreationScreenState createState() => _ArtworkCreationScreenState();
}

class _ArtworkCreationScreenState extends State<ArtworkCreationScreen> {
  List<TransformablePolyline> selectedTrajectories = [];
  TransformablePolyline? selectedItem;
  final GlobalKey _boundaryKey = GlobalKey();
  List<List<Position>> recordedTrajectories = [];
  Set<int> usedTrajectoryIndices = {}; // 保存済みの軌跡インデックスを保持（互換性のため保持）
  Set<int> temporarilyUsedIndices = {}; // 一時的に使用された軌跡インデックス（legacy）
  Set<String> temporarilyUsedGroupIds = {}; // 一時的に使用された軌跡のgroupId
  Set<String> usedLocalTrajectoryGroupIds = {}; // 使用済みローカル軌跡のgroupIdセット
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final FirestoreService _firestoreService =
      FirestoreService(); // Firestoreサービスのインスタンス化
  String? _currentDraftFilePath; // 現在の下書きファイルパスを保持

  bool isRotating = false;
  bool isScaling = false;
  final double canvasPadding = 20.0;

  // 軌跡のサイズ定義
  final double trajectorySize = 100.0;

  @override
  void initState() {
    super.initState();
    _loadRecordTrajectories();
  }

  // データベースから保存済みの軌跡を読み込む
  Future<void> _loadRecordTrajectories() async {
    try {
      // Firebase から使用済み情報を同期（アプリ再インストール対策）
      print("🔄 使用済み情報を Firebase から同期中...");
      await _dbHelper.syncUsedGarminActivitiesFromFirestore();
      await _dbHelper.syncUsedTrajectoriesFromFirestore();
      print("✅ 使用済み情報の同期が完了しました");

      recordedTrajectories.clear();

      // ローカルデータベースからデータを取得（Garmin軌跡を除外）
      List<Map<String, dynamic>> allWalkingData =
          await _dbHelper.getAllWalkingData();

      // デバッグ出力
      print("読み込まれた歩行データ: ${allWalkingData.length}件");

      // データを一意にするためSetを使用（groupIdベース）
      Set<String> uniqueGroupIds = {};
      List<List<Position>> uniqueTrajectoryList = [];

      for (var data in allWalkingData) {
        // Garmin軌跡は除外（is_from_garmin = 1）
        final isFromGarmin = (data['is_from_garmin'] ?? 0) as int;
        if (isFromGarmin == 1) {
          continue;
        }

        String groupId = data['group_id'];

        if (!uniqueGroupIds.contains(groupId)) {
          uniqueGroupIds.add(groupId);

          // positionsをデコード
          List<dynamic> positionsJson = jsonDecode(data['positions']);
          List<Position> trajectory = positionsJson.map((pos) {
            return Position(
              latitude: pos['latitude'],
              longitude: pos['longitude'],
              timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
              accuracy: 0.0,
              altitude: 0.0,
              heading: 0.0,
              speed: 0.0,
              speedAccuracy: 0.0,
              altitudeAccuracy: 0.0,
              headingAccuracy: 0.0,
            );
          }).toList();

          if (trajectory.isNotEmpty) {
            uniqueTrajectoryList.add(trajectory);
          }
        }
      }

      setState(() {
        recordedTrajectories = uniqueTrajectoryList;
      });

      print("一意な軌跡数: ${recordedTrajectories.length}件");
      await _loadUsedTrajectories();
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  /// Firebase から使用済みローカル軌跡のgroupIdを同期して読み込む
  Future<void> _loadUsedTrajectories() async {
    try {
      // Firestore から使用済みローカル軌跡を同期
      await _dbHelper.syncUsedTrajectoriesFromFirestore();

      // ローカルDBから読み込む
      final loadedUsedGroupIds = await _dbHelper.getUsedTrajectories();
      print(
          "✅ 使用済みローカル軌跡を読み込みました: ${loadedUsedGroupIds.length}件 - $loadedUsedGroupIds");

      // setState で UI 更新
      setState(() {
        usedLocalTrajectoryGroupIds = loadedUsedGroupIds.toSet();
      });
    } catch (e) {
      print("❌ 使用済み軌跡の読み込みエラー: $e");
    }
  }

  // アートワークを保存するメソッドを修正
  Future<void> _saveArtwork() async {
    String artworkName = await _promptForArtworkName(); // 作品名を入力
    if (artworkName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('作品名を入力してください。')),
      );
      return;
    }

    // ローディングインジケーターを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      RenderRepaintBoundary boundary = _boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      var image = await boundary.toImage();
      ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final directory = await getApplicationDocumentsDirectory();
      final artworksDirectory = Directory('${directory.path}/artworks');
      final canvasDirectory = Directory('${directory.path}/canvas_states');

      if (!(await artworksDirectory.exists())) {
        await artworksDirectory.create(recursive: true);
      }
      if (!(await canvasDirectory.exists())) {
        await canvasDirectory.create(recursive: true);
      }

      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      String artworkId = 'artwork_$timestamp'; // ユニークなIDを作成
      File imgFile = File('${artworksDirectory.path}/$artworkId.png');
      File canvasFile = File('${canvasDirectory.path}/canvas_$timestamp.json');

      // キャンバスのサイズを取得
      final canvasSize = _boundaryKey.currentContext!.size!;

      // 実際のスクリーンサイズ（AppBarを除く）を取得
      final mediaQuery = MediaQuery.of(context);
      final screenHeight = mediaQuery.size.height -
          mediaQuery.padding.top -
          mediaQuery.padding.bottom -
          AppBar().preferredSize.height;
      final screenWidth = mediaQuery.size.width;

      print('保存時のキャンバスサイズ: ${canvasSize.width} x ${canvasSize.height}');
      print('保存時の実際の画面サイズ: $screenWidth x $screenHeight');

      // 軌跡の数、総距離、総歩数を計算
      int trajectoryCount = selectedTrajectories.length;
      double totalDistance = 0.0;
      int totalSteps = 0;
      List<Map<String, dynamic>> trajectoryDetailsCache = [];

      for (var item in selectedTrajectories) {
        final groupId = generateGroupId(item.polyline);
        var trajectoryDetails =
            await _dbHelper.getWalkingDataByGroupId(groupId);

        // デバッグ: Garmin軌跡の場合、複数のgroupIdを試す
        String actualGroupId = groupId;
        if (trajectoryDetails == null) {
          print('⚠️ groupId "$groupId" でデータが見つかりません。Garmin軌跡か確認中...');
          // DB内に保存されているすべてのGarmin軌跡を確認
          final garminActivities = await _dbHelper.getGarminActivities();
          print('  利用可能なGarmin軌跡数: ${garminActivities.length}');

          if (garminActivities.isNotEmpty) {
            // 座標の境界から最も近いGarmin軌跡を見つける
            double minLat =
                item.polyline.map((p) => p.latitude).reduce(math.min);
            double maxLat =
                item.polyline.map((p) => p.latitude).reduce(math.max);
            double minLng =
                item.polyline.map((p) => p.longitude).reduce(math.min);
            double maxLng =
                item.polyline.map((p) => p.longitude).reduce(math.max);

            double centerLat = (minLat + maxLat) / 2;
            double centerLng = (minLng + maxLng) / 2;

            print('  軌跡の中心座標: ($centerLat, $centerLng)');

            // すべてのGarmin軌跡を確認
            for (final activity in garminActivities) {
              print(
                  '    - groupId: ${activity['group_id']}, distance: ${activity['distance']}, steps: ${activity['steps']}');

              // 座標を復元してチェック
              final positions = jsonDecode(activity['positions']) as List;
              if (positions.isNotEmpty) {
                final firstPos = positions.first as Map<String, dynamic>;
                final lastPos = positions.last as Map<String, dynamic>;

                final minLatDB = math.min(
                    (firstPos['latitude'] as num).toDouble(),
                    (lastPos['latitude'] as num).toDouble());
                final maxLatDB = math.max(
                    (firstPos['latitude'] as num).toDouble(),
                    (lastPos['latitude'] as num).toDouble());
                final minLngDB = math.min(
                    (firstPos['longitude'] as num).toDouble(),
                    (lastPos['longitude'] as num).toDouble());
                final maxLngDB = math.max(
                    (firstPos['longitude'] as num).toDouble(),
                    (lastPos['longitude'] as num).toDouble());

                print(
                    '      DB座標範囲: lat($minLatDB, $maxLatDB), lng($minLngDB, $maxLngDB)');

                // 座標範囲が重なっているか確認
                if (minLat <= maxLatDB &&
                    maxLat >= minLatDB &&
                    minLng <= maxLngDB &&
                    maxLng >= minLngDB) {
                  print('      ✅ 座標が一致！このgroupIdを使用します');
                  actualGroupId = activity['group_id'] as String;
                  trajectoryDetails =
                      await _dbHelper.getWalkingDataByGroupId(actualGroupId);
                  break;
                }
              }
            }
          }
        }

        totalDistance += (trajectoryDetails?['distance'] as double? ?? 0.0);
        totalSteps += (trajectoryDetails?['steps'] as int? ?? 0);
        trajectoryDetailsCache.add({
          'item': item,
          'details': trajectoryDetails,
          'groupId': actualGroupId,
        });
      }

      // 保存時のキャンバス状態（詳細メタデータ付き）
      final canvasState = {
        'canvasWidth': screenWidth, // 実際の画面幅を保存
        'canvasHeight': screenHeight, // 実際の画面高さを保存（AppBarを除く）
        'actualCanvasSize': {
          'width': canvasSize.width,
          'height': canvasSize.height,
        },
        'trajectories': trajectoryDetailsCache.map((cached) {
          final item = cached['item'] as TransformablePolyline;
          final trajectoryDetails = cached['details'];
          final groupId = cached['groupId'];

          // 軌跡の相対位置を計算（0〜1の範囲に正規化）
          double relativeX = item.position.dx / screenWidth;
          double relativeY = item.position.dy / screenHeight;

          // 軌跡の地理的範囲を計算
          double minLat = item.polyline.map((p) => p.latitude).reduce(math.min);
          double maxLat = item.polyline.map((p) => p.latitude).reduce(math.max);
          double minLng =
              item.polyline.map((p) => p.longitude).reduce(math.min);
          double maxLng =
              item.polyline.map((p) => p.longitude).reduce(math.max);

          print('軌跡の絶対位置: (${item.position.dx}, ${item.position.dy})');
          print('軌跡の相対位置: ($relativeX, $relativeY)');
          print('軌跡の回転角度: ${item.rotation}');
          print('軌跡のスケール: ${item.scale}');
          print('軌跡の地理的範囲: lat($minLat, $maxLat), lng($minLng, $maxLng)');

          return {
            'positions': item.polyline.map((p) {
              return {
                'latitude': p.latitude,
                'longitude': p.longitude,
                'timestamp': p.timestamp.toIso8601String(),
              };
            }).toList(),
            'position': {
              'dx': relativeX,
              'dy': relativeY,
              'absoluteX': item.position.dx,
              'absoluteY': item.position.dy,
            },
            'scale': item.scale,
            'rotation': item.rotation,
            'geoBounds': {
              'minLat': minLat,
              'maxLat': maxLat,
              'minLng': minLng,
              'maxLng': maxLng,
            },
            'details': {
              'groupId': groupId,
              'distance': trajectoryDetails?['distance'] ?? 0.0,
              'steps': trajectoryDetails?['steps'] ?? 0,
              'date': trajectoryDetails?['date'] ?? '',
            },
          };
        }).toList(),
        'meta': {
          'trajectoryCount': trajectoryCount,
          'totalDistance': totalDistance,
          'totalSteps': totalSteps,
          'artworkName': artworkName, // 作品名
          'artworkId': artworkId, // 作品のユニークID
          'createdAt': DateTime.now().toIso8601String(),
          'version': '2.0', // メタデータのバージョン
        },
      };

      await canvasFile.writeAsString(jsonEncode(canvasState));
      await imgFile.writeAsBytes(pngBytes);

      // Firestoreに作品を保存 - ここでキャンバス状態を明示的に展開してセット
      await _firestoreService.saveArtwork(
        artworkId: artworkId,
        canvasState: canvasState,
        imageData: pngBytes,
      );

      print(
          "Firestoreに保存した作品データ: artworkId=$artworkId, canvasStateのキー=${canvasState.keys.toList()}");

      // 使用済みの軌跡を保存
      print(
          "📌 使用済みとしてマークする軌跡: ${temporarilyUsedGroupIds.length}件 - $temporarilyUsedGroupIds");
      for (final groupId in temporarilyUsedGroupIds) {
        print('🔹 軌跡をマーク済みにしました: $groupId');
        await _dbHelper.markTrajectoryAsUsed(groupId);
      }
      print("✅ 全軌跡のマーク処理完了");

      temporarilyUsedIndices.clear();
      temporarilyUsedGroupIds.clear();

      // **途中保存ファイルの削除**
      if (_currentDraftFilePath != null) {
        final draftFile = File(_currentDraftFilePath!);
        if (await draftFile.exists()) {
          await draftFile.delete();
          print("途中保存ファイルを削除しました: $_currentDraftFilePath");
        }
        _currentDraftFilePath = null; // 現在の途中保存ファイルパスをクリア
      }

      // ローディングを閉じる
      if (mounted) {
        Navigator.pop(context);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('アートワークが保存されました!')),
        );
        Navigator.pop(
            context, {'imageFile': imgFile, 'canvasFile': canvasFile});
      }
    } catch (e) {
      // ローディングを閉じる
      if (mounted) {
        Navigator.pop(context);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('アートワークの保存に失敗しました: $e')),
        );
      }
    }
  }

  // 作品名を入力するダイアログを表示
  Future<String> _promptForArtworkName() async {
    String artworkName = '';
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('作品名を入力'),
          content: TextField(
            onChanged: (value) {
              artworkName = value;
            },
            decoration: InputDecoration(hintText: '作品名'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('保存'),
            ),
          ],
        );
      },
    );
    return artworkName;
  }

  // 選択された軌跡を削除する
  void _removeSelectedTrajectory() {
    if (selectedItem != null) {
      setState(() {
        selectedTrajectories.remove(selectedItem);

        // 保存されたgroupIdを使用して一時使用中リストから削除
        if (selectedItem!.groupId != null) {
          print("🗑️ 軌跡を削除: groupId=${selectedItem!.groupId}");

          // groupIdベースの管理から削除（モーダルに再表示されるようにする）
          if (temporarilyUsedGroupIds.contains(selectedItem!.groupId)) {
            temporarilyUsedGroupIds.remove(selectedItem!.groupId);
            print("✅ temporarilyUsedGroupIdsから削除しました");
          }

          // legacy インデックスベースの管理からも削除
          int indexToRemove =
              recordedTrajectories.indexOf(selectedItem!.polyline);
          if (indexToRemove != -1 &&
              temporarilyUsedIndices.contains(indexToRemove)) {
            temporarilyUsedIndices.remove(indexToRemove);
          }
        }

        selectedItem = null;
      });
    }
  }

  /// 指定された位置にある軌跡のリストを取得する
  List<TransformablePolyline> _getTrajectoriesAt(Offset position) {
    final double expandedTouchArea = trajectorySize * 1.5;
    final double halfSize = expandedTouchArea / 2;

    // 逆順で検索（上にあるものが先にヒットするように）
    // ただし、全てのヒットするものを取得したいので filter を使う
    return selectedTrajectories.where((item) {
      final double dx = (item.position.dx - position.dx).abs();
      final double dy = (item.position.dy - position.dy).abs();
      return dx <= halfSize && dy <= halfSize;
    }).toList();
  }

  // 使用可能な軌跡を表示するモーダルを表示する
  void _showTrajectoryModal(BuildContext context) async {
    // ローディングインジケーターを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      // モーダルを開く前に基本データを読み込む
      print("🔄 モーダル表示前にデータを読み込み中...");

      // Garmin軌跡を読み込む
      final garminActivities = await _dbHelper.getGarminActivities();
      final usedGarminGroupIds =
          await _dbHelper.getUsedGarminActivityGroupIds();

      // ローカル軌跡のgroupIdマッピングを作成
      final allData = await _dbHelper.getAllWalkingData();
      Map<int, String> localTrajectoryGroupIds = {};
      for (int i = 0; i < allData.length; i++) {
        if ((allData[i]['is_from_garmin'] ?? 0) == 0) {
          localTrajectoryGroupIds[i] = allData[i]['group_id'] as String;
        }
      }

      print("📊 Garmin軌跡: ${garminActivities.length}件");
      print("✅ 使用済みGarmin軌跡: ${usedGarminGroupIds.length}件");
      print(
          "🔧 一時使用中のgroupId: ${temporarilyUsedGroupIds.length}件 - $temporarilyUsedGroupIds");

      // ローディングを閉じる
      if (mounted) {
        Navigator.pop(context);
      }

      // モーダルを表示
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (context) => DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            builder: (context, scrollController) => Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: _TrajectoryModalContent(
                recordedTrajectories: recordedTrajectories,
                usedTrajectoryIndices: usedTrajectoryIndices,
                usedLocalTrajectoryGroupIds: <String>{}, // モーダルのinitStateで最新データを取得
                temporarilyUsedIndices: temporarilyUsedIndices,
                temporarilyUsedGroupIds: temporarilyUsedGroupIds,
                garminActivities: garminActivities,
                usedGarminGroupIds: usedGarminGroupIds.toSet(),
                localTrajectoryGroupIds: localTrajectoryGroupIds,
                dbHelper: _dbHelper,
                scrollController: scrollController,
                onSelectTrajectory: (trajectory, isGarmin, groupId) {
                  Navigator.pop(context);

                  setState(() {
                    final trajectoryIndex =
                        recordedTrajectories.indexOf(trajectory);

                    if (isGarmin) {
                      // Garmin軌跡の場合、groupIdを一時的に記録
                      // ※ 使用済みマークは _saveArtwork() 時に行う
                      if (groupId != null) {
                        temporarilyUsedIndices.add(groupId.hashCode); // legacy
                        temporarilyUsedGroupIds.add(groupId); // 新方式
                        print("📌 Garmin軌跡を一時使用中に追加: $groupId");
                      }
                    } else {
                      // ローカル軌跡の場合、インデックスとgroupIdをマーク
                      if (trajectoryIndex != -1) {
                        temporarilyUsedIndices.add(trajectoryIndex); // legacy
                        // groupIdを取得して追加（非同期なので別途処理）
                        if (groupId != null) {
                          temporarilyUsedGroupIds.add(groupId);
                          print("📌 ローカル軌跡を一時使用中に追加: $groupId");
                        }
                      }
                    }

                    final newTrajectory = TransformablePolyline(
                      trajectory,
                      Offset(
                        MediaQuery.of(context).size.width / 2 - 50,
                        MediaQuery.of(context).size.height / 2 - 50,
                      ),
                      groupId: groupId, // groupIdを保存
                    );
                    newTrajectory.scale = 0.8;
                    selectedTrajectories.add(newTrajectory);
                    // 新しく追加した軌跡を選択状態にする
                    selectedItem = newTrajectory;
                  });
                },
              ),
            ),
          ),
        );
      }
    } catch (e) {
      // エラーが発生した場合、ローディングを閉じる
      if (mounted) {
        Navigator.pop(context);
      }
      print("❌ モーダル表示エラー: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('軌跡の読み込みに失敗しました: $e')),
        );
      }
    }
  }

  // 作品の途中保存
  void _saveDraft({String? draftFilePath}) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final draftsDirectory = Directory('${directory.path}/drafts');

      if (!(await draftsDirectory.exists())) {
        await draftsDirectory.create(recursive: true);
      }

      // 既存のファイルパスが指定されている場合はそれを使用し、新規の場合は新しいファイルを作成
      String filePath = draftFilePath ??
          '${draftsDirectory.path}/draft_${DateTime.now().toIso8601String()}.json';
      File draftFile = File(filePath);

      final canvasSize = _boundaryKey.currentContext!.size!;
      final draftState = {
        'canvasWidth': canvasSize.width,
        'canvasHeight': canvasSize.height,
        'trajectories': selectedTrajectories.map((item) {
          return {
            'positions': item.polyline.map((p) {
              return {
                'latitude': p.latitude,
                'longitude': p.longitude,
                'timestamp': p.timestamp.toIso8601String(),
              };
            }).toList(),
            'position': {
              'dx': item.position.dx / canvasSize.width,
              'dy': item.position.dy / canvasSize.height,
            },
            'scale': item.scale,
            'rotation': item.rotation,
          };
        }).toList(),
        'timestamp': DateTime.now().toIso8601String(),
      };

      await draftFile.writeAsString(jsonEncode(draftState));

      // 現在使用中の軌跡を「使用済み」に設定
      for (final trajectory in selectedTrajectories) {
        int index = recordedTrajectories.indexOf(trajectory.polyline);
        if (index != -1) {
          usedTrajectoryIndices.add(index);
          // インデックスからgroupIdを取得して使用済みとして登録
          final groupId = await _dbHelper.getGroupIdByIndex(index);
          if (groupId != null) {
            await _dbHelper.markTrajectoryAsUsed(groupId);
          }
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('途中保存しました。')),
      );

      // キャンバスの状態をリセット
      setState(() {
        selectedTrajectories.clear();
        temporarilyUsedIndices.clear();
        selectedItem = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('途中保存に失敗しました: $e')),
      );
    }
  }

  // 途中保存した作品を読み込む
  void _loadDraft(Map<String, dynamic> draftData) {
    final canvasWidth = draftData['canvasWidth'];
    final canvasHeight = draftData['canvasHeight'];

    setState(() {
      selectedTrajectories =
          (draftData['trajectories'] as List<dynamic>).map((item) {
        final positions = (item['positions'] as List).map((p) {
          return Position(
            latitude: p['latitude'],
            longitude: p['longitude'],
            timestamp: DateTime.tryParse(p['timestamp']) ?? DateTime.now(),
            accuracy: 0.0,
            altitude: 0.0,
            heading: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
            altitudeAccuracy: 0.0,
            headingAccuracy: 0.0,
          );
        }).toList();

        return TransformablePolyline(
          positions,
          Offset(
            (item['position']['dx'] ?? 0) * canvasWidth,
            (item['position']['dy'] ?? 0) * canvasHeight,
          ),
        )
          ..rotation = item['rotation'] ?? 0.0
          ..scale = item['scale'] ?? 1.0;
      }).toList();

      // 現在の下書きファイルパスを保存
      _currentDraftFilePath = draftData['filePath'];

      // リストに表示されないように一時的に使用中としてマーク
      temporarilyUsedIndices.clear();
      for (final trajectory in selectedTrajectories) {
        final index = recordedTrajectories.indexOf(trajectory.polyline);
        if (index != -1) {
          temporarilyUsedIndices.add(index);
        }
      }
    });
  }

  // 途中保存した作品を一覧表示する
  void _showDraftListScreen() async {
    final selectedDraft = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DraftListScreen(
          onDraftSelected: (draft) {
            Navigator.pop(context, draft);
          },
        ),
      ),
    );

    if (selectedDraft != null) {
      _loadDraft(selectedDraft); // 選択された下書きを復元
    }
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    double screenHeight = MediaQuery.of(context).size.height;

    final double expandedTouchArea = trajectorySize * 1.5; // 回転時の角もカバーできるように拡大
    final double touchAreaOffset =
        (expandedTouchArea - trajectorySize) / 2; // 中央に配置するためのオフセット

    return Scaffold(
      appBar: AppBar(
        title: Text('作品の制作'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'save') {
                _saveArtwork(); // 作品の保存
              } else if (value == 'save_draft') {
                _saveDraft(draftFilePath: _currentDraftFilePath); // 上書き保存
              } else if (value == 'load_draft') {
                _showDraftListScreen(); // 途中保存一覧
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'save',
                child: Text('保存'),
              ),
              PopupMenuItem(
                value: 'save_draft',
                child: Text('下書き保存'),
              ),
              PopupMenuItem(
                value: 'load_draft',
                child: Text('下書き一覧'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTrajectoryModal(context),
        child: Icon(Icons.add),
      ),
      body: Stack(
        children: [
          Container(
            width: screenWidth,
            height: screenHeight,
            color: Colors.grey[200],
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                // キャンバスの白い部分をタップした場合、選択状態を解除
                setState(() {
                  selectedItem = null;
                });
              },
              child: RepaintBoundary(
                key: _boundaryKey,
                child: Stack(
                  children: [
                    ...selectedTrajectories.map((item) {
                      final isSelected = selectedItem == item;

                      return Positioned(
                        left: item.position.dx - expandedTouchArea / 2,
                        top: item.position.dy - expandedTouchArea / 2,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() {
                              // タップした軌跡を選択状態にする
                              selectedItem = item;
                            });
                          },
                          onLongPress: () {
                            // 長押しで重なっている軌跡を循環選択
                            final hitTrajectories =
                                _getTrajectoriesAt(item.position);
                            if (hitTrajectories.length > 1) {
                              setState(() {
                                final candidates =
                                    hitTrajectories.reversed.toList();
                                final currentIndex = candidates.indexOf(item);
                                if (currentIndex != -1) {
                                  final nextIndex =
                                      (currentIndex + 1) % candidates.length;
                                  selectedItem = candidates[nextIndex];

                                  // 選択した軌跡を最前面に移動
                                  selectedTrajectories.remove(selectedItem);
                                  selectedTrajectories.add(selectedItem!);

                                  print(
                                      "Long press cycled to: ${selectedTrajectories.indexOf(selectedItem!)} and brought to front");
                                }
                              });
                            }
                          },
                          onScaleStart: (details) {
                            // 選択された軌跡のみ回転操作を受け入れる
                            if (isSelected) {
                              setState(() {
                                item.lastRotation = item.rotation;
                                item.lastScale = item.scale;
                                isRotating = false;
                                isScaling = false;
                              });
                            }
                          },
                          onScaleUpdate: (details) {
                            // 選択された軌跡のみ更新する
                            if (isSelected) {
                              // 前回のフレームから変化があった場合のみ更新
                              final bool hasRotationChange =
                                  details.rotation.abs() > 0.001;
                              final bool hasScaleChange =
                                  (details.scale - 1.0).abs() > 0.001;
                              final bool hasPositionChange =
                                  details.focalPointDelta.distance > 0.5;

                              if (hasRotationChange ||
                                  hasScaleChange ||
                                  hasPositionChange) {
                                setState(() {
                                  // 回転操作中かどうかを状態として保持
                                  isRotating = hasRotationChange;
                                  isScaling = hasScaleChange;

                                  // 回転処理 - 回転中はスケールを変更しない
                                  if (isRotating) {
                                    item.rotation =
                                        item.lastRotation + details.rotation;
                                  }
                                  // スケール処理 - 回転中でない場合のみ
                                  else if (isScaling) {
                                    // 最小・最大のスケール制限を設定
                                    final newScale =
                                        item.lastScale * details.scale;
                                    item.scale = newScale.clamp(
                                        0.3, 3.0); // 最小0.3倍、最大3倍に制限
                                  }

                                  // 移動処理 - どの向きでも自然に動くように
                                  if (hasPositionChange) {
                                    item.position += details.focalPointDelta;
                                  }
                                });
                              }
                            }
                          },
                          onScaleEnd: (_) {
                            if (isSelected) {
                              setState(() {
                                isRotating = false;
                                isScaling = false;
                                item.lastRotation = item.rotation;
                                item.lastScale = item.scale;
                              });
                            }
                          },
                          child: Stack(
                            children: [
                              Container(
                                width: expandedTouchArea,
                                height: expandedTouchArea,
                                color: Colors.transparent,
                              ),
                              Positioned(
                                left: touchAreaOffset,
                                top: touchAreaOffset,
                                child: Transform.rotate(
                                  angle: item.rotation,
                                  alignment: Alignment.center,
                                  child: Container(
                                    width: trajectorySize,
                                    height: trajectorySize,
                                    decoration: BoxDecoration(
                                      border: selectedItem == item
                                          ? Border.all(
                                              color: isRotating
                                                  ? Colors.orange
                                                  : Colors.red,
                                              width: 2.0,
                                            )
                                          : null,
                                    ),
                                    child: Transform.scale(
                                      scale: item.scale,
                                      alignment: Alignment.center,
                                      child: Stack(
                                        children: [
                                          CustomPaint(
                                            size: Size(
                                                trajectorySize, trajectorySize),
                                            painter: PolylinePainter(
                                              positions: item.polyline,
                                              minLat: item.minLat,
                                              maxLat: item.maxLat,
                                              minLon: item.minLon,
                                              maxLon: item.maxLon,
                                            ),
                                          ),
                                          // デバッグ: タップ領域を視覚化
                                          Positioned.fill(
                                            child: CustomPaint(
                                                //  painter: DebugBoundsPainter(), // デバッグ用ペインター
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
          // 削除ボタンの表示
          if (selectedItem != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: IconButton(
                  icon: Icon(Icons.delete, size: 30, color: Colors.red),
                  onPressed: _removeSelectedTrajectory,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class TransformablePolyline {
  List<Position> polyline;
  Offset position;
  double rotation;
  double lastRotation;
  double scale;
  double lastScale;
  String? groupId; // 軌跡のgroupIdを保存

  double minLat;
  double maxLat;
  double minLon;
  double maxLon;

  TransformablePolyline(this.polyline, this.position, {this.groupId})
      : rotation = 0.0,
        lastRotation = 0.0,
        scale = 1.0, // デフォルト値を設定
        lastScale = 1.0,
        minLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        maxLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        minLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
        maxLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
}

/// 軌跡選択モーダルのコンテンツ
class _TrajectoryModalContent extends StatefulWidget {
  final List<List<Position>> recordedTrajectories;
  final Set<int> usedTrajectoryIndices;
  final Set<String> usedLocalTrajectoryGroupIds;
  final Set<int> temporarilyUsedIndices;
  final Set<String> temporarilyUsedGroupIds;
  final List<Map<String, dynamic>> garminActivities;
  final Set<String> usedGarminGroupIds;
  final Map<int, String> localTrajectoryGroupIds;
  final DatabaseHelper dbHelper;
  final Function(List<Position>, bool isGarmin, String? groupId)
      onSelectTrajectory;
  final ScrollController? scrollController;

  const _TrajectoryModalContent({
    required this.recordedTrajectories,
    required this.usedTrajectoryIndices,
    required this.usedLocalTrajectoryGroupIds,
    required this.temporarilyUsedIndices,
    required this.temporarilyUsedGroupIds,
    required this.garminActivities,
    required this.usedGarminGroupIds,
    required this.localTrajectoryGroupIds,
    required this.dbHelper,
    required this.onSelectTrajectory,
    this.scrollController,
  });

  @override
  State<_TrajectoryModalContent> createState() =>
      _TrajectoryModalContentState();
}

class _TrajectoryModalContentState extends State<_TrajectoryModalContent> {
  late Future<Set<String>> _usedGroupIdsFuture;

  @override
  void initState() {
    super.initState();
    // Firestoreから最新の使用済み軌跡を取得するFutureを初期化
    _usedGroupIdsFuture = _loadLatestUsedTrajectories();
  }

  Future<Set<String>> _loadLatestUsedTrajectories() async {
    try {
      final firestoreService = FirestoreService();
      final trajectories =
          await firestoreService.getUsedTrajectoriesFromFirestore();
      final groupIds = trajectories.map((t) => t['groupId'] as String).toSet();

      print("📌 Firestoreから取得した使用済み軌跡: ${groupIds.length}件 - $groupIds");
      return groupIds;
    } catch (e) {
      print("❌ 使用済み軌跡の読み込みエラー: $e");
      return <String>{};
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Set<String>>(
      future: _usedGroupIdsFuture,
      builder: (context, snapshot) {
        // データが読み込まれるまで待機
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final recentlyUsedGroupIds = snapshot.data ?? <String>{};
        print(
            "🔍 Modal build開始 - _recentlyUsedGroupIds: ${recentlyUsedGroupIds.length}件 - $recentlyUsedGroupIds");

        return _buildTrajectoryGrid(recentlyUsedGroupIds);
      },
    );
  }

  Widget _buildTrajectoryGrid(Set<String> recentlyUsedGroupIds) {
    print(
        "🔍 Modal build開始 - recentlyUsedGroupIds: ${recentlyUsedGroupIds.length}件 - $recentlyUsedGroupIds");

    // フィルタリングは _buildCombinedTrajectories で行うので、ここでは全軌跡を渡す
    // groupIdマッピングを構築
    Map<int, String> localTrajectoryGroupIds = {};
    for (int i = 0; i < widget.recordedTrajectories.length; i++) {
      final groupId = widget.localTrajectoryGroupIds[i];
      if (groupId != null) {
        localTrajectoryGroupIds[i] = groupId;
      }
    }
    print(
        "📊 localTrajectoryGroupIds: ${localTrajectoryGroupIds.length}件 - keys=${localTrajectoryGroupIds.keys.toList()}");

    // 記録した軌跡とGarmin軌跡を統合
    return _buildCombinedTrajectories(
        widget.recordedTrajectories,
        widget.garminActivities,
        localTrajectoryGroupIds,
        recentlyUsedGroupIds,
        widget.temporarilyUsedIndices,
        widget.temporarilyUsedGroupIds,
        widget.usedGarminGroupIds);
  }

  // 記録した軌跡とGarmin軌跡を統合表示
  Widget _buildCombinedTrajectories(
    List<List<Position>> recordedTrajectories,
    List<Map<String, dynamic>> garminActivities,
    Map<int, String> localTrajectoryGroupIds,
    Set<String> recentlyUsedGroupIds,
    Set<int> temporarilyUsedIndices,
    Set<String> temporarilyUsedGroupIds,
    Set<String> usedGarminGroupIds,
  ) {
    if (recordedTrajectories.isEmpty && garminActivities.isEmpty) {
      return Center(
        child: Text('軌跡がありません'),
      );
    }

    // Garmin アクティビティを Position リストに変換
    final List<Map<String, dynamic>> garminTrajectories = [];
    for (final activity in garminActivities) {
      final positions = (jsonDecode(activity['positions']) as List).map((pos) {
        return Position(
          latitude: pos['latitude'],
          longitude: pos['longitude'],
          timestamp: DateTime.tryParse(pos['timestamp']) ?? DateTime.now(),
          accuracy: 0.0,
          altitude: 0.0,
          heading: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );
      }).toList();

      garminTrajectories.add({
        'positions': positions,
        'isGarmin': true,
        'date': activity['date'] as String,
        'distance': activity['distance'] as double,
        'steps': activity['steps'] as int,
        'groupId': activity['group_id'] as String,
      });
    }

    // 記録した軌跡も同じ形式に
    final List<Map<String, dynamic>> recordedWithMetadata = [];
    for (int i = 0; i < recordedTrajectories.length; i++) {
      final trajectory = recordedTrajectories[i];
      final groupId = localTrajectoryGroupIds[i]; // インデックスからgroupIdを取得

      if (groupId == null) {
        print("⚠️  警告: インデックス $i の軌跡にgroupIdがありません");
      }

      recordedWithMetadata.add({
        'positions': trajectory,
        'isGarmin': false,
        'date': DateFormat('yyyy/MM/dd').format(trajectory.first.timestamp),
        'groupId': groupId, // groupIdを含める（nullの可能性あり）
      });
    }
    print(
        "📊 記録した軌跡数: ${recordedWithMetadata.length}件、groupId付き: ${recordedWithMetadata.where((t) => t['groupId'] != null).length}件");

    // 両方を結合してソート（最新順）
    final List<Map<String, dynamic>> allTrajectories = [
      ...recordedWithMetadata,
      ...garminTrajectories
    ];
    allTrajectories.sort((a, b) {
      final List<Position> positionsA = a['positions'];
      final List<Position> positionsB = b['positions'];
      final DateTime latestA = positionsA
          .map((p) => p.timestamp)
          .reduce((value, element) => value.isAfter(element) ? value : element);
      final DateTime latestB = positionsB
          .map((p) => p.timestamp)
          .reduce((value, element) => value.isAfter(element) ? value : element);
      return latestB.compareTo(latestA);
    });

    // 使用済み/使用中の軌跡をフィルタリングで除外
    final List<Map<String, dynamic>> displayTrajectories =
        allTrajectories.where((trajectory) {
      final String? groupId = trajectory['groupId'];
      if (groupId == null) return true; // groupIdがない場合は表示

      final bool isGarmin = trajectory['isGarmin'];

      print("🔍 フィルタリング対象: groupId=$groupId, isGarmin=$isGarmin");

      if (isGarmin) {
        // Garmin軌跡：使用中なら除外
        final isTemporarilyUsed = temporarilyUsedGroupIds.contains(groupId);
        print("  Garmin - temporarily: $isTemporarilyUsed");
        return !isTemporarilyUsed;
      } else {
        // ローカル軌跡：使用済みまたは使用中なら除外
        final isUsed = recentlyUsedGroupIds.contains(groupId);
        final isTemporarilyUsed = temporarilyUsedGroupIds.contains(groupId);
        print("  ローカル - used: $isUsed, temporarily: $isTemporarilyUsed");
        return !isUsed && !isTemporarilyUsed;
      }
    }).toList();

    print("📊 フィルタリング結果: 表示軌跡=${displayTrajectories.length}件");
    final displayGroupIds =
        displayTrajectories.map((t) => t['groupId']).toSet();
    print("📋 表示対象のgroupId: $displayGroupIds");

    return GridView.builder(
      controller: widget.scrollController,
      padding: EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: displayTrajectories.length,
      itemBuilder: (context, index) {
        final trajectory = displayTrajectories[index];
        final List<Position> positions = trajectory['positions'];
        final bool isGarmin = trajectory['isGarmin'];
        final String date = trajectory['date'];
        final String? groupId = trajectory['groupId'];

        return GestureDetector(
          onTap: () {
            widget.onSelectTrajectory(positions, isGarmin, groupId);
          },
          child: Stack(
            children: [
              CustomPaint(
                size: Size(60, 60),
                painter: PolylinePainter(
                  positions: positions,
                  minLat: positions
                      .map((p) => p.latitude)
                      .reduce((a, b) => a < b ? a : b),
                  maxLat: positions
                      .map((p) => p.latitude)
                      .reduce((a, b) => a > b ? a : b),
                  minLon: positions
                      .map((p) => p.longitude)
                      .reduce((a, b) => a < b ? a : b),
                  maxLon: positions
                      .map((p) => p.longitude)
                      .reduce((a, b) => a > b ? a : b),
                ),
              ),
              // 日付ラベル
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.all(4),
                  color: Colors.white.withOpacity(0.8),
                  child: Text(date, style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// デバッグ用: 軌跡のタップ領域を視覚化するペインター
class DebugBoundsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyan.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 矩形の枠線を描画
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );

    // コーナーに小さなマーカーを追加
    final markerPaint = Paint()
      ..color = Colors.cyan
      ..style = PaintingStyle.fill;

    final markerSize = 4.0;
    // 左上
    canvas.drawCircle(Offset(markerSize, markerSize), markerSize, markerPaint);
    // 右上
    canvas.drawCircle(
        Offset(size.width - markerSize, markerSize), markerSize, markerPaint);
    // 左下
    canvas.drawCircle(
        Offset(markerSize, size.height - markerSize), markerSize, markerPaint);
    // 右下
    canvas.drawCircle(Offset(size.width - markerSize, size.height - markerSize),
        markerSize, markerPaint);

    // 中心を示す十字線
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    const crossSize = 10.0;

    canvas.drawLine(
      Offset(centerX - crossSize, centerY),
      Offset(centerX + crossSize, centerY),
      paint,
    );
    canvas.drawLine(
      Offset(centerX, centerY - crossSize),
      Offset(centerX, centerY + crossSize),
      paint,
    );
  }

  @override
  bool shouldRepaint(DebugBoundsPainter oldDelegate) => false;
}
