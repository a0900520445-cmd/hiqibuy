import 'dotenv/config';
import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import { createClient } from '@supabase/supabase-js';

const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, PORT = 3000 } = process.env;
if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('缺少 Supabase 環境變數,請參考 .env.example'); process.exit(1);
}
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const app = express();
app.use(express.json());
app.use(express.static(path.join(path.dirname(fileURLToPath(import.meta.url)), 'public')));

const wrap = (fn) => (req, res) => fn(req, res).catch((e) => res.status(400).json({ error: e.message }));
async function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: '請先登入' });
  req.user = data.user; next();
}

app.get('/api/health', (_, res) => res.send('ok'));
// 前端只拿到 anon key(公開用),service role key 永遠留在後端
app.get('/api/config', (_, res) => res.json({ url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY }));
app.get('/api/products', wrap(async (req, res) => {
  let q = admin.from('merchant_products').select('id,name,price,original_price,stock,image_url,sold,merchants(name)').eq('status', 'active');
  if (req.query.q) q = q.ilike('name', `%${req.query.q}%`);
  const { data, error } = await q.order('created_at', { ascending: false }).limit(60);
  if (error) throw error; res.json(data);
}));
app.get('/api/pickups', wrap(async (_, res) => {
  const { data, error } = await admin.from('pickup_locations').select('id,name').eq('active', true);
  if (error) throw error; res.json(data);
}));
app.post('/api/orders', auth, wrap(async (req, res) => {
  const { items, pickup_id, code } = req.body;
  const { data, error } = await admin.rpc('place_order', { p_user: req.user.id, p_items: items, p_pickup: pickup_id, p_code: code || null });
  if (error) throw error; res.json({ order_id: data });
}));
app.get('/api/orders', auth, wrap(async (req, res) => {
  const { data, error } = await admin.from('orders')
    .select('order_no,total,status,eta_date,created_at,pickup_locations(name),order_items(name,qty,price)')
    .eq('user_id', req.user.id).order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));

// ---------- 商家 ----------
const myMerchant = async (req) => (await admin.from('merchants').select('id,name,intro,contact').eq('owner_id', req.user.id).maybeSingle()).data;
const needMerchant = async (req, res, next) => {
  try { req.merchant = await myMerchant(req); } catch (e) { return res.status(500).json({ error: e.message }); }
  if (!req.merchant) return res.status(403).json({ error: '請先註冊成為商家' });
  next();
};
const productFields = (b) => {
  const p = { name: String(b.name || '').trim(), description: b.description || null, price: parseInt(b.price),
    original_price: b.original_price ? parseInt(b.original_price) : null, stock: parseInt(b.stock),
    image_url: b.image_url || null, category_id: b.category_id || null, status: b.status === 'hidden' ? 'hidden' : 'active' };
  if (!p.name) throw new Error('請輸入商品名稱');
  if (!(p.price >= 0) || !(p.stock >= 0)) throw new Error('價格與庫存需為 0 以上的數字');
  return p;
};
const ORDER_STATUS = ['訂單成立', '訂單處理中', '商品準備中', '已出貨', '已到貨', '已完成', '已取消'];

app.get('/api/categories', wrap(async (_, res) => {
  const { data, error } = await admin.from('product_categories').select('id,name').order('name');
  if (error) throw error; res.json(data);
}));
app.get('/api/merchant/me', auth, wrap(async (req, res) => res.json((await myMerchant(req)) || null)));
app.post('/api/merchant/register', auth, wrap(async (req, res) => {
  if (await myMerchant(req)) throw new Error('你已經是商家');
  const { name, intro, contact } = req.body;
  if (!name || !name.trim()) throw new Error('請輸入商家名稱');
  const { data, error } = await admin.from('merchants').insert({ owner_id: req.user.id, name: name.trim(), intro, contact }).select().single();
  if (error) throw new Error(error.code === '23505' ? '商家名稱已被使用' : error.message);
  await admin.from('profiles').update({ role: 'merchant' }).eq('id', req.user.id).neq('role', 'admin');
  res.json(data);
}));
app.get('/api/merchant/products', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('merchant_products').select('*').eq('merchant_id', req.merchant.id).order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));
app.post('/api/merchant/products', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('merchant_products').insert({ ...productFields(req.body), merchant_id: req.merchant.id }).select().single();
  if (error) throw error; res.json(data);
}));
app.put('/api/merchant/products/:id', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('merchant_products').update(productFields(req.body))
    .eq('id', req.params.id).eq('merchant_id', req.merchant.id).select().maybeSingle();
  if (error) throw error; if (!data) throw new Error('找不到商品');
  res.json(data);
}));
app.delete('/api/merchant/products/:id', auth, needMerchant, wrap(async (req, res) => {
  const { error } = await admin.from('merchant_products').delete().eq('id', req.params.id).eq('merchant_id', req.merchant.id);
  if (error && error.code === '23503') { // 已有訂單引用,不能真的刪除
    await admin.from('merchant_products').update({ status: 'hidden' }).eq('id', req.params.id).eq('merchant_id', req.merchant.id);
    return res.json({ hidden: true });
  }
  if (error) throw error; res.json({ deleted: true });
}));
app.get('/api/merchant/orders', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('order_items')
    .select('name,qty,price,orders(id,order_no,status,eta_date,created_at,pickup_locations(name))')
    .eq('merchant_id', req.merchant.id).order('id', { ascending: false }).limit(100);
  if (error) throw error; res.json(data);
}));
app.put('/api/merchant/orders/:id/status', auth, needMerchant, wrap(async (req, res) => {
  if (!ORDER_STATUS.includes(req.body.status)) throw new Error('無效的訂單狀態');
  const { data: mine } = await admin.from('order_items').select('id').eq('order_id', req.params.id).eq('merchant_id', req.merchant.id).limit(1);
  if (!mine || !mine.length) throw new Error('這不是你的訂單');
  const { error } = await admin.from('orders').update({ status: req.body.status }).eq('id', req.params.id);
  if (error) throw error; res.json({ ok: true });
}));

