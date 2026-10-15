-- =====================================================================
-- 升級 01：可以刪除「已結束」的團（含訂單）
-- 用法：Supabase → SQL Editor → New query → 貼上 → Run（可重複執行）
-- =====================================================================

create or replace function public.ds_session_delete(p_space text, p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ds_sessions;
begin
  if not public.ds__space(p_space) then return public.ds__fail('找不到這個空間，連結可能有誤', 'space'); end if;
  select * into v from public.ds_sessions where id = p_id and space_id = p_space;
  if not found then return jsonb_build_object('ok', true); end if;
  if v.status <> 'closed' then return public.ds__fail('只能刪除已結束的團，請先按「結束訂購」'); end if;
  delete from public.ds_sessions where id = p_id and space_id = p_space;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.ds_session_delete(text, text) to anon, authenticated;
