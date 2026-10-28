-- =====================================================================
-- 升級 04：加入「餐點」（炸物、烤肉、蛋糕點心…），一個團可以同時有飲料店與餐點店
-- 已經用舊版 setup.sql 建好資料庫的，在 SQL Editor 貼上全部內容 → Run（可重複執行，不會清掉資料）。
-- 新安裝的直接執行最新的 setup.sql 就好，不用執行這個檔案。
-- =====================================================================

alter table public.ds_shops add column if not exists kind text not null default 'drink' check (kind in ('drink', 'meal'));
alter table public.ds_sessions add column if not exists extra_shop_ids jsonb not null default '[]'::jsonb;
alter table public.ds_orders add column if not exists shop_id text not null default '';
-- 舊訂單補上所屬店家（原本一個團只有一家店）
update public.ds_orders o set shop_id = s.shop_id from public.ds_sessions s where o.session_id = s.id and o.shop_id = '';

create or replace function public.ds__build_order(p_space text, p_shop_id text, p_order jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.ds_shops;
  v_name text := public.ds__txt(p_order->'name', 40);
  v_item text := public.ds__txt(p_order->'item', 100);
  v_size text := public.ds__txt(p_order->'size', 20);
  v_custom boolean := coalesce(p_order->'custom' = 'true'::jsonb, false);
  v_idx int; v_menu jsonb; v_base int; v_tops jsonb := '[]'::jsonb; v_t jsonb; v_tn text; v_hit jsonb;
begin
  if coalesce(jsonb_typeof(p_order), '') <> 'object' then return public.ds__fail('訂單格式錯誤'); end if;
  if v_name = '' then return public.ds__fail('請先選擇或輸入你的姓名'); end if;
  if v_item = '' then return public.ds__fail(case when v_custom then '請輸入品名' else '請先選一個品項' end); end if;
  select * into s from public.ds_shops where id = p_shop_id and space_id = p_space;
  if not found then return public.ds__fail('這個團的店家已被刪除'); end if;
  if v_custom then
    -- 菜單上沒有的品項（例如季節限定）：品名與單價由訂購人填寫
    if v_size <> '' and not (s.sizes ? v_size) then return public.ds__fail('規格不正確，請重新選擇'); end if;
    if coalesce(jsonb_typeof(p_order->'price'), '') <> 'number' or (p_order->>'price')::numeric not between 1 and 2000 then
      return public.ds__fail('請輸入這個品項的價格（1～2000 元）');
    end if;
    v_base := round((p_order->>'price')::numeric)::int;
  else
    select (t.ord - 1)::int into v_idx from jsonb_array_elements_text(s.sizes) with ordinality t(v, ord) where t.v = v_size limit 1;
    select e into v_menu from jsonb_array_elements(s.items) e where e->>'n' = v_item limit 1;
    if v_menu is null then return public.ds__fail(format('「%s」已不在菜單上，可以改用「自己輸入」', v_item)); end if;
    if v_idx is null or coalesce(jsonb_typeof(v_menu->'p'->v_idx), '') <> 'number' then
      return public.ds__fail('這個規格沒有販售，請換一個規格');
    end if;
    v_base := (v_menu->'p'->>v_idx)::int;
  end if;
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
    'sugar', case when s.kind = 'meal' then '' else public.ds__txt(p_order->'sugar', 20) end,
    'ice', case when s.kind = 'meal' then '' else public.ds__txt(p_order->'ice', 20) end,
    'note', public.ds__txt(p_order->'note', 100), 'custom', v_custom);
end $$;

