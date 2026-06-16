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
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'database_helper.dart';
import 'draft_list_screen.dart';
import 'polyline_painter.dart';
import 'firestore_service.dart';
import 'route_destination_selection_screen.dart';

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

  // 回転ハンドル用の状態変数
  double? _rotationStartAngle; // ドラッグ開始時の基準角度
  bool _isRotationHandleDragging = false; // 回転ハンドルドラッグ中フラグ

  // 軌跡のサイズ定義
  final double trajectorySize = 100.0;

  // スケールバー関連
  double _scaleBarDistanceMeters = 500.0; // スケールバーが表す距離（メートル）
  final double _scaleBarPixelLength = 80.0; // スケールバーの固定ピクセル長
  static const List<double> _scaleDistanceOptions = [
    50,
    100,
    200,
    300,
    500,
    1000,
    2000,
    3000,
    5000,
    10000
  ];

  // ガイド画像機能用の状態変数
  File? _guideImage;
  double _guideImageOpacity = 0.5;
  bool _showGuideImagePanel = false; // コントロールパネルの表示・非表示
  bool _showGuideImageControl = false; // 画面左上のコントロールボタン表示・非表示
  bool _guideImageVisible = true; // ガイド画像の表示・非表示
  Offset _guideImagePosition = Offset.zero; // ガイド画像の位置
  double _guideImageScale = 1.0; // ガイド画像のスケール
  double _guideImageLastScale = 1.0; // スケール操作用
  bool _guideImageLocked = false; // ガイド画像の位置・サイズ固定
  bool _showLayerPanel = false;

  // 軌跡リスト用のデータ（画面下部に常時表示）
  List<Map<String, dynamic>> _garminActivities = [];
  Set<String> _usedGarminGroupIds = {};
  Map<int, String> _localTrajectoryGroupIds = {};
  Set<String> _recentlyUsedGroupIds = {};
  bool _isTrajectoryListLoading = true;

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
      await _loadTrajectoryListData();
    } catch (e) {
      print("軌跡の読み込みエラー: $e");
    }
  }

  /// 軌跡リスト用のデータを読み込む（画面下部に常時表示用）
  Future<void> _loadTrajectoryListData() async {
    try {
      setState(() {
        _isTrajectoryListLoading = true;
      });

      // Garmin軌跡を読み込む
      final garminActivities = await _dbHelper.getGarminActivities();
      final usedGarminGroupIds =
          await _dbHelper.getUsedGarminActivityGroupIds();

      // ローカル軌跡のgroupIdマッピングを作成
      final allData = await _dbHelper.getAllWalkingData();
      Map<int, String> localTrajectoryGroupIds = {};
      int localIndex = 0;
      for (var data in allData) {
        if ((data['is_from_garmin'] ?? 0) == 0) {
          localTrajectoryGroupIds[localIndex] = data['group_id'] as String;
          localIndex++;
        }
      }

      // Firestoreから最新の使用済み軌跡を取得（作品サブコレクションから集計）
      final trajectories =
          await _firestoreService.getAllUsedTrajectoriesFromArtworks();
      final recentlyUsedGroupIds =
          trajectories.map((t) => t['groupId'] as String).toSet();

      print("📊 軌跡リスト用データ読み込み完了:");
      print("  - Garmin軌跡: ${garminActivities.length}件");
      print("  - 使用済みGarmin軌跡: ${usedGarminGroupIds.length}件");
      print("  - ローカル軌跡groupIdマッピング: ${localTrajectoryGroupIds.length}件");
      print("  - 使用済み軌跡: ${recentlyUsedGroupIds.length}件");

      setState(() {
        _garminActivities = garminActivities;
        _usedGarminGroupIds = usedGarminGroupIds.toSet();
        _localTrajectoryGroupIds = localTrajectoryGroupIds;
        _recentlyUsedGroupIds = recentlyUsedGroupIds;
        _isTrajectoryListLoading = false;
      });
    } catch (e) {
      print("❌ 軌跡リスト用データの読み込みエラー: $e");
      setState(() {
        _isTrajectoryListLoading = false;
      });
    }
  }

  /// ガイド画像を選択するメソッド
  Future<void> _pickGuideImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
      );

      if (image != null) {
        setState(() {
          _guideImage = File(image.path);
          _showGuideImagePanel = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ガイド画像を設定しました')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('画像の選択に失敗しました: $e')),
      );
    }
  }

  /// ガイド画像の表示・非表示を切り替えるメソッド
  void _toggleGuideImageVisibility() {
    setState(() {
      _guideImageVisible = !_guideImageVisible;
    });
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
      // 選択状態の軌跡があれば解除する（保存画像に選択枠が表示されないように）
      if (selectedItem != null) {
        setState(() {
          selectedItem = null;
        });
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // ガイド画像が表示されている場合は一時的に非表示にする
      final bool wasGuideImageVisible = _guideImageVisible;
      if (_guideImage != null && _guideImageVisible) {
        setState(() {
          _guideImageVisible = false;
        });
        // UIの更新を待つ
        await Future.delayed(const Duration(milliseconds: 100));
      }

      RenderRepaintBoundary boundary = _boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      var image = await boundary.toImage();
      ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      // ガイド画像の表示状態を復元
      if (_guideImage != null && wasGuideImageVisible) {
        setState(() {
          _guideImageVisible = true;
        });
      }

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
        // モーダルで選択時に保存されたgroupIdを使用（Garmin軌跡対応）
        final groupId = item.groupId ?? generateGroupId(item.polyline);
        var trajectoryDetails =
            await _dbHelper.getWalkingDataByGroupId(groupId);

        // Garmin軌跡の場合、ローカルDBにデータがないため、Garmin軌跡データを取得
        String actualGroupId = groupId;
        if (trajectoryDetails == null) {
          print('⚠️ ローカル軌跡が見つかりません: groupId="$groupId"。Garmin軌跡か確認中...');

          // 最初にgroupIdで直接Garmin軌跡を検索
          trajectoryDetails =
              await _dbHelper.getGarminActivityByGroupId(groupId);

          if (trajectoryDetails != null) {
            print('✅ Garmin軌跡が見つかりました: $groupId');
            actualGroupId = groupId;
          } else {
            print('  Firestore経由でGarmin軌跡の確認を試みます...');
            // Firestoreから直接取得を試みる
            final firestoreActivities =
                await _firestoreService.getAllWalkingData();
            for (final activity in firestoreActivities) {
              if (activity['groupId'] == groupId) {
                print('✅ FirestoreからGarmin軌跡が見つかりました: $groupId');
                trajectoryDetails = activity;
                actualGroupId = groupId;
                break;
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

      // 使用済みの軌跡を作品のサブコレクションに保存
      print(
          "📌 使用済みとしてマークする軌跡: ${temporarilyUsedGroupIds.length}件 - $temporarilyUsedGroupIds");

      // 作品ごとのサブコレクションに保存
      await _firestoreService.saveUsedTrajectoriesForArtwork(
        artworkId,
        temporarilyUsedGroupIds.toList(),
      );

      // ローカルDBにも保存（オフライン時の参照用）
      for (final groupId in temporarilyUsedGroupIds) {
        print('🔹 軌跡をマーク済みにしました: $groupId');
        await _dbHelper.markTrajectoryAsUsedLocally(groupId);
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
        'scaleBarDistance': _scaleBarDistanceMeters,
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
      // スケールバー距離を復元
      final savedScaleDistance = draftData['scaleBarDistance'];
      if (savedScaleDistance != null) {
        _scaleBarDistanceMeters = (savedScaleDistance as num).toDouble();
      }

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

  /// ルート提案画面へ遷移
  ///
  /// 既存のルート提案フロー（出発地・目的地選択 → キャンバス描画 → ルート生成）を使用
  Future<void> _navigateToRouteSuggestion() async {
    final routeResult = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteDestinationSelectionScreen(),
      ),
    );

    // 歩行終了後、新しい軌跡が記録されていれば再読み込み
    if (mounted) {
      await _loadRecordTrajectories();

      if (routeResult != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ルートが選択されました。'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // ─── スケールバー関連メソッド ───

  /// 軌跡の実世界における最大寸法（メートル）を計算
  double _computeTrajectoryExtentMeters(TransformablePolyline item) {
    final meanLat = (item.minLat + item.maxLat) / 2.0;
    final latExtent = (item.maxLat - item.minLat) * 111320.0;
    final lonExtent = (item.maxLon - item.minLon) *
        111320.0 *
        math.cos(meanLat * math.pi / 180.0);
    return math.max(latExtent, lonExtent);
  }

  /// スケールバー設定に基づいて軌跡のスケール値を計算
  double _computeScaleForTrajectory(TransformablePolyline item) {
    final extentMeters = _computeTrajectoryExtentMeters(item);
    if (extentMeters <= 0) return 1.0;
    // metersPerPixel = スケールバー距離 / スケールバーピクセル長
    // 軌跡の描画領域は trajectorySize * 0.8（PolylinePainterの10%パディング考慮）
    final metersPerPixel = _scaleBarDistanceMeters / _scaleBarPixelLength;
    return extentMeters / (metersPerPixel * trajectorySize * 0.8);
  }

  /// すべての軌跡のスケールをスケールバーに基づいて再計算
  void _updateAllTrajectoryScales() {
    for (final item in selectedTrajectories) {
      item.scale = _computeScaleForTrajectory(item);
    }
  }

  /// スケール距離値を表示用にフォーマット
  String _formatScaleDistance(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      return '${km % 1 == 0 ? km.toInt() : km.toStringAsFixed(1)}km';
    }
    return '${meters.toInt()}m';
  }

  /// スケールバーの距離を増やす（次のオプションに切り替え）
  void _increaseScaleDistance() {
    final currentIndex = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    if (currentIndex < _scaleDistanceOptions.length - 1) {
      setState(() {
        _scaleBarDistanceMeters = _scaleDistanceOptions[currentIndex + 1];
        _updateAllTrajectoryScales();
      });
    }
  }

  /// スケールバーの距離を減らす（前のオプションに切り替え）
  void _decreaseScaleDistance() {
    final currentIndex = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    if (currentIndex > 0) {
      setState(() {
        _scaleBarDistanceMeters = _scaleDistanceOptions[currentIndex - 1];
        _updateAllTrajectoryScales();
      });
    }
  }

  /// スケールバーウィジェットを構築
  Widget _buildScaleBar() {
    final currentIndex = _scaleDistanceOptions.indexOf(_scaleBarDistanceMeters);
    final canDecrease = currentIndex > 0;
    final canIncrease = currentIndex < _scaleDistanceOptions.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // スケールバー本体 + 操作ボタン
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // マイナスボタン
              GestureDetector(
                onTap: canDecrease ? _decreaseScaleDistance : null,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.remove,
                    size: 20,
                    color: canDecrease ? Colors.black54 : Colors.grey[400],
                  ),
                ),
              ),
              // スケールバーグラフィック（U字型）
              Container(
                width: _scaleBarPixelLength,
                height: 8,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(width: 1.5, color: Colors.black54),
                    right: BorderSide(width: 1.5, color: Colors.black54),
                    bottom: BorderSide(width: 1.5, color: Colors.black54),
                  ),
                ),
              ),
              // プラスボタン
              GestureDetector(
                onTap: canIncrease ? _increaseScaleDistance : null,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.add,
                    size: 20,
                    color: canIncrease ? Colors.black54 : Colors.grey[400],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          // 距離ラベル（バーの中央に配置）
          SizedBox(
            width: _scaleBarPixelLength + 64, // ボタン幅も考慮
            child: Center(
              child: Text(
                _formatScaleDistance(_scaleBarDistanceMeters),
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.black54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// レイヤーパネルを構築（右側オーバーレイ）
  Widget _buildLayerPanel() {
    return Container(
      width: 80,
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 6,
            offset: const Offset(-2, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'レイヤー',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Flexible(
            child: selectedTrajectories.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(6),
                    child: Text(
                      '軌跡なし',
                      style: TextStyle(fontSize: 9, color: Colors.grey),
                    ),
                  )
                : ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const ClampingScrollPhysics(),
                    buildDefaultDragHandles: false,
                    padding: EdgeInsets.zero,
                    itemCount: selectedTrajectories.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        final displayList =
                            selectedTrajectories.reversed.toList();
                        if (oldIndex < newIndex) newIndex--;
                        final item = displayList.removeAt(oldIndex);
                        displayList.insert(newIndex, item);
                        selectedTrajectories = displayList.reversed.toList();
                      });
                    },
                    itemBuilder: (context, panelIndex) {
                      final arrayIndex =
                          selectedTrajectories.length - 1 - panelIndex;
                      final traj = selectedTrajectories[arrayIndex];
                      final isSelected = selectedItem == traj;
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(traj),
                        index: panelIndex,
                        child: _buildLayerItem(traj, isSelected),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// レイヤーパネルの1アイテムを構築
  Widget _buildLayerItem(TransformablePolyline traj, bool isSelected) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          selectedItem = traj;
          selectedTrajectories.remove(traj);
          selectedTrajectories.add(traj);
        });
      },
      child: Container(
        color: isSelected ? Colors.red.withOpacity(0.08) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isSelected ? Colors.red : Colors.grey[300]!,
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Transform.rotate(
            angle: traj.rotation,
            child: CustomPaint(
              size: const Size(72, 54),
              painter: PolylinePainter(
                positions: traj.polyline,
                minLat: traj.minLat,
                maxLat: traj.maxLat,
                minLon: traj.minLon,
                maxLon: traj.maxLon,
                color: isSelected ? Colors.red : Colors.blue,
                strokeWidth: 2.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;

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
              } else if (value == 'guide_image') {
                setState(() {
                  _showGuideImageControl = !_showGuideImageControl;
                  if (_showGuideImageControl) {
                    _showGuideImagePanel = true;
                  }
                });
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
              PopupMenuItem(
                value: 'guide_image',
                child: Row(
                  children: [
                    Icon(
                      _showGuideImageControl
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 20,
                      color: _showGuideImageControl ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    const Text('ガイド画像設定'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
            bottom: 130 + MediaQuery.of(context).padding.bottom),
        child: FloatingActionButton.small(
          heroTag: 'route_suggestion',
          onPressed: () => _navigateToRouteSuggestion(),
          backgroundColor: Colors.orange,
          child: const Icon(Icons.route, size: 20),
          tooltip: 'ルート提案',
        ),
      ),
      body: Column(
        children: [
          // \u4e0a\u90e8: \u30ad\u30e3\u30f3\u30d0\u30b9\u90e8\u5206
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: screenWidth,
                  color: Colors.grey[200],
                  child: DragTarget<Map<String, dynamic>>(
                    onAcceptWithDetails: (details) {
                      // ドロップされた軌跡データを受け取る
                      final trajectoryData = details.data;
                      final positions =
                          trajectoryData['positions'] as List<Position>;
                      final isGarmin = trajectoryData['isGarmin'] as bool;
                      final groupId = trajectoryData['groupId'] as String?;

                      // ドロップ位置を計算（キャンバス上の位置）
                      final RenderBox? renderBox = _boundaryKey.currentContext
                          ?.findRenderObject() as RenderBox?;
                      if (renderBox != null) {
                        final localPosition =
                            renderBox.globalToLocal(details.offset);

                        setState(() {
                          final trajectoryIndex =
                              recordedTrajectories.indexOf(positions);

                          if (isGarmin) {
                            // Garmin軌跡の場合、groupIdを一時的に記録
                            if (groupId != null) {
                              temporarilyUsedIndices
                                  .add(groupId.hashCode); // legacy
                              temporarilyUsedGroupIds.add(groupId); // 新方式
                              print("📌 Garmin軌跡を一時使用中に追加: $groupId");
                            }
                          } else {
                            // ローカル軌跡の場合、インデックスとgroupIdをマーク
                            if (trajectoryIndex != -1) {
                              temporarilyUsedIndices
                                  .add(trajectoryIndex); // legacy
                              if (groupId != null) {
                                temporarilyUsedGroupIds.add(groupId);
                                print("📌 ローカル軌跡を一時使用中に追加: $groupId");
                              }
                            }
                          }

                          final newTrajectory = TransformablePolyline(
                            positions,
                            localPosition, // ドロップ位置に配置
                            groupId: groupId,
                          );
                          newTrajectory.scale =
                              _computeScaleForTrajectory(newTrajectory);
                          selectedTrajectories.add(newTrajectory);
                          selectedItem = newTrajectory;
                        });
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      return GestureDetector(
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
                              // ガイド画像レイヤー（移動・拡大縮小可能、固定可能、表示・非表示切り替え可能）
                              if (_guideImage != null && _guideImageVisible)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: _guideImageLocked
                                        ? HitTestBehavior.translucent
                                        : HitTestBehavior.translucent,
                                    onScaleStart: _guideImageLocked
                                        ? null
                                        : (details) {
                                            _guideImageLastScale =
                                                _guideImageScale;
                                          },
                                    onScaleUpdate: _guideImageLocked
                                        ? null
                                        : (details) {
                                            setState(() {
                                              // 移動処理
                                              _guideImagePosition +=
                                                  details.focalPointDelta;
                                              // スケール処理（ピンチ操作）
                                              if ((details.scale - 1.0).abs() >
                                                  0.01) {
                                                final newScale =
                                                    _guideImageLastScale *
                                                        details.scale;
                                                _guideImageScale =
                                                    newScale.clamp(0.2, 3.0);
                                              }
                                            });
                                          },
                                    child: ClipRect(
                                      child: Transform.translate(
                                        offset: _guideImagePosition,
                                        child: Transform.scale(
                                          scale: _guideImageScale,
                                          child: Opacity(
                                            opacity: _guideImageOpacity,
                                            child: Image.file(
                                              _guideImage!,
                                              width: MediaQuery.of(context)
                                                  .size
                                                  .width,
                                              fit: BoxFit.fitWidth,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ...selectedTrajectories.map((item) {
                                final isSelected = selectedItem == item;

                                return Positioned(
                                  left:
                                      item.position.dx - expandedTouchArea / 2,
                                  top: item.position.dy - expandedTouchArea / 2,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      setState(() {
                                        selectedItem = item;
                                        selectedTrajectories.remove(item);
                                        selectedTrajectories.add(item);
                                      });
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
                                      // 選択された軌跡のみ更新する（移動のみ）
                                      if (isSelected) {
                                        final bool hasPositionChange =
                                            details.focalPointDelta.distance >
                                                0.5;

                                        if (hasPositionChange) {
                                          setState(() {
                                            // 移動処理のみ
                                            item.position +=
                                                details.focalPointDelta;
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
                                      clipBehavior: Clip.none,
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
                                                      size: Size(trajectorySize,
                                                          trajectorySize),
                                                      painter: PolylinePainter(
                                                        positions:
                                                            item.polyline,
                                                        minLat: item.minLat,
                                                        maxLat: item.maxLat,
                                                        minLon: item.minLon,
                                                        maxLon: item.maxLon,
                                                        strokeWidth:
                                                            4.0 / item.scale,
                                                        color: isSelected
                                                            ? Colors.red
                                                            : Colors.blue,
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
                                        // 回転ハンドル（選択時のみ表示）
                                        if (isSelected)
                                          Builder(
                                            builder: (context) {
                                              // 赤枠の右上角の位置を計算
                                              // 中心からの距離（対角線の半分）
                                              final double radius =
                                                  trajectorySize /
                                                      2 *
                                                      math.sqrt(2);
                                              // 右上は-45度（-π/4）、回転角度を加算
                                              final double handleAngle =
                                                  -math.pi / 4 + item.rotation;
                                              // 中心位置
                                              final double centerX =
                                                  expandedTouchArea / 2;
                                              final double centerY =
                                                  expandedTouchArea / 2;
                                              // ハンドル位置（アイコンサイズを考慮してオフセット）
                                              final double handleSize = 28.0;
                                              final double handleX = centerX +
                                                  radius *
                                                      math.cos(handleAngle) -
                                                  handleSize / 2;
                                              final double handleY = centerY +
                                                  radius *
                                                      math.sin(handleAngle) -
                                                  handleSize / 2;

                                              return Positioned(
                                                left: handleX,
                                                top: handleY,
                                                child: GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onPanStart: (details) {
                                                    // ドラッグ開始時の角度を記録
                                                    final Offset center =
                                                        Offset(
                                                            centerX, centerY);
                                                    final Offset touchOffset =
                                                        Offset(
                                                      handleX +
                                                          handleSize / 2 +
                                                          details.localPosition
                                                              .dx -
                                                          handleSize / 2,
                                                      handleY +
                                                          handleSize / 2 +
                                                          details.localPosition
                                                              .dy -
                                                          handleSize / 2,
                                                    );
                                                    _rotationStartAngle =
                                                        math.atan2(
                                                      touchOffset.dy -
                                                          center.dy,
                                                      touchOffset.dx -
                                                          center.dx,
                                                    );
                                                    item.lastRotation =
                                                        item.rotation;
                                                    setState(() {
                                                      _isRotationHandleDragging =
                                                          true;
                                                      isRotating = true;
                                                    });
                                                  },
                                                  onPanUpdate: (details) {
                                                    if (_isRotationHandleDragging &&
                                                        _rotationStartAngle !=
                                                            null) {
                                                      // グローバル座標で計算
                                                      final RenderBox?
                                                          renderBox =
                                                          context.findRenderObject()
                                                              as RenderBox?;
                                                      if (renderBox != null) {
                                                        // 軌跡の中心をグローバル座標で取得
                                                        final Offset
                                                            itemGlobalCenter =
                                                            Offset(
                                                          item.position.dx,
                                                          item.position.dy,
                                                        );
                                                        // 現在のタッチ位置のグローバル座標
                                                        final Offset
                                                            touchGlobal =
                                                            details
                                                                .globalPosition;
                                                        // キャンバスのオフセットを考慮（Positioned内での相対位置調整）
                                                        final RenderBox?
                                                            stackBox =
                                                            _boundaryKey
                                                                    .currentContext
                                                                    ?.findRenderObject()
                                                                as RenderBox?;
                                                        if (stackBox != null) {
                                                          final Offset
                                                              stackGlobal =
                                                              stackBox
                                                                  .localToGlobal(
                                                                      Offset
                                                                          .zero);
                                                          final Offset
                                                              adjustedTouch =
                                                              touchGlobal -
                                                                  stackGlobal;
                                                          final Offset
                                                              adjustedCenter =
                                                              itemGlobalCenter;

                                                          // 現在の角度を計算
                                                          final double
                                                              currentAngle =
                                                              math.atan2(
                                                            adjustedTouch.dy -
                                                                adjustedCenter
                                                                    .dy,
                                                            adjustedTouch.dx -
                                                                adjustedCenter
                                                                    .dx,
                                                          );
                                                          // 角度の差分を計算
                                                          final double
                                                              deltaAngle =
                                                              currentAngle -
                                                                  _rotationStartAngle!;
                                                          setState(() {
                                                            item.rotation =
                                                                item.lastRotation +
                                                                    deltaAngle;
                                                          });
                                                        }
                                                      }
                                                    }
                                                  },
                                                  onPanEnd: (details) {
                                                    setState(() {
                                                      _isRotationHandleDragging =
                                                          false;
                                                      isRotating = false;
                                                      _rotationStartAngle =
                                                          null;
                                                      item.lastRotation =
                                                          item.rotation;
                                                    });
                                                  },
                                                  child: Container(
                                                    width: handleSize,
                                                    height: handleSize,
                                                    decoration: BoxDecoration(
                                                      color: Colors.white,
                                                      shape: BoxShape.circle,
                                                      border: Border.all(
                                                        color: isRotating
                                                            ? Colors.orange
                                                            : Colors.red,
                                                        width: 2.0,
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: Colors.black
                                                              .withOpacity(0.3),
                                                          blurRadius: 4,
                                                          offset: const Offset(
                                                              0, 2),
                                                        ),
                                                      ],
                                                    ),
                                                    child: Icon(
                                                      Icons.rotate_right,
                                                      size: 18,
                                                      color: isRotating
                                                          ? Colors.orange
                                                          : Colors.red,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ],
                          ),
                        ),
                      );
                    },
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
                // スケールバー（常時表示、画面左上）
                Positioned(
                  top: 8,
                  left: 8,
                  child: _buildScaleBar(),
                ),
                // ガイド画像コントロールUI（スケールバーの下）- メニューから有効化された場合のみ表示
                if (_showGuideImageControl)
                  Positioned(
                    top: 60,
                    left: 8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // トグルボタン
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: Icon(
                              _showGuideImagePanel
                                  ? Icons.expand_less
                                  : Icons.add_photo_alternate,
                              color: _guideImage != null
                                  ? Colors.blue
                                  : Colors.grey[700],
                            ),
                            tooltip:
                                _showGuideImagePanel ? 'パネルを閉じる' : 'ガイド画像設定',
                            onPressed: () {
                              setState(() {
                                _showGuideImagePanel = !_showGuideImagePanel;
                              });
                            },
                          ),
                        ),
                        // コントロールパネル（トグルで表示・非表示）
                        if (_showGuideImagePanel)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ガイド画像選択ボタン
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton.icon(
                                      icon: Icon(
                                        _guideImage != null
                                            ? Icons.image
                                            : Icons.add_photo_alternate,
                                        size: 20,
                                      ),
                                      label: Text(
                                          _guideImage != null ? '変更' : '画像を選択'),
                                      onPressed: _pickGuideImage,
                                    ),
                                    // 表示・非表示切り替えボタン（画像が設定されている場合のみ）
                                    if (_guideImage != null)
                                      IconButton(
                                        icon: Icon(
                                          _guideImageVisible
                                              ? Icons.visibility
                                              : Icons.visibility_off,
                                          size: 20,
                                          color: _guideImageVisible
                                              ? Colors.blue
                                              : Colors.grey,
                                        ),
                                        tooltip: _guideImageVisible
                                            ? '非表示にする'
                                            : '表示する',
                                        onPressed: _toggleGuideImageVisibility,
                                      ),
                                  ],
                                ),
                                // 不透明度スライダー（ガイド画像が設定されている場合のみ表示）
                                if (_guideImage != null) ...[
                                  const SizedBox(height: 8),
                                  const Text(
                                    '不透明度',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey),
                                  ),
                                  SizedBox(
                                    width: 150,
                                    child: Slider(
                                      value: _guideImageOpacity,
                                      min: 0.1,
                                      max: 1.0,
                                      divisions: 9,
                                      label:
                                          '${(_guideImageOpacity * 100).toInt()}%',
                                      onChanged: (value) {
                                        setState(() {
                                          _guideImageOpacity = value;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  // 位置・サイズ固定トグルボタン
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _guideImageLocked
                                            ? Icons.lock
                                            : Icons.lock_open,
                                        size: 18,
                                        color: _guideImageLocked
                                            ? Colors.orange
                                            : Colors.grey,
                                      ),
                                      const SizedBox(width: 4),
                                      const Text('位置・サイズ固定'),
                                      Switch(
                                        value: _guideImageLocked,
                                        onChanged: (value) {
                                          setState(() {
                                            _guideImageLocked = value;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                // \u30ec\u30a4\u30e4\u30fc\u30d1\u30cd\u30eb\u30c8\u30b0\u30eb\u30dc\u30bf\u30f3\uff08\u53f3\u4e0a\uff09
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _showLayerPanel = !_showLayerPanel;
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.layers,
                        size: 22,
                        color: _showLayerPanel
                            ? Colors.blue
                            : Colors.grey[700],
                      ),
                    ),
                  ),
                ),
                // \u30ec\u30a4\u30e4\u30fc\u30d1\u30cd\u30eb\uff08\u53f3\u5074\u30aa\u30fc\u30d0\u30fc\u30ec\u30a4\uff09
                if (_showLayerPanel)
                  Positioned(
                    top: 48,
                    right: 8,
                    child: _buildLayerPanel(),
                  ),
              ],
            ),
          ),
          // \u4e0b\u90e8: \u8ecc\u8de1\u30ea\u30b9\u30c8
          _buildTrajectoryList(),
        ],
      ),
    );
  }

  /// \u753b\u9762\u4e0b\u90e8\u306b\u8868\u793a\u3059\u308b\u8ecc\u8de1\u30ea\u30b9\u30c8\u3092\u69cb\u7bc9
  Widget _buildTrajectoryList() {
    if (_isTrajectoryListLoading) {
      return Container(
        height: 120,
        color: Colors.white,
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    // \u30ed\u30fc\u30ab\u30eb\u8ecc\u8de1\u3068Garmin\u8ecc\u8de1\u3092\u7d71\u5408
    final List<Map<String, dynamic>> allTrajectories = [];

    // \u30ed\u30fc\u30ab\u30eb\u8ecc\u8de1\u3092\u8ffd\u52a0
    for (int i = 0; i < recordedTrajectories.length; i++) {
      final trajectory = recordedTrajectories[i];
      final groupId = _localTrajectoryGroupIds[i];

      // \u4f7f\u7528\u6e08\u307f\u307e\u305f\u306f\u4e00\u6642\u4f7f\u7528\u4e2d\u306e\u8ecc\u8de1\u306f\u9664\u5916
      if (groupId != null) {
        if (_recentlyUsedGroupIds.contains(groupId) ||
            temporarilyUsedGroupIds.contains(groupId)) {
          continue;
        }
      }

      allTrajectories.add({
        'positions': trajectory,
        'isGarmin': false,
        'date': DateFormat('yyyy/MM/dd').format(trajectory.first.timestamp),
        'groupId': groupId,
      });
    }

    // Garmin\u8ecc\u8de1\u3092\u8ffd\u52a0
    for (final activity in _garminActivities) {
      final groupId = activity['group_id'] as String;

      // \u4f7f\u7528\u6e08\u307f\u307e\u305f\u306f\u4e00\u6642\u4f7f\u7528\u4e2d\u306e\u8ecc\u8de1\u306f\u9664\u5916
      if (_usedGarminGroupIds.contains(groupId) ||
          temporarilyUsedGroupIds.contains(groupId)) {
        continue;
      }

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

      allTrajectories.add({
        'positions': positions,
        'isGarmin': true,
        'date': activity['date'] as String,
        'groupId': groupId,
      });
    }

    // \u65e5\u4ed8\u9806\u306b\u30bd\u30fc\u30c8\uff08\u65b0\u3057\u3044\u9806\uff09
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

    if (allTrajectories.isEmpty) {
      return Container(
        height: 120,
        color: Colors.white,
        child: const Center(
          child: Text(
              '\u5229\u7528\u53ef\u80fd\u306a\u8ecc\u8de1\u304c\u3042\u308a\u307e\u305b\u3093'),
        ),
      );
    }

    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Container(
      height: 120 + bottomPadding,
      padding: EdgeInsets.only(bottom: bottomPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 8, bottom: 4),
            child: Text(
              '\u8ecc\u8de1\u3092\u30c9\u30e9\u30c3\u30b0\u3057\u3066\u30ad\u30e3\u30f3\u30d0\u30b9\u306b\u914d\u7f6e',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: allTrajectories.length,
              itemBuilder: (context, index) {
                final trajectory = allTrajectories[index];
                final List<Position> positions = trajectory['positions'];
                final bool isGarmin = trajectory['isGarmin'];
                final String date = trajectory['date'];
                final String? groupId = trajectory['groupId'];

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: LongPressDraggable<Map<String, dynamic>>(
                    data: {
                      'positions': positions,
                      'isGarmin': isGarmin,
                      'groupId': groupId,
                    },
                    feedback: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.blue, width: 2),
                        ),
                        child: CustomPaint(
                          size: const Size(80, 80),
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
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.5,
                      child: _buildTrajectoryTile(positions, date, isGarmin),
                    ),
                    child: GestureDetector(
                      onTap: () {
                        // \u30bf\u30c3\u30d7\u3067\u5730\u56f3\u60c5\u5831\u3092\u8868\u793a
                        _showTrajectoryMapDialog(
                            context, positions, date, isGarmin, groupId);
                      },
                      child: _buildTrajectoryTile(positions, date, isGarmin),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// \u8ecc\u8de1\u30bf\u30a4\u30eb\u3092\u69cb\u7bc9
  Widget _buildTrajectoryTile(
      List<Position> positions, String date, bool isGarmin) {
    return Container(
      width: 70,
      height: 85,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              size: const Size(60, 55),
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
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              date.substring(5), // MM/dd \u306e\u307f\u8868\u793a
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  /// \u8ecc\u8de1\u306e\u5730\u56f3\u60c5\u5831\u3092\u30dd\u30c3\u30d7\u30a2\u30c3\u30d7\u3067\u8868\u793a\u3059\u308b\u30c0\u30a4\u30a2\u30ed\u30b0
  void _showTrajectoryMapDialog(
    BuildContext context,
    List<Position> positions,
    String date,
    bool isGarmin,
    String? groupId,
  ) {
    if (positions.isEmpty) return;

    // \u8ecc\u8de1\u306e\u5883\u754c\u3092\u8a08\u7b97
    final double minLat =
        positions.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    final double maxLat =
        positions.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    final double minLng =
        positions.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    final double maxLng =
        positions.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    // \u4e2d\u5fc3\u5ea7\u6a19\u3092\u8a08\u7b97
    final double centerLat = (minLat + maxLat) / 2;
    final double centerLng = (minLng + maxLng) / 2;

    // \u9069\u5207\u306a\u30ba\u30fc\u30e0\u30ec\u30d9\u30eb\u3092\u8a08\u7b97
    final double latDelta = maxLat - minLat;
    final double lngDelta = maxLng - minLng;
    final double maxDelta = math.max(latDelta, lngDelta);

    // \u30ba\u30fc\u30e0\u30ec\u30d9\u30eb\u306e\u8a08\u7b97\uff08\u5927\u307e\u304b\u306a\u76ee\u5b89\uff09
    double zoomLevel = 15.0;
    if (maxDelta > 0.1) {
      zoomLevel = 10.0;
    } else if (maxDelta > 0.05) {
      zoomLevel = 12.0;
    } else if (maxDelta > 0.01) {
      zoomLevel = 14.0;
    } else if (maxDelta > 0.005) {
      zoomLevel = 15.0;
    } else {
      zoomLevel = 16.0;
    }

    // \u30dd\u30ea\u30e9\u30a4\u30f3\u3092\u4f5c\u6210
    final polyline = gmaps.Polyline(
      polylineId: const gmaps.PolylineId('trajectory'),
      points:
          positions.map((p) => gmaps.LatLng(p.latitude, p.longitude)).toList(),
      color: Colors.blue,
      width: 4,
    );

    // \u7dcf\u8ddd\u96e2\u3092\u8a08\u7b97
    double totalDistance = 0.0;
    for (int i = 0; i < positions.length - 1; i++) {
      totalDistance += Geolocator.distanceBetween(
        positions[i].latitude,
        positions[i].longitude,
        positions[i + 1].latitude,
        positions[i + 1].longitude,
      );
    }

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.5,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // \u5730\u56f3
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: gmaps.GoogleMap(
                    initialCameraPosition: gmaps.CameraPosition(
                      target: gmaps.LatLng(centerLat, centerLng),
                      zoom: zoomLevel,
                    ),
                    polylines: {polyline},
                    myLocationEnabled: false,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    compassEnabled: false,
                    rotateGesturesEnabled: false,
                    scrollGesturesEnabled: false,
                    zoomGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    mapType: gmaps.MapType.normal,
                    onMapCreated: (controller) {
                      // \u5730\u56f3\u304c\u4f5c\u6210\u3055\u308c\u305f\u3089\u30dd\u30ea\u30e9\u30a4\u30f3\u304c\u898b\u3048\u308b\u3088\u3046\u306b\u30ab\u30e1\u30e9\u3092\u8abf\u6574
                      Future.delayed(const Duration(milliseconds: 300), () {
                        if (positions.length >= 2) {
                          controller.moveCamera(
                            gmaps.CameraUpdate.newLatLngBounds(
                              gmaps.LatLngBounds(
                                southwest: gmaps.LatLng(
                                    minLat - 0.001, minLng - 0.001),
                                northeast: gmaps.LatLng(
                                    maxLat + 0.001, maxLng + 0.001),
                              ),
                              50, // padding
                            ),
                          );
                        }
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // \u60c5\u5831\u8868\u793a
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // \u7dcf\u8ddd\u96e2
                  Row(
                    children: [
                      Icon(Icons.straighten, size: 16, color: Colors.grey[700]),
                      const SizedBox(width: 4),
                      Text(
                        totalDistance >= 1000
                            ? '${(totalDistance / 1000).toStringAsFixed(2)} km'
                            : '${totalDistance.toStringAsFixed(0)} m',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  // \u8a18\u9332\u65e5\u6642
                  Row(
                    children: [
                      Icon(Icons.calendar_today,
                          size: 16, color: Colors.grey[700]),
                      const SizedBox(width: 4),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // \u9589\u3058\u308b\u30dc\u30bf\u30f3
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('\u9589\u3058\u308b'),
                ),
              ),
            ],
          ),
        ),
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
          await firestoreService.getAllUsedTrajectoriesFromArtworks();
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

        // 軌跡をドラッグ可能にする
        final trajectoryWidget = Stack(
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
        );

        return LongPressDraggable<Map<String, dynamic>>(
          data: {
            'positions': positions,
            'isGarmin': isGarmin,
            'groupId': groupId,
          },
          feedback: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue, width: 2),
              ),
              child: CustomPaint(
                size: Size(80, 80),
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
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.5,
            child: trajectoryWidget,
          ),
          child: GestureDetector(
            onTap: () {
              // タップで地図情報を表示
              _showTrajectoryMapDialog(
                  context, positions, date, isGarmin, groupId);
            },
            child: trajectoryWidget,
          ),
        );
      },
    );
  }

  /// 軌跡の地図情報をポップアップで表示するダイアログ
  void _showTrajectoryMapDialog(
    BuildContext context,
    List<Position> positions,
    String date,
    bool isGarmin,
    String? groupId,
  ) {
    if (positions.isEmpty) return;

    // 軌跡の境界を計算
    final double minLat =
        positions.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    final double maxLat =
        positions.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    final double minLng =
        positions.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    final double maxLng =
        positions.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    // 中心座標を計算
    final double centerLat = (minLat + maxLat) / 2;
    final double centerLng = (minLng + maxLng) / 2;

    // 適切なズームレベルを計算
    final double latDelta = maxLat - minLat;
    final double lngDelta = maxLng - minLng;
    final double maxDelta = math.max(latDelta, lngDelta);

    // ズームレベルの計算（大まかな目安）
    double zoomLevel = 15.0;
    if (maxDelta > 0.1) {
      zoomLevel = 10.0;
    } else if (maxDelta > 0.05) {
      zoomLevel = 12.0;
    } else if (maxDelta > 0.01) {
      zoomLevel = 14.0;
    } else if (maxDelta > 0.005) {
      zoomLevel = 15.0;
    } else {
      zoomLevel = 16.0;
    }

    // ポリラインを作成
    final polyline = gmaps.Polyline(
      polylineId: const gmaps.PolylineId('trajectory'),
      points:
          positions.map((p) => gmaps.LatLng(p.latitude, p.longitude)).toList(),
      color: Colors.blue,
      width: 4,
    );

    // 総距離を計算
    double totalDistance = 0.0;
    for (int i = 0; i < positions.length - 1; i++) {
      totalDistance += Geolocator.distanceBetween(
        positions[i].latitude,
        positions[i].longitude,
        positions[i + 1].latitude,
        positions[i + 1].longitude,
      );
    }

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.5,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 地図
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: gmaps.GoogleMap(
                    initialCameraPosition: gmaps.CameraPosition(
                      target: gmaps.LatLng(centerLat, centerLng),
                      zoom: zoomLevel,
                    ),
                    polylines: {polyline},
                    myLocationEnabled: false,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    compassEnabled: false,
                    rotateGesturesEnabled: false,
                    scrollGesturesEnabled: false,
                    zoomGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    mapType: gmaps.MapType.normal,
                    onMapCreated: (controller) {
                      // 地図が作成されたらポリラインが見えるようにカメラを調整
                      Future.delayed(const Duration(milliseconds: 300), () {
                        if (positions.length >= 2) {
                          controller.moveCamera(
                            gmaps.CameraUpdate.newLatLngBounds(
                              gmaps.LatLngBounds(
                                southwest: gmaps.LatLng(
                                    minLat - 0.001, minLng - 0.001),
                                northeast: gmaps.LatLng(
                                    maxLat + 0.001, maxLng + 0.001),
                              ),
                              50, // padding
                            ),
                          );
                        }
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 情報表示
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 総距離
                  Row(
                    children: [
                      Icon(Icons.straighten, size: 16, color: Colors.grey[700]),
                      const SizedBox(width: 4),
                      Text(
                        totalDistance >= 1000
                            ? '${(totalDistance / 1000).toStringAsFixed(2)} km'
                            : '${totalDistance.toStringAsFixed(0)} m',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  // 記録日時
                  Row(
                    children: [
                      Icon(Icons.calendar_today,
                          size: 16, color: Colors.grey[700]),
                      const SizedBox(width: 4),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // \u9589\u3058\u308b\u30dc\u30bf\u30f3
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('\u9589\u3058\u308b'),
                ),
              ),
            ],
          ),
        ),
      ),
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
