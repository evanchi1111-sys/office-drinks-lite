-- =====================================================================
-- 飲料訂購（專屬連結版）：Supabase 資料庫設定
-- 資料表一律以 ds_ 開頭，可以和其他系統共用同一個 Supabase 專案。
-- 每個「空間」有一組猜不到的代號，知道代號（連結）的人才能讀寫該空間的資料。
-- 用法：Supabase → SQL Editor → New query → 貼上全部內容 → Run（可重複執行）
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. 資料表 ----------

create table if not exists public.ds_spaces (
  id         text primary key,                    -- 隨機代號 = 進入空間的鑰匙
  name       text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now(),
  active_at  timestamptz not null default now()
);

create table if not exists public.ds_shops (
  id         text primary key,
  space_id   text not null references public.ds_spaces(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  phone      text not null default '' check (char_length(phone) <= 30),
  sizes      jsonb not null default '[]'::jsonb,  -- ["中杯","大杯"]
  items      jsonb not null default '[]'::jsonb,  -- [{"n":"珍珠奶茶","p":[50,60]}]，null = 沒賣
  toppings   jsonb not null default '[]'::jsonb,  -- [{"n":"珍珠","p":10}]
  created_at timestamptz not null default now()
);
create index if not exists ds_shops_space_idx on public.ds_shops (space_id);

create table if not exists public.ds_units (
  id       text primary key,
  space_id text not null references public.ds_spaces(id) on delete cascade,
  name     text not null check (char_length(name) between 1 and 60),
  members  jsonb not null default '[]'::jsonb,
  ord      int  not null default 0,
  unique (space_id, name)
);

create table if not exists public.ds_sessions (
  id           text primary key,
  space_id     text not null references public.ds_spaces(id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 60),
  shop_id      text not null,
  shop_name    text not null,
  status       text not null default 'open' check (status in ('open', 'closed')),
  participants jsonb,                             -- null = 名單上所有人
  created_at   timestamptz not null default now()
);
create index if not exists ds_sessions_space_idx on public.ds_sessions (space_id, created_at);

create table if not exists public.ds_orders (
  id         text primary key,
  space_id   text not null references public.ds_spaces(id) on delete cascade,
  session_id text not null references public.ds_sessions(id) on delete cascade,
  unit       text not null default '',
  name       text not null,
  item       text not null,
  size       text not null default '',
  price      int,                                 -- 含加料的單杯價格（由資料庫依菜單計算）
  toppings   jsonb not null default '[]'::jsonb,
  sugar      text not null default '',
  ice        text not null default '',
  note       text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists ds_orders_space_idx on public.ds_orders (space_id, created_at);

-- ---------- 2. 安全規則：網頁不能直接讀寫資料表，一律透過下方函式並出示空間代號 ----------

alter table public.ds_spaces   enable row level security;
alter table public.ds_shops    enable row level security;
alter table public.ds_units    enable row level security;
alter table public.ds_sessions enable row level security;
alter table public.ds_orders   enable row level security;
revoke all on public.ds_spaces, public.ds_shops, public.ds_units, public.ds_sessions, public.ds_orders from anon, authenticated;

-- ---------- 3. 共用函式 ----------

create or replace function public.ds__id(n int default 12) returns text
language sql volatile set search_path = public as $$
  select substr(translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', 'xyz'), 1, n)
$$;

create or replace function public.ds__fail(msg text, code text default null) returns jsonb
language sql immutable set search_path = public as $$ select jsonb_build_object('ok', false, 'error', msg, 'code', code) $$;

create or replace function public.ds__txt(v jsonb, max_len int) returns text
language sql immutable set search_path = public as $$
  select case when jsonb_typeof(v) = 'string' then left(btrim(v #>> '{}'), max_len) else '' end
$$;

-- 確認空間存在，並記錄最後使用時間
create or replace function public.ds__space(p_space text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_space is null or char_length(p_space) < 12 then return false; end if;
  update public.ds_spaces set active_at = now() where id = p_space and active_at < now() - interval '1 hour';
  return exists (select 1 from public.ds_spaces where id = p_space);
end $$;

-- 依菜單算出訂單內容與價格（加料以目前菜單的加價為準）
create or replace function public.ds__build_order(p_space text, p_shop_id text, p_order jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.ds_shops;
  v_name text := public.ds__txt(p_order->'name', 40);
  v_item text := public.ds__txt(p_order->'item', 100);
  v_size text := public.ds__txt(p_order->'size', 20);
  v_idx int; v_menu jsonb; v_base int; v_tops jsonb := '[]'::jsonb; v_t jsonb; v_tn text; v_hit jsonb;
begin
  if coalesce(jsonb_typeof(p_order), '') <> 'object' then return public.ds__fail('訂單格式錯誤'); end if;
  if v_name = '' then return public.ds__fail('請先選擇或輸入你的姓名'); end if;
  if v_item = '' then return public.ds__fail('請選一杯飲料'); end if;
  select * into s from public.ds_shops where id = p_shop_id and space_id = p_space;
  if not found then return public.ds__fail('這個團的飲料店已被刪除'); end if;
  select (t.ord - 1)::int into v_idx from jsonb_array_elements_text(s.sizes) with ordinality t(v, ord) where t.v = v_size limit 1;
  select e into v_menu from jsonb_array_elements(s.items) e where e->>'n' = v_item limit 1;
  if v_menu is null then return public.ds__fail(format('「%s」已不在菜單上', v_item)); end if;
  if v_idx is null or coalesce(jsonb_typeof(v_menu->'p'->v_idx), '') <> 'number' then
    return public.ds__fail('這個規格沒有販售，請換一個規格');
  end if;
  v_base := (v_menu->'p'->>v_idx)::int;
  if coalesce(jsonb_typeof(coalesce(p_order->'toppings', '[]'::jsonb)), '') <> 'array' then return public.ds__fail('加料格式錯誤'); end if;
  if jsonb_array_length(coalesce(p_order->'toppings', '[]'::jsonb)) > 10 then return public.ds__fail('加料最多 10 種'); end if;
  for v_t in select * from jsonb_array_elements(coalesce(p_order->'toppings', '[]'::jsonb)) loop
    v_tn := case when jsonb_typeof(v_t) = 'object' then v_t->>'n' else v_t #>> '{}' end;
    select e into v_hit from jsonb_array_elements(s.toppings) e where e->>'n' = v_tn limit 1;
    if v_hit is null then return public.ds__fail(format('加料「%s」已不在菜單上', v_tn)); end if;
    if not v_tops @> jsonb_build_array(v_hit) then
      v_tops := v_tops || jsonb_build_array(v_hit);
      v_base := v_base + coalesce((v_hit->>'p')::int, 0);
    end if;
  end loop;
  return jsonb_build_object('ok', true,
    'unit', public.ds__txt(p_order->'unit', 60), 'name', v_name, 'item', v_item, 'size', v_size,
    'price', v_base, 'toppings', v_tops,
    'sugar', public.ds__txt(p_order->'sugar', 20), 'ice', public.ds__txt(p_order->'ice', 20),
    'note', public.ds__txt(p_order->'note', 100));
end $$;

create or replace function public.ds__participants(p jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare v jsonb := '[]'::jsonb; e jsonb; n text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if coalesce(jsonb_typeof(p), '') <> 'array' or jsonb_array_length(p) > 600 then raise exception 'bad participants'; end if;
  for e in select * from jsonb_array_elements(p) loop
    n := public.ds__txt(e->'name', 40);
    if n <> '' then v := v || jsonb_build_array(jsonb_build_object('unit', public.ds__txt(e->'unit', 60), 'name', n)); end if;
  end loop;
  return v;
end $$;

-- ---------- 4. 空間 ----------

create or replace function public.ds_space_create(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text := public.ds__id(16); v_name text := left(btrim(coalesce(p_name, '')), 60);
begin
  if v_name = '' then return public.ds__fail('請輸入空間名稱，例如公司或部門名稱'); end if;
  -- 防止被大量濫建：全系統每分鐘最多 20 個新空間
  if (select count(*) from public.ds_spaces where created_at > now() - interval '1 minute') >= 20 then
    return public.ds__fail('現在建立的人太多，請稍後再試');
  end if;
  insert into public.ds_spaces (id, name) values (v_id, v_name);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.ds_space_rename(p_space text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text := left(btrim(coalesce(p_name, '')), 60);
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if v_name = '' then return public.ds__fail('空間名稱不能空白'); end if;
  update public.ds_spaces set name = v_name where id = p_space;
  return jsonb_build_object('ok', true);
end $$;

-- 刪除整個空間：要輸入正確的空間名稱
create or replace function public.ds_space_delete(p_space text, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if not exists (select 1 from public.ds_spaces where id = p_space and name = btrim(coalesce(p_confirm, ''))) then
    return public.ds__fail('空間名稱不符，沒有刪除');
  end if;
  delete from public.ds_spaces where id = p_space;
  return jsonb_build_object('ok', true);
end $$;

-- 讀取空間的全部資料
create or replace function public.ds_load(p_space text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sp public.ds_spaces;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select * into sp from public.ds_spaces where id = p_space;
  return jsonb_build_object('ok', true,
    'space', jsonb_build_object('id', sp.id, 'name', sp.name),
    'shops', coalesce((select jsonb_agg(to_jsonb(s) - 'space_id' order by s.created_at) from public.ds_shops s where s.space_id = p_space), '[]'::jsonb),
    'units', coalesce((select jsonb_agg(to_jsonb(u) - 'space_id' order by u.ord) from public.ds_units u where u.space_id = p_space), '[]'::jsonb),
    'sessions', coalesce((select jsonb_agg(to_jsonb(x) - 'space_id' order by x.created_at desc) from
      (select * from public.ds_sessions where space_id = p_space order by created_at desc limit 100) x), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(to_jsonb(o) - 'space_id' order by o.created_at, o.id) from
      (select * from public.ds_orders where space_id = p_space order by created_at desc limit 5000) o), '[]'::jsonb));
end $$;

-- ---------- 5. 訂購與開團 ----------

create or replace function public.ds_order_add(p_space text, p_session text, p_order jsonb, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions; o jsonb; i int;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select * into v from public.ds_sessions where id = p_session and space_id = p_space;
  if not found then return public.ds__fail('找不到這個團'); end if;
  if v.status <> 'open' then return public.ds__fail('這個團已經結束訂購了'); end if;
  if p_qty is null or p_qty < 1 or p_qty > 30 then return public.ds__fail('杯數需在 1～30 之間'); end if;
  o := public.ds__build_order(p_space, v.shop_id, p_order);
  if not (o->>'ok')::boolean then return o; end if;
  for i in 1..p_qty loop
    insert into public.ds_orders (id, space_id, session_id, unit, name, item, size, price, toppings, sugar, ice, note)
    values (public.ds__id(12), p_space, v.id, o->>'unit', o->>'name', o->>'item', o->>'size', (o->>'price')::int,
            o->'toppings', o->>'sugar', o->>'ice', o->>'note');
  end loop;
  return jsonb_build_object('ok', true, 'count', p_qty, 'price', (o->>'price')::int);
end $$;

create or replace function public.ds_order_update(p_space text, p_id text, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions; o jsonb;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select s.* into v from public.ds_orders r join public.ds_sessions s on s.id = r.session_id where r.id = p_id and r.space_id = p_space;
  if not found then return public.ds__fail('找不到這筆訂單'); end if;
  if v.status <> 'open' then return public.ds__fail('這個團已經結束訂購了'); end if;
  o := public.ds__build_order(p_space, v.shop_id, p_order);
  if not (o->>'ok')::boolean then return o; end if;
  update public.ds_orders set unit = o->>'unit', name = o->>'name', item = o->>'item', size = o->>'size',
    price = (o->>'price')::int, toppings = o->'toppings', sugar = o->>'sugar', ice = o->>'ice', note = o->>'note'
  where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ds_order_delete(p_space text, p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select s.* into v from public.ds_orders r join public.ds_sessions s on s.id = r.session_id where r.id = p_id and r.space_id = p_space;
  if not found then return jsonb_build_object('ok', true); end if;
  if v.status <> 'open' then return public.ds__fail('這個團已經結束訂購了，不能刪除訂單'); end if;
  delete from public.ds_orders where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ds_session_create(p_space text, p_title text, p_shop text, p_participants jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.ds_shops; v_id text := public.ds__id(10); v_title text := left(btrim(coalesce(p_title, '')), 60);
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if v_title = '' then return public.ds__fail('請輸入團名'); end if;
  select * into s from public.ds_shops where id = p_shop and space_id = p_space;
  if not found then return public.ds__fail('找不到這家飲料店'); end if;
  begin
    insert into public.ds_sessions (id, space_id, title, shop_id, shop_name, participants)
    values (v_id, p_space, v_title, s.id, s.name, public.ds__participants(p_participants));
  exception when others then return public.ds__fail('參加成員名單格式錯誤');
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.ds_session_set_participants(p_space text, p_id text, p_participants jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  begin
    update public.ds_sessions set participants = public.ds__participants(p_participants) where id = p_id and space_id = p_space;
  exception when others then return public.ds__fail('參加成員名單格式錯誤');
  end;
  if not found then return public.ds__fail('找不到這個團'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ds_session_set_status(p_space text, p_id text, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if p_status not in ('open', 'closed') then return public.ds__fail('狀態錯誤'); end if;
  update public.ds_sessions set status = p_status where id = p_id and space_id = p_space;
  if not found then return public.ds__fail('找不到這個團'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 團不能刪除，只能結束訂購（舊版的刪除函式一併移除）
drop function if exists public.ds_session_delete(text, text);

-- ---------- 6. 菜單與名單（有連結的人都能修改） ----------

create or replace function public.ds_shop_save(p_space text, p_shop jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id text; v_name text;
  v_sizes jsonb := '[]'::jsonb; v_items jsonb := '[]'::jsonb; v_tops jsonb := '[]'::jsonb;
  x jsonb; n text; p jsonb; i int; v_p jsonb;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if coalesce(jsonb_typeof(p_shop), '') <> 'object' then return public.ds__fail('店家資料格式錯誤'); end if;
  v_name := public.ds__txt(p_shop->'name', 60);
  if v_name = '' then return public.ds__fail('店名不能空白'); end if;
  if coalesce(jsonb_typeof(p_shop->'sizes'), '') <> 'array' or jsonb_array_length(p_shop->'sizes') not between 1 and 8 then
    return public.ds__fail('規格需要 1～8 個');
  end if;
  for x in select * from jsonb_array_elements(p_shop->'sizes') loop
    n := public.ds__txt(x, 20);
    v_sizes := v_sizes || to_jsonb(case when n = '' then '規格' else n end);
  end loop;
  if coalesce(jsonb_typeof(coalesce(p_shop->'items', '[]'::jsonb)), '') <> 'array' or jsonb_array_length(coalesce(p_shop->'items', '[]'::jsonb)) > 500 then
    return public.ds__fail('品項最多 500 個');
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_shop->'items', '[]'::jsonb)) loop
    n := public.ds__txt(x->'n', 100);
    if n = '' then continue; end if;
    v_p := '[]'::jsonb;
    for i in 0 .. jsonb_array_length(v_sizes) - 1 loop
      p := x->'p'->i;
      v_p := v_p || case when jsonb_typeof(p) = 'number' and (p #>> '{}')::numeric between 0 and 100000
                         then to_jsonb(round((p #>> '{}')::numeric)::int) else 'null'::jsonb end;
    end loop;
    v_items := v_items || jsonb_build_array(jsonb_build_object('n', n, 'p', v_p));
  end loop;
  if coalesce(jsonb_typeof(coalesce(p_shop->'toppings', '[]'::jsonb)), '') <> 'array' or jsonb_array_length(coalesce(p_shop->'toppings', '[]'::jsonb)) > 60 then
    return public.ds__fail('加料最多 60 種');
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_shop->'toppings', '[]'::jsonb)) loop
    n := public.ds__txt(x->'n', 40);
    if n = '' then continue; end if;
    p := x->'p';
    v_tops := v_tops || jsonb_build_array(jsonb_build_object('n', n, 'p',
      case when jsonb_typeof(p) = 'number' then least(1000, greatest(0, round((p #>> '{}')::numeric)::int)) else 0 end));
  end loop;

  v_id := nullif(public.ds__txt(p_shop->'id', 40), '');
  if v_id is null then
    if (select count(*) from public.ds_shops where space_id = p_space) >= 100 then return public.ds__fail('每個空間最多 100 家店'); end if;
    v_id := public.ds__id(10);
    insert into public.ds_shops (id, space_id, name, phone, sizes, items, toppings)
    values (v_id, p_space, v_name, public.ds__txt(p_shop->'phone', 30), v_sizes, v_items, v_tops);
  else
    update public.ds_shops set name = v_name, phone = public.ds__txt(p_shop->'phone', 30),
      sizes = v_sizes, items = v_items, toppings = v_tops
    where id = v_id and space_id = p_space;
    if not found then return public.ds__fail('找不到這家飲料店，可能已被刪除'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.ds_shop_delete(p_space text, p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  delete from public.ds_shops where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

-- 儲存整份名單：依順序寫入，清單裡沒有的單位會被刪除
create or replace function public.ds_roster_save(p_space text, p_units jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; m jsonb; n text; v_id text; v_members jsonb; v_names text[] := '{}'; i int := 0;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if coalesce(jsonb_typeof(p_units), '') <> 'array' or jsonb_array_length(p_units) > 200 then return public.ds__fail('名單格式錯誤'); end if;
  for x in select * from jsonb_array_elements(p_units) loop
    n := public.ds__txt(x->'name', 60);
    if n = '' then return public.ds__fail('單位名稱不能空白'); end if;
    if n = any(v_names) then return public.ds__fail(format('單位「%s」重複了', n)); end if;
    v_names := v_names || n;
  end loop;
  -- 先刪掉清單裡沒有的單位，再把留下的單位改成暫時名稱，避免改名互換或同名新增時撞到 unique
  delete from public.ds_units where space_id = p_space
    and id not in (select x->>'id' from jsonb_array_elements(p_units) x where x->>'id' is not null);
  update public.ds_units set name = '~' || id where space_id = p_space;
  for x in select * from jsonb_array_elements(p_units) loop
    n := public.ds__txt(x->'name', 60);
    v_members := '[]'::jsonb;
    if jsonb_typeof(x->'members') = 'array' then
      for m in select * from jsonb_array_elements(x->'members') loop
        if public.ds__txt(m, 40) <> '' and not v_members @> to_jsonb(public.ds__txt(m, 40)) and jsonb_array_length(v_members) < 300 then
          v_members := v_members || to_jsonb(public.ds__txt(m, 40));
        end if;
      end loop;
    end if;
    v_id := nullif(public.ds__txt(x->'id', 40), '');
    if v_id is not null and exists (select 1 from public.ds_units where id = v_id and space_id = p_space) then
      update public.ds_units set name = n, members = v_members, ord = i where id = v_id and space_id = p_space;
    else
      insert into public.ds_units (id, space_id, name, members, ord) values (public.ds__id(10), p_space, n, v_members, i);
    end if;
    i := i + 1;
  end loop;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 7. 權限：內部函式不給網頁呼叫 ----------
revoke execute on function public.ds__id(int) from public, anon, authenticated;
revoke execute on function public.ds__space(text) from public, anon, authenticated;
revoke execute on function public.ds__build_order(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.ds__participants(jsonb) from public, anon, authenticated;