create or replace function public.ds__extra_shops(p_space text, p_primary text, p_extra jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'::jsonb; e jsonb; v_id text;
begin
  if p_extra is null or jsonb_typeof(p_extra) = 'null' then return v; end if;
  if jsonb_typeof(p_extra) <> 'array' or jsonb_array_length(p_extra) > 10 then raise exception 'bad shops'; end if;
  for e in select * from jsonb_array_elements(p_extra) loop
    v_id := public.ds__txt(e, 40);
    if v_id = '' or v_id = p_primary or v @> to_jsonb(v_id) then continue; end if;
    if not exists (select 1 from public.ds_shops where ds_shops.id = v_id and ds_shops.space_id = p_space) then raise exception 'unknown shop'; end if;
    v := v || to_jsonb(v_id);
  end loop;
  return v;
end $$;

revoke execute on function public.ds__build_order(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.ds__extra_shops(text, text, jsonb) from public, anon, authenticated;

create or replace function public.ds_order_add(p_space text, p_session text, p_order jsonb, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions; o jsonb; i int; v_shop text;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select * into v from public.ds_sessions where id = p_session and space_id = p_space;
  if not found then return public.ds__fail('找不到這個團'); end if;
  if v.status <> 'open' then return public.ds__fail('這個團已經結束訂購了'); end if;
  if p_qty is null or p_qty < 1 or p_qty > 30 then return public.ds__fail('數量需在 1～30 之間'); end if;
  -- 訂單指定的店家必須是這個團的店家；沒指定就是主要店家
  v_shop := coalesce(nullif(public.ds__txt(p_order->'shop_id', 40), ''), v.shop_id);
  if v_shop <> v.shop_id and not (v.extra_shop_ids @> to_jsonb(v_shop)) then return public.ds__fail('這家店不在這個團裡'); end if;
  o := public.ds__build_order(p_space, v_shop, p_order);
  if not (o->>'ok')::boolean then return o; end if;
  for i in 1..p_qty loop
    insert into public.ds_orders (id, space_id, session_id, shop_id, unit, name, item, size, price, toppings, sugar, ice, note, custom)
    values (public.ds__id(12), p_space, v.id, v_shop, o->>'unit', o->>'name', o->>'item', o->>'size', (o->>'price')::int,
            o->'toppings', o->>'sugar', o->>'ice', o->>'note', (o->>'custom')::boolean);
  end loop;
  return jsonb_build_object('ok', true, 'count', p_qty, 'price', (o->>'price')::int);
end $$;

create or replace function public.ds_order_update(p_space text, p_id text, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions; o jsonb; v_shop text;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select s.* into v from public.ds_orders r join public.ds_sessions s on s.id = r.session_id where r.id = p_id and r.space_id = p_space;
  if not found then return public.ds__fail('找不到這筆訂單'); end if;
  if v.status <> 'open' then return public.ds__fail('這個團已經結束訂購了'); end if;
  v_shop := coalesce(nullif(public.ds__txt(p_order->'shop_id', 40), ''), v.shop_id);
  if v_shop <> v.shop_id and not (v.extra_shop_ids @> to_jsonb(v_shop)) then return public.ds__fail('這家店不在這個團裡'); end if;
  o := public.ds__build_order(p_space, v_shop, p_order);
  if not (o->>'ok')::boolean then return o; end if;
  update public.ds_orders set shop_id = v_shop, unit = o->>'unit', name = o->>'name', item = o->>'item', size = o->>'size',
    price = (o->>'price')::int, toppings = o->'toppings', sugar = o->>'sugar', ice = o->>'ice', note = o->>'note',
    custom = (o->>'custom')::boolean
  where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.ds_session_create(text, text, text, jsonb);
create or replace function public.ds_session_create(p_space text, p_title text, p_shop text, p_participants jsonb, p_extra_shops jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.ds_shops; v_id text := public.ds__id(10); v_title text := left(btrim(coalesce(p_title, '')), 60); v_extra jsonb;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if v_title = '' then return public.ds__fail('請輸入團名'); end if;
  select * into s from public.ds_shops where id = p_shop and space_id = p_space;
  if not found then return public.ds__fail('找不到這家店'); end if;
  begin
    v_extra := public.ds__extra_shops(p_space, s.id, p_extra_shops);
  exception when others then return public.ds__fail('加開的店家不存在，請重新選擇');
  end;
  begin
    insert into public.ds_sessions (id, space_id, title, shop_id, shop_name, participants, extra_shop_ids)
    values (v_id, p_space, v_title, s.id, s.name, public.ds__participants(p_participants), v_extra);
  exception when others then return public.ds__fail('參加成員名單格式錯誤');
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.ds_session_set_shops(p_space text, p_id text, p_shops jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions; s public.ds_shops; v_extra jsonb; v_bad text;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select * into v from public.ds_sessions where id = p_id and space_id = p_space;
  if not found then return public.ds__fail('找不到這個團'); end if;
  if coalesce(jsonb_typeof(p_shops), '') <> 'array' or jsonb_array_length(p_shops) < 1 then return public.ds__fail('請至少選一家店'); end if;
  select * into s from public.ds_shops where id = public.ds__txt(p_shops->0, 40) and space_id = p_space;
  if not found then return public.ds__fail('找不到這家店'); end if;
  begin
    v_extra := public.ds__extra_shops(p_space, s.id, p_shops - 0);
  exception when others then return public.ds__fail('店家不存在，請重新選擇');
  end;
  select r.shop_id into v_bad from public.ds_orders r
  where r.session_id = p_id and r.space_id = p_space and r.shop_id <> '' and r.shop_id <> s.id and not (v_extra @> to_jsonb(r.shop_id)) limit 1;
  if v_bad is not null then
    return public.ds__fail(format('「%s」已經有人訂了，不能從這個團移除', coalesce((select name from public.ds_shops where id = v_bad), '這家店')));
  end if;
  update public.ds_sessions set shop_id = s.id, shop_name = s.name, extra_shop_ids = v_extra where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ds_shop_save(p_space text, p_shop jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id text; v_name text;
  v_sizes jsonb := '[]'::jsonb; v_items jsonb := '[]'::jsonb; v_tops jsonb := '[]'::jsonb;
  v_kind text; v_cat text;
  x jsonb; n text; p jsonb; i int; v_p jsonb;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  if coalesce(jsonb_typeof(p_shop), '') <> 'object' then return public.ds__fail('店家資料格式錯誤'); end if;
  v_kind := public.ds__txt(p_shop->'kind', 10);
  if v_kind not in ('drink', 'meal') then v_kind := null; end if;  -- 沒帶 = 維持原本的種類（新增時是飲料店）
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
    v_cat := public.ds__txt(x->'c', 20);
    v_items := v_items || jsonb_build_array(jsonb_build_object('n', n, 'p', v_p)
      || case when v_cat <> '' then jsonb_build_object('c', v_cat) else '{}'::jsonb end);
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
    insert into public.ds_shops (id, space_id, name, phone, sizes, items, toppings, kind)
    values (v_id, p_space, v_name, public.ds__txt(p_shop->'phone', 30), v_sizes, v_items, v_tops, coalesce(v_kind, 'drink'));
  else
    update public.ds_shops set name = v_name, phone = public.ds__txt(p_shop->'phone', 30),
      sizes = v_sizes, items = v_items, toppings = v_tops, kind = coalesce(v_kind, kind)
    where id = v_id and space_id = p_space;
    if not found then return public.ds__fail('找不到這家店，可能已被刪除'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
