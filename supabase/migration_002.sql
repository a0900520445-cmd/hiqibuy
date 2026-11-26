-- 在 schema.sql 之後執行。優惠券領取、節慶活動、統一金額計算。

alter table coupons
  add column if not exists claim_limit int,                         -- 發放數量(null = 不限)
  add column if not exists claimed_count int not null default 0,
  add column if not exists claim_required boolean not null default false; -- true = 需先領取才能使用

create table campaigns (
  id uuid primary key default gen_random_uuid(),
  year int, kind text not null default 'custom' check (kind in ('double10','double11','custom')),
  name text not null, starts_at timestamptz not null, ends_at timestamptz not null,
  discount_percent int not null default 0 check (discount_percent between 0 and 90), -- 全站折掉幾 %
  threshold_min int not null default 0, threshold_off int not null default 0,         -- 滿額折抵
  free_ship_min int not null default 0,                                                -- 滿額免運(0 = 無)
  allow_coupon boolean not null default true,                                          -- 是否可與優惠券併用
  banner_text text, content text, active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (year, kind));
create trigger trg_upd before update on campaigns for each row execute function set_updated_at();
alter table campaigns enable row level security;
create policy cmp_read on campaigns for select using (active or is_admin());
create policy cmp_admin on campaigns for all using (is_admin()) with check (is_admin());

alter table orders
  add column if not exists campaign_id uuid references campaigns(id),
  add column if not exists campaign_discount int not null default 0;

-- 每年 10/10、11/11(台灣時間)自動建立活動;折扣數字只是預設值,管理員可隨時修改
create or replace function ensure_yearly_campaigns() returns void language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now() at time zone 'Asia/Taipei')::int;
begin
  insert into campaigns(year, kind, name, starts_at, ends_at, discount_percent, banner_text)
  values (y, 'double10', 'Hi-Qi 雙十購物節',
          make_timestamptz(y,10,10,0,0,0,'Asia/Taipei'), make_timestamptz(y,10,10,23,59,59,'Asia/Taipei'),
          10, '雙十限定,全站 9 折')
  on conflict (year, kind) do nothing;
  insert into campaigns(year, kind, name, starts_at, ends_at, threshold_min, threshold_off, banner_text)
  values (y, 'double11', 'Hi-Qi 雙十一購物狂歡節',
          make_timestamptz(y,11,11,0,0,0,'Asia/Taipei'), make_timestamptz(y,11,11,23,59,59,'Asia/Taipei'),
          1111, 111, '滿 NT$1,111 折 NT$111')
  on conflict (year, kind) do nothing;
end $$;
revoke execute on function ensure_yearly_campaigns() from public, anon, authenticated;

-- 統一計價:購物車預覽與真正下單都走這支,金額永遠一致
create or replace function quote_order(p_user uuid, p_items jsonb, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; c coupons%rowtype; cam campaigns%rowtype;
  v_sub int := 0; v_cd int := 0; v_pd int := 0; v_ship int := 60; v_after int; v_base int; v_has boolean;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception '購物車是空的'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'qty')::int < 1 then raise exception '數量不正確'; end if;
    select * into p from merchant_products where id = (it->>'product_id')::uuid and status = 'active';
    if not found then raise exception '商品不存在或已下架'; end if;
    v_sub := v_sub + p.price * (it->>'qty')::int;
  end loop;

  -- 活動只在期間內生效,結束後自動不再套用
  select * into cam from campaigns where active and now() between starts_at and ends_at
    order by discount_percent desc, threshold_off desc limit 1;
  v_has := found;
  if v_has then
    v_cd := floor(v_sub * cam.discount_percent / 100.0)::int;
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

-- 下單:先鎖庫存、鎖優惠券,再用 quote_order 算出最終金額
create or replace function place_order(p_user uuid, p_items jsonb, p_pickup uuid, p_code text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; q jsonb; v_oid uuid := gen_random_uuid(); v_no text;
begin
  if not exists(select 1 from pickup_locations where id = p_pickup and active) then raise exception '請選擇到貨地點'; end if;
  for it in select e from jsonb_array_elements(p_items) e order by e->>'product_id' loop  -- 固定順序避免死結
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
  return v_oid;
end $$;
revoke execute on function place_order(uuid,jsonb,uuid,text) from public, anon, authenticated;

-- 領券
create or replace function claim_coupon(p_user uuid, p_coupon uuid) returns void language plpgsql security definer set search_path = public as $$
declare c coupons%rowtype;
begin
  select * into c from coupons where id = p_coupon for update;
  if not found or not c.active or now() > c.ends_at then raise exception '優惠券無效或已過期'; end if;
  if now() < c.starts_at then raise exception '活動尚未開始'; end if;
  if exists(select 1 from user_coupons where user_id = p_user and coupon_id = c.id) then raise exception '你已領取過這張優惠券'; end if;
  if c.claim_limit is not null and c.claimed_count >= c.claim_limit then raise exception '優惠券已被領完'; end if;
  insert into user_coupons(user_id, coupon_id) values (p_user, c.id);
  update coupons set claimed_count = claimed_count + 1 where id = c.id;
end $$;
revoke execute on function claim_coupon(uuid,uuid) from public, anon, authenticated;

select ensure_yearly_campaigns();
-- 範例免運券(需先領取、限量 500)
insert into coupons(code,name,type,value,min_spend,ends_at,claim_limit,claim_required)
values ('FREEDELIVERY500','會員免運券','free_shipping',0,300, now()+interval '1 year',500,true)
on conflict (code) do nothing;
