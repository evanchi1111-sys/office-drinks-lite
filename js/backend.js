import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export class SpaceError extends Error {}

function friendlyError(error) {
  const msg = String(error?.message || error || '');
  if (/failed to fetch|network/i.test(msg)) return new Error('網路連線失敗，請檢查網路後再試');
  if (/ds_/.test(msg) && /schema cache|does not exist|could not find/i.test(msg)) return new Error('資料庫尚未設定，請先執行 supabase/setup.sql');
  return new Error(msg || '發生未知錯誤');
}

// 資料庫函式回傳 {ok, error, code}
function unwrap(res) {
  if (!res || res.ok !== true) {
    const msg = res?.error || '操作失敗';
    throw res?.code === 'space' ? new SpaceError(msg) : new Error(msg);
  }
  return res;
}

const norm = (d) => ({
  space: d.space,
  shops: (d.shops ?? []).map((s) => ({ ...s, sizes: s.sizes ?? [], items: s.items ?? [], toppings: s.toppings ?? [] })),
  units: (d.units ?? []).map((u) => ({ ...u, members: u.members ?? [] })),
  sessions: d.sessions ?? [],
  orders: (d.orders ?? []).map((o) => ({ ...o, toppings: o.toppings ?? [] })),
});

export async function createBackend({ demo }) {
  return demo ? createDemoBackend() : createSupabaseBackend();
}

// ---------------------------------------------------------------- Supabase

async function createSupabaseBackend() {
  const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm');
  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const call = async (fn, args) => {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw friendlyError(error);
    return unwrap(data);
  };
  let channel = null;

  // 即時同步：資料表不公開，改用「廣播」通知同一個空間的其他人重新讀取
  const notify = () => channel?.send({ type: 'broadcast', event: 'changed', payload: {} });
  const write = async (fn, args) => { const r = await call(fn, args); notify(); return r; };

  return {
    createSpace: async (name) => (await call('ds_space_create', { p_name: name })).id,
    renameSpace: (space, name) => write('ds_space_rename', { p_space: space, p_name: name }),
    deleteSpace: (space, confirm) => call('ds_space_delete', { p_space: space, p_confirm: confirm }),
    load: async (space) => norm(await call('ds_load', { p_space: space })),
    subscribe(space, onChange, onStatus = () => {}) {
      channel = sb.channel(`ds-${space}`, { config: { broadcast: { self: false } } });
      channel.on('broadcast', { event: 'changed' }, onChange);
      channel.subscribe((status) => onStatus(status));
      return () => { sb.removeChannel(channel); channel = null; };
    },

    addOrder: (space, sessionId, order, qty) => write('ds_order_add', { p_space: space, p_session: sessionId, p_order: order, p_qty: qty }),
    updateOrder: (space, id, order) => write('ds_order_update', { p_space: space, p_id: id, p_order: order }),
    deleteOrder: (space, id) => write('ds_order_delete', { p_space: space, p_id: id }),

    createSession: async (space, title, shopId, participants) =>
      (await write('ds_session_create', { p_space: space, p_title: title, p_shop: shopId, p_participants: participants })).id,
    setParticipants: (space, id, participants) => write('ds_session_set_participants', { p_space: space, p_id: id, p_participants: participants }),
    setStatus: (space, id, status) => write('ds_session_set_status', { p_space: space, p_id: id, p_status: status }),
    deleteSession: (space, id) => write('ds_session_delete', { p_space: space, p_id: id }),

    saveShop: async (space, shop) => (await write('ds_shop_save', { p_space: space, p_shop: shop })).id,
    deleteShop: (space, id) => write('ds_shop_delete', { p_space: space, p_id: id }),
    saveRoster: (space, units) => write('ds_roster_save', { p_space: space, p_units: units }),
  };
}

// ---------------------------------------------------------------- 示範模式（資料只在這個分頁）

