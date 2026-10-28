// 訂單彙總、名單、菜單解析等純邏輯（不碰畫面與資料庫）

export const SUGAR_OPTIONS = ['正常糖', '少糖', '半糖', '微糖', '無糖'];
export const ICE_OPTIONS = ['正常冰', '少冰', '微冰', '去冰', '常溫', '熱'];
export const NO_UNIT = '(未分單位)';

export const esc = (s) =>
  String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

export const formatPrice = (p) => (p == null ? '—' : `$${p}`);

// ---------------------------------------------------------------- 店家種類（飲料／餐點）

export const KIND_ICON = { drink: '🧋', meal: '🍗' };
export const KIND_LABEL = { drink: '飲料', meal: '餐點' };
export const KIND_UNIT = { drink: '杯', meal: '份' };
export const kindOf = (shop) => (shop?.kind === 'meal' ? 'meal' : 'drink');

// 依品名猜一個代表圖示（沒對到就用店家種類的預設圖示）；前面的關鍵字優先
const EMOJI_RULES = [
  [/珍珠|波霸|奶茶|布丁奶/, '🧋'], [/咖啡|拿鐵|美式|摩卡/, '☕'], [/檸檬|柳橙|柑|橘/, '🍋'], [/芒果/, '🥭'], [/草莓/, '🍓'], [/葡萄/, '🍇'], [/西瓜/, '🍉'],
  [/鮮奶|牛奶|豆漿/, '🥛'], [/冰沙|冰淇淋|霜淇淋/, '🍧'], [/果汁|汁/, '🧃'], [/茶|青|烏龍|仙草/, '🍵'],
  [/甜不辣|串|關東煮|魚/, '🍢'], [/薯條|地瓜/, '🍟'], [/雞腿|雞排|雞|鹽酥|炸/, '🍗'], [/五花|培根|豬|肉/, '🥓'], [/玉米/, '🌽'], [/蝦/, '🍤'], [/起司|乳酪/, '🧀'],
  [/蛋糕|提拉|千層|慕斯/, '🍰'], [/布丁|奶酪|焦糖/, '🍮'], [/塔|派/, '🥧'], [/司康|可頌|麵包|吐司/, '🥐'], [/餅乾|曲奇/, '🍪'], [/甜甜圈/, '🍩'], [/冰/, '🍨'],
];
export const emojiFor = (name, kind) => EMOJI_RULES.find(([re]) => re.test(name ?? ''))?.[1] ?? (kind === 'meal' ? '🍽️' : '🥤');

/** 這個團有哪些店家（第一個是主要店家，其餘是加開的）。 */
export const sessionShopIds = (session) => [session.shop_id, ...(session.extra_shop_ids ?? [])];
/** 訂單屬於哪家店（舊訂單沒記錄時算主要店家）。 */
export const orderShopId = (o, session) => o.shop_id || session.shop_id;

/** 依店家分組：照團裡店家的順序；訂單所屬的店若已被刪除也會保留一組。 */
export function groupByShop(orders, session, shops) {
  const ids = sessionShopIds(session);
  for (const o of orders) {
    const id = orderShopId(o, session);
    if (!ids.includes(id)) ids.push(id);
  }
  return ids.map((id) => {
    const shop = shops.find((s) => s.id === id) ?? null;
    return {
      id, shop, kind: kindOf(shop),
      name: shop?.name ?? (id === session.shop_id ? session.shop_name : '（已刪除的店家）'),
      phone: shop?.phone ?? '',
      orders: orders.filter((o) => orderShopId(o, session) === id),
    };
  });
}

/** 「3 杯」「2 份」，飲料與餐點都有時「3 杯飲料、2 份餐點」。 */
export function countText(orders, session, shops) {
  const n = { drink: 0, meal: 0 };
  for (const o of orders) n[kindOf(shops.find((s) => s.id === orderShopId(o, session)))] += 1;
  if (n.drink && n.meal) return `${n.drink} 杯飲料、${n.meal} 份餐點`;
  return n.meal ? `${n.meal} 份` : `${n.drink} 杯`;
}

const toppingKey = (t) => (t ?? []).map((x) => x.n).sort().join('+');

// ---------------------------------------------------------------- 彙總

