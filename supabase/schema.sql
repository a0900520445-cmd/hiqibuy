-- Hi-Qi schema。在 Supabase SQL Editor 整份貼上執行。
create extension if not exists pgcrypto;
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null, role text not null default 'member' check (role in ('member','merchant','admin')),
  created_at timestamptz default now(), updated_at timestamptz default now());
create table merchants (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid unique not null references profiles(id) on delete cascade,
  name text not null unique, intro text, logo_url text, contact text,
  created_at timestamptz default now(), updated_at timestamptz default now());
create table product_categories (
  id uuid primary key default gen_random_uuid(), name text unique not null,
  created_at timestamptz default now(), updated_at timestamptz default now());
create table merchant_products (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid references merchants(id) on delete cascade, -- null = Hi-Qi 自營
  category_id uuid references product_categories(id),
  name text not null, description text, price int not null check (price >= 0),
  original_price int, stock int not null default 0 check (stock >= 0),
  image_url text, status text not null default 'active' check (status in ('active','hidden')),
  sold int not null default 0,
  created_at timestamptz default now(), updated_at timestamptz default now());
create index on merchant_products(merchant_id); create index on merchant_products(category_id);
create table product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references merchant_products(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  rating int not null check (rating between 1 and 5), content text,
  created_at timestamptz default now(), updated_at timestamptz default now());
create index on product_reviews(product_id);
create table cart_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  product_id uuid not null references merchant_products(id) on delete cascade,
  qty int not null check (qty > 0), unique (user_id, product_id),
  created_at timestamptz default now(), updated_at timestamptz default now());
create table favorites (
  user_id uuid references profiles(id) on delete cascade,
  product_id uuid references merchant_products(id) on delete cascade,
  created_at timestamptz default now(), primary key (user_id, product_id));
create table pickup_locations (
  id uuid primary key default gen_random_uuid(), name text unique not null, active boolean default true,
  created_at timestamptz default now(), updated_at timestamptz default now());
create table coupons (
  id uuid primary key default gen_random_uuid(),
  code text unique not null, name text not null,
  type text not null check (type in ('amount','percent','free_shipping')),
  value int not null default 0, min_spend int not null default 0,
  merchant_id uuid references merchants(id), product_id uuid references merchant_products(id),
  starts_at timestamptz not null default now(), ends_at timestamptz not null,
  max_uses int, used_count int not null default 0, active boolean not null default true,
  campaign text, created_at timestamptz default now(), updated_at timestamptz default now());
create table user_coupons (
  user_id uuid references profiles(id) on delete cascade,
  coupon_id uuid references coupons(id) on delete cascade,
  claimed_at timestamptz default now(), primary key (user_id, coupon_id));
create sequence order_seq;
create table orders (
  id uuid primary key default gen_random_uuid(), order_no text unique not null,
  user_id uuid not null references profiles(id),
  subtotal int not null, discount int not null default 0, shipping int not null default 0, total int not null,
  coupon_id uuid references coupons(id),
  pickup_id uuid not null references pickup_locations(id),
  eta_date date not null, status text not null default '訂單成立',
  created_at timestamptz default now(), updated_at timestamptz default now());
create index on orders(user_id);
create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references merchant_products(id),
  merchant_id uuid references merchants(id),
  name text not null, price int not null, qty int not null);
create index on order_items(order_id); create index on order_items(merchant_id);
create table coupon_usage (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references coupons(id), user_id uuid not null references profiles(id),
  order_id uuid not null references orders(id), used_at timestamptz default now(),
  unique (coupon_id, user_id));
create table announcements (
  id uuid primary key default gen_random_uuid(), title text not null, body text, active boolean default true,
  created_at timestamptz default now(), updated_at timestamptz default now());

do $$ declare t text; begin
  for t in select unnest(array['profiles','merchants','product_categories','merchant_products','product_reviews','cart_items','pickup_locations','coupons','orders','announcements']) loop
    execute format('create trigger trg_upd before update on %I for each row execute function set_updated_at()', t);
  end loop; end $$;

-- 註冊時自動建立 profile
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin insert into profiles(id, username) values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1))); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;
create or replace function my_merchant() returns uuid language sql stable security definer set search_path = public as
$$ select id from merchants where owner_id = auth.uid() $$;

-- RLS
alter table profiles enable row level security;
alter table merchants enable row level security;
alter table product_categories enable row level security;
alter table merchant_products enable row level security;
alter table product_reviews enable row level security;
alter table cart_items enable row level security;
alter table favorites enable row level security;
alter table pickup_locations enable row level security;
alter table coupons enable row level security;
alter table user_coupons enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
alter table coupon_usage enable row level security;
alter table announcements enable row level security;

