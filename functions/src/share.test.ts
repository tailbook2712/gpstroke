import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  embedJson,
  escapeHtml,
  foundPageContent,
  notFoundPageContent,
  parseSharePath,
  renderSharePage,
  toPublicShareData,
} from './share';

const sharedDoc = {
  version: 1,
  shareId: 'P5J94wMXekzsN_RjhtSH',
  ownerUid: 'owner-uid',
  artworkId: 'artwork_1795749749920',
  artworkName: '函館の鳥',
  createdAt: '2026-11-26T06:10:00.000Z',
  canvasWidth: 390,
  canvasHeight: 707.6,
  strokeCount: 2,
  totalSteps: 3960,
  totalDistance: 3.692,
  sharedAt: { seconds: 1, nanoseconds: 0 },
  strokes: [
    {
      polyline: '_p~iF~ps|U',
      pointCount: 1,
      x: 202.3,
      y: 255.6,
      scale: 3.77,
      rotation: 0,
      groupId: 'garmin_1795359820741',
      date: '2026-11-22T15:03:40.968Z',
      steps: 2560,
      distance: 2.21,
    },
    'broken',
  ],
};

test('共有ページの URL を読む', () => {
  assert.deepEqual(parseSharePath('/s/P5J94wMXekzsN_RjhtSH'), {
    shareId: 'P5J94wMXekzsN_RjhtSH',
    image: false,
  });
  assert.deepEqual(parseSharePath('/s/P5J94wMXekzsN_RjhtSH/'), {
    shareId: 'P5J94wMXekzsN_RjhtSH',
    image: false,
  });
  assert.deepEqual(parseSharePath('/s/P5J94wMXekzsN_RjhtSH/image.png'), {
    shareId: 'P5J94wMXekzsN_RjhtSH',
    image: true,
  });
  assert.equal(parseSharePath('/s/'), null);
  assert.equal(parseSharePath('/s/short'), null);
  assert.equal(parseSharePath('/s/../users/x'), null);
  assert.equal(parseSharePath('/s/P5J94wMXekzsN_RjhtSH/other'), null);
  assert.equal(parseSharePath('/share/?id=P5J94wMXekzsN_RjhtSH'), null);
});

test('ページに出すのは再生に必要な項目だけ（作成者や作品の ID は出さない）', () => {
  const data = toPublicShareData(sharedDoc);
  assert.ok(data);
  assert.equal(data.artworkName, '函館の鳥');
  assert.equal(data.strokes.length, 1);
  assert.deepEqual(Object.keys(data.strokes[0]).sort(), [
    'date', 'distance', 'polyline', 'rotation', 'scale', 'steps', 'x', 'y',
  ]);
  const json = JSON.stringify(data);
  assert.ok(!json.includes('owner-uid'));
  assert.ok(!json.includes('artwork_1795749749920'));
  assert.ok(!json.includes('garmin_1795359820741'));
});

test('キャンバスの大きさがない共有データは再生できない', () => {
  assert.equal(toPublicShareData({ strokes: [] }), null);
  assert.equal(toPublicShareData({ canvasWidth: 0, canvasHeight: 600 }), null);
});

test('作品名が空なら無題の作品にする', () => {
  const data = toPublicShareData({ ...sharedDoc, artworkName: '  ' });
  assert.equal(data?.artworkName, '無題の作品');
});

test('作品名などを HTML に入れるときは無害化する', () => {
  assert.equal(
    escapeHtml(`<img src=x onerror="alert('x')">&`),
    '&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;&amp;',
  );
});

test('埋め込む JSON から </script> で抜け出せない', () => {
  const embedded = embedJson({ name: '</script><script>alert(1)</script>' });
  assert.ok(!embedded.includes('</script>'));
  assert.deepEqual(JSON.parse(embedded), { name: '</script><script>alert(1)</script>' });
});

test('テンプレートを埋める（値の中の {{...}} は埋め直さない）', () => {
  const data = toPublicShareData({ ...sharedDoc, artworkName: '{{SHARE_DATA}}<b>' });
  assert.ok(data);
  const html = renderSharePage(
    '<title>{{TITLE}}</title><meta content="{{IMAGE_URL}}">' +
      '<script type="application/json">{{SHARE_DATA}}</script>{{UNKNOWN}}',
    foundPageContent(data, 'https://gpstroke.web.app', 'P5J94wMXekzsN_RjhtSH'),
  );
  assert.ok(html.includes('<title>{{SHARE_DATA}}&lt;b&gt; | GPStroke</title>'));
  assert.ok(html.includes('content="https://gpstroke.web.app/s/P5J94wMXekzsN_RjhtSH/image.png"'));
  assert.ok(html.includes('{{UNKNOWN}}'));
  const json = /<script type="application\/json">(.*)<\/script>/.exec(html)?.[1];
  assert.equal(JSON.parse(json ?? 'null').artworkName, '{{SHARE_DATA}}<b>');
});

test('作品が見つからないときは共有データを null にする', () => {
  const html = renderSharePage(
    '<title>{{TITLE}}</title><script>{{SHARE_DATA}}</script>',
    notFoundPageContent('https://gpstroke.web.app'),
  );
  assert.equal(html, '<title>作品が見つかりません | GPStroke</title><script>null</script>');
});

test('説明文に作品の概要を入れる', () => {
  const data = toPublicShareData(sharedDoc);
  assert.ok(data);
  assert.equal(
    foundPageContent(data, 'https://gpstroke.web.app', 'P5J94wMXekzsN_RjhtSH').description,
    '歩いた軌跡を集めて描いた GPS アート（1 ストローク · 3,960 歩 · 3.69 km）',
  );
});
