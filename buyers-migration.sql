-- ============================================================
--  초대제 + 지갑식 수량 관리 (2026-07-23)
--  Supabase 대시보드 → SQL Editor 에 "이 파일만" 붙여넣고 [Run] 한 번.
--  ⚠ schema.sql 전체를 다시 돌리지 마세요 — 테이블이 삭제됩니다.
--  이 스크립트는 buyers 테이블을 새로 만들고 claim() 을 교체할 뿐,
--  기존 products / submissions / photos 데이터는 건드리지 않습니다.
--
--  동작 요약
--   · buyers 에 등록된(초대된) 아이디만 주문 가능        → 아니면 NOT_INVITED
--   · quota = 전 상품 "통틀어" 총 허용 수량(지갑)         → 초과면 LIMIT
--   · 지갑을 다 쓰면 그 아이디는 자동으로 opened=false    → "완료" 처리
-- ============================================================

-- 1) buyers : 초대된 아이디별 지갑(총 허용 수량) + on/off 스위치
create table if not exists buyers (
  id         text primary key,           -- 정규화된 인스타 아이디 (소문자, @ 제거)
  quota      int     not null default 1, -- 전 상품 통틀어 총 허용 수량
  opened     boolean not null default true,
  note       text    default '',
  created_at timestamptz default now()
);

alter table buyers enable row level security;
drop policy if exists buyers_read  on buyers;
drop policy if exists buyers_write on buyers;
-- 전체 명단은 손님에게 노출하지 않음 → 읽기·쓰기 모두 관리자(로그인)만.
-- 손님은 아래 buyer_status() RPC 로 "자기 아이디 상태"만 확인.
create policy buyers_read  on buyers for select using (auth.uid() is not null);
create policy buyers_write on buyers for all
  using (auth.uid() is not null) with check (auth.uid() is not null);

-- realtime : 관리자 화면에서 실시간 반영
do $$
begin
  begin alter publication supabase_realtime add table buyers; exception when duplicate_object then null; end;
end $$;

-- ============================================================
-- 2) buyer_status(id) : 손님 입장 시 "자기 아이디 상태"만 안전하게 조회
--    전체 명단 노출 없이 → {invited, opened, quota, used, remaining}
-- ============================================================
create or replace function buyer_status(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key  text := lower(replace(coalesce(p_id, ''), '@', ''));
  v_row  buyers%rowtype;
  v_used int;
begin
  if v_key = '' then
    return jsonb_build_object('invited', false);
  end if;
  select * into v_row from buyers where id = v_key;
  if v_row.id is null then
    return jsonb_build_object('invited', false);
  end if;
  select count(*) into v_used from submissions
    where lower(replace(buyer, '@', '')) = v_key;
  return jsonb_build_object(
    'invited',   true,
    'opened',    v_row.opened,
    'quota',     v_row.quota,
    'used',      v_used,
    'remaining', greatest(0, v_row.quota - v_used)
  );
end;
$$;
grant execute on function buyer_status(text) to anon, authenticated;

-- ============================================================
-- 3) claim() 교체 : 초대제 + 지갑식(전 상품 통틀어) + 소진 시 자동 OFF
--    성공 시 새 확정수량 반환.
--    실패 예외: NOT_INVITED / LIMIT / SOLD_OUT / NO_SIZE
-- ============================================================
create or replace function claim(
  p_product_id text,
  p_size_key   text,
  p_buyer      text,
  p_opt        jsonb,
  p_ship       jsonb
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc     jsonb;
  v_qty     int;
  v_claimed int;
  v_quota   int;
  v_opened  boolean;
  v_mine    int;
  v_key     text := lower(replace(p_buyer, '@', ''));
begin
  -- 초대 여부 확인 (buyers 에 등록돼 있어야 함) + 행 잠금
  select quota, opened into v_quota, v_opened
    from buyers where id = v_key for update;
  if v_quota is null then raise exception 'NOT_INVITED'; end if;

  -- 상품 정의 잠금
  select doc into v_doc from products where id = p_product_id for update;
  if v_doc is null then raise exception 'NO_SIZE'; end if;

  -- 이 옵션(size_key)의 정원(qty)
  select (elem->>'qty')::int into v_qty
    from jsonb_array_elements(v_doc->'sizes') elem
    where elem->>'key' = p_size_key
    limit 1;
  if v_qty is null then raise exception 'NO_SIZE'; end if;

  -- 지갑: 전 상품 통틀어 이 아이디가 이미 쓴 수량 (소진 시 LIMIT)
  select count(*) into v_mine from submissions
    where lower(replace(buyer, '@', '')) = v_key;
  if v_mine >= v_quota then raise exception 'LIMIT'; end if;

  -- 소진은 아니지만 관리자가 수동으로 꺼둔(opened=false) 아이디는 차단
  if not v_opened then raise exception 'NOT_INVITED'; end if;

  -- 재고 잠금 & 확인
  insert into size_counts (product_id, size_key, claimed)
    values (p_product_id, p_size_key, 0)
    on conflict (product_id, size_key) do nothing;
  select claimed into v_claimed from size_counts
    where product_id = p_product_id and size_key = p_size_key for update;
  if v_claimed >= v_qty then raise exception 'SOLD_OUT'; end if;

  -- 확정
  insert into submissions (product_id, size_key, buyer, opt, ship)
    values (p_product_id, p_size_key, p_buyer,
            coalesce(p_opt, '{}'::jsonb), coalesce(p_ship, '{}'::jsonb));
  update size_counts set claimed = claimed + 1
    where product_id = p_product_id and size_key = p_size_key;

  -- 지갑 소진 시 자동 OFF (완료 처리) → 이후 이 아이디로는 주문 불가
  if v_mine + 1 >= v_quota then
    update buyers set opened = false where id = v_key;
  end if;

  return v_claimed + 1;
end;
$$;
grant execute on function claim(text, text, text, jsonb, jsonb) to anon, authenticated;
