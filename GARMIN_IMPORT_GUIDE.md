# Garmin アクティビティインポート機能の実装ガイド

## 概要

このガイドでは、Garmin Connect からダウンロードした GPX ファイルをアプリケーションにインポートし、作品の一部として利用する機能について説明します。

## ファイル構成

### 1. **gpx_parser.dart** - GPX ファイルパーサー
- `GpxParser` クラス: GPX ファイルを解析して軌跡情報を抽出
- `GarminActivityData` クラス: Garmin アクティビティデータを表現

**主な機能:**
- XML フォーマットの GPX ファイルを解析
- 位置情報（緯度・経度・時刻）を抽出
- 距離を自動計算
- タイムスタンプベースのグループID生成

### 2. **garmin_import_screen.dart** - Garmin インポート画面
ユーザーが GPX ファイルを選択してインポートできるUI

**主な機能:**
- `FilePicker` を使用したファイル選択
- インポート前にプレビュー表示
- 複数ファイルの一括インポート対応
- インポート履歴の表示

### 3. **database_helper.dart の拡張**
新しいメソッドを追加:
- `getGarminActivities()`: Garmin データソースのデータを取得
- `getActivitiesBySource()`: 特定のデータソースを持つデータを取得

### 4. **walking_tracker_screen.dart の修正**
- BottomNavigationBar に「Garmin」タブを追加
- `_navigateToGarminImportScreen()` メソッドの実装

### 5. **artwork_creation_screen.dart の修正**
- `_TrajectoryModalContent` ウィジェットの追加
- TabBar で「記録した軌跡」と「Garmin アクティビティ」を分離表示
- Garmin データを軌跡として選択可能に

## 使用方法

### ユーザー向け

1. **ファイルのダウンロード**
   - Garmin Connect サイトからアクティビティをダウンロード
   - GPX 形式で保存してスマホ内に保存

2. **アプリへのインポート**
   - アプリを開く
   - BottomNavigationBar の「Garmin」タブをタップ
   - 「GPX ファイルを選択」ボタンをタップ
   - ダウンロードしたGPXファイルを選択
   - ファイル内容をプレビュー
   - 「保存」ボタンで完了

3. **作品制作時の利用**
   - 「作品の制作」タブに遷移
   - FloatingActionButton をタップして軌跡を選択
   - モーダルで「Garmin」タブをクリック
   - インポートしたアクティビティを選択
   - 他の軌跡と同じように編集・回転・スケール変更が可能

## データ構造

### GPX ファイル フォーマット

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1">
  <metadata>
    <name>アクティビティ名</name>
    <time>2025-10-28T10:30:00Z</time>
  </metadata>
  <trk>
    <trkseg>
      <trkpt lat="35.6812" lon="139.7671">
        <ele>50</ele>
        <time>2025-10-28T10:30:00Z</time>
      </trkpt>
      ...
    </trkseg>
  </trk>
</gpx>
```

### データベース保存形式

Garmin データは通常のウォーキングデータと同じテーブルに保存されます:
- `group_id`: `garmin_<タイムスタンプ>` の形式で自動生成
- `date`: インポート時の日時
- `distance`: キロメートル単位で計算
- `steps`: ポイント数を歩数として記録
- `positions`: JSON形式の位置情報

## パッケージ依存関係

以下のパッケージが必要です:

```yaml
dependencies:
  file_picker: ^8.1.2  # ファイル選択ダイアログ
  xml: ^6.5.0           # XML解析
  intl: ^0.20.1        # 日付フォーマット
```

## トラブルシューティング

### GPX ファイルが読み込めない場合
- GPX ファイルが正しい XML 形式であるか確認
- ファイルに `<trkseg>` と `<trkpt>` 要素が含まれているか確認

### 距離が計算されていない場合
- 位置情報（`lat` 属性と `lon` 属性）が正しく記載されているか確認
- `Geolocator.distanceBetween()` で計算可能な座標範囲か確認

### データベースに保存されない場合
- ファイルシステムの権限を確認
- データベースの初期化が正常に完了しているか確認

## 拡張可能性

将来的に以下の機能を追加可能:
- 複数の Garmin アカウント対応
- Garmin Connect API 連携による自動インポート
- 心拍数や他のメトリクスのインポート
- GPX 以外のフォーマット（TCX、FIT）対応
- インポート時のフィルタリング機能

## 技術的な注意

1. **パフォーマンス**: 大きなGPXファイル（10,000以上のポイント）の場合、パース処理に時間がかかる可能性があります
2. **メモリ使用量**: すべての位置情報がメモリに読み込まれます
3. **日時のタイムゾーン**: GPXファイルのタイムスタンプはISO8601形式を想定しています

