import 'dotenv/config';
import express from 'express';
import path from 'path';
import { randomUUID } from 'crypto';
import { fileURLToPath } from 'url';
import { createClient } from '@supabase/supabase-js';

const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, PORT = 3000 } = process.env;
if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('缺少 Supabase 環境變數,請參考 .env.example'); process.exit(1);
}
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const app = express();
app.set('trust proxy', 1);
app.use(express.json({ limit: '4mb' }));
app.use(express.static(path.join(path.dirname(fileURLToPath(import.meta.url)), 'public')));

const wrap = (fn) => (req, res) => fn(req, res).catch((e) => res.status(400).json({ error: e.message }));
async function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: '請先登入' });
  req.user = data.user; next();
}


const regHits = new Map();
const regLimit = (req, res, next) => {
  const now = Date.now(), a = (regHits.get(req.ip) || []).filter((t) => now - t < 3600e3);
  if (a.length >= 15) return res.status(429).json({ error: '註冊次數過多,請稍後再試' });
  a.push(now); regHits.set(req.ip, a); next();
};
async function findUserByEmail(email) {
  for (let page = 1; page <= 5; page++) {
    const { data } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    const u = data && data.users.find((x) => (x.email || '').toLowerCase() === email);
    if (u) return u;
    if (!data || data.users.length < 1000) break;
  }
  return null;
}
app.post('/api/register', regLimit, wrap(async (req, res) => {
  const username = String(req.body.username || '').trim(), email = String(req.body.email || '').trim().toLowerCase();
  const { password, confirm } = req.body;
  if (!username || username.length > 30) throw new Error('請輸入使用者名稱(30 字以內)');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('電子郵件格式不正確');
  if (!password || password.length < 6) throw new Error('密碼至少 6 碼');
  if (password !== confirm) throw new Error('兩次輸入的密碼不一致');
  const { error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { username } });
  if (error) {
    if (!/already|registered|exists/i.test(error.message)) throw new Error(error.message);
    const old = await findUserByEmail(email);   // 先前卡在「未驗證」的帳號:直接補完驗證
    if (!old || old.email_confirmed_at) throw new Error('此電子郵件已註冊,請直接登入');
    const { error: e2 } = await admin.auth.admin.updateUserById(old.id, { password, email_confirm: true, user_metadata: { username } });
    if (e2) throw new Error(e2.message);
  }
  res.json({ ok: true });
}));
app.get('/api/health', (_, res) => res.send('ok'));
// 前端只拿到 anon key(公開用),service role key 永遠留在後端
app.get('/api/config', (_, res) => res.json({ url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY }));
app.get('/api/products', wrap(async (req, res) => {
  let q = admin.from('merchant_products').select('id,name,price,original_price,stock,image_url,sold,merchants(name),product_variants(id)').eq('status', 'active');
  if (req.query.q) q = q.ilike('name', `%${req.query.q}%`);
  if (req.query.category) q = q.eq('category_id', req.query.category);
  if (parseInt(req.query.min) > 0) q = q.gte('price', parseInt(req.query.min));
  if (parseInt(req.query.max) > 0) q = q.lte('price', parseInt(req.query.max));
  if (req.query.instock === '1') q = q.gt('stock', 0);
  const sorts = { hot: ['sold', false], price_asc: ['price', true], price_desc: ['price', false] };
  const [col, asc] = sorts[req.query.sort] || ['created_at', false];
  const { data, error } = await q.order(col, { ascending: asc }).limit(60);
  if (error) throw error;
  res.json(data.map((p) => ({ ...p, has_variants: p.product_variants.length > 0, product_variants: undefined })));
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
    .select('order_no,total,status,eta_date,created_at,pickup_locations(name),order_items(name,qty,price),order_gifts(name)')
    .eq('user_id', req.user.id).order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));

// ---------- 商家 ----------
const myMerchant = async (req) => (await admin.from('merchants').select('id,name,intro,contact,suspended').eq('owner_id', req.user.id).maybeSingle()).data;
const needMerchant = async (req, res, next) => {
  try { req.merchant = await myMerchant(req); } catch (e) { return res.status(500).json({ error: e.message }); }
  if (!req.merchant) return res.status(403).json({ error: '請先註冊成為商家' });
  if (req.merchant.suspended) return res.status(403).json({ error: '你的商家帳號已被停權,請聯絡管理員' });
  next();
};
const productFields = (b) => {
  const p = { name: String(b.name || '').trim(), description: b.description || null, price: parseInt(b.price),
    original_price: b.original_price ? parseInt(b.original_price) : null, stock: parseInt(b.stock) || 0,
    image_url: b.image_url || null, category_id: b.category_id || null, status: b.status === 'hidden' ? 'hidden' : 'active' };
  if (!p.name) throw new Error('請輸入商品名稱');
  if (!(p.price >= 0) || !(p.stock >= 0)) throw new Error('價格與庫存需為 0 以上的數字');
  parseVariants(b);
  return p;
};
const parseVariants = (b) => {
  const out = [], seen = new Set();
  for (const part of String(b.variants || '').split(/[,\n，]/).map((x) => x.trim()).filter(Boolean)) {
    const m = /^(.+?)\s*[:：]\s*(\d+)$/.exec(part);
    if (!m) throw new Error('規格格式不正確,請用「名稱:庫存」,多個規格以逗號分隔');
    if (seen.has(m[1])) throw new Error('規格名稱重複:' + m[1]);
    seen.add(m[1]); out.push({ name: m[1], stock: parseInt(m[2]) });
  }
  if (out.length > 30) throw new Error('規格最多 30 個');
  return out;
};
async function saveExtras(mid, pid, b) {
  await saveGift(mid, pid, b);
  const vs = parseVariants(b);
  const { data: ex } = await admin.from('product_variants').select('id,name').eq('product_id', pid);
  const keep = new Set();
  for (let i = 0; i < vs.length; i++) {
    const old = (ex || []).find((e) => e.name === vs[i].name);
    if (old) { await admin.from('product_variants').update({ stock: vs[i].stock, sort_order: i }).eq('id', old.id); keep.add(old.id); }
    else {
      const { data: nv, error } = await admin.from('product_variants').insert({ product_id: pid, name: vs[i].name, stock: vs[i].stock, sort_order: i }).select('id').single();
      if (error) throw error; keep.add(nv.id);
    }
  }
  for (const e of ex || []) if (!keep.has(e.id)) await admin.from('product_variants').delete().eq('id', e.id);
  if (vs.length) await admin.from('merchant_products').update({ stock: vs.reduce((a, v) => a + v.stock, 0) }).eq('id', pid);
  const imgs = String(b.images || '').split('\n').map((x) => x.trim()).filter((x) => /^https?:\/\//.test(x)).slice(0, 6);
  await admin.from('product_images').delete().eq('product_id', pid);
  if (imgs.length) await admin.from('product_images').insert(imgs.map((url, i) => ({ product_id: pid, url, sort_order: i })));
}
async function checkVariants(items) {
  const ids = [...new Set(items.map((i) => i.product_id))];
  if (!ids.length) return;
  const { data } = await admin.from('product_variants').select('id,product_id').in('product_id', ids);
  const by = {};
  (data || []).forEach((v) => { (by[v.product_id] = by[v.product_id] || new Set()).add(v.id); });
  for (const i of items) {
    const set = by[i.product_id];
    if (set && !set.has(i.variant_id)) throw new Error('請先選擇商品規格');
    if (!set && i.variant_id) throw new Error('商品規格已變更,請重新加入購物車');
  }
}
async function saveGift(mid, pid, b) {
  const name = String(b.gift_name || '').trim();
  const { data: links } = await admin.from('product_gifts').select('gift_id').eq('product_id', pid);
  if (!name) { if (links && links.length) await admin.from('product_gifts').delete().eq('product_id', pid); return; }
  const g = { name, image_url: b.gift_image || null,
    stock: b.gift_stock === '' || b.gift_stock == null ? null : Math.max(0, parseInt(b.gift_stock) || 0),
    min_qty: Math.max(1, parseInt(b.gift_min_qty) || 1), active: true };
  if (links && links.length) {
    const { error } = await admin.from('gifts').update(g).eq('id', links[0].gift_id).eq('merchant_id', mid); if (error) throw error;
  } else {
    const { data: ng, error } = await admin.from('gifts').insert({ ...g, merchant_id: mid }).select('id').single(); if (error) throw error;
    const e2 = await admin.from('product_gifts').insert({ product_id: pid, gift_id: ng.id }); if (e2.error) throw e2.error;
  }
}
const ORDER_STATUS = ['訂單成立', '訂單處理中', '商品準備中', '已出貨', '已到貨', '已完成', '已取消'];

// 圖片上傳到 Supabase Storage(公開 bucket「hiqi」,伺服器啟動時自動建立)
admin.storage.createBucket('hiqi', { public: true }).then(() => {});
app.post('/api/upload', auth, needMerchant, wrap(async (req, res) => {
  const m = /^data:(image\/(png|jpeg|webp|gif));base64,(.+)$/.exec(req.body.dataUrl || '');
  if (!m) throw new Error('只支援 PNG / JPEG / WebP / GIF 圖片');
  const buf = Buffer.from(m[3], 'base64');
  if (buf.length > 2.5 * 1024 * 1024) throw new Error('圖片太大(上限 2.5MB)');
  const file = `${req.merchant.id}/${randomUUID()}.${m[2] === 'jpeg' ? 'jpg' : m[2]}`;
  const { error } = await admin.storage.from('hiqi').upload(file, buf, { contentType: m[1] });
  if (error) throw error;
  res.json({ url: admin.storage.from('hiqi').getPublicUrl(file).data.publicUrl });
}));
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
  const { data, error } = await admin.from('merchant_products').select('*,product_gifts(gifts(*)),product_variants(name,stock,sort_order),product_images(url,sort_order)').eq('merchant_id', req.merchant.id).order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));
