import 'package:flutter_test/flutter_test.dart';
import 'package:walk_tracker_app/artwork.dart';
import 'package:walk_tracker_app/legacy_data_cleanup.dart';

void main() {
  group('以前の軌跡（walking_data）', () {
    test('同じ ID の軌跡が trajectories にあるものだけを消す', () {
      expect(
        LegacyDataCleanup.walkingDataIdsToDelete(
          ['a', 'garmin_1', 'unreadable'],
          {'a', 'garmin_1', 'only-new'},
        ),
        ['a', 'garmin_1'],
      );
    });
  });

  group('作品の以前のフィールド', () {
    final converted = {
      'schemaVersion': Artwork.schemaVersion,
      'name': '函館の鳥',
      'strokes': [],
      'canvasWidth': 390.0,
      'canvasHeight': 707.0,
      'imageData': 'base64...',
      'trajectories': [],
      'meta': {},
      'timestamp': '2026-11-20T09:00:00.000',
      'artworkId': 'artwork_1',
    };

    test('新しい形式に変換済みの作品からは、以前のフィールドを消す', () {
      expect(
        LegacyDataCleanup.artworkFieldsToDelete(converted,
            hasImageDocument: true),
        ['imageData', 'trajectories', 'meta', 'timestamp', 'artworkId'],
      );
    });

    test('作品画像のドキュメントがなければ、画像（imageData）は残す', () {
      expect(
        LegacyDataCleanup.artworkFieldsToDelete(converted,
            hasImageDocument: false),
        ['trajectories', 'meta', 'timestamp', 'artworkId'],
      );
    });

    test('新しい形式になっていない作品からは何も消さない', () {
      final legacy = Map<String, dynamic>.from(converted)
        ..remove('schemaVersion');
      expect(
        LegacyDataCleanup.artworkFieldsToDelete(legacy, hasImageDocument: true),
        isEmpty,
      );
    });

    test('新しく保存した作品（以前のフィールドがない）からは何も消さない', () {
      expect(
        LegacyDataCleanup.artworkFieldsToDelete({
          'schemaVersion': Artwork.schemaVersion,
          'name': '新しい作品',
          'strokes': [],
          // 新しい形式でも使っているフィールドは消さない
          'canvasWidth': 390.0,
          'canvasHeight': 707.0,
        }, hasImageDocument: true),
        isEmpty,
      );
    });
  });

  group('下書きの以前のフィールド', () {
    test('strokes を持つ下書きからは、以前のフィールドを消す', () {
      expect(
        LegacyDataCleanup.draftFieldsToDelete({
          'strokes': [],
          'updatedAt': 'Timestamp',
          'trajectories': [],
          'timestamp': '2026-11-15T18:30:00.000',
          'guideImageOpacity': 0.5,
        }),
        ['trajectories', 'timestamp'],
      );
    });

    test('strokes を持たない（変換できていない）下書きからは何も消さない', () {
      expect(
        LegacyDataCleanup.draftFieldsToDelete({
          'trajectories': [],
          'timestamp': '2026-11-15T18:30:00.000',
        }),
        isEmpty,
      );
    });
  });
}
