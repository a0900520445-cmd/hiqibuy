-- 在 migration_003.sql 之後執行。首頁 Banner、商家停權。

create table banners (
  id uuid primary key default gen_random_uuid(),
  title text not null, image_url text,
  sort_order int not null default 0, active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now());
create index on banners(sort_order);
create trigger trg_upd before update on banners for each row execute function set_updated_at();
alter table banners enable row level security;
create policy b_read on banners for select using (active or is_admin());
create policy b_admin on banners for all using (is_admin()) with check (is_admin());

alter table merchants add column if not exists suspended boolean not null default false;

insert into announcements(title, body) values ('歡迎來到 Hi-Qi', '商品陸續上架中,領取優惠券再下單最划算。');