// ---------- 商品詳細、評論、收藏 ----------
async function optUser(req) {
  const t = (req.headers.authorization || '').replace('Bearer ', '');
  if (!t) return null;
  const { data } = await admin.auth.getUser(t);
  return data.user || null;
}
app.get('/api/products/:id', wrap(async (req, res) => {
  const { data: p, error } = await admin.from('merchant_products')
    .select('*,merchants(name,intro),product_categories(name)').eq('id', req.params.id).eq('status', 'active').maybeSingle();
  if (error) throw error; if (!p) throw new Error('找不到商品');
  const { data: rv } = await admin.from('product_reviews').select('id,user_id,rating,content,created_at').eq('product_id', p.id).order('created_at', { ascending: false });
  const ids = [...new Set(rv.map((r) => r.user_id))];
  const { data: pf } = ids.length ? await admin.from('profiles').select('id,username').in('id', ids) : { data: [] };
  const names = Object.fromEntries(pf.map((x) => [x.id, x.username]));
  const u = await optUser(req);
  let fav = false;
  if (u) { const { data: f } = await admin.from('favorites').select('product_id').eq('user_id', u.id).eq('product_id', p.id).maybeSingle(); fav = !!f; }
  const avg = rv.length ? rv.reduce((s, r) => s + r.rating, 0) / rv.length : 0;
  res.json({ ...p, avg: Math.round(avg * 10) / 10, fav, reviews: rv.map((r) => ({
    id: r.id, rating: r.rating, content: r.content, created_at: r.created_at,
    username: names[r.user_id] || '會員', mine: !!u && u.id === r.user_id })) });
}));
app.post('/api/products/:id/reviews', auth, wrap(async (req, res) => {
  const rating = parseInt(req.body.rating), content = String(req.body.content || '').trim().slice(0, 500);
  if (!(rating >= 1 && rating <= 5)) throw new Error('請選擇 1~5 顆星');
  if (!content) throw new Error('請輸入評論內容');
  const { data: ex } = await admin.from('product_reviews').select('id').eq('product_id', req.params.id).eq('user_id', req.user.id).maybeSingle();
  const q = ex ? admin.from('product_reviews').update({ rating, content }).eq('id', ex.id)
                : admin.from('product_reviews').insert({ product_id: req.params.id, user_id: req.user.id, rating, content });
  const { error } = await q; if (error) throw error;
  res.json({ ok: true, updated: !!ex });
}));
app.delete('/api/reviews/:id', auth, wrap(async (req, res) => {
  const { error } = await admin.from('product_reviews').delete().eq('id', req.params.id).eq('user_id', req.user.id);
  if (error) throw error; res.json({ ok: true });
}));
app.get('/api/favorites', auth, wrap(async (req, res) => {
  const { data, error } = await admin.from('favorites').select('merchant_products(id,name,price,image_url,stock,status)').eq('user_id', req.user.id).order('created_at', { ascending: false });
  if (error) throw error; res.json(data.map((x) => x.merchant_products).filter((p) => p && p.status === 'active'));
}));
app.post('/api/favorites/:pid', auth, wrap(async (req, res) => {
  const { error } = await admin.from('favorites').upsert({ user_id: req.user.id, product_id: req.params.pid });
  if (error) throw error; res.json({ ok: true });
}));
app.delete('/api/favorites/:pid', auth, wrap(async (req, res) => {
  const { error } = await admin.from('favorites').delete().eq('user_id', req.user.id).eq('product_id', req.params.pid);
  if (error) throw error; res.json({ ok: true });
}));

