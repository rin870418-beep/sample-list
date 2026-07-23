-- ============================================================
--  명단 취소 기능 추가 (2026-07-23)
--  Supabase 대시보드 → SQL Editor 에 "이 파일만" 붙여넣고 [Run] 한 번.
--  ⚠ schema.sql 전체를 다시 돌리지 마세요 — 테이블이 삭제됩니다.
--  이 스크립트는 함수만 만들 뿐 데이터를 건드리지 않습니다.
-- ============================================================
create or replace function unclaim(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pid text;
  v_key text;
begin
  delete from submissions where id = p_id
    returning product_id, size_key into v_pid, v_key;
  if v_pid is null then return; end if;   -- 이미 삭제된 행이면 조용히 종료
  update size_counts set claimed = greatest(0, claimed - 1)
    where product_id = v_pid and size_key = v_key;
end;
$$;

revoke all on function unclaim(bigint) from anon, public;
grant execute on function unclaim(bigint) to authenticated;
