/* ============================================================================
   PecStore — dados do app Gestão Pecuária
   ----------------------------------------------------------------------------
   • A tela nunca espera a rede: cadastros, estoque, livro e pendências ficam
     guardados no aparelho e aparecem na hora, mesmo sem internet.
   • Lançamentos feitos sem internet entram numa FILA no aparelho, cada um com
     um código único gerado aqui. Quando a conexão volta, a fila é enviada; se
     o mesmo lançamento chegar duas vezes, o banco reconhece e não duplica.
   • O banco tem a palavra final: se recusar um lançamento (ex.: estoque
     negativo, mês fechado), ele fica marcado como RECUSADO com a explicação,
     para corrigir ou descartar. Nada se perde em silêncio.
   • Toda conversa com o banco passa pelas funções public.pec_* (06_api.sql).
   ============================================================================ */
(function(){
  'use strict';

  var AUTH_KEY   = 'pec-jsrural-auth';
  var CACHE_KEY  = 'pec-jsrural-cache-v1';
  var OUTBOX_KEY = 'pec-jsrural-pendentes-v1';
  var DEVICE_KEY = 'pec-jsrural-aparelho';
  var RETRY_MS   = 30000;

  function readJSON(k){ try{ var r = localStorage.getItem(k); return r ? JSON.parse(r) : null; }catch(e){ return null; } }
  function writeJSON(k, v){ try{ localStorage.setItem(k, JSON.stringify(v)); return true; }catch(e){ return false; } }
  function uuid(){
    if(window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c){
      var r = Math.random()*16|0; return (c==='x' ? r : (r&0x3|0x8)).toString(16);
    });
  }
  function deviceId(){
    var d = null; try{ d = localStorage.getItem(DEVICE_KEY); }catch(e){}
    if(!d){ d = 'ap-' + uuid().slice(0,8); try{ localStorage.setItem(DEVICE_KEY, d); }catch(e){} }
    return d;
  }

  /* Erro do banco → {transitorio, mensagem, codigo}. Transitório = tentar de novo depois. */
  function classificar(err){
    if(!err) return null;
    var msg = err.message || String(err);
    var code = err.code || '';
    var semRede = !code && /fetch|network|Load failed|timeout|ECONN|offline/i.test(msg);
    var transitorio = semRede || code === 'PGRST301' || /^5\d\d$/.test(String(err.status||'')) || code === '57014';
    if(code === 'PGRST202') msg = 'O banco ainda não tem esta função instalada. Avise o administrador (migração 06_api).';
    if(semRede) msg = 'Sem conexão com o servidor.';
    return { transitorio: transitorio, mensagem: msg, codigo: err.hint || code, detalhe: err.details || null };
  }

  function create(opts){
    opts = opts || {};
    var cfg = opts.config || {};
    var configurado = !!(cfg.supabaseUrl && cfg.supabaseAnonKey && window.supabase && window.supabase.createClient);
    var client = configurado ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
      auth: { persistSession:true, autoRefreshToken:true, detectSessionInUrl:true, storageKey:AUTH_KEY }
    }) : null;

    var cache = readJSON(CACHE_KEY) || {};
    var outbox = readJSON(OUTBOX_KEY) || [];
    var user = null, flushing = null, retryTimer = null, refreshing = null, proximoRefresh = null;
    var status = { online: navigator.onLine !== false, enviando:false, atualizando:false,
                   pendentes: 0, recusados: 0, ultimaSync: cache.atualizadoEm || null, erro:null };

    function contar(){
      status.pendentes = outbox.filter(function(e){ return e.estado === 'pendente'; }).length;
      status.recusados = outbox.filter(function(e){ return e.estado === 'recusado'; }).length;
    }
    function persist(){ writeJSON(CACHE_KEY, cache); writeJSON(OUTBOX_KEY, outbox); contar(); }
    function emitStatus(){ contar(); if(opts.onStatus) opts.onStatus(Object.assign({}, status)); }
    function emitData(parte){ if(opts.onData) opts.onData(parte); }
    function setStatus(p){ Object.assign(status, p); emitStatus(); }

    async function rpc(fn, args, tentou){
      if(!client) throw { transitorio:false, mensagem:'App sem configuração do Supabase.' };
      var r;
      try{ r = await client.rpc(fn, args || {}); }
      catch(e){ throw classificar(e); }
      if(r.error){
        var c = classificar(r.error);
        if(!tentou && (r.error.code === 'PGRST301' || /JWT expired/i.test(r.error.message||''))){
          try{ await client.auth.refreshSession(); return rpc(fn, args, true); }catch(e){}
        }
        throw c;
      }
      return r.data;
    }

    /* ---------------- login ---------------- */
    async function init(){
      if(!configurado) return 'config';
      client.auth.onAuthStateChange(function(ev, session){
        user = session ? session.user : null;
        if(ev === 'SIGNED_OUT'){ user = null; }
      });
      var s = await client.auth.getSession();
      user = s && s.data && s.data.session ? s.data.session.user : null;
      if(!user) return 'login';
      if(cache.email && cache.email !== user.email){ cache = {}; persist(); }
      if(!cache.sessao){
        try{ await carregarSessao(); }
        catch(e){ if(e && e.codigo === 'SEM_ACESSO'){ await sair(true); throw e; } if(!e.transitorio) throw e; return 'login'; }
      }
      return 'ok';
    }
    async function entrar(email, senha){
      var r = await client.auth.signInWithPassword({ email: String(email||'').trim(), password: senha });
      if(r.error){
        var m = /invalid login/i.test(r.error.message) ? 'E-mail ou senha incorretos.' :
                /fetch|network/i.test(r.error.message) ? 'Sem internet. Para o primeiro acesso no aparelho é preciso estar conectado.' : r.error.message;
        throw { mensagem: m };
      }
      user = r.data.user;
      if(cache.email && cache.email !== user.email){ cache = {}; }
      try{ await carregarSessao(); }
      catch(e){ await sair(true); throw e; }
      refresh();
      return true;
    }
    async function sair(forcar){
      if(!forcar && status.pendentes > 0) return { bloqueado:true, pendentes: status.pendentes };
      try{ if(client) await client.auth.signOut(); }catch(e){}
      user = null; cache = {}; persist(); emitData('tudo');
      return { ok:true };
    }
    async function esqueciSenha(email){
      var r = await client.auth.resetPasswordForEmail(String(email||'').trim(), { redirectTo: location.href.split('#')[0] });
      if(r.error) throw { mensagem: r.error.message };
      return true;
    }
    async function trocarSenha(nova){
      var r = await client.auth.updateUser({ password: nova });
      if(r.error) throw { mensagem: r.error.message };
      return true;
    }
    async function carregarSessao(){
      cache.sessao = await rpc('pec_sessao');
      cache.email = user && user.email;
      persist(); emitData('sessao');
    }

    /* ---------------- leitura ---------------- */
    async function refresh(){
      if(!client || !user || !status.online) return false;
      /* se já está atualizando, agenda UMA nova rodada para depois: o que mudou agora não pode ficar de fora */
      if(refreshing){ if(!proximoRefresh) proximoRefresh = refreshing.then(function(){ proximoRefresh = null; return refresh(); }); return proximoRefresh; }
      setStatus({ atualizando:true });
      refreshing = (async function(){
        await null;
        try{
          await carregarSessao();
          var r = await Promise.all([
            rpc('pec_cadastros'), rpc('pec_estoque', {}), rpc('pec_resumo'),
            rpc('pec_livro', { p: { limite: 200 } }),
            (cache.sessao && (cache.sessao.permissoes || []).indexOf('PEND_VER') >= 0) ? rpc('pec_pendencias') : Promise.resolve([])   /* perfis sem pendências (ex.: Diretoria) */
          ]);
          cache.cad = r[0]; cache.estoque = r[1]; cache.resumo = r[2]; cache.livro = r[3]; cache.pendencias = r[4];
          cache.estoqueEm = new Date().toISOString(); cache.atualizadoEm = cache.estoqueEm;
          persist(); setStatus({ ultimaSync: cache.atualizadoEm, erro:null });
          emitData('tudo');
          return true;
        }catch(e){
          setStatus({ erro: e && e.mensagem });
          if(e && e.transitorio) setStatus({ online:false });
          return false;
        }finally{ refreshing = null; setStatus({ atualizando:false }); }
      })();
      return refreshing;
    }
    async function livro(filtros){
      if(!status.online) throw { transitorio:true, mensagem:'Sem internet — mostrando os últimos lançamentos guardados no aparelho.' };
      return rpc('pec_livro', { p: filtros || {} });
    }
    async function estoqueEm(data){
      return rpc('pec_estoque', { p_data: data });
    }

    /* ---------------- fila de envio ---------------- */
    function enfileirar(tipo, payload, resumo){
      var item = { id: payload.id || uuid(), tipo: tipo, payload: payload, resumo: resumo || '', criado: Date.now(), estado:'pendente', erro:null };
      outbox.push(item); persist(); emitStatus(); emitData('fila');
      agendarEnvio();
      return item;
    }
    function lancar(payload, resumo){
      payload.id = payload.id || uuid();
      payload.dispositivo_id = deviceId();
      payload.origem = 'APP';
      return enfileirar('lancar', payload, resumo);
    }
    function estornar(documentoId, motivo, resumo){
      return enfileirar('estornar', { id: uuid(), documento: documentoId, motivo: motivo }, resumo);
    }
    function salvarPendencia(p, resumo){
      p.id = p.id || uuid();
      return enfileirar('pendencia', p, resumo);
    }
    /* chamada genérica que pode esperar na fila (contagem do Mapão, reprodução):
       as funções do banco aceitam reenvio do mesmo id sem duplicar */
    function filaRpc(fn, args, resumo, extra){
      return enfileirar('rpc', Object.assign({ id: uuid(), fn: fn, args: args }, extra || {}), resumo);
    }
    function descartar(id){
      outbox = outbox.filter(function(e){ return e.id !== id; }); persist(); emitStatus(); emitData('fila');
    }
    function reenviar(id, payloadNovo){
      outbox.forEach(function(e){ if(e.id === id){ e.estado = 'pendente'; e.erro = null; if(payloadNovo) e.payload = payloadNovo; } });
      persist(); emitStatus(); emitData('fila'); agendarEnvio();
    }
    function agendarEnvio(){ if(client && user && status.online) setTimeout(enviar, 150); }

    async function enviar(){
      if(flushing) return flushing;
      if(!client || !user) return { ok:false };
      flushing = (async function(){
        await null;   /* garante que "flushing" já foi atribuído antes do finally (fila vazia não pode travar o envio) */
        var enviados = 0, recusados = 0;
        setStatus({ enviando:true });
        try{
          for(var i = 0; i < outbox.length; i++){
            var e = outbox[i];
            if(e.estado !== 'pendente') continue;
            try{
              if(e.tipo === 'lancar') e.resposta = await rpc('pec_lancar', { p: e.payload });
              else if(e.tipo === 'estornar') e.resposta = await rpc('pec_estornar', { p_documento: e.payload.documento, p_motivo: e.payload.motivo });
              else if(e.tipo === 'pendencia') e.resposta = await rpc('pec_pendencia_salvar', { p: e.payload });
              else if(e.tipo === 'rpc') e.resposta = await rpc(e.payload.fn, e.payload.args);
              e.estado = 'enviado'; enviados++;
              setStatus({ online:true });
            }catch(err){
              if(err && err.transitorio){ setStatus({ online:false, erro: err.mensagem }); break; }
              e.estado = 'recusado'; e.erro = (err && err.mensagem) || 'Recusado pelo servidor.'; e.codigo = err && err.codigo; recusados++;
            }
            persist();
          }
          outbox = outbox.filter(function(e){ return e.estado !== 'enviado'; });
          persist();
        }finally{
          setStatus({ enviando:false });
          flushing = null;
        }
        emitData('fila');
        if(enviados > 0) await refresh();
        return { ok:true, enviados: enviados, recusados: recusados };
      })();
      return flushing;
    }

    /* Estoque que a tela mostra = último estoque do servidor + lançamentos ainda na fila */
    function estoqueEfetivo(){
      var rows = (cache.estoque || []).map(function(r){ return Object.assign({}, r); });
      var fator = {};
      ((cache.cad && cache.cad.categorias) || []).forEach(function(c){ fator[c.id] = Number(c.fator_ua) || 0; });
      outbox.forEach(function(e){
        if(e.tipo !== 'lancar' || e.estado !== 'pendente') return;
        (e.payload.pernas || []).forEach(function(p){
          var k = [p.retiro_id, p.pasto_id || null, p.lote_id || null, p.categoria_id, p.raca_id || null].join('|');
          var row = rows.find(function(r){ return [r.retiro_id, r.pasto_id || null, r.lote_id || null, r.categoria_id, r.raca_id || null].join('|') === k; });
          if(!row){ row = { retiro_id:p.retiro_id, pasto_id:p.pasto_id||null, lote_id:p.lote_id||null, categoria_id:p.categoria_id, raca_id:p.raca_id||null, cabecas:0, ua:0, pendente:true }; rows.push(row); }
          row.cabecas = Number(row.cabecas) + p.sentido * Number(p.quantidade);
          row.ua = row.cabecas * (fator[p.categoria_id] || 0);
          row.pendente = true;
        });
      });
      return rows.filter(function(r){ return Number(r.cabecas) !== 0; });
    }

    /* ---------------- cadastros e usuários (precisam de internet) ---------------- */
    async function salvarCadastro(tipo, dados){
      var r = await rpc('pec_cadastro_salvar', { p_tipo: tipo, p: dados });
      refresh(); return r;
    }
    async function usuarios(){ return rpc('pec_usuarios'); }

    /* consulta que guarda a última resposta no aparelho: sem internet, devolve a guardada */
    async function consultar(fn, args, chave){
      cache.extra = cache.extra || {};
      chave = chave || fn;
      try{
        var r = await rpc(fn, args);
        cache.extra[chave] = { em: new Date().toISOString(), dados: r };
        persist();
        return { dados: r, em: cache.extra[chave].em, offline: false };
      }catch(e){
        if(e && e.transitorio && cache.extra[chave]){ setStatus({ online:false }); return { dados: cache.extra[chave].dados, em: cache.extra[chave].em, offline: true }; }
        throw e;
      }
    }
    function guardado(chave){ var c = cache.extra && cache.extra[chave]; return c ? { dados: c.dados, em: c.em, offline: true } : null; }
    /* ação que precisa de internet (aprovar ajuste, fechar mês...): executa e atualiza tudo */
    async function executar(fn, args){
      if(!status.online) throw { transitorio:true, mensagem:'Esta ação precisa de internet.' };
      var r = await rpc(fn, args);
      refresh();
      return r;
    }
    async function convidar(p){ return rpc('pec_convidar', { p: p }); }

    /* ---------------- conectividade ---------------- */
    window.addEventListener('online', function(){ setStatus({ online:true }); enviar(); refresh(); });
    window.addEventListener('offline', function(){ setStatus({ online:false }); });
    document.addEventListener('visibilitychange', function(){ if(document.visibilityState === 'visible' && user){ setStatus({ online: navigator.onLine !== false }); enviar(); } });
    retryTimer = setInterval(function(){ if(user && navigator.onLine !== false){ if(!status.online) setStatus({ online:true }); if(status.pendentes) enviar(); } }, RETRY_MS);
    contar();

    return {
      init: init, entrar: entrar, sair: sair, esqueciSenha: esqueciSenha, trocarSenha: trocarSenha,
      refresh: refresh, livro: livro, estoqueEm: estoqueEm,
      lancar: lancar, estornar: estornar, salvarPendencia: salvarPendencia, descartar: descartar, reenviar: reenviar, enviar: enviar,
      salvarCadastro: salvarCadastro, usuarios: usuarios, convidar: convidar,
      filaRpc: filaRpc, consultar: consultar, guardado: guardado, executar: executar,
      estoqueEfetivo: estoqueEfetivo, uuid: uuid,
      get sessao(){ return cache.sessao || null; },
      get cad(){ return cache.cad || null; },
      get resumo(){ return cache.resumo || null; },
      get livroCache(){ return cache.livro || []; },
      get pendencias(){ return cache.pendencias || []; },
      get fila(){ return outbox.slice(); },
      get status(){ return Object.assign({}, status); },
      get usuario(){ return user; },
      tem: function(perm){ return !!(cache.sessao && (cache.sessao.permissoes || []).indexOf(perm) >= 0); }
    };
  }

  window.PecStore = { create: create };
})();