// ---------- 計價、優惠券中心、活動、管理員 ----------
app.post('/api/quote', wrap(async (req, res) => {
  const u = await optUser(req);
  const { data, error } = await admin.rpc('quote_order', { p_user: u ? u.id : null, p_items: req.body.items || [], p_code: req.body.code || null });
  if (error) throw error; res.json(data);
}));
app.get('/api/me', auth, wrap(async (req, res) => {
  const { data } = await admin.from('profiles').select('role,username').eq('id', req.user.id).single(); res.json(data);
}));
app.get('/api/coupon-center', wrap(async (req, res) => {
  const u = await optUser(req), now = new Date(), DAY = 864e5;
  const { data: cs, error } = await admin.from('coupons')
    .select('id,code,name,type,value,min_spend,starts_at,ends_at,claim_limit,claimed_count')
    .eq('active', true).gte('ends_at', new Date(Date.now() - 30 * DAY).toISOString()).order('ends_at');
  if (error) throw error;
  let claimed = new Set(), used = new Set();
  if (u) {
    const [a, b] = await Promise.all([admin.from('user_coupons').select('coupon_id').eq('user_id', u.id), admin.from('coupon_usage').select('coupon_id').eq('user_id', u.id)]);
    claimed = new Set((a.data || []).map((x) => x.coupon_id)); used = new Set((b.data || []).map((x) => x.coupon_id));
  }
  const out = [];
  for (const c of cs) {
    const ends = new Date(c.ends_at), mine = claimed.has(c.id); let status;
    if (used.has(c.id)) status = 'used';
    else if (ends < now) status = mine ? 'expired' : null;
    else if (mine) status = 'claimed';
    else if (new Date(c.starts_at) > now) status = 'upcoming';
    else if (c.claim_limit !== null && c.claimed_count >= c.claim_limit) status = 'soldout';
    else status = 'available';
    if (status) out.push({ ...c, status, soon: status === 'claimed' && ends - now < 3 * DAY });
  }
  res.json(out);
}));
app.post('/api/coupons/:id/claim', auth, wrap(async (req, res) => {
  const { error } = await admin.rpc('claim_coupon', { p_user: req.user.id, p_coupon: req.params.id });
  if (error) throw error; res.json({ ok: true });
}));
app.get('/api/campaign', wrap(async (_, res) => {
  const now = new Date().toISOString();
  const { data: a } = await admin.from('campaigns').select('*').eq('active', true).lte('starts_at', now).gte('ends_at', now).order('discount_percent', { ascending: false }).limit(1);
  const { data: up } = await admin.from('campaigns').select('id,name,starts_at').eq('active', true).gt('starts_at', now).order('starts_at').limit(1);
  const { data: top } = await admin.from('merchant_products').select('id,name,price,original_price,image_url,sold,stock').eq('status', 'active').order('sold', { ascending: false }).limit(12);
  res.json({ active: (a && a[0]) || null, upcoming: (up && up[0]) || null, top });
}));