export function aggregate(orders) {
  const map = new Map();
  for (const o of orders) {
    const k = [o.shop_id ?? '', o.item, o.size, o.sugar, o.ice, toppingKey(o.toppings), o.note, o.price ?? ''].join('|');
    const hit = map.get(k);
    if (hit) {
      hit.count += 1;
      hit.total += o.price ?? 0;
    } else {
      map.set(k, { shop_id: o.shop_id, item: o.item, size: o.size, sugar: o.sugar, ice: o.ice, note: o.note, toppings: o.toppings, count: 1, price: o.price, total: o.price ?? 0 });
    }
  }
  return Array.from(map.values()).sort((a, b) => a.item.localeCompare(b.item, 'zh-Hant'));
}

export const totalOf = (orders) => orders.reduce((s, o) => s + (o.price ?? 0), 0);

/** 這個團預期要訂的人：有指定成員用指定名單，否則是整份名單。 */
export function expectedPeople(session, units) {
  if (session?.participants) return session.participants;
  return units.flatMap((u) => u.members.map((name) => ({ unit: u.name, name })));
}

export function groupByUnit(orders, units, session) {
  const expected = expectedPeople(session, units);
  const done = new Set(orders.map((o) => o.name));
  const keys = new Set();
  for (const o of orders) keys.add(o.unit || NO_UNIT);
  for (const p of expected) keys.add(p.unit || NO_UNIT);
  const rosterNames = units.map((u) => u.name);
  const ordered = [...rosterNames.filter((n) => keys.has(n)), ...Array.from(keys).filter((k) => !rosterNames.includes(k))];
  return ordered.map((unit) => {
    const list = orders.filter((o) => (o.unit || NO_UNIT) === unit);
    const want = expected.filter((p) => (p.unit || NO_UNIT) === unit).map((p) => p.name);
    const notYet = Array.from(new Set(want)).filter((n) => !done.has(n));
    return { unit, orders: list, notYet };
  });
}

export function pendingPeople(orders, units, session) {
  return groupByUnit(orders, units, session).filter((g) => g.notYet.length > 0).map((g) => ({ unit: g.unit, names: g.notYet }));
}

// 加料名稱本身已經是「加辣」「加蛋」這類時，不再多加一個「加」
export const toppingText = (t) => (t && t.length ? ` ${t.every((x) => x.n.startsWith('加')) ? '' : '加'}${t.map((x) => x.n).join('、')}` : '');

export function drinkLabel(a) {
  return [a.item, a.size, a.sugar, a.ice].filter(Boolean).join(' ') + toppingText(a.toppings) + (a.note ? `(${a.note})` : '');
}

export function summaryText(session, orders, shops) {
  return groupByShop(orders, session, shops)
    .filter((g) => g.orders.length)
    .map((g) => {
      const lines = aggregate(g.orders).map((r) => `${drinkLabel(r)} × ${r.count}`);
      return [`【${session.title}】${g.name}${g.phone ? `(${g.phone})` : ''}`, ...lines, `共 ${g.orders.length} ${KIND_UNIT[g.kind]}，合計 $${totalOf(g.orders)}`].join('\n');
    })
    .join('\n\n');
}

export function detailText(orders, units, session, shops) {
  const head = ['單位', '姓名', '店家', '品項', '規格', '甜度', '冰量', '加料', '備註', '價格'].join('\t');
  const shopName = (o) => shops.find((s) => s.id === orderShopId(o, session))?.name ?? session.shop_name;
  const rows = groupByUnit(orders, units)
    .flatMap((g) => g.orders)
    .map((o) => [o.unit, o.name, shopName(o), o.item, o.size, o.sugar, o.ice, o.toppings.map((t) => t.n).join('、'), o.note, o.price ?? ''].join('\t'));
  return [head, ...rows].join('\n');
}

/** 這個人以前點過、現在這家店還買得到的飲料（價格以目前菜單為準），最多 8 個。 */
export function favsFor(name, allOrders, shop) {
  if (!name || !shop) return [];
  const map = new Map();
  for (const o of allOrders) {
    if (o.name !== name) continue;
    const it = shop.items.find((x) => x.n === o.item);
    if (!it) continue;
    const si = shop.sizes.indexOf(o.size);
    const base = si >= 0 ? it.p[si] : null;
    if (base == null) continue;
    const tops = [];
    let missing = false;
    for (const t of o.toppings) {
      const cur = shop.toppings.find((x) => x.n === t.n);
      if (!cur) { missing = true; break; }
      tops.push(cur);
    }
    if (missing) continue;
    const price = base + tops.reduce((s, t) => s + t.p, 0);
    const k = [o.item, o.size, o.sugar, o.ice, toppingKey(tops), o.note].join('|');
    const hit = map.get(k);
    if (hit) hit.count += 1;
    else map.set(k, { key: k, item: o.item, size: o.size, sugar: o.sugar, ice: o.ice, note: o.note, toppings: tops, price, count: 1 });
  }
  return Array.from(map.values()).sort((a, b) => b.count - a.count).slice(0, 8);
}

