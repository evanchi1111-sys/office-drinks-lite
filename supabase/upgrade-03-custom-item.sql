-- =====================================================================
-- 升級 03：訂購時可以自行輸入菜單上沒有的品項（例如季節限定）
-- 用法：Supabase → SQL Editor → New query → 貼上 → Run（可重複執行）
-- =====================================================================

alter table public.ds_orders add column if not exists custom boolean not null default false;

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
  if v_item = '' then return public.ds__fail(case when v_custom then '請輸入飲料名稱' else '請選一杯飲料' end); end if;
  select * into s from public.ds_shops where id = p_shop_id and space_id = p_space;
  if not found then return public.ds__fail('這個團的飲料店已被刪除'); end if;
  if v_custom then
    -- 菜單上沒有的品項（例如季節限定）：品名與單杯價格由訂購人填寫
    if v_size <> '' and not (s.sizes ? v_size) then return public.ds__fail('規格不正確，請重新選擇'); end if;
    if coalesce(jsonb_typeof(p_order->'price'), '') <> 'number' or (p_order->>'price')::numeric not between 1 and 2000 then
      return public.ds__fail('請輸入這杯飲料的價格（1～2000 元）');
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
    'sugar', public.ds__txt(p_order->'sugar', 20), 'ice', public.ds__txt(p_order->'ice', 20),
    'note', public.ds__txt(p_order->'note', 100), 'custom', v_custom);
end $$;

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
    insert into public.ds_orders (id, space_id, session_id, unit, name, item, size, price, toppings, sugar, ice, note, custom)
    values (public.ds__id(12), p_space, v.id, o->>'unit', o->>'name', o->>'item', o->>'size', (o->>'price')::int,
            o->'toppings', o->>'sugar', o->>'ice', o->>'note', (o->>'custom')::boolean);
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
    price = (o->>'price')::int, toppings = o->'toppings', sugar = o->>'sugar', ice = o->>'ice', note = o->>'note',
    custom = (o->>'custom')::boolean
  where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.ds__build_order(text, text, jsonb) from public, anon, authenticated;
