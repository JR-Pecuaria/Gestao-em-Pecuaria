/* ============================================================================
   Gestão Pecuária JS Rural — Entrega 3
   Mapão (conferência de campo) · Reprodução (estação, IATF, DG) · Mês (fechamento)
   Usa os utilitários do app.js (PecApp.h) e as funções public.pec_* da 08_entrega3.sql.
   ============================================================================ */
(function(){
  'use strict';
  var A = window.PecApp, store = A.store, H = A.h, X = A.ext;
  var $ = H.$, $$ = H.$$, esc = H.esc, n0 = H.n0, n1 = H.n1, pct = H.pct, dataBR = H.dataBR, opt = H.opt, v = H.v, toast = H.toast;
  function D(){ return H.dic(); }
  function mesBR(iso){ if(!iso) return '—'; var p = String(iso).slice(0,7).split('-'); return p[1] + '/' + p[0]; }
  function mesISO(d){ return String(d).slice(0,7) + '-01'; }
  function mesAnterior(){ var d = new Date(); d.setDate(1); d.setMonth(d.getMonth() - 1); return d.toISOString().slice(0,7) + '-01'; }
  function mesAtual(){ return H.hoje().slice(0,7) + '-01'; }
  function erroMsg(e){ return (e && e.mensagem) || 'Não foi possível concluir. Tente de novo.'; }
  function nomeCat(id){ return (D().cat[id] || {}).nome || '?'; }
  function codPasto(id){ return id ? ((D().pas[id] || {}).codigo || '?') : 'SEM PASTO'; }
  function ordemPasto(a, b){ if(!a) return 1; if(!b) return -1; return codPasto(a).localeCompare(codPasto(b), 'pt-BR', {numeric:true}); }
  function difHtml(d){ if(d == null) return '<span class="dif zero">·</span>'; return '<span class="dif ' + (d > 0 ? 'pos' : d < 0 ? 'neg' : 'zero') + '">' + (d > 0 ? '+' : '') + n0(d) + '</span>'; }
  var STATUS_INV = { EMITIDO:['emitido','info'], EM_CONTAGEM:['em contagem','warn'], CONTADO:['contado','info'], AJUSTADO:['conferido e ajustado','good'], CANCELADO:['cancelado','neutral'] };
  function chipInv(st){ var s = STATUS_INV[st] || [st, 'neutral']; return '<span class="chip ' + s[1] + '">' + s[0] + '</span>'; }
  function pendentesRpc(fn, filtro){ return store.fila.filter(function(e){ return e.tipo === 'rpc' && e.estado === 'pendente' && (!fn || e.payload.fn === fn) && (!filtro || filtro(e)); }); }
  async function enviarEDepois(fn){ try{ await store.enviar(); }catch(e){} if(fn) await fn(); }

  /* ==========================================================================
     MAPÃO — conferência de campo
     ========================================================================== */
  var M = { inv: null, lista: null, det: null, emRet: '', emMes: '' };
  var RASCUNHO_KEY = 'pec-jsrural-contagem-v1';
  function rascunhos(){ try{ return JSON.parse(localStorage.getItem(RASCUNHO_KEY) || '{}'); }catch(e){ return {}; } }
  function salvarRascunhos(r){ try{ localStorage.setItem(RASCUNHO_KEY, JSON.stringify(r)); }catch(e){} }
  function chave(p, c){ return (p || 'SEM') + '|' + c; }

  async function carregarLista(){
    try{ var r = await store.consultar('pec_inventarios', { p: {} }, 'inventarios'); M.lista = r; }
    catch(e){ M.lista = store.guardado('inventarios') || { dados: [], erro: erroMsg(e) }; }
    renderMapao();
  }
  async function carregarInv(id){
    try{ M.det = await store.consultar('pec_inventario', { p_id: id }, 'inv:' + id); }
    catch(e){ M.det = store.guardado('inv:' + id); if(!M.det){ toast(erroMsg(e), true); M.inv = null; } }
    renderMapao();
  }

  /* linhas da contagem = servidor + fila (ainda não enviada) + rascunho na tela */
  function linhasContagem(inv){
    var by = {};
    (inv.itens || []).forEach(function(it){ by[chave(it.pasto_id, it.categoria_id)] = Object.assign({}, it); });
    pendentesRpc('pec_inventario_contar', function(e){ return e.payload.args.p.inventario_id === inv.id; }).forEach(function(e){
      (e.payload.args.p.itens || []).forEach(function(it){
        var k = chave(it.pasto_id, it.categoria_id);
        by[k] = Object.assign(by[k] || { pasto_id: it.pasto_id || null, categoria_id: it.categoria_id, qtd_sistema: 0 }, { qtd_campo: it.qtd_campo, observacao: it.observacao, naFila: true });
      });
    });
    var r = rascunhos()[inv.id] || {};
    Object.keys(r).forEach(function(k){
      var p = k.split('|'); var pid = p[0] === 'SEM' ? null : p[0];
      by[k] = Object.assign(by[k] || { pasto_id: pid, categoria_id: p[1], qtd_sistema: 0 }, { qtd_campo: r[k].qtd, observacao: r[k].obs, rascunho: true });
    });
    return Object.keys(by).map(function(k){ var x = by[k]; x.dif = (x.qtd_campo == null || x.qtd_campo === '') ? null : Number(x.qtd_campo) - Number(x.qtd_sistema || 0); return x; });
  }

  function renderMapao(){
    var el = $('#panel-conferencia'); if(!el || !store.sessao) return;
    if(M.inv && M.det) return renderInv(el);
    var podeContar = store.tem('INV_CONTAR');
    var rets = H.retirosLiberados();
    if(!M.emRet) M.emRet = (rets[0] || {}).id || '';
    if(!M.emMes) M.emMes = (new Date().getDate() <= 15 ? mesAnterior() : mesAtual()).slice(0,7);
    var html = '<div class="stack"><div class="card panel-pad"><h2 class="section-title">Mapão do gado</h2>' +
      '<p class="section-hint">O sistema tira a fotografia do estoque de cada pasto no fim do mês. O vaqueiro conta no campo, aqui no celular (funciona sem internet) ou na folha impressa. As diferenças viram pendências e, depois de procurar o lançamento que faltou, o gerente aprova o ajuste.</p>' +
      '<div class="filters"><div class="field"><label for="mpRet">Retiro</label><select class="select" id="mpRet">' + rets.map(function(r){ return opt(r.id, r.nome, r.id === M.emRet); }).join('') + '</select></div>' +
      '<div class="field"><label for="mpMes">Mês</label><input class="input" type="month" id="mpMes" value="' + M.emMes + '" max="' + H.hoje().slice(0,7) + '"></div>' +
      '<div class="row">' + (podeContar ? '<button class="icon-btn btn-primary" data-act="mp-emitir" type="button">Abrir Mapão para contar</button>' : '') +
      '<button class="icon-btn" data-act="mp-imprimir" type="button">Imprimir folha</button></div></div></div>';
    var lista = (M.lista && M.lista.dados) || [];
    html += '<div class="card"><div class="panel-pad spread" style="padding-bottom:8px"><h2 class="section-title">Mapões dos últimos meses</h2>' + (M.lista && M.lista.offline ? '<span class="chip warn">sem internet · guardado em ' + H.quandoBR(M.lista.em) + '</span>' : '') + '</div>';
    if(!M.lista) html += '<div class="empty">Carregando…</div>';
    else if(!lista.length) html += '<div class="empty">Nenhum Mapão emitido ainda. Escolha o retiro e o mês acima.</div>';
    lista.forEach(function(i){
      var rs = i.resumo || {}; var p = rs.linhas ? Math.round(100 * rs.contadas / rs.linhas) : 0;
      html += '<div class="inv-row" data-act="mp-abrir" data-id="' + i.id + '">' + H.retiroTag(i.retiro_id) +
        '<span class="num">' + mesBR(i.competencia) + '</span>' + chipInv(i.status) +
        '<div class="progress" title="' + p + '% das linhas contadas"><span style="width:' + p + '%"></span></div>' +
        '<span class="sub">sistema ' + n0(rs.sistema) + ' cab. · contado ' + n0(rs.campo) + ' · ' + n0(rs.contadas) + '/' + n0(rs.linhas) + ' linhas' +
        (rs.divergentes ? ' · <b style="color:var(--bad)">' + rs.divergentes + ' divergência(s)</b>' : '') +
        (i.contado_por_nome ? ' · contado por ' + esc(i.contado_por_nome) : '') + '</span></div>';
    });
    el.innerHTML = html + '</div></div>';
  }

  function renderInv(el){
    var inv = M.det.dados; var d = D();
    var aberto = inv.status === 'EMITIDO' || inv.status === 'EM_CONTAGEM';
    var podeContar = store.tem('INV_CONTAR') && aberto, podeAjustar = store.tem('INV_AJUSTAR');
    var linhas = linhasContagem(inv);
    var tot = linhas.reduce(function(a, x){ a.sis += Number(x.qtd_sistema || 0); if(x.qtd_campo != null && x.qtd_campo !== ''){ a.campo += Number(x.qtd_campo); a.cont++; a.sisCont += Number(x.qtd_sistema || 0); } if(x.dif) a.div++; return a; }, { sis:0, campo:0, cont:0, sisCont:0, div:0 });
    var naFila = pendentesRpc('pec_inventario_contar', function(e){ return e.payload.args.p.inventario_id === inv.id; }).length;
    var rasc = Object.keys(rascunhos()[inv.id] || {}).length;

    var html = '<div class="stack"><div><button class="back-link" data-act="mp-voltar" type="button">← Mapões</button></div>' +
      '<div class="card panel-pad"><div class="spread"><div><h2 class="section-title">' + H.retiroTag(inv.retiro_id) + ' · Mapão ' + mesBR(inv.competencia) + '</h2>' +
      '<p class="section-hint" style="margin:4px 0 0">Posição do sistema em ' + dataBR(inv.data_posicao) + (inv.emitido_por ? ' · emitido por ' + esc(inv.emitido_por) : '') + '</p></div>' + chipInv(inv.status) + '</div>' +
      (M.det.offline ? '<div class="msg warn" style="margin-top:10px">Sem internet: mostrando o Mapão guardado em ' + H.quandoBR(M.det.em) + '. A contagem fica na fila e segue quando a conexão voltar.</div>' : '') +
      '<div class="kpi-grid" style="margin-top:12px">' +
        kpi(n0(tot.sis), 'Cabeças no sistema') + kpi(n0(tot.campo), 'Contadas no campo', tot.cont + ' de ' + linhas.length + ' linhas') +
        kpi(difHtml(tot.campo - tot.sisCont).replace('class="dif', 'style="font-size:inherit" class="dif'), 'Diferença nas linhas contadas') + kpi(n0(tot.div), 'Linhas divergentes', '', tot.div ? 'alert' : '') +
      '</div>';
    if(podeContar){
      html += '<div class="grid-3" style="margin-top:14px">' +
        '<div class="field"><label for="mpData">Data da contagem</label><input class="input" type="date" id="mpData" value="' + (inv.data_contagem || H.hoje()) + '" max="' + H.hoje() + '"></div>' +
        '<div class="field"><label for="mpQuem">Contado por</label><input class="input" id="mpQuem" value="' + esc(inv.contado_por_nome || '') + '" placeholder="nome do vaqueiro"></div>' +
        '<div class="field"><label for="mpObs">Observação geral</label><input class="input" id="mpObs" value="' + esc(inv.observacao || '') + '"></div></div>';
    } else if(inv.contado_por_nome || inv.data_contagem){
      html += '<p class="muted" style="margin:10px 0 0; font-size:.86rem">Contado ' + (inv.data_contagem ? 'em ' + dataBR(inv.data_contagem) : '') + (inv.contado_por_nome ? ' por ' + esc(inv.contado_por_nome) : '') + (inv.observacao ? ' · ' + esc(inv.observacao) : '') + '</p>';
    }
    html += '<div class="row" style="margin-top:14px">' +
      '<button class="icon-btn" data-act="mp-imprimir-inv" type="button">Imprimir folha</button>' +
      (podeContar ? '<button class="icon-btn btn-primary" data-act="mp-concluir" type="button">Concluir contagem</button>' : '') +
      (inv.status === 'CONTADO' && podeAjustar ? '<button class="icon-btn btn-primary" data-act="mp-aprovar" type="button">Aprovar ajustes</button><button class="icon-btn" data-act="mp-reabrir" type="button">Reabrir contagem</button>' : '') +
      (inv.status !== 'AJUSTADO' && podeAjustar ? '<button class="icon-btn btn-danger" data-act="mp-cancelar" type="button">Cancelar Mapão</button>' : '') +
      '</div>' + (naFila || rasc ? '<p class="section-hint" style="margin:10px 0 0">' + (naFila ? naFila + ' pasto(s) na fila de envio. ' : '') + (rasc ? rasc + ' linha(s) digitadas e ainda não salvas — toque em "Salvar pasto".' : '') + '</p>' : '') + '</div>';

    if(inv.status === 'CONTADO' || inv.status === 'AJUSTADO') html += quadroDivergencias(inv, linhas);

    // cartões por pasto
    var porPasto = {};
    linhas.forEach(function(x){ var k = x.pasto_id || 'SEM'; (porPasto[k] = porPasto[k] || []).push(x); });
    var pastos = Object.keys(porPasto).sort(function(a, b){ return ordemPasto(a === 'SEM' ? null : a, b === 'SEM' ? null : b); });
    var vazios = H.pastosDo(inv.retiro_id).filter(function(p){ return !porPasto[p.id]; });
    html += '<div>';
    pastos.forEach(function(k){ html += cartaoPasto(inv, k === 'SEM' ? null : k, porPasto[k], podeContar); });
    html += '</div>';
    if(podeContar && vazios.length){
      html += '<details class="mais card panel-pad"><summary>Pastos sem gado no sistema (' + vazios.length + ') — anotar animais encontrados</summary><div class="row" style="margin-top:10px">' +
        vazios.map(function(p){ return '<button class="icon-btn btn-sm" data-act="mp-add-pasto" data-pasto="' + p.id + '" type="button">' + esc(p.codigo) + '</button>'; }).join('') + '</div></details>';
    }
    el.innerHTML = html + '</div>';
  }
  function kpi(v, l, s, cls){ return '<div class="card kpi ' + (cls || '') + '"><div class="v">' + v + '</div><div class="l">' + l + '</div>' + (s ? '<div class="s">' + s + '</div>' : '') + '</div>'; }

  function cartaoPasto(inv, pastoId, linhas, podeContar){
    var p = pastoId ? D().pas[pastoId] : null;
    linhas.sort(function(a, b){ return ((D().cat[a.categoria_id] || {}).ordem || 99) - ((D().cat[b.categoria_id] || {}).ordem || 99); });
    var sis = linhas.reduce(function(s, x){ return s + Number(x.qtd_sistema || 0); }, 0);
    var contadas = linhas.filter(function(x){ return x.qtd_campo != null && x.qtd_campo !== ''; });
    var emRasc = linhas.some(function(x){ return x.rascunho; }), emFila = linhas.some(function(x){ return x.naFila && !x.rascunho; });
    var est = emRasc ? '<span class="chip warn">não salvo</span>' : emFila ? '<span class="chip info">na fila</span>' :
              contadas.length === linhas.length ? '<span class="chip good">contado</span>' : contadas.length ? '<span class="chip warn">parcial</span>' : '<span class="chip neutral">não contado</span>';
    var html = '<div class="card pasto-card' + (pastoId ? '' : ' sem-pasto') + '" data-pasto-card="' + (pastoId || 'SEM') + '">' +
      '<div class="pasto-head"><span><b>' + esc(codPasto(pastoId)) + '</b> <span class="muted" style="font-size:.82rem">' + (p && Number(p.area_ha) ? n1(p.area_ha) + ' ha · ' : '') + n0(sis) + ' cab. no sistema</span></span>' + est + '</div>' +
      (pastoId ? '' : '<div class="msg warn" style="margin:10px 16px 0">Estes animais foram lançados sem pasto. No campo, anote-os no pasto onde estão (abra o pasto em "Pastos sem gado no sistema" se precisar) e deixe esta linha com 0.</div>') +
      '<div class="conta-row head"><span>Categoria</span><span style="text-align:right">Sistema</span><span style="text-align:right">Campo</span><span style="text-align:right">Dif.</span><span class="obs">Observação</span></div>';
    linhas.forEach(function(x){
      var k = chave(pastoId, x.categoria_id);
      html += '<div class="conta-row" data-k="' + k + '"><span>' + esc(nomeCat(x.categoria_id)) + '</span><span class="sis">' + n0(x.qtd_sistema) + '</span>' +
        (podeContar ? '<input class="input campo" inputmode="numeric" data-campo="' + k + '" value="' + (x.qtd_campo == null ? '' : x.qtd_campo) + '" aria-label="Contado: ' + esc(nomeCat(x.categoria_id)) + '">'
                    : '<span class="sis">' + (x.qtd_campo == null ? '—' : n0(x.qtd_campo)) + '</span>') +
        difHtml(x.dif) +
        (podeContar ? '<input class="input obs" data-obs="' + k + '" value="' + esc(x.observacao || '') + '" placeholder="obs.">' : '<span class="obs muted" style="font-size:.8rem">' + esc(x.observacao || '') + '</span>') + '</div>';
    });
    if(podeContar){
      var presentes = linhas.map(function(x){ return x.categoria_id; });
      var outras = H.categorias(function(c){ return presentes.indexOf(c.id) < 0; });
      html += '<div class="pasto-foot"><select class="select" data-addcat="' + (pastoId || 'SEM') + '" style="max-width:220px">' + opt('', '+ categoria encontrada') + outras.map(function(c){ return opt(c.id, c.nome); }).join('') + '</select>' +
        '<span class="row"><button class="icon-btn btn-sm" data-act="mp-bate" data-pasto="' + (pastoId || 'SEM') + '" type="button">Bate com o sistema</button>' +
        '<button class="icon-btn btn-sm btn-primary" data-act="mp-salvar-pasto" data-pasto="' + (pastoId || 'SEM') + '" type="button">Salvar pasto</button></span></div>';
    }
    return html + '</div>';
  }

  function quadroDivergencias(inv, linhas){
    var div = linhas.filter(function(x){ return x.dif; }).sort(function(a, b){ return ordemPasto(a.pasto_id, b.pasto_id); });
    var html = '<div class="card panel-pad"><h2 class="section-title">Divergências</h2>';
    if(!div.length) return html + '<p class="section-hint">Nenhuma: o campo bateu com o sistema em todas as linhas contadas.</p></div>';
    if(inv.status === 'CONTADO') html += '<p class="section-hint">Antes de aprovar, procure lançamentos que faltaram (morte, nascimento, transferência) e lance com data até ' + dataBR(inv.data_posicao) + '. Ao aprovar, o sistema recalcula e só ajusta o que ainda sobrar.</p>';
    html += '<div class="table-scroll"><table><thead><tr><th>Pasto</th><th>Categoria</th><th class="n">Sistema</th><th class="n">Campo</th><th class="n">Dif.</th><th>Grau</th><th>Ajuste</th></tr></thead><tbody>' +
      div.map(function(x){ var c = x.classe === 'ALTA' ? 'bad' : x.classe === 'MEDIA' ? 'warn' : 'info';
        return '<tr><td><b>' + esc(codPasto(x.pasto_id)) + '</b></td><td>' + esc(nomeCat(x.categoria_id)) + '</td><td class="n">' + n0(x.qtd_sistema) + '</td><td class="n">' + n0(x.qtd_campo) + '</td><td class="n">' + difHtml(x.dif) + '</td>' +
          '<td>' + (x.classe ? '<span class="chip ' + c + '">' + esc(String(x.classe).toLowerCase().replace('media', 'média')) + '</span>' : '') + '</td><td>' + (x.ajuste_numero ? 'nº ' + x.ajuste_numero : '—') + '</td></tr>'; }).join('') +
      '</tbody></table></div></div>';
    return html;
  }

  function lerLinhaTela(k){
    var c = $('[data-campo="' + k + '"]'), o = $('[data-obs="' + k + '"]');
    return { qtd: c ? c.value.trim() : '', obs: o ? o.value.trim() : '' };
  }
  function guardarRascunho(k){
    var inv = M.det && M.det.dados; if(!inv) return;
    var r = rascunhos(); r[inv.id] = r[inv.id] || {};
    var x = lerLinhaTela(k);
    r[inv.id][k] = { qtd: x.qtd === '' ? null : x.qtd, obs: x.obs };
    salvarRascunhos(r);
  }
  function salvarPasto(pastoKey){
    var inv = M.det.dados;
    var linhas = linhasContagem(inv).filter(function(x){ return (x.pasto_id || 'SEM') === pastoKey; });
    var itens = [], erro = null;
    linhas.forEach(function(x){
      var k = chave(x.pasto_id, x.categoria_id), t = lerLinhaTela(k);
      if(t.qtd !== '' && !/^\d+$/.test(t.qtd)) erro = 'Contagem de ' + nomeCat(x.categoria_id) + ' em ' + codPasto(x.pasto_id) + ': use só números inteiros.';
      if(t.qtd === '' && x.qtd_campo == null && !t.obs) return;     // não contado e sem nada a dizer
      itens.push({ pasto_id: x.pasto_id || null, categoria_id: x.categoria_id, qtd_campo: t.qtd === '' ? null : Number(t.qtd), observacao: t.obs || null });
    });
    if(erro) return toast(erro, true);
    if(!itens.length) return toast('Digite a contagem de pelo menos uma categoria deste pasto.', true);
    store.filaRpc('pec_inventario_contar', { p: { inventario_id: inv.id, data_contagem: ($('#mpData') || {}).value || H.hoje(),
      contado_por_nome: ($('#mpQuem') || {}).value || null, observacao: ($('#mpObs') || {}).value || null, itens: itens } },
      'Contagem ' + codPasto(pastoKey === 'SEM' ? null : pastoKey) + ' · Mapão ' + mesBR(inv.competencia));
    var r = rascunhos(); if(r[inv.id]){ Object.keys(r[inv.id]).forEach(function(k){ if(k.split('|')[0] === pastoKey) delete r[inv.id][k]; }); salvarRascunhos(r); }
    toast(store.status.online ? 'Pasto salvo.' : 'Pasto salvo no aparelho. Será enviado quando a internet voltar.');
    renderMapao();
    enviarEDepois(function(){ if(store.status.online && M.inv === inv.id && !pendentesRpc('pec_inventario_contar').length) return carregarInv(inv.id); });
  }

  async function imprimirMapoes(retiros, competencia){
    var area = $('#printArea'), html = '';
    try{
      for(var i = 0; i < retiros.length; i++){
        var r = await store.consultar('pec_mapao', { p_retiro: retiros[i], p_competencia: competencia }, 'mapao:' + retiros[i] + ':' + competencia);
        html += folhaMapao(r.dados);
      }
    }catch(e){ return toast(erroMsg(e), true); }
    area.innerHTML = html;
    if(window.PEC_SEM_IMPRESSAO){ area.classList.add('preview'); return; }   /* usado pelo teste automático */
    setTimeout(function(){ window.print(); }, 50);
  }
  var ROTULO = { 'Vaca':'VACA', 'Primípara':'PRIMÍPARA', 'Novilha Matriz':'NOVILHA', 'Leiteira':'LEITEIRA', 'Bez. Macho':'BEZ. MACHO MAM.', 'Bez. Fêmea':'BEZ. FÊMEA MAM.',
    'Vaca Descarte':'VACA DESCARTE', 'Desmama Fêmea':'DESMAME 8 a 12 m', 'Novilha':'NOVILHAS 13 a 24 m', 'Fêmea Descarte':'DESCARTE', 'Desmama Macho':'DESMAME 8 a 12 m',
    'Garrote':'GARROTE 13 a 24 m', 'Boi':'BOI > 24 m', 'Touro':'TOURO' };
  function grupoMapao(c){ var o = c.ordem; return o <= 4 ? 'MATRIZES' : (o >= 8 && o <= 10) ? 'FÊMEAS' : (o >= 11 && o <= 13) ? 'MACHOS' : ''; }
  function folhaMapao(m){
    var cats = H.categorias().slice().sort(function(a, b){ return a.ordem - b.ordem; });
    var pastos = H.pastosDo(m.retiro_id).map(function(p){ return p.id; });
    var val = {}, semp = false;
    (m.linhas || []).forEach(function(l){ var k = (l.pasto_id || 'SEM') + '|' + l.categoria_id; val[k] = (val[k] || 0) + Number(l.cabecas); if(!l.pasto_id) semp = true; if(l.pasto_id && pastos.indexOf(l.pasto_id) < 0) pastos.push(l.pasto_id); });
    var campo = {}, temCampo = false;
    if(m.inventario && m.inventario.status !== 'EMITIDO'){
      (m.inventario.itens || []).forEach(function(it){ var k = it.pasto_id || 'SEM'; if(it.qtd_campo != null){ campo[k] = (campo[k] || 0) + Number(it.qtd_campo); temCampo = true; } });
    }
    pastos.sort(ordemPasto); if(semp) pastos.push('SEM');
    // cabeçalho em dois níveis, como na planilha
    var h1 = '<th rowspan="2" style="width:7%">PASTO</th><th rowspan="2" style="width:4.5%">ÁREA (ha)</th>', h2 = '', ultimo = null, span = 0, grupos = [];
    cats.forEach(function(c){ var g = grupoMapao(c); if(g && g === ultimo){ grupos[grupos.length - 1].n++; } else grupos.push({ g: g, n: 1, c: c }); ultimo = g; });
    grupos.forEach(function(g){
      if(g.g){ h1 += '<th colspan="' + g.n + '">' + g.g + '</th>'; }
      else h1 += '<th rowspan="2">' + esc(ROTULO[g.c.nome] || g.c.nome.toUpperCase()) + '</th>';
    });
    cats.forEach(function(c){ if(grupoMapao(c)) h2 += '<th>' + esc(ROTULO[c.nome] || c.nome.toUpperCase()) + '</th>'; });
    h1 += '<th rowspan="2" style="width:4.5%">TOTAL</th><th rowspan="2" style="width:6%">CONTADO NO CAMPO</th><th rowspan="2" style="width:14%">OBSERVAÇÃO</th>';
    var tot = {}, totG = 0, totArea = 0, totCampo = 0;
    var corpo = pastos.map(function(pid){
      var p = pid === 'SEM' ? null : D().pas[pid]; var soma = 0;
      var tds = cats.map(function(c){ var x = val[pid + '|' + c.id] || 0; soma += x; tot[c.id] = (tot[c.id] || 0) + x; return '<td class="n">' + (x ? n0(x) : '') + '</td>'; }).join('');
      totG += soma; if(p) totArea += Number(p.area_ha || 0); if(campo[pid] != null) totCampo += campo[pid];
      return '<tr class="' + (pid === 'SEM' ? 'semp' : '') + '"><td><b>' + esc(pid === 'SEM' ? 'SEM PASTO' : codPasto(pid)) + '</b></td><td class="n">' + (p && Number(p.area_ha) ? n1(p.area_ha) : '') + '</td>' + tds +
        '<td class="n"><b>' + (soma ? n0(soma) : '') + '</b></td><td class="n campo">' + (campo[pid] != null ? n0(campo[pid]) : '') + '</td><td></td></tr>';
    }).join('');
    var r = D().ret[m.retiro_id] || {};
    return '<section class="mapa-print"><div class="topo"><span><b>RETIRO: ' + esc(String(r.nome || '').toUpperCase()) + '</b></span><h2>MAPA DE EFETIVO PECUÁRIO</h2><span>MÊS: ' + mesBR(m.competencia) + ' • posição em ' + dataBR(m.posicao) + '</span></div>' +
      '<p class="nota">Estoque por pasto na data da posição (saldo anterior + entradas − saídas). Confira no campo e anote na coluna CONTADO NO CAMPO.</p>' +
      '<table><thead><tr>' + h1 + '</tr><tr>' + h2 + '</tr></thead><tbody>' + corpo +
      '<tr class="total"><td>TOTAL</td><td class="n">' + (totArea ? n1(totArea) : '') + '</td>' + cats.map(function(c){ return '<td class="n">' + (tot[c.id] ? n0(tot[c.id]) : '') + '</td>'; }).join('') +
      '<td class="n">' + n0(totG) + '</td><td class="n campo">' + (temCampo ? n0(totCampo) : '') + '</td><td></td></tr></tbody></table>' +
      '<p class="confere">Conferência (saldo anterior + entradas − saídas): ' + n0(totG) + ' cab.' + (semp ? ' — atenção: há animais sem pasto informado.' : '') + '</p>' +
      '<div class="assin"><span>Vaqueiro: ______________________________</span><span>Encarregado: ______________________________</span><span>Data da contagem: ____/____/________</span></div></section>';
  }

  X.abrir.conferencia = function(){ if(M.inv) carregarInv(M.inv); else carregarLista(); };
  X.render.push(function(){ if(A.ui.tab === 'conferencia') renderMapao(); });
  X.acoes['mp-emitir'] = async function(){
    var ret = $('#mpRet').value, mes = $('#mpMes').value;
    if(!ret || !/^\d{4}-\d{2}$/.test(mes)) return toast('Escolha o retiro e o mês.', true);
    try{ var r = await store.executar('pec_inventario_emitir', { p_retiro: ret, p_competencia: mes + '-01' });
      if(r.ja_existia) toast('Este Mapão já tinha sido emitido. Abrindo.');
      M.inv = r.id; M.det = { dados: r, em: new Date().toISOString(), offline: false }; renderMapao(); window.scrollTo({top:0});
      carregarInv(r.id);
    }catch(e){ toast(erroMsg(e), true); }
  };
  X.acoes['mp-imprimir'] = function(){ var mes = $('#mpMes').value; if(!/^\d{4}-\d{2}$/.test(mes)) return toast('Escolha o mês.', true); imprimirMapoes([$('#mpRet').value], mes + '-01'); };
  X.acoes['mp-imprimir-inv'] = function(){ var i = M.det.dados; imprimirMapoes([i.retiro_id], i.competencia); };
  X.acoes['mp-abrir'] = function(t){ M.inv = t.getAttribute('data-id'); M.det = store.guardado('inv:' + M.inv); renderMapao(); carregarInv(M.inv); window.scrollTo({top:0}); };
  X.acoes['mp-voltar'] = function(){ M.inv = null; M.det = null; carregarLista(); };
  X.acoes['mp-bate'] = function(t){
    var pk = t.getAttribute('data-pasto');
    $$('[data-pasto-card="' + pk + '"] .conta-row[data-k]').forEach(function(row){
      var k = row.getAttribute('data-k'), inp = $('[data-campo="' + k + '"]', row);
      inp.value = String(Number(row.querySelector('.sis').textContent.replace(/\./g, '')) || 0); guardarRascunho(k);
    });
    salvarPasto(pk);
  };
  X.acoes['mp-salvar-pasto'] = function(t){ salvarPasto(t.getAttribute('data-pasto')); };
  X.acoes['mp-add-pasto'] = function(t){
    var pid = t.getAttribute('data-pasto'), inv = M.det.dados;
    H.montar('Anotar animais em ' + codPasto(pid), H.fSel('cat', 'Categoria', opt('', 'Escolha') + H.categorias().map(function(c){ return opt(c.id, c.nome); }).join('')) + H.fNum('qtd', 'Quantidade encontrada'),
      function(form){ H.exigir(v(form, 'cat'), 'Escolha a categoria.'); var q = H.num(v(form, 'qtd')); H.exigir(Number.isInteger(q) && q >= 0, 'Quantidade inválida.');
        var r = rascunhos(); r[inv.id] = r[inv.id] || {}; r[inv.id][chave(pid, v(form, 'cat'))] = { qtd: String(q), obs: '' }; salvarRascunhos(r);
        H.fecharSheet(); renderMapao(); var c = $('[data-pasto-card="' + pid + '"]'); if(c) c.scrollIntoView({block:'center'}); }, null, 'Anotar');
  };
  X.acoes['mp-concluir'] = async function(){
    var inv = M.det.dados;
    if(Object.keys(rascunhos()[inv.id] || {}).length) return toast('Há linhas digitadas e não salvas. Toque em "Salvar pasto" antes.', true);
    try{ await store.enviar(); }catch(e){}
    if(pendentesRpc('pec_inventario_contar', function(e){ return e.payload.args.p.inventario_id === inv.id; }).length)
      return toast('A contagem ainda está na fila do aparelho. Conecte-se à internet para concluir.', true);
    await carregarInv(inv.id);
    var l = linhasContagem(M.det.dados), naoCont = l.filter(function(x){ return (x.qtd_campo == null || x.qtd_campo === '') && Number(x.qtd_sistema); });
    H.montar('Concluir contagem',
      '<p>Depois de concluir, a contagem não pode mais ser editada pelo vaqueiro. As diferenças viram pendências para o escritório investigar.</p>' +
      (naoCont.length ? '<div class="msg warn">' + naoCont.length + ' linha(s) com gado no sistema não foram contadas: ' + naoCont.slice(0, 8).map(function(x){ return esc(codPasto(x.pasto_id) + ' ' + nomeCat(x.categoria_id)); }).join(', ') + (naoCont.length > 8 ? '…' : '') + '. Elas ficam sem ajuste.</div>' : '<div class="msg ok">Todas as linhas com gado foram contadas.</div>'),
      async function(){ var r = await store.executar('pec_inventario_concluir', { p_id: inv.id });
        H.fecharSheet(); toast(r.divergencias ? r.divergencias + ' divergência(s) registradas em Pendências.' : 'Contagem concluída: bateu tudo.');
        M.det = { dados: r.inventario, em: new Date().toISOString() }; renderMapao(); }, null, 'Concluir contagem');
  };
  X.acoes['mp-aprovar'] = function(){
    var inv = M.det.dados; var div = (inv.itens || []).filter(function(x){ return x.diferenca; });
    H.montar('Aprovar ajustes de inventário',
      '<p>Cada linha divergente vira um lançamento <b>Ajuste de Inventário</b> com data de ' + dataBR(inv.data_posicao) + ', com o seu nome. O sistema recalcula antes: se alguém já lançou o que faltava, o ajuste fica menor.</p>' +
      '<div class="msg info">' + div.length + ' linha(s) divergentes no momento: saldo ' + n0(div.reduce(function(s, x){ return s + Number(x.diferenca); }, 0)) + ' cab.</div>' + H.fTxt('motivo', 'Motivo (vai no lançamento)', 'value="Conferência de campo — Mapão ' + mesBR(inv.competencia) + '"'),
      async function(form){ var r = await store.executar('pec_inventario_aprovar', { p_id: inv.id, p_motivo: v(form, 'motivo') });
        H.fecharSheet(); toast(r.ajustes + ' ajuste(s) lançados no Livro.'); M.det = { dados: r.inventario, em: new Date().toISOString() }; renderMapao(); }, null, 'Aprovar e lançar ajustes');
  };
  X.acoes['mp-reabrir'] = async function(){ try{ await store.executar('pec_inventario_reabrir', { p_id: M.det.dados.id }); toast('Contagem reaberta.'); carregarInv(M.det.dados.id); }catch(e){ toast(erroMsg(e), true); } };
  X.acoes['mp-cancelar'] = async function(){ if(!confirm('Cancelar este Mapão? A contagem feita nele será descartada.')) return;
    try{ await store.executar('pec_inventario_cancelar', { p_id: M.det.dados.id }); toast('Mapão cancelado.'); M.inv = null; M.det = null; carregarLista(); }catch(e){ toast(erroMsg(e), true); } };
  X.mudar.push(function(t){
    if(t.id === 'mpRet') M.emRet = t.value;
    if(t.id === 'mpMes') M.emMes = t.value;
    if(t.hasAttribute && t.hasAttribute('data-addcat') && t.value){
      var inv = M.det.dados, pk = t.getAttribute('data-addcat');
      var r = rascunhos(); r[inv.id] = r[inv.id] || {}; r[inv.id][chave(pk === 'SEM' ? null : pk, t.value)] = { qtd: null, obs: '' }; salvarRascunhos(r); renderMapao();
      var inp = $('[data-campo="' + chave(pk === 'SEM' ? null : pk, t.value) + '"]'); if(inp) inp.focus();
    }
  });
  document.addEventListener('input', function(ev){
    var t = ev.target; var k = t.getAttribute && (t.getAttribute('data-campo') || t.getAttribute('data-obs'));
    if(!k || !M.det) return;
    guardarRascunho(k);
    if(t.hasAttribute('data-campo')){
      var row = t.closest('.conta-row'), sis = Number(row.querySelector('.sis').textContent.replace(/\./g, '')) || 0;
      var d = t.value.trim() === '' ? null : Number(t.value) - sis; row.querySelector('.dif').outerHTML = difHtml(isNaN(d) ? null : d);
      var card = t.closest('.pasto-card'); var chip = card.querySelector('.pasto-head .chip'); if(chip){ chip.className = 'chip warn'; chip.textContent = 'não salvo'; }
    }
  });

  /* ==========================================================================
     REPRODUÇÃO
     ========================================================================== */
  var R = { est: null, dados: null };
  async function carregarRepro(){
    var chaveR = 'repro:' + (R.est || 'atual');
    try{ R.dados = await store.consultar('pec_reproducao', { p_estacao: R.est }, chaveR); }
    catch(e){ R.dados = store.guardado(chaveR) || (R.dados && R.dados.dados ? Object.assign({}, R.dados, { offline: true }) : { dados: null, erro: erroMsg(e) }); }
    if(R.dados && R.dados.dados && R.dados.dados.estacao) R.est = R.dados.dados.estacao.id;
    renderRepro();
  }
  function txt(a, b){ return b ? pct(a / b) : '—'; }
  function renderRepro(){
    var el = $('#panel-reproducao'); if(!el || !store.sessao) return;
    var pode = store.tem('REPRO_LANCAR');
    var d = R.dados && R.dados.dados;
    if(!R.dados){ el.innerHTML = '<div class="card empty">Carregando…</div>'; return; }
    if(!d){ el.innerHTML = '<div class="card panel-pad"><div class="msg err">' + esc(R.dados.erro || 'Sem dados.') + '</div></div>'; return; }
    var e = d.estacao, fila = pendentesRpc(null).length;
    var html = '<div class="stack"><div class="card panel-pad"><div class="spread"><h2 class="section-title">Estação de monta</h2><span class="row">' +
      (pode ? '<button class="icon-btn btn-sm" data-act="rp-estacao" type="button">+ Nova estação</button>' + (e ? '<button class="icon-btn btn-sm" data-act="rp-estacao" data-id="' + e.id + '" type="button">Editar</button>' : '') : '') + '</span></div>';
    if(!e){
      el.innerHTML = html + '<p class="section-hint">Nenhuma estação cadastrada. Comece pela estação de monta (ex.: "Estação 26/27", de novembro a fevereiro). Para ter natalidade e desmame desta safra, cadastre também a estação anterior, que gerou os bezerros que estão nascendo.</p></div></div>';
      return;
    }
    html += '<div class="filters" style="margin-top:8px"><div class="field"><label for="rpEst">Estação</label><select class="select" id="rpEst">' + d.estacoes.map(function(x){ return opt(x.id, x.nome + ' (' + dataBR(x.inicio) + ' a ' + dataBR(x.fim) + ')', x.id === e.id); }).join('') + '</select></div></div>' +
      '<p class="section-hint" style="margin-top:8px">Monta na safra ' + esc(e.safra || '—') + '. Os partos desta estação caem na safra <b>' + esc(e.safra_paricao || '—') + '</b>, onde ficam a natalidade e o desmame.' + (R.dados.offline ? ' <span class="chip warn">sem internet · dados de ' + H.quandoBR(R.dados.em) + '</span>' : '') + (fila ? ' <span class="chip info">' + fila + ' alteração(ões) na fila</span>' : '') + '</p></div>';

    var tExp = 0, tPre = 0, tIns1 = 0, tPre1 = 0, comDg = true;
    d.prenhez.forEach(function(x){ tExp += Number(x.expostas || 0); tPre += Number(x.prenhes || 0); tIns1 += Number(x.inseminadas_1a || 0); tPre1 += Number(x.prenhes_1a || 0); if(!x.com_dg) comDg = false; });
    /* totais das taxas só com os retiros que têm fêmeas expostas nesta estação (senão a natalidade passa de 100%) */
    var par = d.paricao.reduce(function(a, x){ a.nascTot += Number(x.nascimentos); a.desmTot += Number(x.desmamados); a.kgTot += Number(x.peso_desmama);
      if(Number(x.expostas) > 0){ a.exp += Number(x.expostas); a.nasc += Number(x.nascimentos); a.desm += Number(x.desmamados); a.kg += Number(x.peso_desmama); } return a; },
      { exp:0, nasc:0, desm:0, kg:0, nascTot:0, desmTot:0, kgTot:0 });
    html += '<div class="kpi-grid">' + kpi(n0(tExp), 'Fêmeas expostas') + kpi(n0(tPre), 'Prenhes no DG', comDg ? '' : 'falta DG em algum lote') +
      kpi(txt(tPre, tExp), 'Taxa de prenhez', 'prenhes ÷ expostas') + kpi(txt(tPre1, tIns1), 'Concepção na 1ª IATF', n0(tPre1) + ' de ' + n0(tIns1) + ' inseminadas') + '</div>';

    // agenda
    html += '<div class="card panel-pad"><h2 class="section-title">Agenda de manejo</h2><p class="section-hint">D8, IATF e DG previstos nos próximos 45 dias, e DG atrasado (IATF + ' + d.dias_ate_dg + ' dias sem diagnóstico).</p>';
    if(!d.agenda.length) html += '<div class="empty" style="padding:12px">Nada agendado.</div>';
    d.agenda.forEach(function(a){
      html += '<div class="agenda-item' + (a.atrasado ? ' atrasado' : '') + '"><span class="quando">' + dataBR(a.data) + (a.atrasado ? ' atrasado' : '') + '</span><span class="chip ' + (a.evento === 'DG' ? 'info' : 'neutral') + '">' + a.evento + ' · ' + a.rodada + 'ª</span><span>' + H.retiroTag(a.retiro_id) + ' · ' + esc(nomeCat(a.categoria_id)) + (a.lote_id ? ' · ' + esc((D().lot[a.lote_id] || {}).codigo || '') : '') + '</span></div>';
    });
    html += '</div>';

    // quadro 1: retiro × categoria
    var cats = []; d.prenhez.forEach(function(x){ if(cats.indexOf(x.categoria_id) < 0) cats.push(x.categoria_id); });
    cats.sort(function(a, b){ return (D().cat[a] || {}).ordem - (D().cat[b] || {}).ordem; });
    var rets = []; d.prenhez.forEach(function(x){ if(rets.indexOf(x.retiro_id) < 0) rets.push(x.retiro_id); });
    html += '<div class="card"><div class="panel-pad" style="padding-bottom:8px"><h2 class="section-title">Exposição e prenhez por categoria</h2><p class="section-hint" style="margin-bottom:0">Primíparas costumam ter a menor prenhez do rebanho. Referência em cria Nelore bem manejada: vacas 80–90%, primíparas 60–75%, novilhas 80–90%.</p></div>';
    if(!rets.length) html += '<div class="empty">Nenhum lote nesta estação ainda.</div>';
    else {
      html += '<div class="table-scroll" style="border:none; border-top:1px solid var(--border); border-radius:0 0 12px 12px"><table><thead><tr><th rowspan="2">Retiro</th>' + cats.map(function(c){ return '<th class="grp" colspan="3">' + esc(nomeCat(c)) + '</th>'; }).join('') + '<th class="grp" colspan="3">Total</th></tr><tr>' +
        cats.concat(['T']).map(function(){ return '<th class="n bl">Expostas</th><th class="n">Prenhes</th><th class="n">Taxa</th>'; }).join('') + '</tr></thead><tbody>';
      var totC = {};
      rets.forEach(function(r){
        var te = 0, tp = 0;
        html += '<tr><td>' + H.retiroTag(r) + '</td>' + cats.map(function(c){
          var x = d.prenhez.find(function(y){ return y.retiro_id === r && y.categoria_id === c; });
          if(!x) return '<td class="n bl zero">·</td><td class="n zero">·</td><td class="n zero">·</td>';
          te += Number(x.expostas); tp += Number(x.prenhes || 0); totC[c] = totC[c] || { e:0, p:0 }; totC[c].e += Number(x.expostas); totC[c].p += Number(x.prenhes || 0);
          return '<td class="n bl">' + n0(x.expostas) + '</td><td class="n">' + (x.prenhes == null ? '—' : n0(x.prenhes)) + '</td><td class="n taxa">' + (x.prenhes == null ? '—' : txt(x.prenhes, x.expostas)) + '</td>';
        }).join('') + '<td class="n bl"><b>' + n0(te) + '</b></td><td class="n"><b>' + n0(tp) + '</b></td><td class="n taxa">' + txt(tp, te) + '</td></tr>';
      });
      html += '</tbody><tfoot><tr><td>Total</td>' + cats.map(function(c){ var t = totC[c] || { e:0, p:0 }; return '<td class="n bl">' + n0(t.e) + '</td><td class="n">' + n0(t.p) + '</td><td class="n">' + txt(t.p, t.e) + '</td>'; }).join('') +
        '<td class="n bl">' + n0(tExp) + '</td><td class="n">' + n0(tPre) + '</td><td class="n">' + txt(tPre, tExp) + '</td></tr></tfoot></table></div>';
    }
    html += '</div>';

    // lotes
    html += '<div class="spread"><h2 class="section-title">Lotes expostos</h2>' + (pode ? '<button class="icon-btn btn-primary" data-act="rp-lote" type="button">+ Lote reprodutivo</button>' : '') + '</div>';
    if(!d.lotes.length) html += '<div class="card empty">Cadastre os lotes de fêmeas expostas nesta estação: retiro, categoria (vaca, primípara, novilha) e quantas foram expostas.</div>';
    d.lotes.forEach(function(l){ html += cartaoLote(l, pode); });

    // quadro 2: parição e desmama
    html += '<div class="card"><div class="panel-pad" style="padding-bottom:8px"><h2 class="section-title">Parição e desmama — safra ' + esc(e.safra_paricao || '—') + '</h2><p class="section-hint" style="margin-bottom:0">Natalidade = nascimentos ÷ fêmeas expostas nesta estação. Desmame = desmamados ÷ expostas. kg/matriz = peso total desmamado ÷ expostas. Os nascimentos e desmamas vêm do Livro.</p></div>';
    if(!d.paricao.length) html += '<div class="empty">Sem dados de parição ainda.</div>';
    else {
      html += '<div class="table-scroll" style="border:none; border-top:1px solid var(--border); border-radius:0 0 12px 12px"><table><thead><tr><th>Retiro</th><th class="n">Expostas</th><th class="n">Nascimentos</th><th class="n">Natalidade</th><th class="n">Mortes bez.</th><th class="n">Desmamados</th><th class="n">Taxa desmame</th><th class="n">Peso total (kg)</th><th class="n">Peso médio</th><th class="n">kg/matriz</th></tr></thead><tbody>' +
        d.paricao.map(function(x){ return '<tr><td>' + H.retiroTag(x.retiro_id) + '</td><td class="n">' + n0(x.expostas) + '</td><td class="n">' + n0(x.nascimentos) + '</td><td class="n taxa">' + txt(x.nascimentos, x.expostas) + '</td><td class="n">' + n0(x.mortes_bezerros) + '</td><td class="n">' + n0(x.desmamados) + '</td><td class="n taxa">' + txt(x.desmamados, x.expostas) + '</td><td class="n">' + n0(x.peso_desmama) + '</td><td class="n">' + (Number(x.desmamados) && Number(x.peso_desmama) ? n1(x.peso_desmama / x.desmamados) : '—') + '</td><td class="n">' + (Number(x.expostas) && Number(x.peso_desmama) ? n1(x.peso_desmama / x.expostas) : '—') + '</td></tr>'; }).join('') +
        '</tbody><tfoot><tr><td>Total</td><td class="n">' + n0(par.exp) + '</td><td class="n">' + n0(par.nascTot) + '</td><td class="n">' + txt(par.nasc, par.exp) + '</td><td class="n">' + n0(d.paricao.reduce(function(s, x){ return s + Number(x.mortes_bezerros); }, 0)) + '</td><td class="n">' + n0(par.desmTot) + '</td><td class="n">' + txt(par.desm, par.exp) + '</td><td class="n">' + n0(par.kgTot) + '</td><td class="n">' + (par.desmTot && par.kgTot ? n1(par.kgTot / par.desmTot) : '—') + '</td><td class="n">' + (par.exp && par.kg ? n1(par.kg / par.exp) : '—') + '</td></tr></tfoot></table></div>' +
        (d.paricao.some(function(x){ return !Number(x.expostas) && Number(x.nascimentos); }) ? '<p class="section-hint" style="padding:0 20px 14px">Retiros sem lote cadastrado nesta estação ficam fora das taxas do total. Cadastre os lotes deles para a natalidade da fazenda inteira.</p>' : '');
    }
    if(d.desmama.length){
      html += '<div class="panel-pad"><h3 style="font-size:1rem">Desmamas com peso</h3><div class="table-scroll" style="margin-top:8px"><table><thead><tr><th>Data</th><th>Retiro</th><th>Sexo</th><th class="n">Cab.</th><th class="n">Peso médio</th><th class="n">Idade (dias)</th><th class="n">GMD (kg/dia)</th><th class="n">P205 (kg)</th></tr></thead><tbody>' +
        d.desmama.map(function(x){ return '<tr><td>' + dataBR(x.data) + '</td><td>' + (x.retiro_id ? H.retiroTag(x.retiro_id) : '—') + '</td><td>' + (x.sexo === 'M' ? 'Machos' : 'Fêmeas') + '</td><td class="n">' + n0(x.quantidade) + '</td><td class="n">' + n1(x.peso_medio_kg) + '</td><td class="n">' + (x.idade_dias == null ? '—' : n0(x.idade_dias)) + '</td><td class="n">' + (x.gmd_kg_dia == null ? '—' : H.nf3.format(x.gmd_kg_dia)) + '</td><td class="n">' + (x.p205_kg == null ? '—' : n1(x.p205_kg)) + '</td></tr>'; }).join('') +
        '</tbody></table></div><p class="section-hint" style="margin-top:6px">GMD e P205 aparecem quando a desmama é lançada com a data média de nascimento. Peso ao nascer padrão: ' + H.parametro('PN_PADRAO_M', 32) + ' kg machos, ' + H.parametro('PN_PADRAO_F', 30) + ' kg fêmeas.</p></div>';
    }
    html += '</div>';
    el.innerHTML = html + '</div>';
  }
  function cartaoLote(l, pode){
    var lt = l.lote_id ? D().lot[l.lote_id] : null;
    var html = '<div class="card lote-card"><div class="lote-head"><div><span class="t">' + H.retiroTag(l.retiro_id) + ' · ' + esc(nomeCat(l.categoria_id)) + (lt ? ' · ' + esc(lt.codigo) : '') + '</span>' +
      '<div class="muted" style="font-size:.82rem">' + n0(l.qtd_expostas) + ' expostas' + (l.ecc_medio ? ' · ECC ' + n1(l.ecc_medio) : '') + (l.carimbo_bezerro ? ' · bezerros ' + esc(l.carimbo_bezerro) : '') + (l.observacao ? ' · ' + esc(l.observacao) : '') + '</div></div>' +
      '<div class="row"><span class="taxa" title="Taxa de prenhez">' + (l.taxa_prenhez == null ? 'sem DG' : pct(l.taxa_prenhez) + ' prenhez') + '</span>' +
      (pode ? '<button class="icon-btn btn-sm" data-act="rp-lote" data-id="' + l.id + '" type="button">Editar</button>' : '') + '</div></div>';
    if(l.rodadas.length){
      html += '<div class="table-scroll" style="border:none; border-radius:0"><table><thead><tr><th>Rodada</th><th>Protocolo</th><th>D0</th><th>IATF</th><th class="n">Insem.</th><th>Touro / sêmen</th><th>DG</th><th class="n">Prenhes</th><th class="n">Vazias</th><th class="n">Concepção</th>' + (pode ? '<th></th>' : '') + '</tr></thead><tbody>' +
        l.rodadas.map(function(r){ return '<tr><td><b>' + r.rodada + 'ª</b> <span class="faint">' + esc(({IATF:'IATF', RESSINCRONIZACAO:'ressinc.', REPASSE_TOURO:'repasse', MONTA_NATURAL:'monta'})[r.tipo] || r.tipo) + '</span></td><td>' + esc(nomeProt(r.protocolo_id)) + '</td><td>' + dataBR(r.data_d0) + '</td><td>' + dataBR(r.data_iatf) + '</td><td class="n">' + (r.qtd_inseminadas == null ? '—' : n0(r.qtd_inseminadas)) + '</td><td>' + esc(r.touro_semen || '—') + '</td><td>' + dataBR(r.data_dg) + '</td><td class="n">' + (r.qtd_prenhes == null ? '—' : n0(r.qtd_prenhes)) + '</td><td class="n">' + (r.qtd_vazias == null ? '—' : n0(r.qtd_vazias)) + '</td><td class="n taxa">' + (r.qtd_prenhes == null ? '—' : txt(r.qtd_prenhes, r.qtd_inseminadas)) + '</td>' +
          (pode ? '<td><button class="icon-btn btn-sm" data-act="rp-rodada" data-lote="' + l.id + '" data-id="' + r.id + '" type="button">Editar</button></td>' : '') + '</tr>'; }).join('') + '</tbody></table></div>';
    }
    var dg = l.dg_final;
    html += '<div class="pasto-foot"><span class="muted" style="font-size:.84rem">' + (dg ? '<b>DG final</b> ' + dataBR(dg.data_dg) + ': ' + n0(dg.qtd_prenhes) + ' prenhes, ' + n0(dg.qtd_vazias) + ' vazias' + (dg.qtd_descarte ? ', ' + n0(dg.qtd_descarte) + ' para descarte' : '') : 'Sem DG final (vale a soma das rodadas).') + '</span>' +
      (pode ? '<span class="row"><button class="icon-btn btn-sm" data-act="rp-rodada" data-lote="' + l.id + '" type="button">+ ' + (l.rodadas.length + 1) + 'ª rodada</button><button class="icon-btn btn-sm" data-act="rp-dg" data-lote="' + l.id + '" type="button">DG final</button></span>' : '') + '</div>';
    return html + '</div>';
  }
  function nomeProt(id){ var p = ((R.dados && R.dados.dados && R.dados.dados.protocolos) || []).find(function(x){ return x.id === id; }); return p ? p.nome : '—'; }
  function salvarRepro(fn, p, resumo){
    store.filaRpc(fn, { p: p }, resumo);
    H.fecharSheet(); toast(store.status.online ? 'Salvo.' : 'Salvo no aparelho. Será enviado quando a internet voltar.');
    renderRepro();
    enviarEDepois(async function(){
      var rec = store.fila.filter(function(e){ return e.tipo === 'rpc' && e.estado === 'recusado' && e.payload.fn === fn; });
      if(rec.length) toast('Recusado: ' + rec[rec.length - 1].erro + ' Corrija em Lançar → fila.', true);
      if(store.status.online) await carregarRepro();
    });
  }
  function achaLote(id){ return R.dados.dados.lotes.find(function(x){ return x.id === id; }); }
  X.abrir.reproducao = function(){ carregarRepro(); };
  X.render.push(function(){ if(A.ui.tab === 'reproducao') renderRepro(); });
  X.mudar.push(function(t){ if(t.id === 'rpEst'){ R.est = t.value; R.dados = store.guardado('repro:' + t.value) || R.dados; carregarRepro(); } });
  X.acoes['rp-estacao'] = function(t){
    var id = t.getAttribute('data-id'); var e = id ? R.dados.dados.estacao : {};
    var ano = new Date().getFullYear();
    H.montar(id ? 'Editar estação' : 'Nova estação de monta',
      H.fTxt('nome', 'Nome', 'value="' + esc(e.nome || ('Estação ' + String(ano).slice(2) + '/' + String(ano + 1).slice(2))) + '"') +
      '<div class="grid-2"><div class="field"><label for="ini">Início</label><input class="input" type="date" id="ini" name="ini" value="' + (e.inicio || ano + '-11-01') + '"></div>' +
      '<div class="field"><label for="fim">Fim</label><input class="input" type="date" id="fim" name="fim" value="' + (e.fim || (ano + 1) + '-02-28') + '"></div></div>' +
      '<p class="section-hint">A safra (julho a junho) é criada sozinha se ainda não existir.</p>',
      function(form){ H.exigir(v(form, 'nome').trim(), 'Dê um nome à estação.'); H.exigir(v(form, 'ini') && v(form, 'fim') && v(form, 'fim') > v(form, 'ini'), 'O fim precisa ser depois do início.');
        var nid = id || store.uuid(); R.est = nid;
        salvarRepro('pec_estacao_salvar', { id: nid, nome: v(form, 'nome').trim(), inicio: v(form, 'ini'), fim: v(form, 'fim') }, 'Estação ' + v(form, 'nome').trim()); }, null, 'Salvar estação');
  };
  X.acoes['rp-lote'] = function(t){
    var id = t.getAttribute('data-id'); var l = id ? achaLote(id) : {};
    var matrizes = H.categorias(function(c){ return c.sexo === 'F' && (c.eh_matriz || c.fase === 'RECRIA'); });
    var form = H.montar(id ? 'Editar lote reprodutivo' : 'Novo lote reprodutivo',
      '<div class="grid-3">' + H.fSel('ret', 'Retiro', H.retirosLiberados().map(function(r){ return opt(r.id, r.nome, r.id === l.retiro_id); }).join('')) +
      H.fSel('cat', 'Categoria', matrizes.map(function(c){ return opt(c.id, c.nome, c.id === l.categoria_id); }).join('')) + H.fSel('lote', 'Lote', '') + '</div>' +
      '<div class="grid-3">' + H.fNum('exp', 'Fêmeas expostas', 'value="' + (l.qtd_expostas || '') + '"', ' ') + H.fNum('ecc', 'ECC médio (1 a 5)', 'value="' + (l.ecc_medio || '') + '"') + H.fTxt('carimbo', 'Carimbo dos bezerros', 'value="' + esc(l.carimbo_bezerro || '') + '" placeholder="ex.: Cr9"') + '</div>' +
      H.fObs() + (id && !l.rodadas.length && !l.dg_final ? '<button class="icon-btn btn-sm btn-danger" data-act="rp-excluir" data-tipo="lote" data-id="' + id + '" type="button" style="align-self:flex-start">Excluir lote</button>' : ''),
      function(form){
        var q = H.num(v(form, 'exp')); H.exigir(Number.isInteger(q) && q > 0, 'Informe quantas fêmeas foram expostas.');
        var ecc = H.num(v(form, 'ecc')); H.exigir(isNaN(ecc) || (ecc >= 1 && ecc <= 5), 'ECC vai de 1 a 5.');
        salvarRepro('pec_lote_reprodutivo_salvar', { id: id || store.uuid(), estacao_id: R.est, retiro_id: v(form, 'ret'), categoria_id: v(form, 'cat'), lote_id: v(form, 'lote') || null,
          qtd_expostas: q, ecc_medio: isNaN(ecc) ? null : ecc, carimbo_bezerro: v(form, 'carimbo') || null, observacao: v(form, 'obs') || null }, 'Lote reprodutivo ' + nomeCat(v(form, 'cat')));
      }, null, 'Salvar lote');
    if(l.observacao) form.elements.obs.value = l.observacao;
    function upd(){
      var ls = H.lotesDo(v(form, 'ret')), sel = form.elements.lote, keep = sel.value || l.lote_id || '';
      sel.innerHTML = opt('', '(sem lote)') + ls.map(function(x){ return opt(x.id, x.codigo + (x.carimbo ? ' · ' + x.carimbo : '')); }).join(''); sel.value = keep;
      var hoje = store.estoqueEfetivo().filter(function(r){ return r.retiro_id === v(form, 'ret') && r.categoria_id === v(form, 'cat') && (!sel.value || r.lote_id === sel.value); }).reduce(function(s, r){ return s + Number(r.cabecas); }, 0);
      $('#exp_hint').textContent = 'No estoque hoje: ' + n0(hoje) + ' ' + nomeCat(v(form, 'cat')) + (sel.value ? ' neste lote' : ' no retiro');
    }
    ['ret', 'cat', 'lote'].forEach(function(n){ form.elements[n].addEventListener('change', upd); }); upd();
  };
  X.acoes['rp-rodada'] = function(t){
    var l = achaLote(t.getAttribute('data-lote')), id = t.getAttribute('data-id');
    var r = id ? l.rodadas.find(function(x){ return x.id === id; }) : { rodada: l.rodadas.length + 1, tipo: l.rodadas.length ? 'RESSINCRONIZACAO' : 'IATF' };
    var anteriores = l.rodadas.filter(function(x){ return x.rodada < r.rodada; });
    var disp = l.qtd_expostas - anteriores.reduce(function(s, x){ return s + Number(x.qtd_prenhes || 0) + Number(x.qtd_perdas || 0); }, 0);
    var prots = (R.dados.dados.protocolos || []);
    var form = H.montar(r.rodada + 'ª rodada · ' + nomeCat(l.categoria_id),
      '<div class="grid-2">' + H.fSel('tipo', 'Tipo', [['IATF','IATF'],['RESSINCRONIZACAO','Ressincronização (IATF)'],['REPASSE_TOURO','Repasse com touro'],['MONTA_NATURAL','Monta natural']].map(function(x){ return opt(x[0], x[1], x[0] === r.tipo); }).join('')) +
      H.fTxt('prot', 'Protocolo', 'list="dlProt" value="' + esc(r.protocolo_id ? nomeProt(r.protocolo_id) : (prots[0] || {}).nome || '') + '" placeholder="ex.: P4 9 dias"') + '</div>' +
      '<datalist id="dlProt">' + prots.map(function(p){ return opt(p.nome, p.nome); }).join('') + '</datalist>' +
      '<div class="grid-3">' + dataCampo('d0', 'D0', r.data_d0) + dataCampo('d8', 'D8 (retirada)', r.data_d8) + dataCampo('di', 'Dia da IATF', r.data_iatf) + '</div>' +
      '<div class="grid-2">' + H.fNum('ins', 'Inseminadas', 'value="' + (r.qtd_inseminadas == null ? '' : r.qtd_inseminadas) + '"', 'Disponíveis nesta rodada: ' + n0(disp)) + H.fTxt('touro', 'Touro / sêmen', 'value="' + esc(r.touro_semen || '') + '"') + '</div>' +
      '<div class="legend-box"><b>Diagnóstico de gestação (DG)</b> — preencha depois, no dia do DG (' + R.dados.dados.dias_ate_dg + ' dias após a IATF)</div>' +
      '<div class="grid-2">' + dataCampo('ddg', 'Data do DG', r.data_dg, true) + H.fNum('pre', 'Prenhes', 'value="' + (r.qtd_prenhes == null ? '' : r.qtd_prenhes) + '"') + '</div>' +
      '<div class="grid-2">' + H.fNum('vaz', 'Vazias', 'value="' + (r.qtd_vazias == null ? '' : r.qtd_vazias) + '"', ' ') + H.fNum('per', 'Perdas (morte/descarte entre IATF e DG)', 'value="' + (r.qtd_perdas || 0) + '"') + '</div>' +
      (id && r.rodada === Math.max.apply(null, l.rodadas.map(function(x){ return x.rodada; })) ? '<button class="icon-btn btn-sm btn-danger" data-act="rp-excluir" data-tipo="rodada" data-id="' + id + '" type="button" style="align-self:flex-start">Excluir rodada</button>' : ''),
      function(form){
        var ins = H.num(v(form, 'ins')), pre = H.num(v(form, 'pre')), vaz = H.num(v(form, 'vaz')), per = H.num(v(form, 'per')) || 0;
        H.exigir(isNaN(ins) || (Number.isInteger(ins) && ins >= 0 && ins <= disp), 'Inseminadas passa das ' + disp + ' fêmeas disponíveis nesta rodada.');
        if(!isNaN(pre)){ H.exigir(!isNaN(ins), 'Informe quantas foram inseminadas.'); H.exigir(v(form, 'ddg'), 'Informe a data do DG.');
          H.exigir(pre + (isNaN(vaz) ? 0 : vaz) + per === ins, 'No DG, prenhes + vazias + perdas precisa dar ' + ins + ' (inseminadas).'); }
        var prot = v(form, 'prot').trim(), pobj = prots.find(function(p){ return p.nome.toLowerCase() === prot.toLowerCase(); });
        salvarRepro('pec_rodada_salvar', { id: id || store.uuid(), lote_reprodutivo_id: l.id, rodada: r.rodada, tipo: v(form, 'tipo'),
          protocolo_id: pobj ? pobj.id : null, protocolo_nome: pobj ? null : (prot || null),
          data_d0: v(form, 'd0') || null, data_d8: v(form, 'd8') || null, data_iatf: v(form, 'di') || null, qtd_inseminadas: isNaN(ins) ? null : ins,
          touro_semen: v(form, 'touro') || null, data_dg: v(form, 'ddg') || null, qtd_prenhes: isNaN(pre) ? null : pre, qtd_vazias: isNaN(vaz) ? null : vaz, qtd_perdas: per },
          r.rodada + 'ª rodada · ' + nomeCat(l.categoria_id) + ' · ' + ((D().ret[l.retiro_id] || {}).nome || ''));
      }, null, 'Salvar rodada');
    function somaDias(iso, n){ var d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0,10); }
    form.elements.d0.addEventListener('change', function(){
      var p = prots.find(function(x){ return x.nome.toLowerCase() === v(form, 'prot').trim().toLowerCase(); }), dias = (p && p.dias) || { D8: 8, D10: 10 };
      if(v(form, 'd0')){ if(!v(form, 'd8')) form.elements.d8.value = somaDias(v(form, 'd0'), dias.D8 || 8); if(!v(form, 'di')) form.elements.di.value = somaDias(v(form, 'd0'), dias.D10 || dias.IATF || 10); }
    });
    function calcVaz(){ var ins = H.num(v(form, 'ins')), pre = H.num(v(form, 'pre')), per = H.num(v(form, 'per')) || 0;
      if(!isNaN(ins) && !isNaN(pre)){ form.elements.vaz.value = Math.max(0, ins - pre - per); $('#vaz_hint').textContent = 'Concepção: ' + (ins ? pct(pre / ins) : '—'); } }
    ['pre', 'per', 'ins'].forEach(function(n){ form.elements[n].addEventListener('input', calcVaz); });
  };
  function dataCampo(nome, rot, val, semMax){ return '<div class="field"><label for="' + nome + '">' + rot + '</label><input class="input" type="date" id="' + nome + '" name="' + nome + '" value="' + (val || '') + '"></div>'; }
  X.acoes['rp-dg'] = function(t){
    var l = achaLote(t.getAttribute('data-lote')), dg = l.dg_final || {};
    H.montar('DG final · ' + nomeCat(l.categoria_id),
      '<p class="section-hint">Diagnóstico do fim da estação, depois do repasse. Quando informado, ele vale no lugar da soma das rodadas.</p>' +
      '<div class="grid-2">' + dataCampo('ddg', 'Data do DG final', dg.data_dg) + H.fNum('pre', 'Prenhes', 'value="' + (dg.qtd_prenhes == null ? '' : dg.qtd_prenhes) + '"') + '</div>' +
      '<div class="grid-2">' + H.fNum('vaz', 'Vazias', 'value="' + (dg.qtd_vazias == null ? '' : dg.qtd_vazias) + '"', n0(l.qtd_expostas) + ' expostas no lote') + H.fNum('desc', 'Separadas para descarte', 'value="' + (dg.qtd_descarte || 0) + '"') + '</div>',
      function(form){ var pre = H.num(v(form, 'pre')), vaz = H.num(v(form, 'vaz'));
        H.exigir(v(form, 'ddg'), 'Informe a data.'); H.exigir(Number.isInteger(pre) && Number.isInteger(vaz), 'Informe prenhes e vazias.');
        H.exigir(pre + vaz <= l.qtd_expostas, 'Prenhes + vazias passa das ' + l.qtd_expostas + ' expostas.');
        salvarRepro('pec_dg_final_salvar', { lote_reprodutivo_id: l.id, data_dg: v(form, 'ddg'), qtd_prenhes: pre, qtd_vazias: vaz, qtd_descarte: H.num(v(form, 'desc')) || 0 }, 'DG final · ' + nomeCat(l.categoria_id));
      }, null, 'Salvar DG final');
  };
  X.acoes['rp-excluir'] = async function(t){
    if(!confirm('Excluir este registro de reprodução?')) return;
    try{ await store.executar('pec_reproducao_excluir', { p_tipo: t.getAttribute('data-tipo'), p_id: t.getAttribute('data-id') }); H.fecharSheet(); toast('Excluído.'); carregarRepro(); }
    catch(e){ H.erroSheet(erroMsg(e)); }
  };

  /* ==========================================================================
     MÊS — fechamento, Mapões do mês e evolução mensal
     ========================================================================== */
  var F = { comp: null, dados: null, evo: null, porCat: false };
  async function carregarMes(){
    F.comp = F.comp || mesAnterior();
    var k = 'fech:' + F.comp;
    try{ F.dados = await store.consultar('pec_fechamento', { p_competencia: F.comp }, k); }
    catch(e){ F.dados = store.guardado(k) || { dados: null, erro: erroMsg(e) }; }
    try{ F.evo = await store.consultar('pec_evolucao', {}, 'evolucao'); }catch(e){ F.evo = store.guardado('evolucao'); }
    renderMes();
  }
  function renderMes(){
    var el = $('#panel-mes'); if(!el || !store.sessao) return;
    if(!F.dados){ el.innerHTML = '<div class="card empty">Carregando…</div>'; return; }
    var d = F.dados.dados;
    if(!d){ el.innerHTML = '<div class="card panel-pad"><div class="msg err">' + esc(F.dados.erro) + '</div></div>'; return; }
    var fechado = d.status === 'FECHADO';
    var html = '<div class="stack"><div class="card panel-pad"><h2 class="section-title">Fechamento do mês</h2><p class="section-hint">Regra: saldo anterior + entradas − saídas = saldo final, por retiro e categoria. Mês fechado não aceita lançamentos; correções entram no mês aberto, por estorno.</p>' +
      '<div class="mes-chips">' + d.meses.map(function(m){ return '<button type="button" class="mes-chip' + (m.competencia === d.competencia ? ' on' : '') + (m.status === 'FECHADO' ? ' fechado' : '') + '" data-act="fm-mes" data-mes="' + m.competencia + '">' + mesBR(m.competencia) + '</button>'; }).join('') + '</div>' +
      (F.dados.offline ? '<div class="msg warn" style="margin-top:10px">Sem internet: dados de ' + H.quandoBR(F.dados.em) + '.</div>' : '') + '</div>';

    // situação e checklist
    var bloqueios = d.bloqueios || [], avisos = d.avisos || [];
    var soCriticos = bloqueios.length && bloqueios.every(function(b){ return b.codigo !== 'MES_EM_ANDAMENTO' && b.codigo !== 'MESES_ANTERIORES'; });
    html += '<div class="card panel-pad"><div class="spread"><h2 class="section-title">' + mesBR(d.competencia) + ' · ' + (fechado ? '<span class="chip good">fechado</span>' : '<span class="chip warn">aberto</span>') + '</h2><span class="row">' +
      (!fechado && store.tem('PERIODO_FECHAR') ? '<button class="icon-btn btn-primary" data-act="fm-fechar" type="button"' + (bloqueios.length && !(soCriticos && store.tem('PERIODO_EDITAR_FECHADO')) ? ' disabled' : '') + '>' + (bloqueios.length && soCriticos ? 'Fechar mesmo assim' : 'Fechar o mês') + '</button>' : '') +
      (fechado && store.tem('PERIODO_REABRIR') ? '<button class="icon-btn" data-act="fm-reabrir" type="button">Reabrir o mês</button>' : '') +
      '<button class="icon-btn" data-act="fm-imprimir" type="button">Imprimir Mapões do mês</button></span></div>';
    if(fechado) html += '<p class="muted" style="font-size:.86rem; margin:6px 0 0">Fechado em ' + H.quandoBR(d.fechado_em) + (d.fechado_por ? ' por ' + esc(d.fechado_por) : '') + '.' +
      (d.fotografia_total != null && Number(d.fotografia_total) !== Number(d.total_atual) ? ' <b style="color:var(--bad)">Atenção: o saldo final mudou desde o fechamento (' + n0(d.fotografia_total) + ' → ' + n0(d.total_atual) + ').</b>' : '') + '</p>';
    if(d.motivo_reabertura) html += '<p class="muted" style="font-size:.84rem; margin:6px 0 0">Reaberto em ' + H.quandoBR(d.reaberto_em) + (d.reaberto_por ? ' por ' + esc(d.reaberto_por) : '') + ': "' + esc(d.motivo_reabertura) + '"</p>';
    if(!fechado){
      html += '<div style="margin-top:10px">';
      bloqueios.forEach(function(b){ html += '<div class="check-item bloq"><span class="ic">✕</span><span>' + esc(b.mensagem) + '</span></div>'; });
      avisos.forEach(function(b){ html += '<div class="check-item aviso"><span class="ic">!</span><span>' + esc(b.mensagem) + '</span></div>'; });
      if(!bloqueios.length) html += '<div class="check-item ok"><span class="ic">✓</span><span>Nada impede o fechamento' + (avisos.length ? ' — os avisos acima não bloqueiam, mas vale resolver antes' : '') + '.</span></div>';
      html += '</div>';
    }
    html += '</div>';

    // fechamento por retiro
    var porRet = {}, t = zeros();
    d.linhas.forEach(function(x){ var r = porRet[x.retiro_id] = porRet[x.retiro_id] || zeros(); somaLinha(r, x); somaLinha(t, x); });
    var rets = H.retirosLiberados().filter(function(r){ return porRet[r.id]; });
    html += '<div class="card"><div class="panel-pad spread" style="padding-bottom:8px"><h2 class="section-title">Fechamento por retiro</h2><div class="seg"><button type="button" data-act="fm-visao" data-v="ret" class="' + (F.porCat ? '' : 'on') + '">Por retiro</button><button type="button" data-act="fm-visao" data-v="cat" class="' + (F.porCat ? 'on' : '') + '">Por categoria</button></div></div>';
    html += '<div class="table-scroll" style="border:none; border-top:1px solid var(--border); border-radius:0 0 12px 12px"><table><thead><tr><th>' + (F.porCat ? 'Categoria' : 'Retiro') + '</th><th class="n">Saldo anterior</th><th class="n bl">Nasc.</th><th class="n">Compras</th><th class="n">Outras entr.</th><th class="n">Total entr.</th><th class="n bl">Mortes</th><th class="n">Vendas</th><th class="n">Outras saídas</th><th class="n">Total saídas</th><th class="n bl">Saldo final</th>' + (F.porCat ? '' : '<th>Mapão</th><th class="n">Sem pasto</th>') + '<th>Confere</th></tr></thead><tbody>';
    if(F.porCat){
      var porCat = {}; d.linhas.forEach(function(x){ var r = porCat[x.categoria_id] = porCat[x.categoria_id] || zeros(); somaLinha(r, x); });
      H.categorias().filter(function(c){ return porCat[c.id]; }).forEach(function(c){ html += linhaFech(esc(c.nome), porCat[c.id], null); });
    } else rets.forEach(function(r){ html += linhaFech(H.retiroTag(r.id), porRet[r.id], r.id, d); });
    html += '</tbody><tfoot>' + linhaFech('Total', t, null).replace('<tr>', '<tr>') + '</tfoot></table></div></div>';

    // evolução mensal
    var ev = F.evo && F.evo.dados;
    if(ev && ev.meses && ev.meses.length){
      html += '<div class="card"><div class="panel-pad" style="padding-bottom:8px"><h2 class="section-title">Evolução mensal — safra ' + esc(ev.safra) + '</h2><p class="section-hint" style="margin-bottom:0">Movimentos de cada mês e o rebanho no fim do mês. O primeiro mês inclui o saldo inicial lançado.</p></div>' +
        '<div class="table-scroll" style="border:none; border-top:1px solid var(--border); border-radius:0 0 12px 12px"><table><thead><tr><th>Mês</th><th class="n">Saldo inicial</th><th class="n">Nasc.</th><th class="n">Compras</th><th class="n">Entr. transf.</th><th class="n">Mortes</th><th class="n">Vendas</th><th class="n">Saídas transf.</th><th class="n">Ajustes</th><th class="n">Desmamados</th><th class="n bl">Rebanho no fim</th><th class="n">Variação</th><th></th></tr></thead><tbody>' +
        ev.meses.map(function(m){ var vr = Number(m.estoque_fim) - Number(m.estoque_ini);
          return '<tr><td class="num">' + mesBR(m.mes) + '</td>' + ['saldo_inicial','nascimentos','compras','entradas_transf','mortes','vendas','saidas_transf'].map(function(k){ return '<td class="n' + (Number(m[k]) ? '' : ' zero') + '">' + (Number(m[k]) ? n0(m[k]) : '·') + '</td>'; }).join('') +
            '<td class="n' + (Number(m.ajustes) ? '' : ' zero') + '">' + (Number(m.ajustes) ? (m.ajustes > 0 ? '+' : '') + n0(m.ajustes) : '·') + '</td><td class="n' + (Number(m.desmamados) ? '' : ' zero') + '">' + (Number(m.desmamados) ? n0(m.desmamados) : '·') + '</td>' +
            '<td class="n bl"><b>' + n0(m.estoque_fim) + '</b></td><td class="n">' + difHtml(vr) + '</td><td>' + (m.fechado ? '<span class="chip good">fechado</span>' : '') + '</td></tr>'; }).join('') +
        '</tbody></table></div></div>';
    }
    el.innerHTML = html + '</div>';
  }
  function zeros(){ return { sa:0, nasc:0, comp:0, ent:0, te:0, mor:0, ven:0, sai:0, ts:0, sf:0, ok:true }; }
  function somaLinha(r, x){ r.sa += +x.saldo_anterior; r.nasc += +x.nascimentos; r.comp += +x.compras; r.ent += +x.entradas_internas + +x.outras_entradas; r.te += +x.total_entradas;
    r.mor += +x.mortes; r.ven += +x.vendas; r.sai += +x.saidas_internas + +x.outras_saidas; r.ts += +x.total_saidas; r.sf += +x.saldo_final; r.ok = r.ok && x.confere; }
  function linhaFech(rot, r, retId, d){
    var c = function(x){ return '<td class="n' + (x ? '' : ' zero') + '">' + (x ? n0(x) : '·') + '</td>'; };
    var extra = '';
    if(retId){ var mp = d.mapoes[retId], sp = Number(d.sem_pasto[retId] || 0);
      extra = '<td>' + (mp ? chipInv(mp.status) : '<span class="chip neutral">não emitido</span>') + '</td><td class="n' + (sp ? '' : ' zero') + '"' + (sp ? ' style="color:var(--warn); font-weight:700"' : '') + '>' + (sp ? n0(sp) : '·') + '</td>'; }
    else if(d === undefined && !F.porCat) extra = '<td></td><td></td>';
    return '<tr><td>' + rot + '</td><td class="n">' + n0(r.sa) + '</td>' + c(r.nasc).replace('class="n', 'class="n bl') + c(r.comp) + c(r.ent) + '<td class="n"><b>' + n0(r.te) + '</b></td>' +
      c(r.mor).replace('class="n', 'class="n bl') + c(r.ven) + c(r.sai) + '<td class="n"><b>' + n0(r.ts) + '</b></td><td class="n bl"><b>' + n0(r.sf) + '</b></td>' + extra +
      '<td>' + (r.ok ? '<span class="chip good">ok</span>' : '<span class="chip bad">divergente</span>') + '</td></tr>';
  }
  X.abrir.mes = function(){ carregarMes(); };
  X.render.push(function(){ if(A.ui.tab === 'mes') renderMes(); });
  X.acoes['fm-mes'] = function(t){ F.comp = t.getAttribute('data-mes'); F.dados = store.guardado('fech:' + F.comp) || F.dados; carregarMes(); };
  X.acoes['fm-visao'] = function(t){ F.porCat = t.getAttribute('data-v') === 'cat'; renderMes(); };
  X.acoes['fm-imprimir'] = function(){
    var d = F.dados.dados; var rets = H.retirosLiberados().filter(function(r){ return d.linhas.some(function(x){ return x.retiro_id === r.id && Number(x.saldo_final); }); }).map(function(r){ return r.id; });
    if(!rets.length) return toast('Nenhum retiro com gado neste mês.', true);
    imprimirMapoes(rets, d.competencia);
  };
  X.acoes['fm-fechar'] = function(){
    var d = F.dados.dados, forcar = (d.bloqueios || []).length > 0;
    H.montar('Fechar ' + mesBR(d.competencia),
      '<p>Depois de fechado, ninguém lança com data de ' + mesBR(d.competencia) + '. O sistema guarda a fotografia do saldo de cada retiro e categoria.</p>' +
      (forcar ? '<div class="msg err">Há alertas críticos. Fechar mesmo assim fica registrado na auditoria com o seu nome.</div>' : '') +
      ((d.avisos || []).length ? '<div class="msg warn">' + d.avisos.length + ' aviso(s) em aberto — veja a lista antes de confirmar.</div>' : ''),
      async function(){ var r = await store.executar('pec_fechar_mes', { p_competencia: d.competencia, p_forcar: forcar });
        if(r && r.fechado === false){ H.erroSheet(r.motivo || 'Não foi possível fechar.'); return; }
        H.fecharSheet(); toast('Mês ' + mesBR(d.competencia) + ' fechado.'); carregarMes(); }, null, forcar ? 'Fechar mesmo assim' : 'Fechar o mês');
  };
  X.acoes['fm-reabrir'] = function(){
    var d = F.dados.dados;
    H.montar('Reabrir ' + mesBR(d.competencia), '<p>Reabrir permite lançar de novo com data deste mês. Fica registrado quem reabriu e por quê.</p>' + H.fObs('Motivo da reabertura (obrigatório)'),
      async function(form){ H.exigir((v(form, 'obs') || '').trim().length >= 5, 'Explique em uma frase por que o mês precisa ser reaberto.');
        await store.executar('pec_reabrir_mes', { p_competencia: d.competencia, p_motivo: v(form, 'obs').trim() });
        H.fecharSheet(); toast('Mês reaberto.'); carregarMes(); }, null, 'Reabrir');
  };

  /* recusados de contagem e reprodução aparecem na fila da aba Lançar com o resumo */
})();