// ---------------------------------------------------------------- 分發單（A4 列印）

export function sheetHTML(session, orders, units, shops) {
  const shopGroups = groupByShop(orders, session, shops).filter((g) => g.orders.length);
  const multi = shopGroups.length > 1;
  const groups = groupByUnit(orders, units, session).filter((g) => g.orders.length > 0);
  const date = new Date(session.created_at).toLocaleDateString('zh-TW');
  const shopName = (o) => shops.find((s) => s.id === orderShopId(o, session))?.name ?? session.shop_name;
  const shopTables = shopGroups
    .map((g) => {
      const rows = aggregate(g.orders)
        .map((r) => `<tr><td>${esc(drinkLabel(r))}</td><td class="n">${r.count}</td><td class="n">${r.price == null ? '—' : '$' + r.price}</td><td class="n">$${r.total}</td></tr>`)
        .join('');
      return `<h2>${esc(g.name)}${g.phone ? ` ・ 電話 ${esc(g.phone)}` : ''}</h2>
<table><thead><tr><th>品項</th><th class="n">數量（${KIND_UNIT[g.kind]}）</th><th class="n">單價</th><th class="n">小計</th></tr></thead><tbody>${rows}</tbody>
<tfoot><tr><td>合計</td><td class="n">${g.orders.length}</td><td></td><td class="n">$${totalOf(g.orders)}</td></tr></tfoot></table>`;
    })
    .join('');
  const page1 = `<section><h1>${esc(session.title)}</h1><p class="sub">${date} ・ 品項彙總</p>${shopTables}${multi ? `<p class="grand">總計 ${esc(countText(orders, session, shops))} ・ $${totalOf(orders)}</p>` : ''}</section>`;
  const unitPages = groups
    .map((g) => {
      const rows = g.orders
        .map((o) => `<tr><td>${esc(o.name)}</td><td>${esc(drinkLabel(o))}${multi ? ` <span class="shop">（${esc(shopName(o))}）</span>` : ''}</td><td class="n">${o.price == null ? '—' : '$' + o.price}</td><td class="sign"></td></tr>`)
        .join('');
      return `<section><h1>${esc(g.unit)}</h1><p class="sub">${esc(session.title)} ・ ${esc(shopGroups.map((x) => x.name).join('、'))} ・ ${esc(countText(g.orders, session, shops))} ・ 小計 $${totalOf(g.orders)}</p>
<table><thead><tr><th>姓名</th><th>品項</th><th class="n">金額</th><th class="sign">簽收</th></tr></thead><tbody>${rows}</tbody></table></section>`;
    })
    .join('');
  return `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(session.title)} 分發單</title>
<style>
@page{size:A4;margin:14mm}
*{box-sizing:border-box}
body{font-family:"Noto Sans TC","PingFang TC","Microsoft JhengHei",sans-serif;color:#222;margin:0;padding:16px}
section{page-break-after:always;max-width:190mm;margin:0 auto 24px}
section:last-child{page-break-after:auto}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:17px;margin:18px 0 6px}
.grand{margin:14px 0 0;font-weight:700;font-size:15px}
.shop{color:#666;font-size:12px}
.sub{margin:0 0 14px;color:#555;font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{border:1px solid #888;padding:8px 10px;text-align:left}
th{background:#eee}
.n{text-align:right;white-space:nowrap}
td.sign{width:30%;height:34px}
tfoot td{font-weight:700;background:#f6f6f6}
.bar{position:sticky;top:0;background:#fff;padding:8px 0;margin-bottom:12px;border-bottom:1px solid #ddd;text-align:center}
.bar button{font-size:16px;padding:8px 20px;border-radius:8px;border:1px solid #2b6a4a;background:#2b6a4a;color:#fff}
@media print{.bar{display:none}body{padding:0}}
</style></head><body><div class="bar"><button onclick="window.print()">列印分發單</button></div>${page1}${unitPages}</body></html>`;
}

// ---------------------------------------------------------------- 菜單、名單匯入

