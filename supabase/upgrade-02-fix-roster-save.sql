-- =====================================================================
-- 升級 02：修正「儲存名單」出錯（column reference "x" is ambiguous）
-- 用法：Supabase → SQL Editor → New query → 貼上 → Run（可重複執行）
-- =====================================================================

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
    and id not in (select elem->>'id' from jsonb_array_elements(p_units) elem where elem->>'id' is not null);
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