app.post('/api/merchant/products', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('merchant_products').insert({ ...productFields(req.body), merchant_id: req.merchant.id }).select().single();
  if (error) throw error;
  await saveExtras(req.merchant.id, data.id, req.body); res.json(data);
}));
app.put('/api/merchant/products/:id', auth, needMerchant, wrap(async (req, res) => {
  const { data, error } = await admin.from('merchant_products').update(productFields(req.body))
    .eq('id', req.params.id).eq('merchant_id', req.merchant.id).select().maybeSingle();
  if (error) throw error; if (!data) throw new Error('找不到商品');
  await saveExtras(req.merchant.id, data.id, req.body); res.json(data);
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
    .select('*,merchants(name,intro),product_categories(name),product_gifts(gifts(name,image_url,stock,min_qty,active)),product_variants(id,name,stock,sort_order),product_images(url,sort_order)').eq('id', req.params.id).eq('status', 'active').maybeSingle();
  if (error) throw error; if (!p) throw new Error('找不到商品');
  const { data: rv } = await admin.from('product_reviews').select('id,user_id,rating,content,created_at').eq('product_id', p.id).order('created_at', { ascending: false });
  const ids = [...new Set(rv.map((r) => r.user_id))];
  const { data: pf } = ids.length ? await admin.from('profiles').select('id,username').in('id', ids) : { data: [] };
  const names = Object.fromEntries(pf.map((x) => [x.id, x.username]));
  const u = await optUser(req);
  let fav = false;
  if (u) { const { data: f } = await admin.from('favorites').select('product_id').eq('user_id', u.id).eq('product_id', p.id).maybeSingle(); fav = !!f; }
  const avg = rv.length ? rv.reduce((s, r) => s + r.rating, 0) / rv.length : 0;
  const gg = p.product_gifts && p.product_gifts[0] && p.product_gifts[0].gifts;
  const gift = gg && gg.active ? { name: gg.name, image_url: gg.image_url, min_qty: gg.min_qty, sold_out: gg.stock !== null && gg.stock <= 0 } : null;
  res.json({ ...p, product_gifts: undefined, gift, avg: Math.round(avg * 10) / 10, fav, reviews: rv.map((r) => ({
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
  await checkVariants(req.body.items || []);
  const { data, error } = await admin.rpc('quote_order', { p_user: u ? u.id : null, p_items: req.body.items || [], p_code: req.body.code || null });
  if (error) throw error;
  const { data: gifts } = await admin.rpc('gifts_for_items', { p_items: req.body.items || [] });
  res.json({ ...data, gifts: gifts || [] });
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
// ---------- 首頁公告 / Banner(公開) ----------
app.get('/api/site', wrap(async (_, res) => {
  const [b, a] = await Promise.all([
    admin.from('banners').select('id,title,image_url').eq('active', true).order('sort_order'),
    admin.from('announcements').select('id,title,body').eq('active', true).order('created_at', { ascending: false }).limit(5)]);
  res.json({ banners: b.data || [], announcements: a.data || [] });
}));

// ---------- 管理員:會員 / 商家 / 商品 / 評論(必須放在通用 /api/admin/:kind 之前) ----------
KINDS.announcements = { f: ['title','body','active'], nullable: ['body'], bool: ['active'], int: [] };
KINDS.banners = { f: ['title','image_url','sort_order','active'], nullable: ['image_url'], bool: ['active'], int: ['sort_order'] };
KINDS.product_categories = { f: ['name'], nullable: [], bool: [], int: [] };
async function emailMap() {
  const m = {};
  for (let page = 1; page <= 5; page++) {
    const { data } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    (data ? data.users : []).forEach((u) => { m[u.id] = u.email; });
    if (!data || data.users.length < 1000) break;
  }
  return m;
}
app.get('/api/admin/members', auth, needAdmin, wrap(async (_, res) => {
  const [{ data, error }, emails] = await Promise.all([admin.from('profiles').select('id,username,role,created_at').order('created_at', { ascending: false }), emailMap()]);
  if (error) throw error; res.json(data.map((m) => ({ ...m, email: emails[m.id] || '' })));
}));
app.put('/api/admin/members/:id/role', auth, needAdmin, wrap(async (req, res) => {
  if (!['member', 'merchant', 'admin'].includes(req.body.role)) throw new Error('無效的身分');
  if (req.params.id === req.user.id) throw new Error('不能修改自己的身分');
  const { error } = await admin.from('profiles').update({ role: req.body.role }).eq('id', req.params.id);
  if (error) throw error; res.json({ ok: true });
}));
app.get('/api/admin/merchants', auth, needAdmin, wrap(async (_, res) => {
  const { data, error } = await admin.from('merchants').select('*,profiles(username)').order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));
app.put('/api/admin/merchants/:id/suspend', auth, needAdmin, wrap(async (req, res) => {
  const f = !!req.body.suspended;
  const { error } = await admin.from('merchants').update({ suspended: f }).eq('id', req.params.id);
  if (error) throw error;
  if (f) await admin.from('merchant_products').update({ status: 'hidden' }).eq('merchant_id', req.params.id);
  res.json({ ok: true });
}));
app.get('/api/admin/products', auth, needAdmin, wrap(async (_, res) => {
  const { data, error } = await admin.from('merchant_products').select('id,name,price,stock,status,sold,merchants(name)').order('created_at', { ascending: false }).limit(200);
  if (error) throw error; res.json(data);
}));
app.put('/api/admin/products/:id/status', auth, needAdmin, wrap(async (req, res) => {
  if (!['active', 'hidden'].includes(req.body.status)) throw new Error('無效的狀態');
  const { error } = await admin.from('merchant_products').update({ status: req.body.status }).eq('id', req.params.id);
  if (error) throw error; res.json({ ok: true });
}));
app.get('/api/admin/reviews', auth, needAdmin, wrap(async (_, res) => {
  const { data, error } = await admin.from('product_reviews').select('id,rating,content,user_id,merchant_products(name)').order('created_at', { ascending: false }).limit(200);
  if (error) throw error;
  const ids = [...new Set(data.map((r) => r.user_id))];
  const { data: pf } = ids.length ? await admin.from('profiles').select('id,username').in('id', ids) : { data: [] };
  const names = Object.fromEntries(pf.map((x) => [x.id, x.username]));
  res.json(data.map((r) => ({ id: r.id, rating: r.rating, content: r.content, product: r.merchant_products && r.merchant_products.name, username: names[r.user_id] || '會員' })));
}));
app.delete('/api/admin/reviews/:id', auth, needAdmin, wrap(async (req, res) => {
  const { error } = await admin.from('product_reviews').delete().eq('id', req.params.id);
  if (error) throw error; res.json({ ok: true });
}));

const adm = [auth, needAdmin, (req, res, next) => (KINDS[req.params.kind] ? next() : res.status(404).json({ error: '未知項目' }))];
app.get('/api/admin/:kind', ...adm, wrap(async (req, res) => {
  const { data, error } = await admin.from(req.params.kind).select('*').order('created_at', { ascending: false });
  if (error) throw error; res.json(data);
}));
app.post('/api/admin/:kind', ...adm, wrap(async (req, res) => {
  const body = adminBody(req.params.kind, req.body);
  if (!String(body.name || body.title || '').trim()) throw new Error('請輸入名稱');
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