/** 貼上的文字／CSV 切成列：有 tab 就用 tab 分隔，否則用逗號。 */
export function splitCSV(text) {
  const src = text.replace(/^﻿/, '');
  const delim = src.includes('\t') ? '\t' : ',';
  const rows = [];
  let row = [];
  let cell = '';
  let inQ = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inQ) {
      if (c === '"') {
        if (src[i + 1] === '"') { cell += '"'; i++; } else inQ = false;
      } else cell += c;
    } else if (c === '"' && cell === '') {
      inQ = true;
    } else if (c === delim) {
      row.push(cell);
      cell = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = '';
    } else cell += c;
  }
  row.push(cell);
  rows.push(row);
  return rows.map((r) => r.map((x) => x.trim())).filter((r) => r.some((x) => x !== ''));
}

export function parsePrice(s) {
  if (!s) return null;
  const m = s.replace(/,/g, '').match(/\d+(?:\.\d+)?/);
  return m ? Math.round(parseFloat(m[0])) : null;
}

const NAME_PRICE = /^(.+?)[\s:：]*(?:NT\$?|\$|＄)?\s*(\d+)\s*(?:元)?$/i;
const TOPPING_LINE = /^(.+?)[\s,，:：]*[+＋]?\s*(?:NT\$?|\$|＄)?\s*(\d+)?\s*(?:元)?$/i;

