-- 在 migration_005.sql 之後執行。活動專屬商品折扣、限量。

create table campaign_products (
  campaign_id uuid not null references campaigns(id) on delete cascade,
  product_id uuid not null references merchant_products(id) on delete cascade,
  discount_percent int not null check (discount_percent between 1 and 90), -- 該商品折掉幾 %(取代全站折扣,不疊加)
  limit_qty int check (limit_qty is null or limit_qty >= 1),                 -- 活動價限量(null = 不限量)
  sold_count int not null default 0,                                         -- 活動期間已以活動價售出數量
  created_at timestamptz default now(),
  primary key (campaign_id, product_id));
create index on campaign_products(product_id);
alter table campaign_products enable row level security;
create policy cpd_read on campaign_products for select using (true);
create policy cpd_admin on campaign_products for all using (is_admin()) with check (is_admin());

-- 統一計價:活動商品用專屬折扣;限量售完後,超出的數量改用全站折扣;滿額折抵、免運仍照活動設定
create or replace function quote_order(p_user uuid, p_items jsonb, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; c coupons%rowtype; cam campaigns%rowtype; r record; cp campaign_products%rowtype;
  v_sub int := 0; v_cd int := 0; v_pd int := 0; v_ship int := 60; v_after int; v_base int; v_has boolean; v_pr int; v_rem int;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception '購物車是空的'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'qty')::int < 1 then raise exception '數量不正確'; end if;
    select * into p from merchant_products where id = (it->>'product_id')::uuid and status = 'active';
    if not found then raise exception '商品不存在或已下架'; end if;
    v_sub := v_sub + p.price * (it->>'qty')::int;
  end loop;

  select * into cam from campaigns where active and now() between starts_at and ends_at
    order by discount_percent desc, threshold_off desc limit 1;
  v_has := found;
  if v_has then
    for r in select (x->>'product_id')::uuid as pid, sum((x->>'qty')::int)::int as q
             from jsonb_array_elements(p_items) x group by 1 loop
      select price into v_pr from merchant_products where id = r.pid;
      select * into cp from campaign_products where campaign_id = cam.id and product_id = r.pid;
      if found then
        v_rem := case when cp.limit_qty is null then r.q else greatest(0, least(r.q, cp.limit_qty - cp.sold_count)) end;
        v_cd := v_cd + floor(v_pr * cp.discount_percent / 100.0)::int * v_rem
                     + floor(v_pr * (r.q - v_rem) * cam.discount_percent / 100.0)::int;
      else
        v_cd := v_cd + floor(v_pr * r.q * cam.discount_percent / 100.0)::int;
      end if;
    end loop;
    if cam.threshold_min > 0 and v_sub >= cam.threshold_min then v_cd := v_cd + cam.threshold_off; end if;
    v_cd := least(v_cd, v_sub);
    if cam.free_ship_min > 0 and v_sub >= cam.free_ship_min then v_ship := 0; end if;
  end if;
  v_after := v_sub - v_cd;

  if p_code is not null and p_code <> '' then
    if p_user is null then raise exception '請先登入'; end if;
    select * into c from coupons where upper(code) = upper(p_code);
    if not found or not c.active or now() < c.starts_at or now() > c.ends_at then raise exception '優惠券無效或已過期'; end if;
    if v_has and not cam.allow_coupon then raise exception '「%」期間不可同時使用優惠券', cam.name; end if;
    if c.claim_required and not exists(select 1 from user_coupons where user_id = p_user and coupon_id = c.id) then
      raise exception '請先到優惠券中心領取此優惠券'; end if;
    if c.max_uses is not null and c.used_count >= c.max_uses then raise exception '優惠券已被使用完畢'; end if;
    if v_after < c.min_spend then raise exception '未達最低消費 NT$%', c.min_spend; end if;
    if exists(select 1 from coupon_usage where coupon_id = c.id and user_id = p_user) then raise exception '你已使用過此優惠券'; end if;
    select coalesce(sum(mp.price * (x->>'qty')::int), 0) into v_base
      from jsonb_array_elements(p_items) x join merchant_products mp on mp.id = (x->>'product_id')::uuid
      where (c.product_id is null or mp.id = c.product_id) and (c.merchant_id is null or mp.merchant_id = c.merchant_id);
    if v_base = 0 then raise exception '此優惠券不適用於購物車內的商品'; end if;
    if c.type = 'amount' then v_pd := least(c.value, v_base);
    elsif c.type = 'percent' then v_pd := floor(v_base * c.value / 100.0)::int;
    else v_ship := 0; end if;
    v_pd := least(v_pd, v_after);
  end if;

  return jsonb_build_object('subtotal', v_sub, 'campaign_discount', v_cd, 'coupon_discount', v_pd,
    'shipping', v_ship, 'total', v_after - v_pd + v_ship,
    'campaign_id', cam.id, 'campaign_name', case when v_has then cam.name end,
    'coupon_id', c.id, 'coupon_name', c.name);
end $$;
revoke execute on function quote_order(uuid,jsonb,text) from public, anon, authenticated;

-- 下單:多鎖活動商品列,再用同一份計價;下單後累計活動價已售數量(限量不會超賣)
create or replace function place_order(p_user uuid, p_items jsonb, p_pickup uuid, p_code text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; q jsonb; gr record; ar record; gs int; vs int; v_vid uuid;
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
  perform 1 from campaign_products
    where product_id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)
      and campaign_id in (select id from campaigns where active and now() between starts_at and ends_at)
    order by campaign_id, product_id for update;
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
  if q->>'campaign_id' is not null then
    for ar in select (x->>'product_id')::uuid as pid, sum((x->>'qty')::int)::int as qty
              from jsonb_array_elements(p_items) x group by 1 loop
      update campaign_products
        set sold_count = sold_count + case when limit_qty is null then ar.qty
                                           else greatest(0, least(ar.qty, limit_qty - sold_count)) end
        where campaign_id = (q->>'campaign_id')::uuid and product_id = ar.pid;
    end loop;
  end if;
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
