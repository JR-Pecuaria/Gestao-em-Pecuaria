/* Imitação mínima do Supabase para testar o app de ponta a ponta sem internet.
   • /auth/v1/*         → login com senha fixa "teste123", JWT com sub/email
   • /rest/v1/rpc/:fn   → chama public.fn no Postgres local, com o mesmo
                          request.jwt.claims e o papel "authenticated" que o Supabase usa
   • resto              → arquivos do app (config.js aponta para cá)
   Uso: node mock_supabase.js <porta> <pasta_do_app>                           */
const http = require('http'), fs = require('fs'), path = require('path'), crypto = require('crypto');
const { Pool } = require('pg');
const PORT = Number(process.argv[2] || 8787), APP = path.resolve(process.argv[3] || '../app');
const pool = new Pool({ host: '/tmp', user: 'postgres', database: process.env.PGDATABASE || 'pecuaria', max: 4 });
const state = { offline: false };

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const uidDe = (email) => { const h = crypto.createHash('md5').update(email).digest('hex'); return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-8${h.slice(17,20)}-${h.slice(20,32)}`; };
function sessao(email){
  const now = Math.floor(Date.now()/1000), sub = uidDe(email);
  const claims = { sub, email, role: 'authenticated', aud: 'authenticated', exp: now + 3600, iat: now };
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  return { access_token: `${b64({alg:'HS256',typ:'JWT'})}.${b64(claims)}.sig`, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'r-' + Buffer.from(email).toString('base64url'), user };
}
function claimsDe(req){
  const a = (req.headers.authorization || '').replace(/^Bearer /, '');
  try{ const c = JSON.parse(Buffer.from(a.split('.')[1], 'base64url').toString()); return c.sub ? c : null; }catch(e){ return null; }
}
const send = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*' }); res.end(body === undefined ? '' : JSON.stringify(body)); };

const assinaturas = {};
async function assinatura(fn){
  if(assinaturas[fn]) return assinaturas[fn];
  const r = await pool.query(`select proretset, coalesce(proargnames,'{}') nomes, array(select format_type(t,null) from unnest(proargtypes) t) tipos
                              from pg_proc where proname=$1 and pronamespace='public'::regnamespace`, [fn]);
  return (assinaturas[fn] = r.rows[0] || null);
}
async function rpc(fn, args, claims){
  const sig = await assinatura(fn);
  if(!sig) return [404, { code: 'PGRST202', message: `Could not find the function public.${fn}`, details: null, hint: null }];
  const params = [], partes = [];
  Object.keys(args || {}).forEach((k) => {
    const i = sig.nomes.indexOf(k); if(i < 0) return;
    const v = args[k]; params.push(v !== null && typeof v === 'object' ? JSON.stringify(v) : v);
    partes.push(`${k} => $${params.length}::${sig.tipos[i]}`);
  });
  const c = await pool.connect();
  try{
    await c.query('BEGIN');
    await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims || { role: 'anon' })]);
    await c.query('SET LOCAL ROLE authenticated');
    const q = sig.proretset ? `select coalesce(jsonb_agg(to_jsonb(x)), '[]') r from public.${fn}(${partes.join(',')}) x`
                            : `select to_jsonb(public.${fn}(${partes.join(',')})) r`;
    const r = await c.query(q, params);
    await c.query('COMMIT');
    return [200, r.rows[0].r];
  }catch(e){
    await c.query('ROLLBACK').catch(() => {});
    return [400, { code: e.code, message: e.message, details: e.detail || null, hint: e.hint || null }];
  }finally{ c.release(); }
}

http.createServer((req, res) => {
  let body = ''; req.on('data', (d) => body += d);
  req.on('end', async () => {
    const url = new URL(req.url, 'http://x');
    if(req.method === 'OPTIONS'){ res.writeHead(204, { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }); return res.end(); }
    if(url.pathname === '/__offline'){ state.offline = url.searchParams.get('v') === '1'; return send(res, 200, state); }
    if(url.pathname.startsWith('/auth/') || url.pathname.startsWith('/rest/')){
      if(state.offline){ req.socket.destroy(); return; }   /* simula queda de rede */
      const j = body ? JSON.parse(body) : {};
      if(url.pathname === '/auth/v1/token'){
        if(url.searchParams.get('grant_type') === 'refresh_token') return send(res, 200, sessao(Buffer.from(j.refresh_token.slice(2), 'base64url').toString()));
        if(j.password !== 'teste123') return send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials', msg: 'Invalid login credentials' });
        return send(res, 200, sessao(j.email));
      }
      if(url.pathname === '/auth/v1/user'){ const c = claimsDe(req); return c ? send(res, 200, sessao(c.email).user) : send(res, 401, { msg: 'no' }); }
      if(url.pathname === '/auth/v1/logout'){ res.writeHead(204, { 'access-control-allow-origin': '*' }); return res.end(); }
      const m = url.pathname.match(/^\/rest\/v1\/rpc\/(\w+)$/);
      if(m){ const [code, out] = await rpc(m[1], j, claimsDe(req)); return send(res, code, out); }
      return send(res, 404, { message: 'mock: rota não implementada ' + url.pathname });
    }
    if(url.pathname === '/js/config.js'){
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(`window.PEC_CONFIG={supabaseUrl:location.origin,supabaseAnonKey:'${b64({alg:'HS256'})}.${b64({role:'anon'})}.sig'};`);
    }
    let f = path.join(APP, decodeURIComponent(url.pathname)); if(f.endsWith('/')) f += 'index.html';
    if(!f.startsWith(APP) || !fs.existsSync(f)){ res.writeHead(404); return res.end(); }
    const tipos = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.png':'image/png', '.webmanifest':'application/manifest+json' };
    res.writeHead(200, { 'content-type': tipos[path.extname(f)] || 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  });
}).listen(PORT, () => console.log('mock em http://localhost:' + PORT));