/** 每行一個加料：「大珍珠 10」「小珍珠,10」「椰果」（沒寫價格 = 0）。 */
export function parseToppingsText(text) {
  const out = [];
  for (const raw of text.replace(/^﻿/, '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = line.match(TOPPING_LINE);
    const n = (m?.[1] ?? line).trim();
    if (!n || out.some((t) => t.n === n)) continue;
    out.push({ n: n.slice(0, 40), p: m?.[2] ? Math.min(1000, parseInt(m[2], 10)) : 0 });
  }
  return out;
}

export function mergeToppings(existing, incoming, mode) {
  if (mode === 'replace') return incoming.length ? incoming : existing;
  const out = existing.map((t) => ({ ...t }));
  for (const t of incoming) {
    const hit = out.find((x) => x.n === t.n);
    if (hit) hit.p = t.p;
    else out.push({ ...t });
  }
  return out;
}

function defaultSizes(n) {
  if (n <= 1) return ['中杯'];
  if (n === 2) return ['中杯', '大杯'];
  return Array.from({ length: n }, (_, i) => `規格${i + 1}`);
}

export function parseMenu(text) {
  let rows = splitCSV(text);
  if (rows.length === 0) return { sizes: ['中杯'], items: [] };
  // 單一儲存格「珍珠奶茶 50」拆成品名、價格
  rows = rows.map((r) => {
    if (r.length === 1) {
      const m = r[0].match(NAME_PRICE);
      if (m) return [m[1].trim(), m[2]];
    }
    // Excel 貼上的分類標題列（「炸物」後面只有空白格）當成單一儲存格
    if (r.length > 1 && r.slice(1).every((x) => x === '')) return [r[0]];
    return r;
  });
  const first = rows[0];
  const looksHeader = first.length > 1 && (first[0] === '品名' || first.slice(1).every((c) => c !== '' && parsePrice(c) === null));
  let sizes;
  let body = rows;
  if (looksHeader) {
    sizes = first.slice(1).filter((c) => c !== '');
    body = rows.slice(1);
  } else {
    sizes = defaultSizes(Math.max(1, ...rows.map((r) => r.length - 1)));
  }
  if (sizes.length === 0) sizes = ['中杯'];
  const items = [];
  let cat = '';
  for (const r of body) {
    const n = r[0]?.trim();
    if (!n) continue;
    const p = sizes.map((_, i) => parsePrice(r[i + 1]));
    if (r.length === 1 && p.every((x) => x === null)) { cat = n.slice(0, 20); continue; } // 分類標題列：之後的品項都歸這一類
    items.push(cat ? { n, p, c: cat } : { n, p });
  }
  return { sizes, items, header: looksHeader };
}

export function applyMenu(existing, parsed, mode) {
  if (mode === 'replace') return { ...parsed, toppings: mergeToppings(existing.toppings ?? [], parsed.toppings ?? [], 'replace') };
  const sizes = [...existing.sizes];
  for (const s of parsed.sizes) if (!sizes.includes(s)) sizes.push(s);
  const remap = (labels, p) => sizes.map((s) => { const i = labels.indexOf(s); return i >= 0 ? (p[i] ?? null) : null; });
  const items = existing.items.map((it) => ({ ...it, p: remap(existing.sizes, it.p) }));
  for (const it of parsed.items) {
    const np = remap(parsed.sizes, it.p);
    const hit = items.find((x) => x.n === it.n);
    if (hit) {
      hit.p = hit.p.map((v, i) => np[i] ?? v);
      if (it.c) hit.c = it.c;
    } else items.push({ n: it.n, p: np, ...(it.c ? { c: it.c } : {}) });
  }
  return { sizes, items, toppings: mergeToppings(existing.toppings ?? [], parsed.toppings ?? [], 'append') };
}

const csvCell = (v) => { const s = String(v ?? ''); return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

/** 匯出菜單成 CSV（與匯入格式相同，加料放在下方「加料」區段）；開頭加 BOM 讓 Excel 正確顯示中文。 */
export function menuToCSV(shop) {
  // 沒有分類的品項在最前面；有分類的各自接在「分類標題列」（只有一格）後面，匯入時會還原
  const row = (i) => [i.n, ...shop.sizes.map((_, k) => i.p[k] ?? '')];
  const cats = [...new Set(shop.items.map((i) => i.c).filter(Boolean))];
  const rows = [['品名', ...shop.sizes], ...shop.items.filter((i) => !i.c).map(row), ...cats.flatMap((c) => [[c], ...shop.items.filter((i) => i.c === c).map(row)])];
  if (shop.toppings.length) rows.push([], ['加料', '加價'], ...shop.toppings.map((t) => [t.n, t.p]));
  return '﻿' + rows.map((r) => r.map(csvCell).join(',')).join('\r\n') + '\r\n';
}

/** 把匯入的文字拆成「菜單」與「加料」兩段：從第一格是「加料」的那一行開始算加料。 */
export function splitMenuSections(text) {
  const lines = text.replace(/^﻿/, '').split(/\r?\n/);
  const at = lines.findIndex((l) => /^\s*"?加料"?\s*([,\t，]|$)/.test(l));
  if (at < 0) return { menu: text, toppings: '' };
  const toppings = lines.slice(at + 1)
    .map((l) => splitCSV(l)[0])
    .filter((r) => r && r[0])
    .map((r) => `${r[0]} ${r[1] ?? ''}`.trim())
    .join('\n');
  return { menu: lines.slice(0, at).join('\n'), toppings };
}

/** 匯出名單成 CSV：一人一列（單位,姓名），方便 Excel 排序篩選；沒有人員的單位只寫單位。可直接再匯入。 */
export function rosterToCSV(units) {
  const rows = [['單位', '姓名'], ...units.flatMap((u) => (u.members.length ? u.members.map((m) => [u.name, m]) : [[u.name]]))];
  return '﻿' + rows.map((r) => r.map(csvCell).join(',')).join('\r\n') + '\r\n';
}

export function parseRoster(text) {
  const map = new Map();
  for (const raw of text.replace(/^﻿/, '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const parts = line.split(/[,，\t、;；:：]+/).map((x) => x.trim().replace(/^"|"$/g, '').trim()).filter(Boolean);
    if (parts.length < 1) continue;
    if (parts[0] === '單位' && (parts[1] === '姓名' || parts.length === 1)) continue;
    const [unit, ...names] = parts;
    const arr = map.get(unit) ?? [];
    for (const n of names) if (!arr.includes(n)) arr.push(n);
    map.set(unit, arr);
  }
  return Array.from(map, ([name, members]) => ({ name, members }));
}

export function mergeRoster(existing, incoming, mode) {
  if (mode === 'replace') return incoming;
  const out = existing.map((u) => ({ ...u, members: [...u.members] }));
  for (const u of incoming) {
    const hit = out.find((x) => x.name === u.name);
    if (hit) { for (const m of u.members) if (!hit.members.includes(m)) hit.members.push(m); }
    else out.push({ name: u.name, members: [...u.members] });
  }
  return out;
}

/** 讀取上傳的文字／CSV：先試 UTF-8，不行再用 Big5（Excel 存的中文 CSV）。 */
export async function readTextFile(file) {
  const buf = await file.arrayBuffer();
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf).replace(/^﻿/, '');
  } catch {
    return new TextDecoder('big5').decode(buf);
  }
}
