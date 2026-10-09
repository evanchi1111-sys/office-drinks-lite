// Supabase 專案設定（與其他系統共用同一個專案，本系統資料表以 ds_ 開頭）。
// 這兩個值本來就是公開的；真正的安全由資料庫規則（supabase/setup.sql）把關。
// 注意：千萬不要貼上 service_role / secret key。
export const SUPABASE_URL = 'https://agquezkmsyehabgjuwqk.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_pqBCZYPukEOYslnHpaCIEQ_teG22t5D';
