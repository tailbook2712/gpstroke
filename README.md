# GPStroke

### 研究概要
ウォーキングやランニングなどの歩行活動は，身体的な健康維持やメンタルヘルスの向上に効果があることが広く知られている．しかし，日常生活では仕事や家事が忙しく，運動時間を確保できない人が多いという課題がある．従来の歩行促進手法では，運動のためにまとまった時間が必要であり，特に多忙な現代人にとって実践が難しいことが指摘されている． 
そこで本研究では，日常生活の中で手軽に歩行活動を取り入れるために，GPSアートを活用した新たな歩行促進システムを提案する．従来のGPSアートのように一筆書きで計画的に移動して作品を描く方法とは異なり，日常生活の隙間時間に行った歩行活動をストロークとして蓄積・再構成し，それを作品として表現することができる．

### 作品共有機能（スライドショーのリンク共有）

作品詳細画面の共有ボタンから、作品のスライドショーをブラウザで再生できるリンクを生成し、X / Instagram などに共有できる。

- 共有データ: Firestore のトップレベルコレクション `shared_artworks/{shareId}`（`lib/artwork_share_service.dart`）
- 閲覧ページ: `docs/share/index.html`（GitHub Pages: `https://tailbook2712.github.io/gpstroke/share/?id=<shareId>`）
- 閲覧ページは Firestore REST API で未ログインのまま共有データを読み取り、アプリと同じ Web Mercator 整列計算で Google Maps をストロークに重ねて再生する

初回セットアップ:

1. Firestore のセキュリティルールに `firestore.rules` の内容を反映する（`firebase deploy --only firestore:rules`、またはコンソールに貼り付け）。`shared_artworks` の公開読み取りを許可しないと閲覧ページで「作品が見つかりません」になる。
2. Google Cloud Console で Maps JavaScript API 用のブラウザキー（HTTP リファラー `https://tailbook2712.github.io/*` に制限）を発行し、`docs/share/index.html` の `CONFIG.MAPS_API_KEY` に設定する。未設定の場合、閲覧ページは地図なし（ストロークと記録情報のみ）で再生される。

### デモビデオ
[https://youtu.be/WWZCzNrbnBU](https://youtu.be/kuIYlk2MlRw)
