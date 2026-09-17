-- v3.0.130: 管理者専用の曲登録依頼一覧（補足・送信者名を含む）。
-- Supabase SQL Editor で実行してください。
create or replace function public.admin_list_song_requests(p_search text default '')
returns table (
  id uuid, user_id uuid, genre text, title text, artist text,
  chart text, level integer, note text, status text,
  created_at timestamptz, username text
)
language sql stable security definer
set search_path = ''
as $function$
  select r.id, r.user_id, r.genre, r.title, r.artist,
         r.chart, r.level, r.note, r.status, r.created_at, p.username
  from public.song_requests r
  left join public.profiles p on p.id = r.user_id
  where (select public.is_admin())
    and r.status = 'pending'
    and (coalesce(p_search, '') = ''
      or r.title ilike '%' || p_search || '%'
      or r.genre ilike '%' || p_search || '%'
      or r.artist ilike '%' || p_search || '%'
      or coalesce(p.username, '') ilike '%' || p_search || '%')
  order by r.created_at desc
  limit 500
$function$;
revoke all on function public.admin_list_song_requests(text) from PUBLIC, anon;
grant execute on function public.admin_list_song_requests(text) to authenticated;
