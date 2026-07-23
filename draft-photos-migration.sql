-- ============================================================
--  시안(디자인 초안) 사진 첨부 기능 — photos 테이블에 kind 컬럼 추가
--  Supabase 대시보드 → SQL Editor 에 붙여넣고 [Run] 한 번.
--  기존 사진은 모두 'item'(받은 상품 사진)으로 유지되고,
--  신청 시 첨부하는 시안 사진만 kind='draft' 로 저장된다.
-- ============================================================

alter table photos add column if not exists kind text not null default 'item';

-- (선택) 조회 편의를 위한 인덱스
create index if not exists photos_product_kind_idx on photos (product_id, kind);
