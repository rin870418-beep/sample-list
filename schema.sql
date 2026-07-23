-- ============================================================
--  샘플 리스트 — Supabase 스키마 (확정본)
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 [Run] 한 번.
--
--  안전: 아직 매장이 오픈 전이라 products/submissions/photos 에는
--  실데이터가 없습니다. 아래는 그 3개를 깨끗이 재생성합니다.
--  settings(설정 1행)는 보존합니다.
--  ⚠ 이미 손님 주문/사진이 쌓인 뒤라면 이 스크립트를 돌리지 마세요.
-- ============================================================

-- 1) 비어있는 테이블 정리 (settings 는 건드리지 않음)
drop table if exists photos       cascade;
drop table if exists submissions  cascade;
drop table if exists size_counts  cascade;
drop table if exists products     cascade;

-- 2) products : 상품 "정의"만 통짜 JSON 으로 (claims/gallery 제외)
create table products (
  id         text primary key,
  doc        jsonb not null,          -- {name,desc,copyForm,images,sizes:[{key,label,qty,...}],deadline,perPerson,closed,...}
  sort       double precision default 0,
  updated_at timestamptz default now()
);

-- 3) size_counts : 옵션별 확정 수량 (개인정보 없음 → 손님도 읽기 가능)
create table size_counts (
  product_id text not null references products(id) on delete cascade,
  size_key   text not null,
  claimed    int  not null default 0,
  primary key (product_id, size_key)
);

-- 4) submissions : 손님 신청 1건 = 1행 (배송정보 포함 → 관리자만 읽기)
create table submissions (
  id         bigint generated always as identity primary key,
  product_id text not null references products(id) on delete cascade,
  size_key   text not null,
  buyer      text not null,
  opt        jsonb not null default '{}'::jsonb,
  ship       jsonb not null default '{}'::jsonb,
  created_at timestamptz default now()
);
create index on submissions (product_id);

-- 5) photos : 손님이 올린 사진 메타 (실파일은 Storage) → 관리자만 읽기
create table photos (
  id         text primary key,
  product_id text not null references products(id) on delete cascade,
  buyer      text,
  size       text,
  msg        text,
  filename   text,
  mime       text,
  bytes      bigint,
  path       text,        -- Storage 안의 경로
  sent       boolean default false,
  created_at timestamptz default now()
);
create index on photos (product_id);

-- 6) settings : 이미 있으면 보존, 없으면 생성 + 필요한 컬럼 보장
create table if not exists settings (
  id        int primary key default 1,
  title     text default '샘플 리스트',
  subtitle  text default '',
  email1    text default '',
  email2    text default '',
  w3key     text default '',
  admin_ids text default '',
  tr        jsonb default '{}'::jsonb
);
insert into settings (id) values (1) on conflict (id) do nothing;

-- ============================================================
--  7) claim() : 원자적 신청 — 재고초과·개인한도 초과를 서버가 막음
--     성공 시 새 확정수량 반환, 실패 시 예외(SOLD_OUT / LIMIT / NO_SIZE)
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
  v_limit   int;
  v_ov      int;
  v_mine    int;
  v_key     text := lower(replace(p_buyer, '@', ''));
begin
  -- 상품 정의 잠금 (동시 신청 직렬화 지점 중 하나)
  select doc into v_doc from products where id = p_product_id for update;
  if v_doc is null then raise exception 'NO_SIZE'; end if;

  -- 이 옵션(size_key)의 정원(qty)
  select (elem->>'qty')::int into v_qty
    from jsonb_array_elements(v_doc->'sizes') elem
    where elem->>'key' = p_size_key
    limit 1;
  if v_qty is null then raise exception 'NO_SIZE'; end if;

  -- 개인 한도: perPerson, allowList 로 지정된 아이디는 그 cnt 로 상향
  v_limit := greatest(1, coalesce((v_doc->>'perPerson')::int, 1));
  select greatest(1, (a->>'cnt')::int) into v_ov
    from jsonb_array_elements(coalesce(v_doc->'allowList', '[]'::jsonb)) a
    where a->>'cnt' is not null
      and lower(replace(a->>'id', '@', '')) = v_key
    limit 1;
  if v_ov is not null then v_limit := v_ov; end if;

  select count(*) into v_mine from submissions
    where product_id = p_product_id
      and lower(replace(buyer, '@', '')) = v_key;
  if v_mine >= v_limit then raise exception 'LIMIT'; end if;

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

  return v_claimed + 1;
end;
$$;

grant execute on function claim(text, text, text, jsonb, jsonb) to anon, authenticated;

-- ============================================================
--  7-b) unclaim() : 관리자가 명단에서 1건 취소 — submissions 삭제 + 재고 -1
--       (claim 의 짝. 관리자만 실행. 손님(anon)은 호출 불가)
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

-- ============================================================
--  8) RLS (행 수준 보안)
-- ============================================================
alter table products     enable row level security;
alter table size_counts  enable row level security;
alter table submissions  enable row level security;
alter table photos       enable row level security;
alter table settings     enable row level security;

-- products : 누구나 읽기 / 관리자(로그인)만 쓰기
drop policy if exists products_read  on products;
drop policy if exists products_write on products;
create policy products_read  on products for select using (true);
create policy products_write on products for all
  using (auth.uid() is not null) with check (auth.uid() is not null);

-- size_counts : 누구나 읽기 / 직접 쓰기 없음 (claim RPC 가 owner 권한으로만 변경)
drop policy if exists counts_read on size_counts;
create policy counts_read on size_counts for select using (true);

-- submissions : 관리자만 읽기 / 직접 insert 없음 (claim RPC 경유)
drop policy if exists subs_read on submissions;
create policy subs_read on submissions for select
  using (auth.uid() is not null);

-- photos : 손님 업로드(insert)만 익명 허용 / 읽기·삭제는 관리자
drop policy if exists photos_insert on photos;
drop policy if exists photos_read   on photos;
drop policy if exists photos_delete on photos;
create policy photos_insert on photos for insert with check (true);
create policy photos_read   on photos for select using (auth.uid() is not null);
create policy photos_delete on photos for delete using (auth.uid() is not null);

-- settings : 누구나 읽기(제목·안내문 표시용) / 관리자만 수정
drop policy if exists settings_read  on settings;
drop policy if exists settings_write on settings;
create policy settings_read  on settings for select using (true);
create policy settings_write on settings for all
  using (auth.uid() is not null) with check (auth.uid() is not null);

-- ============================================================
--  9) Storage 버킷 sample-photos (public) + 정책
-- ============================================================
insert into storage.buckets (id, name, public)
  values ('sample-photos', 'sample-photos', true)
  on conflict (id) do update set public = true;

drop policy if exists sp_insert on storage.objects;
drop policy if exists sp_read   on storage.objects;
drop policy if exists sp_delete on storage.objects;
create policy sp_insert on storage.objects for insert
  with check (bucket_id = 'sample-photos');
create policy sp_read on storage.objects for select
  using (bucket_id = 'sample-photos');
create policy sp_delete on storage.objects for delete
  using (bucket_id = 'sample-photos' and auth.uid() is not null);

-- ============================================================
--  10) Realtime : 이 테이블들의 변경을 브라우저로 실시간 푸시
-- ============================================================
do $$
begin
  begin alter publication supabase_realtime add table products;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table size_counts; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table submissions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table photos;      exception when duplicate_object then null; end;
end $$;
