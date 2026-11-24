import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:walk_tracker_app/draft_store.dart';

void main() {
  group('DraftStore.compressGuideImage', () {
    test('大きな写真を、長辺の上限以下・Firestore に収まる JPEG にする', () {
      // ノイズの多い画像は圧縮が効きにくいため、画質や大きさを下げる処理まで通る
      final random = math.Random(1);
      final source = img.Image(width: 3000, height: 2000);
      for (final pixel in source) {
        pixel
          ..r = random.nextInt(256)
          ..g = random.nextInt(256)
          ..b = random.nextInt(256);
      }
      final original = Uint8List.fromList(img.encodePng(source));

      final compressed = DraftStore.compressGuideImage(original);

      expect(compressed.length, lessThanOrEqualTo(DraftStore.maxGuideImageBytes));
      final decoded = img.decodeJpg(compressed)!;
      expect(math.max(decoded.width, decoded.height),
          lessThanOrEqualTo(DraftStore.maxGuideImageSide));
      // 縦横比は変えない（キャンバスでの下絵の位置が変わらないように）
      expect(decoded.width / decoded.height, closeTo(1.5, 0.01));
    });

    test('写真の向き（EXIF）を画素に反映する', () {
      final source = img.Image(width: 40, height: 20);
      source.exif.imageIfd.orientation = 6; // 時計回りに 90度回して表示する
      final original = Uint8List.fromList(img.encodeJpg(source));

      final decoded = img.decodeJpg(DraftStore.compressGuideImage(original))!;

      expect(decoded.width, 20);
      expect(decoded.height, 40);
    });

    test('読めない形式でも、上限に収まるならそのまま返す', () {
      final original = Uint8List.fromList(List.filled(1000, 7));
      expect(DraftStore.compressGuideImage(original), same(original));
    });
  });
}
