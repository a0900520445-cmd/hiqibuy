-- 在 migration_006.sql 之後執行。商品平均評分、評論數、瀏覽數。

alter table merchant_products
  add column if not exists rating_avg numeric(2,1) not null default 0,
  add column if not exists rating_count int not null default 0,
  add column if not exists views int not null default 0;

-- 評論新增 / 修改 / 刪除時自動更新該商品的平均評分
create or replace function refresh_rating() returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid := coalesce(new.product_id, old.product_id);
begin
  update merchant_products set
    rating_avg = coalesce((select round(avg(rating)::numeric, 1) from product_reviews where product_id = pid), 0),
    rating_count = (select count(*) from product_reviews where product_id = pid)
  where id = pid;
  return null;
end $$;
create trigger trg_rating after insert or update or delete on product_reviews for each row execute function refresh_rating();
update merchant_products p set
  rating_avg = coalesce((select round(avg(rating)::numeric, 1) from product_reviews where product_id = p.id), 0),
  rating_count = (select count(*) from product_reviews where product_id = p.id);

-- 瀏覽數(只有後端能呼叫)
create or replace function increment_views(p_id uuid) returns void language sql security definer set search_path = public as $$
  update merchant_products set views = views + 1 where id = p_id $$;
revoke execute on function increment_views(uuid) from public, anon, authenticated;

-- 防止商家用公開的 anon key 直接竄改系統統計欄位(評分、瀏覽數、已售數量)
create or replace function guard_product_counters() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.rating_avg := 0; new.rating_count := 0; new.views := 0; new.sold := 0;
    elsif (new.rating_avg, new.rating_count, new.views, new.sold) is distinct from (old.rating_avg, old.rating_count, old.views, old.sold) then
      raise exception '不可修改系統統計欄位';
    end if;
  end if;
  return new;
end $$;
create trigger trg_guard_counters before insert or update on merchant_products for each row execute function guard_product_counters();