create policy p_self on profiles for select using (id = auth.uid() or is_admin());
create policy p_self_upd on profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from profiles where id = auth.uid()));
create policy m_read on merchants for select using (true);
create policy m_own on merchants for all using (owner_id = auth.uid() or is_admin()) with check (owner_id = auth.uid() or is_admin());
create policy c_read on product_categories for select using (true);
create policy c_admin on product_categories for all using (is_admin()) with check (is_admin());
create policy pr_read on merchant_products for select using (status = 'active' or merchant_id = my_merchant() or is_admin());
create policy pr_own on merchant_products for all using (merchant_id = my_merchant() or is_admin()) with check (merchant_id = my_merchant() or is_admin());
create policy rv_read on product_reviews for select using (true);
create policy rv_ins on product_reviews for insert with check (user_id = auth.uid());
create policy rv_own on product_reviews for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy rv_del on product_reviews for delete using (user_id = auth.uid() or is_admin());
create policy ci_own on cart_items for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy fv_own on favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy pl_read on pickup_locations for select using (true);
create policy pl_admin on pickup_locations for all using (is_admin()) with check (is_admin());
create policy cp_read on coupons for select using (active or is_admin());
create policy cp_admin on coupons for all using (is_admin()) with check (is_admin());
create policy uc_own on user_coupons for select using (user_id = auth.uid());
create policy o_own on orders for select using (user_id = auth.uid() or is_admin()
  or exists(select 1 from order_items oi where oi.order_id = orders.id and oi.merchant_id = my_merchant()));
create policy oi_read on order_items for select using (
  exists(select 1 from orders o where o.id = order_id and (o.user_id = auth.uid() or is_admin())) or merchant_id = my_merchant());
create policy cu_own on coupon_usage for select using (user_id = auth.uid() or is_admin());
create policy an_read on announcements for select using (active or is_admin());
create policy an_admin on announcements for all using (is_admin()) with check (is_admin());
-- orders / order_items / coupon_usage / user_coupons 沒有寫入 policy:前端無法寫入,只有後端 service role 可以。

-- 下單:金額、庫存、優惠券全部在資料庫交易內重算;row lock 避免超賣與重複兌換
create or replace function place_order(p_user uuid, p_items jsonb, p_pickup uuid, p_code text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; p merchant_products%rowtype; c coupons%rowtype; v_sub int := 0; v_disc int := 0;
        v_ship int := 60; v_oid uuid; v_no text;
begin
  if jsonb_array_length(p_items) = 0 then raise exception '購物車是空的'; end if;
  if not exists(select 1 from pickup_locations where id = p_pickup and active) then raise exception '請選擇到貨地點'; end if;
  v_oid := gen_random_uuid();
  v_no := 'HQ-' || to_char(now() at time zone 'Asia/Taipei','YYYYMMDD') || '-' || lpad(nextval('order_seq')::text,3,'0');
  insert into orders(id, order_no, user_id, subtotal, total, pickup_id, eta_date)
  values (v_oid, v_no, p_user, 0, 0, p_pickup,
          (now() at time zone 'Asia/Taipei')::date + (1 + floor(random()*15))::int); -- 下單時產生一次,之後固定
  for it in select * from jsonb_array_elements(p_items) loop
    select * into p from merchant_products where id = (it->>'product_id')::uuid and status = 'active' for update;
    if not found then raise exception '商品不存在或已下架'; end if;
    if (it->>'qty')::int < 1 or p.stock < (it->>'qty')::int then raise exception '「%」庫存不足', p.name; end if;
    update merchant_products set stock = stock - (it->>'qty')::int, sold = sold + (it->>'qty')::int where id = p.id;
    insert into order_items(order_id, product_id, merchant_id, name, price, qty)
    values (v_oid, p.id, p.merchant_id, p.name, p.price, (it->>'qty')::int);
    v_sub := v_sub + p.price * (it->>'qty')::int;
  end loop;
  if p_code is not null and p_code <> '' then
    select * into c from coupons where upper(code) = upper(p_code) for update;
    if not found or not c.active or now() < c.starts_at or now() > c.ends_at then raise exception '優惠券無效或已過期'; end if;
    if c.max_uses is not null and c.used_count >= c.max_uses then raise exception '優惠券已被領完'; end if;
    if v_sub < c.min_spend then raise exception '未達最低消費 NT$%', c.min_spend; end if;
    if exists(select 1 from coupon_usage where coupon_id = c.id and user_id = p_user) then raise exception '你已使用過此優惠券'; end if;
    if c.type = 'amount' then v_disc := least(c.value, v_sub);
    elsif c.type = 'percent' then v_disc := floor(v_sub * c.value / 100.0)::int;
    else v_ship := 0; end if;
    insert into coupon_usage(coupon_id, user_id, order_id) values (c.id, p_user, v_oid);
    update coupons set used_count = used_count + 1 where id = c.id;
  end if;
  update orders set subtotal = v_sub, discount = v_disc, shipping = v_ship, total = v_sub - v_disc + v_ship,
                    coupon_id = c.id where id = v_oid;
  return v_oid;
end $$;
revoke execute on function place_order(uuid,jsonb,uuid,text) from public, anon, authenticated;

-- 種子資料
insert into pickup_locations(name) values ('Hi-Qi東區總店'),('童話Hi-Qi店到店'),('Hi-Qi台中大里店');
insert into product_categories(name) values ('生活用品'),('3C電子'),('美妝保養'),('食品飲料'),('服飾'),('居家用品'),('文具'),('玩具'),('其他');
insert into coupons(code,name,type,value,min_spend,ends_at) values
 ('HIQI100','折抵 NT$100','amount',100,500, now()+interval '1 year'),
 ('HIQI10','全館 9 折','percent',10,0, now()+interval '1 year'),
 ('FREEDELIVERY','免運費','free_shipping',0,0, now()+interval '1 year');
-- 設自己為管理員:update profiles set role='admin' where id = '<你的 auth user id>';