function createDemoBackend() {
  const uid = (n = 10) => Array.from({ length: n }, () => 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Math.floor(Math.random() * 56)]).join('');
  const now = () => new Date().toISOString();
  const t0 = Date.now() - 3 * 86400000;
  const at = (min) => new Date(t0 + min * 60000).toISOString();
  const spaces = new Map();

  function seedSpace(id, name) {
    const db = {
      space: { id, name },
      shops: [
        {
          id: uid(), name: '示範茶飲', phone: '04-1234-5678', created_at: at(0), sizes: ['中杯', '大杯'],
          items: [
            { n: '珍珠奶茶', p: [45, 55] }, { n: '四季春青茶', p: [30, 35] }, { n: '檸檬綠茶', p: [40, 50] },
            { n: '冬瓜檸檬', p: [40, 50] }, { n: '紅茶拿鐵', p: [50, 60] }, { n: '黑糖鮮奶', p: [null, 70] },
          ],
          toppings: [{ n: '珍珠', p: 10 }, { n: '椰果', p: 10 }, { n: '仙草凍', p: 0 }],
        },
      ],
      units: [
        { id: uid(), name: '總務課', members: ['王小明', '李大華', '陳美玲'], ord: 0 },
        { id: uid(), name: '工務課', members: ['張家豪', '黃怡君'], ord: 1 },
      ],
      sessions: [],
      orders: [],
    };
    const shop = db.shops[0];
    db.sessions.push({ id: uid(), title: '示範飲料團', shop_id: shop.id, shop_name: shop.name, status: 'open', participants: null, created_at: at(10) });
    db.orders.push({ id: uid(12), session_id: db.sessions[0].id, unit: '總務課', name: '李大華', item: '四季春青茶', size: '大杯',
      sugar: '無糖', ice: '去冰', note: '', toppings: [], price: 35, created_at: at(20) });
    spaces.set(id, db);
  }
  // 示範資料存在這個分頁（sessionStorage），換頁不會不見，關掉分頁就清除
  const KEY = 'drink-lite-demo';
  const save = () => { try { sessionStorage.setItem(KEY, JSON.stringify([...spaces])); } catch { /* ignore */ } };
  try { for (const [k, v] of JSON.parse(sessionStorage.getItem(KEY)) ?? []) spaces.set(k, v); } catch { /* ignore */ }
  if (!spaces.size) { seedSpace('demo-space-0001', '示範公司'); save(); }

  const listeners = new Set();
  const emit = () => { save(); setTimeout(() => listeners.forEach((fn) => fn()), 30); };
  const clone = (v) => JSON.parse(JSON.stringify(v));
  const fail = (msg) => { throw new Error(msg); };
  const txt = (v, n) => (typeof v === 'string' ? v.trim().slice(0, n) : '');
  const sp = (space) => {
    const db = spaces.get(space);
    if (!db) throw new SpaceError('找不到這個空間，連結可能有誤');
    return db;
  };
  // 與資料庫 ds__build_order 相同的規則
  const buildOrder = (db, shopId, o) => {
    const name = txt(o?.name, 40);
    const item = txt(o?.item, 100);
    const size = txt(o?.size, 20);
    if (!name) fail('請先選擇或輸入你的姓名');
    if (!item) fail('請選一杯飲料');
    const shop = db.shops.find((s) => s.id === shopId);
    if (!shop) fail('這個團的飲料店已被刪除');
    const it = shop.items.find((x) => x.n === item);
    if (!it) fail(`「${item}」已不在菜單上`);
    const idx = shop.sizes.indexOf(size);
    if (idx < 0 || typeof it.p[idx] !== 'number') fail('這個規格沒有販售，請換一個規格');
    if ((o.toppings ?? []).length > 10) fail('加料最多 10 種');
    const toppings = [];
    for (const t of o.toppings ?? []) {
      const n = typeof t === 'object' ? t.n : t;
      const hit = shop.toppings.find((x) => x.n === n);
      if (!hit) fail(`加料「${n}」已不在菜單上`);
      if (!toppings.includes(hit)) toppings.push(hit);
    }
    return { unit: txt(o.unit, 60), name, item, size, price: it.p[idx] + toppings.reduce((s, t) => s + t.p, 0),
      toppings: clone(toppings), sugar: txt(o.sugar, 20), ice: txt(o.ice, 20), note: txt(o.note, 100) };
  };
  const sessionOf = (db, orderId) => {
    const o = db.orders.find((x) => x.id === orderId);
    return o && db.sessions.find((s) => s.id === o.session_id);
  };
  const participants = (p) => (p == null ? null : p.map((x) => ({ unit: txt(x.unit, 60), name: txt(x.name, 40) })).filter((x) => x.name));
  const done = (extra = {}) => { emit(); return { ok: true, ...extra }; };

  return {
    isDemo: true,
    demoSpace: 'demo-space-0001',
    async createSpace(name) {
      const n = txt(name, 60);
      if (!n) fail('請輸入空間名稱，例如公司或部門名稱');
      const id = uid(16);
      seedSpace(id, n);
      const db = spaces.get(id);
      db.shops = []; db.units = []; db.sessions = []; db.orders = [];
      save();
      return id;
    },
    async renameSpace(space, name) {
      const n = txt(name, 60);
      if (!n) fail('空間名稱不能空白');
      sp(space).space.name = n;
      return done();
    },
    async deleteSpace(space, confirm) {
      if (sp(space).space.name !== txt(confirm, 60)) fail('空間名稱不符，沒有刪除');
      spaces.delete(space);
      save();
      return { ok: true };
    },
    async load(space) {
      const db = sp(space);
      return clone({
        space: db.space,
        shops: [...db.shops].sort((a, b) => a.created_at.localeCompare(b.created_at)),
        units: [...db.units].sort((a, b) => a.ord - b.ord),
        sessions: [...db.sessions].sort((a, b) => b.created_at.localeCompare(a.created_at)),
        orders: [...db.orders].sort((a, b) => a.created_at.localeCompare(b.created_at)),
      });
    },
    subscribe(_space, onChange, onStatus = () => {}) {
      listeners.add(onChange);
      setTimeout(() => onStatus('SUBSCRIBED'), 0);
      return () => listeners.delete(onChange);
    },

    async addOrder(space, sessionId, order, qty) {
      const db = sp(space);
      const s = db.sessions.find((x) => x.id === sessionId);
      if (!s) fail('找不到這個團');
      if (s.status !== 'open') fail('這個團已經結束訂購了');
      if (!(qty >= 1 && qty <= 30)) fail('杯數需在 1～30 之間');
      const o = buildOrder(db, s.shop_id, order);
      for (let i = 0; i < qty; i++) db.orders.push({ id: uid(12), session_id: s.id, ...clone(o), created_at: now() });
      return done({ count: qty, price: o.price });
    },
    async updateOrder(space, id, order) {
      const db = sp(space);
      const s = sessionOf(db, id);
      if (!s) fail('找不到這筆訂單');
      if (s.status !== 'open') fail('這個團已經結束訂購了');
      Object.assign(db.orders.find((x) => x.id === id), buildOrder(db, s.shop_id, order));
      return done();
    },
    async deleteOrder(space, id) {
      const db = sp(space);
      const s = sessionOf(db, id);
      if (!s) return { ok: true };
      if (s.status !== 'open') fail('這個團已經結束訂購了，不能刪除訂單');
      db.orders = db.orders.filter((x) => x.id !== id);
      return done();
    },

    async createSession(space, title, shopId, parts) {
      const db = sp(space);
      const t = txt(title, 60);
      if (!t) fail('請輸入團名');
      const shop = db.shops.find((s) => s.id === shopId);
      if (!shop) fail('找不到這家飲料店');
      const id = uid(10);
      db.sessions.push({ id, title: t, shop_id: shop.id, shop_name: shop.name, status: 'open', participants: participants(parts), created_at: now() });
      emit();
      return id;
    },
    async setParticipants(space, id, parts) {
      const s = sp(space).sessions.find((x) => x.id === id);
      if (!s) fail('找不到這個團');
      s.participants = participants(parts);
      return done();
    },
    async setStatus(space, id, status) {
      const s = sp(space).sessions.find((x) => x.id === id);
      if (!s) fail('找不到這個團');
      s.status = status;
      return done();
    },
    async deleteSession(space, id) {
      const db = sp(space);
      db.sessions = db.sessions.filter((x) => x.id !== id);
      db.orders = db.orders.filter((x) => x.session_id !== id);
      return done();
    },

    async saveShop(space, shop) {
      const db = sp(space);
      const name = txt(shop.name, 60);
      if (!name) fail('店名不能空白');
      if (!(shop.sizes?.length >= 1 && shop.sizes.length <= 8)) fail('規格需要 1～8 個');
      const sizes = shop.sizes.map((s) => txt(s, 20) || '規格');
      const items = (shop.items ?? []).filter((i) => txt(i.n, 100)).map((i) => ({
        n: txt(i.n, 100), p: sizes.map((_, k) => (typeof i.p[k] === 'number' && i.p[k] >= 0 ? Math.round(i.p[k]) : null)),
      }));
      const toppings = (shop.toppings ?? []).filter((t) => txt(t.n, 40)).map((t) => ({
        n: txt(t.n, 40), p: typeof t.p === 'number' ? Math.min(1000, Math.max(0, Math.round(t.p))) : 0,
      }));
      const row = { name, phone: txt(shop.phone, 30), sizes, items, toppings };
      if (shop.id) {
        const hit = db.shops.find((s) => s.id === shop.id);
        if (!hit) fail('找不到這家飲料店，可能已被刪除');
        Object.assign(hit, row);
        emit();
        return hit.id;
      }
      const id = uid(10);
      db.shops.push({ id, ...row, created_at: now() });
      emit();
      return id;
    },
    async deleteShop(space, id) {
      const db = sp(space);
      db.shops = db.shops.filter((s) => s.id !== id);
      return done();
    },
    async saveRoster(space, units) {
      const db = sp(space);
      const names = units.map((u) => txt(u.name, 60));
      if (names.some((n) => !n)) fail('單位名稱不能空白');
      const dup = names.find((n, i) => names.indexOf(n) !== i);
      if (dup) fail(`單位「${dup}」重複了`);
      db.units = units.map((u, i) => ({
        id: u.id && db.units.some((x) => x.id === u.id) ? u.id : uid(10),
        name: names[i],
        members: Array.from(new Set((u.members ?? []).map((m) => txt(m, 40)).filter(Boolean))).slice(0, 300),
        ord: i,
      }));
      return done();
    },
  };
}
