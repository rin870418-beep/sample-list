-- ============================================================
--  공개대상(#1) 기준으로 되돌리기 (2026-07-23)
--  Supabase 대시보드 → SQL Editor 에 "이 파일만" 붙여넣고 [Run] 한 번.
--
--  왜: 오늘 buyers-migration.sql 이 claim() 을 "초대명단(buyers)에
--      등록된 아이디만 주문 가능" 으로 바꿔놨습니다. 그래서 공개대상
--      아이디로는 NOT_INVITED 로 막혔습니다. 이 스크립트는 claim() 을
--      원래의 "상품별 공개대상(allowList) + 개인 한도" 방식으로 되돌립니다.
--
--  · buyers 테이블/buyer_status 함수는 그대로 두어도 됩니다(이제 안 쓰임).
--  · products / submissions / photos 데이터는 건드리지 않습니다.
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
