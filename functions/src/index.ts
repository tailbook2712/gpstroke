import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions';
import { onRequest } from 'firebase-functions/v2/https';

import {
  foundPageContent,
  notFoundPageContent,
  parseSharePath,
  renderSharePage,
  toPublicShareData,
} from './share';

initializeApp();
const db = getFirestore();

/** 共有ページのテンプレート（functions/templates/share.html） */
const template = readFileSync(join(__dirname, '..', 'templates', 'share.html'), 'utf8');

/** 共有ページのドメイン（リクエストから分からないときに使う） */
const DEFAULT_HOST = 'gpstroke.web.app';

/**
 * CDN（Firebase Hosting）にキャッシュさせる時間（秒）
 *
 * 共有を停止した（または作品を削除した）作品は、長くてもこの時間で見られなくなる。
 * 停止がすぐ反映されるよう短めにしている（その分、Functions と Firestore の読み込みは増える）
 */
const PAGE_CACHE_SECONDS = 60;
const IMAGE_CACHE_SECONDS = 300;
const NOT_FOUND_CACHE_SECONDS = 60;

/**
 * 作品の共有ページ（Firebase Hosting の `/s/**` から呼ばれる）
 *
 * - `/s/{shareId}`: 共有データと OGP の meta タグを埋め込んだ共有ページ
 * - `/s/{shareId}/image.png`: OGP 画像（地図を含まない作品画像）
 *
 * 共有データ（shared_artworks）は管理者の権限で読むため、Firestore のルールでは
 * 一般の読み取りを許可しない
 */
export const sharePage = onRequest(
  { region: 'us-central1', invoker: 'public', maxInstances: 10 },
  async (req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.status(405).set('Allow', 'GET, HEAD').send('Method Not Allowed');
      return;
    }

    const host = (req.get('x-forwarded-host') ?? req.hostname ?? '').split(',')[0].trim();
    const origin = `https://${host || DEFAULT_HOST}`;
    const route = parseSharePath(req.path);

    try {
      const snapshot = route
        ? await db.collection('shared_artworks').doc(route.shareId).get()
        : null;
      const doc = snapshot?.exists ? snapshot.data() ?? null : null;

      // OGP 画像: 共有データが指す作品の画像（users/{uid}/artwork_images/{artworkId}）
      if (route?.image) {
        const ownerUid = doc?.ownerUid;
        const artworkId = doc?.artworkId;
        const image =
          typeof ownerUid === 'string' && ownerUid && typeof artworkId === 'string' && artworkId
            ? await db
                .collection('users')
                .doc(ownerUid)
                .collection('artwork_images')
                .doc(artworkId)
                .get()
            : null;
        const bytes = image?.get('image');
        if (!(bytes instanceof Uint8Array)) {
          res
            .status(404)
            .set('Cache-Control', `public, max-age=${NOT_FOUND_CACHE_SECONDS}, s-maxage=${NOT_FOUND_CACHE_SECONDS}`)
            .send('Not Found');
          return;
        }
        res
          .status(200)
          .set('Cache-Control', `public, max-age=${IMAGE_CACHE_SECONDS}, s-maxage=${IMAGE_CACHE_SECONDS}`)
          .type('png')
          .send(Buffer.from(bytes));
        return;
      }

      const data = doc ? toPublicShareData(doc) : null;
      if (route && data) {
        res
          .status(200)
          .set('Cache-Control', `public, max-age=60, s-maxage=${PAGE_CACHE_SECONDS}`)
          .type('html')
          .send(renderSharePage(template, foundPageContent(data, origin, route.shareId)));
      } else {
        res
          .status(404)
          .set('Cache-Control', `public, max-age=${NOT_FOUND_CACHE_SECONDS}, s-maxage=${NOT_FOUND_CACHE_SECONDS}`)
          .type('html')
          .send(renderSharePage(template, notFoundPageContent(origin)));
      }
    } catch (error) {
      logger.error('共有ページの表示エラー', { path: req.path, error });
      res
        .status(500)
        .set('Cache-Control', 'no-store')
        .type('text')
        .send('作品を読み込めませんでした。時間をおいて再読み込みしてください。');
    }
  },
);