const needAdmin = async (req, res, next) => {
  const { data } = await admin.from('profiles').select('role').eq('id', req.user.id).single();
  if (!data || data.role !== 'admin') return res.status(403).json({ error: '沒有權限' });
  next();
};
const KINDS = {
  coupons: { f: ['code','name','type','value','min_spend','starts_at','ends_at','max_uses','claim_limit','claim_required','active'],
    nullable: ['max_uses','claim_limit'], bool: ['claim_required','active'], int: ['value','min_spend','max_uses','claim_limit'] },
  campaigns: { f: ['name','starts_at','ends_at','discount_percent','threshold_min','threshold_off','free_ship_min','allow_coupon','banner_text','content','active'],
    nullable: ['banner_text','content'], bool: ['allow_coupon','active'], int: ['discount_percent','threshold_min','threshold_off','free_ship_min'] },
};
function adminBody(kind, b) {
  const K = KINDS[kind], o = {};
  for (const k of K.f) {
    if (!(k in b)) continue; let v = b[k];
    if (K.bool.includes(k)) v = !!v;
    else if (K.int.includes(k)) { v = (v === '' || v === null) ? (K.nullable.includes(k) ? null : 0) : parseInt(v); if (Number.isNaN(v)) throw new Error(k + ' 必須是數字'); }
    else if (K.nullable.includes(k) && v === '') v = null;
    o[k] = v;
  }
  if (o.code) o.code = String(o.code).trim().toUpperCase();
  if ('starts_at' in o && (!o.starts_at || !o.ends_at)) throw new Error('請設定期間');
  return o;
}
const adm = [auth, needAdmin, (req, res, next) => (KINDS[req.params.kind] ? next() : res.status(404).json({ error: '未知項目' }))];
app.get('/api/admin/:kind', ...adm, wrap(async (req, res) => {
  const { data, error } = await admin.from(req.params.kind).select('*').order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));
app.post('/api/admin/:kind', ...adm, wrap(async (req, res) => {
  const body = adminBody(req.params.kind, req.body);
  if (!body.name || !String(body.name).trim()) throw new Error('請輸入名稱');
  if (req.params.kind === 'coupons' && !body.code) throw new Error('請輸入優惠券代碼');
  const { data, error } = await admin.from(req.params.kind).insert(body).select().single();
  if (error) throw new Error(error.code === '23505' ? '代碼重複' : error.message); res.json(data);
}));
app.put('/api/admin/:kind/:id', ...adm, wrap(async (req, res) => {
  const { data, error } = await admin.from(req.params.kind).update(adminBody(req.params.kind, req.body)).eq('id', req.params.id).select().maybeSingle();
  if (error) throw new Error(error.code === '23505' ? '代碼重複' : error.message);
  if (!data) throw new Error('找不到資料'); res.json(data);
}));
app.delete('/api/admin/:kind/:id', ...adm, wrap(async (req, res) => {
  const { error } = await admin.from(req.params.kind).delete().eq('id', req.params.id);
  if (error) throw new Error(error.code === '23503' ? '已有使用紀錄,請改為停用' : error.message); res.json({ ok: true });
}));

// 每年 10/10、11/11 自動建立活動(台灣時間)
const ensureCampaigns = () => admin.rpc('ensure_yearly_campaigns').then(({ error }) => { if (error) console.error('建立年度活動失敗(尚未執行 migration_002.sql?):', error.message); });
ensureCampaigns(); setInterval(ensureCampaigns, 6 * 3600 * 1000);

app.listen(PORT, () => console.log(`Hi-Qi 啟動於 http://localhost:${PORT}`));
