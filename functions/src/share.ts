/**
 * 作品の共有ページの組み立て（Firestore や HTTP に依存しない処理）
 */

/** 共有ページの URL の種類 */
export interface ShareRoute {
  shareId: string;
  /** OGP 画像（/s/{shareId}/image.png）か */
  image: boolean;
}

/**
 * 共有ページの URL（`/s/{shareId}` と `/s/{shareId}/image.png`）を読む。形が違えば null
 *
 * 共有 ID は英数字・`-`・`_` だけ（アプリの ArtworkShareService が作る形）
 */
export function parseSharePath(path: string): ShareRoute | null {
  const match = /^\/s\/([A-Za-z0-9_-]{8,64})(\/image\.png)?\/?$/.exec(path);
  if (!match) return null;
  return { shareId: match[1], image: match[2] !== undefined };
}

/** 共有ページに渡すストローク */
export interface PublicStroke {
  polyline: string;
  x: number;
  y: number;
  scale: number;
  rotation: number;
  date: string;
  steps: number;
  distance: number;
}

/** 共有ページに渡す共有データ */
export interface PublicShareData {
  artworkName: string;
  createdAt: string;
  canvasWidth: number;
  canvasHeight: number;
  totalSteps: number;
  totalDistance: number;
  strokes: PublicStroke[];
}

const toNumber = (value: unknown, fallback = 0): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : fallback;

const toText = (value: unknown, fallback = ''): string =>
  typeof value === 'string' ? value : fallback;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/**
 * 共有データ（Firestore の shared_artworks のドキュメント）から、共有ページの再生に
 * 必要な項目だけを取り出す。作成者のユーザー ID や作品 ID などはページに出さない。
 * キャンバスの大きさがない（再生できない）場合は null
 */
export function toPublicShareData(doc: Record<string, unknown>): PublicShareData | null {
  const canvasWidth = toNumber(doc.canvasWidth);
  const canvasHeight = toNumber(doc.canvasHeight);
  if (canvasWidth <= 0 || canvasHeight <= 0) return null;

  const strokes = Array.isArray(doc.strokes) ? doc.strokes.filter(isRecord) : [];
  return {
    artworkName: toText(doc.artworkName).trim() || '無題の作品',
    createdAt: toText(doc.createdAt),
    canvasWidth,
    canvasHeight,
    totalSteps: toNumber(doc.totalSteps),
    totalDistance: toNumber(doc.totalDistance),
    strokes: strokes.map((stroke) => ({
      polyline: toText(stroke.polyline),
      x: toNumber(stroke.x),
      y: toNumber(stroke.y),
      scale: toNumber(stroke.scale, 1),
      rotation: toNumber(stroke.rotation),
      date: toText(stroke.date),
      steps: toNumber(stroke.steps),
      distance: toNumber(stroke.distance),
    })),
  };
}

/** 作品の概要（共有ページの作品名の下と同じ形） */
export function describeArtwork(data: PublicShareData): string {
  return `${data.strokes.length} ストローク · ` +
    `${Math.round(data.totalSteps).toLocaleString('ja-JP')} 歩 · ` +
    `${data.totalDistance.toFixed(2)} km`;
}

/** HTML の本文・属性値に入れる文字列を無害化する */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * `<script type="application/json">` に埋め込む JSON
 *
 * 作品名などに `</script>` が含まれていても、スクリプトから抜け出せないようにする
 */
export function embedJson(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

/** 共有ページに埋める内容 */
export interface SharePageContent {
  title: string;
  description: string;
  pageUrl: string;
  imageUrl: string;
  /** 共有データ（作品が見つからない場合は null） */
  data: PublicShareData | null;
}

/** 作品が見つかったときの共有ページの内容 */
export function foundPageContent(
  data: PublicShareData,
  origin: string,
  shareId: string,
): SharePageContent {
  return {
    title: `${data.artworkName} | GPStroke`,
    description: `歩いた軌跡を集めて描いた GPS アート（${describeArtwork(data)}）`,
    pageUrl: `${origin}/s/${shareId}`,
    imageUrl: `${origin}/s/${shareId}/image.png`,
    data,
  };
}

/** 作品が見つからないときの共有ページの内容 */
export function notFoundPageContent(origin: string): SharePageContent {
  return {
    title: '作品が見つかりません | GPStroke',
    description: '共有が解除されたか、リンクが正しくない可能性があります。',
    pageUrl: origin,
    imageUrl: '',
    data: null,
  };
}

/**
 * テンプレートの `{{TITLE}}` などを埋める
 *
 * 埋めた値の中に `{{...}}` があっても、それは埋め直さない
 */
export function renderSharePage(template: string, content: SharePageContent): string {
  const values: Record<string, string> = {
    TITLE: escapeHtml(content.title),
    DESCRIPTION: escapeHtml(content.description),
    PAGE_URL: escapeHtml(content.pageUrl),
    IMAGE_URL: escapeHtml(content.imageUrl),
    SHARE_DATA: embedJson(content.data),
  };
  return template.replace(/\{\{([A-Z_]+)\}\}/g, (whole, key: string) => values[key] ?? whole);
}
