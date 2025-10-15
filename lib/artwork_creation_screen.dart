import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'database_helper.dart';
import 'draft_list_screen.dart';
import 'polyline_painter.dart';
import 'package:intl/intl.dart';
import 'firestore_service.dart'; // Firestoreサービスをインポート

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
  Set<int> usedTrajectoryIndices = {}; // 保存済みの軌跡インデックスを保持
  Set<int> temporarilyUsedIndices = {}; // 一時的に使用された軌跡インデックス
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final FirestoreService _firestoreService =
      FirestoreService(); // Firestoreサービスのインスタンス化
  String? _currentDraftFilePath; // 現在の下書きファイルパスを保持

  bool isDraggingRotationHandle = false; // 回転ハンドルをドラッグ中かどうか
  Offset? rotationDragStartPoint; // 回転ドラッグ開始点
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
      recordedTrajectories.clear();

      // ローカルデータベースからデータを取得
      List<Map<String, dynamic>> allWalkingData =
          await _dbHelper.getAllWalkingData();

      // デバッグ出力
      print("読み込まれた歩行データ: ${allWalkingData.length}件");

      // データを一意にするためSetを使用（groupIdベース）
      Set<String> uniqueGroupIds = {};
      List<List<Position>> uniqueTrajectoryList = [];

      for (var data in allWalkingData) {
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

  // データベースから保存済みの軌跡インデックスを読み込む
  Future<void> _loadUsedTrajectories() async {
    try {
      final loadedUsedIndices = await _dbHelper.getUsedTrajectories();
      setState(() {
        usedTrajectoryIndices = loadedUsedIndices.toSet();
      });
    } catch (e) {
      print("使用済み軌跡の読み込みエラー: $e");
    }
  }

  // アートワークを保存するメソッドを修正
  Future<void> _saveArtwork() async {
    String artworkName = await _promptForArtworkName(); // 作品名を入力
    if (artworkName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('作品名を入力してください。')),
      );
      return;
    }

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
        final trajectoryDetails =
            await _dbHelper.getWalkingDataByGroupId(groupId);
        totalDistance += (trajectoryDetails?['distance'] as double? ?? 0.0);
        totalSteps += (trajectoryDetails?['steps'] as int? ?? 0);
        trajectoryDetailsCache.add({
          'item': item,
          'details': trajectoryDetails,
          'groupId': groupId,
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
      for (final index in temporarilyUsedIndices) {
        usedTrajectoryIndices.add(index);
        await _dbHelper.insertUsedTrajectory(index);
      }
      temporarilyUsedIndices.clear();

      // **途中保存ファイルの削除**
      if (_currentDraftFilePath != null) {
        final draftFile = File(_currentDraftFilePath!);
        if (await draftFile.exists()) {
          await draftFile.delete();
          print("途中保存ファイルを削除しました: $_currentDraftFilePath");
        }
        _currentDraftFilePath = null; // 現在の途中保存ファイルパスをクリア
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークが保存されました!')),
      );
      Navigator.pop(context, {'imageFile': imgFile, 'canvasFile': canvasFile});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('アートワークの保存に失敗しました: $e')),
      );
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
      int indexToRemove = recordedTrajectories.indexOf(selectedItem!.polyline);
      setState(() {
        selectedTrajectories.remove(selectedItem);
        if (temporarilyUsedIndices.contains(indexToRemove)) {
          temporarilyUsedIndices.remove(indexToRemove);
        }
        selectedItem = null;
      });
    }
  }

  // 使用可能な軌跡を表示するモーダルを表示する
  void _showTrajectoryModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        // 使用可能な軌跡をフィルタリング
        final availableTrajectories = List.generate(
          recordedTrajectories.length,
          (index) => !usedTrajectoryIndices.contains(index) &&
                  !temporarilyUsedIndices.contains(index)
              ? recordedTrajectories[index]
              : null,
        ).where((trajectory) => trajectory != null).toList();

        // 軌跡を最新の順にソート
        availableTrajectories.sort((a, b) {
          final DateTime latestA = a!.map((p) => p.timestamp).reduce(
              (value, element) => value.isAfter(element) ? value : element);
          final DateTime latestB = b!.map((p) => p.timestamp).reduce(
              (value, element) => value.isAfter(element) ? value : element);
          return latestB.compareTo(latestA); // 新しい順
        });

        return Container(
          height: MediaQuery.of(context).size.height * 0.5,
          padding: EdgeInsets.all(10),
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: availableTrajectories.length,
            itemBuilder: (context, index) {
              final trajectory = availableTrajectories[index];
              DateTime date = trajectory!.first.timestamp;
              String formattedDate = DateFormat('MM/dd').format(date);
              return GestureDetector(
                onTap: () {
                  Navigator.pop(context); // モーダルを閉じる
                  setState(() {
                    final trajectoryIndex =
                        recordedTrajectories.indexOf(trajectory);
                    temporarilyUsedIndices.add(trajectoryIndex);
                    // 新しい軌跡を追加するとき、scaleを0.6に設定（元の動作と同じ）
                    final newTrajectory = TransformablePolyline(
                      trajectory,
                      Offset(
                        MediaQuery.of(context).size.width / 2 - 50, // 位置を調整
                        MediaQuery.of(context).size.height / 2 - 50, // 位置を調整
                      ),
                    );
                    selectedTrajectories.add(newTrajectory);
                  });
                },
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size(60, 60), // モーダル内のプレビューサイズはそのまま
                      painter: PolylinePainter(
                        positions: trajectory,
                        minLat: trajectory
                            .map((p) => p.latitude)
                            .reduce((a, b) => a < b ? a : b),
                        maxLat: trajectory
                            .map((p) => p.latitude)
                            .reduce((a, b) => a > b ? a : b),
                        minLon: trajectory
                            .map((p) => p.longitude)
                            .reduce((a, b) => a < b ? a : b),
                        maxLon: trajectory
                            .map((p) => p.longitude)
                            .reduce((a, b) => a > b ? a : b),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: EdgeInsets.all(4),
                        color: Colors.white.withOpacity(0.8),
                        child:
                            Text(formattedDate, style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
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
          await _dbHelper.insertUsedTrajectory(index); // 使用済みとして登録
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
        )..rotation = item['rotation'] ?? 0.0;
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

    final double expandedTouchArea = trajectorySize * 2.0; // タッチ領域の拡大
    final double touchAreaOffset = (expandedTouchArea - trajectorySize) / 2;

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
                        left: item.position.dx - touchAreaOffset,
                        top: item.position.dy - touchAreaOffset,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() {
                              // タップした軌跡を選択状態にする
                              selectedItem = item;
                            });
                          },
                          onPanStart: (details) {
                            // 回転ハンドルでの回転中は移動操作を無効化
                            if (isDraggingRotationHandle) return;
                          },
                          onPanUpdate: (details) {
                            // 回転ハンドルでの回転中は移動操作を無効化
                            if (isDraggingRotationHandle) return;

                            // 選択された軌跡のみ移動操作を受け入れる
                            if (isSelected) {
                              setState(() {
                                item.position += details.delta;
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
                                  child: Stack(
                                    children: [
                                      Container(
                                        width: trajectorySize,
                                        height: trajectorySize,
                                        decoration: BoxDecoration(
                                          border: selectedItem == item
                                              ? Border.all(
                                                  color:
                                                      isDraggingRotationHandle
                                                          ? Colors.orange
                                                          : Colors.red,
                                                  width: 2.0,
                                                )
                                              : null,
                                        ),
                                        child: CustomPaint(
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
                                      ),
                                      // 回転ハンドル（選択されている時のみ表示、枠線と一緒に回転するが向きは固定）
                                      if (selectedItem == item)
                                        Positioned(
                                          right: 4, // 枠線の内側に配置（4pxのマージン）
                                          bottom: 4, // 枠線の内側に配置（4pxのマージン）
                                          child: Transform.rotate(
                                            angle: -item
                                                .rotation, // 軌跡の回転に対して逆回転させて向きを固定
                                            alignment: Alignment.center,
                                            child: GestureDetector(
                                              onPanStart: (details) {
                                                setState(() {
                                                  isDraggingRotationHandle =
                                                      true;
                                                  rotationDragStartPoint =
                                                      details.globalPosition;
                                                  item.lastRotation =
                                                      item.rotation;
                                                });
                                              },
                                              onPanUpdate: (details) {
                                                if (isDraggingRotationHandle &&
                                                    rotationDragStartPoint !=
                                                        null) {
                                                  // 軌跡の中心を計算
                                                  final center = Offset(
                                                    item.position.dx +
                                                        trajectorySize / 2,
                                                    item.position.dy +
                                                        trajectorySize / 2,
                                                  );

                                                  // 開始点から中心への角度
                                                  final startAngle = math.atan2(
                                                    rotationDragStartPoint!.dy -
                                                        center.dy,
                                                    rotationDragStartPoint!.dx -
                                                        center.dx,
                                                  );

                                                  // 現在点から中心への角度
                                                  final currentAngle =
                                                      math.atan2(
                                                    details.globalPosition.dy -
                                                        center.dy,
                                                    details.globalPosition.dx -
                                                        center.dx,
                                                  );

                                                  // 角度差を計算して回転を適用
                                                  final angleDelta =
                                                      currentAngle - startAngle;

                                                  setState(() {
                                                    item.rotation =
                                                        item.lastRotation +
                                                            angleDelta;
                                                  });
                                                }
                                              },
                                              onPanEnd: (details) {
                                                setState(() {
                                                  isDraggingRotationHandle =
                                                      false;
                                                  rotationDragStartPoint = null;
                                                  item.lastRotation =
                                                      item.rotation;
                                                });
                                              },
                                              child: Container(
                                                width: 36,
                                                height: 36,
                                                decoration: BoxDecoration(
                                                  color: Colors.blue,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                      color: Colors.white,
                                                      width: 2),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black26,
                                                      blurRadius: 4,
                                                      offset: Offset(0, 2),
                                                    ),
                                                  ],
                                                ),
                                                child: Icon(
                                                  Icons.rotate_right,
                                                  size: 16,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
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

  double minLat;
  double maxLat;
  double minLon;
  double maxLon;

  TransformablePolyline(this.polyline, this.position)
      : rotation = 0.0,
        lastRotation = 0.0,
        minLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        maxLat =
            polyline.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        minLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
        maxLon =
            polyline.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
}
