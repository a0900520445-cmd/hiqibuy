-- 在 migration_004.sql 之後執行。商品規格(各規格獨立庫存)與多張商品圖片。

create table product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references merchant_products(id) on delete cascade,
  name text not null, stock int not null default 0 check (stock >= 0), sort_order int not null default 0,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (product_id, name));
create trigger trg_upd before update on product_variants for each row execute function set_updated_at();
create table product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references merchant_products(id) on delete cascade,
  url text not null, sort_order int not null default 0,
  created_at timestamptz default now());
create index on product_images(product_id);
alter table order_items add column if not exists variant_id uuid references product_variants(id) on delete set null;

alter table product_variants enable row level security;
alter table product_images enable row level security;
create policy pv_read on product_variants for select using (true);
create policy pv_own on product_variants for all
  using (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())))
  with check (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())));
create policy pi_read on product_images for select using (true);
create policy pi_own on product_images for all
  using (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())))
  with check (exists(select 1 from merchant_products p where p.id = product_id and (p.merchant_id = my_merchant() or is_admin())));

-- 有規格的商品:merchant_products.stock = 各規格庫存總和(由後端維護);下單時同時扣規格庫存與商品庫存
create or replace function place_order(p_user uuid, p_items jsonb, p_pickup uuid, p_code text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; q jsonb; gr record; gs int; vs int; v_vid uuid;
        v_oid uuid := gen_random_uuid(); v_no text;
begin
  if not exists(select 1 from pickup_locations where id = p_pickup and active) then raise exception '請選擇到貨地點'; end if;
  for it in select e from jsonb_array_elements(p_items) e order by e->>'product_id', e->>'variant_id' loop
    v_vid := nullif(it->>'variant_id','')::uuid;
    select * into p from merchant_products where id = (it->>'product_id')::uuid and status = 'active' for update;
    if not found then raise exception '商品不存在或已下架'; end if;
    if (it->>'qty')::int < 1 or p.stock < (it->>'qty')::int then raise exception '「%」庫存不足', p.name; end if;
    if exists(select 1 from product_variants where product_id = p.id) then
      if v_vid is null then raise exception '請選擇「%」的規格', p.name; end if;
      select stock into vs from product_variants where id = v_vid and product_id = p.id for update;
      if not found then raise exception '規格不存在或已下架'; end if;
      if vs < (it->>'qty')::int then raise exception '「%」此規格庫存不足', p.name; end if;
      update product_variants set stock = stock - (it->>'qty')::int where id = v_vid;
    elsif v_vid is not null then raise exception '商品規格不正確'; end if;
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
  insert into order_items(order_id, product_id, merchant_id, name, price, qty, variant_id)
    select v_oid, mp.id, mp.merchant_id, mp.name || coalesce('(' || pv.name || ')', ''), mp.price, (x->>'qty')::int, pv.id
    from jsonb_array_elements(p_items) x
    join merchant_products mp on mp.id = (x->>'product_id')::uuid
    left join product_variants pv on pv.id = nullif(x->>'variant_id','')::uuid;
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
