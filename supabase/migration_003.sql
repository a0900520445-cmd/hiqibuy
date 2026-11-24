-- 在 migration_002.sql 之後執行。贈品系統。

create table gifts (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references merchants(id) on delete cascade,
  name text not null, image_url text,
  stock int check (stock is null or stock >= 0),      -- null = 不限量
  min_qty int not null default 1 check (min_qty >= 1), -- 領取條件:購買滿幾件
  active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now());
create trigger trg_upd before update on gifts for each row execute function set_updated_at();
create table product_gifts (
  product_id uuid references merchant_products(id) on delete cascade,
  gift_id uuid references gifts(id) on delete cascade,
  primary key (product_id, gift_id));
create index on product_gifts(gift_id);
create table order_gifts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  gift_id uuid references gifts(id) on delete set null,
  name text not null, qty int not null default 1,
  created_at timestamptz default now());
create index on order_gifts(order_id);

alter table gifts enable row level security;
alter table product_gifts enable row level security;
alter table order_gifts enable row level security;
create policy g_read on gifts for select using (active or merchant_id = my_merchant() or is_admin());
create policy g_own on gifts for all using (merchant_id = my_merchant() or is_admin()) with check (merchant_id = my_merchant() or is_admin());
create policy pg_read on product_gifts for select using (true);
create policy pg_own on product_gifts for all
  using (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())))
  with check (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())));
create policy og_read on order_gifts for select using (
  exists(select 1 from orders o where o.id = order_id and (o.user_id = auth.uid() or is_admin()))
  or exists(select 1 from gifts g where g.id = gift_id and g.merchant_id = my_merchant()));
-- order_gifts 沒有寫入 policy:只有 place_order(後端)能發放贈品。

-- 結帳預覽:購物車符合條件的贈品,以及是否已送完
create or replace function gifts_for_items(p_items jsonb) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(distinct jsonb_build_object('name', g.name, 'available', (g.stock is null or g.stock > 0))), '[]'::jsonb)
  from jsonb_array_elements(p_items) x
  join product_gifts pg on pg.product_id = (x->>'product_id')::uuid
  join gifts g on g.id = pg.gift_id and g.active
  where (x->>'qty')::int >= g.min_qty $$;
revoke execute on function gifts_for_items(jsonb) from public, anon, authenticated;

-- place_order 加上贈品發放(鎖定贈品列,贈品用完就不再發,避免超發)
create or replace function place_order(p_user uuid, p_items jsonb, p_pickup uuid, p_code text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; q jsonb; gr record; gs int;
        v_oid uuid := gen_random_uuid(); v_no text;
begin
  if not exists(select 1 from pickup_locations where id = p_pickup and active) then raise exception '請選擇到貨地點'; end if;
  for it in select e from jsonb_array_elements(p_items) e order by e->>'product_id' loop
    select * into p from merchant_products where id = (it->>'product_id')::uuid and status = 'active' for update;
    if not found then raise exception '商品不存在或已下架'; end if;
    if (it->>'qty')::int < 1 or p.stock < (it->>'qty')::int then raise exception '「%」庫存不足', p.name; end if;
    update merchant_products set stock = stock - (it->>'qty')::int, sold = sold + (it->>'qty')::int where id = p.id;
  end loop;
  if p_code is not null and p_code <> '' then perform 1 from coupons where upper(code) = upper(p_code) for update; end if;
  q := quote_order(p_user, p_items, p_code);
  v_no := 'HQ-' || to_char(now() at time zone 'Asia/Taipei','YYYYMMDD') || '-' || lpad(nextval('order_seq')::text,3,'0');
  insert into orders(id, order_no, user_id, subtotal, discount, shipping, total, coupon_id, campaign_id, campaign_discount, pickup_id, eta_date)
  values (v_oid, v_no, p_user, (q->>'subtotal')::int, (q->>'campaign_discount')::int + (q->>'coupon_discount')::int,
          (q->>'shipping')::int, (q->>'total')::int, (q->>'coupon_id')::uuid, (q->>'campaign_id')::uuid,
          (q->>'campaign_discount')::int, p_pickup,
          (now() at time zone 'Asia/Taipei')::date + (1 + floor(random()*15))::int);
  insert into order_items(order_id, product_id, merchant_id, name, price, qty)
    select v_oid, mp.id, mp.merchant_id, mp.name, mp.price, (x->>'qty')::int
    from jsonb_array_elements(p_items) x join merchant_products mp on mp.id = (x->>'product_id')::uuid;
  if q->>'coupon_id' is not null then
    insert into coupon_usage(coupon_id, user_id, order_id) values ((q->>'coupon_id')::uuid, p_user, v_oid);
    update coupons set used_count = used_count + 1 where id = (q->>'coupon_id')::uuid;
  end if;
  for gr in select distinct g.id as gid, g.name as gname
            from jsonb_array_elements(p_items) x
            join product_gifts pg on pg.product_id = (x->>'product_id')::uuid
            join gifts g on g.id = pg.gift_id and g.active
            where (x->>'qty')::int >= g.min_qty order by g.id loop
    select stock into gs from gifts where id = gr.gid for update;
    if gs is null or gs > 0 then
      update gifts set stock = stock - 1 where id = gr.gid and stock is not null;
      insert into order_gifts(order_id, gift_id, name) values (v_oid, gr.gid, gr.gname);
    end if;
  end loop;
  return v_oid;
end $$;
revoke execute on function place_order(uuid,jsonb,uuid,text) from public, anon, authenticated;
