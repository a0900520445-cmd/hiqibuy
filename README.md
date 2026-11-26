# Hi-Qi 購物商城

Node.js + Express + Supabase。前端為 `public/index.html`,由 Express 一併提供,所以 Render 只需要一個 Web Service。

## 1. Supabase
1. 建立專案 → SQL Editor → 依序貼上並執行 `supabase/schema.sql`、`supabase/migration_002.sql`、`supabase/migration_003.sql`、`supabase/migration_004.sql`、`supabase/migration_005.sql`、`supabase/migration_006.sql`、`supabase/migration_007.sql`。
2. Settings > API 複製 URL、anon key、service_role key。
3. 註冊一個帳號後,執行:`update profiles set role='admin' where id='<你的 user id>';`
4. 商品可先在 Table Editor 的 `merchant_products` 新增(merchant_id 留空即自營)。

## 2. 本機
```
cp .env.example .env   # 填入三個 Supabase 值
npm install
npm run dev            # http://localhost:3000
```

## 3. 部署到 Render
1. 把專案推到 GitHub。
2. Render → New → Blueprint → 選該 repo(會讀 `render.yaml`)。
3. 填入 `SUPABASE_URL`、`SUPABASE_ANON_KEY`、`SUPABASE_SERVICE_ROLE_KEY`。
4. 部署完成後 Supabase → Authentication → URL Configuration,把 Site URL 設成你的 Render 網址。

注意:`SUPABASE_SERVICE_ROLE_KEY` 只存在 Render 環境變數,不會送到瀏覽器。
Render 免費方案閒置後會休眠,第一次開啟會慢幾十秒。

## 註冊與驗證信
註冊由後端直接建立帳號(不寄驗證信),避開 Supabase 內建寄信的每小時額度限制。若之後要驗證信箱,請在 Supabase → Authentication → SMTP Settings 設定自己的 SMTP(例如 Resend),再改回由 Supabase 寄信。
