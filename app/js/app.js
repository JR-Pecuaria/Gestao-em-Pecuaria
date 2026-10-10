/* ============================================================================
   Gestão Pecuária JS Rural — telas
   Início · Lançar (6 botões) · Estoque · Livro · Pendências · Cadastros
   Regras de negócio moram no banco (02_regras.sql). Aqui só se ajuda o usuário
   a acertar de primeira e se mostra a resposta do banco em português claro.
   ============================================================================ */
(function(){
  'use strict';

  var store = PecStore.create({ config: window.PEC_CONFIG, onStatus: pintarStatus, onData: function(){ renderTudo(); } });
  var ui = { tab:'inicio', estModo:'retiro', estRetiro:'', estData:'', estHist:null, livroOp:'', livroRetiro:'', livroBusca:'', pendFiltro:'abertas', cadAba:'fazenda', cadRetiro:'' };

  /* ---------------- utilidades ---------------- */
  var $ = function(s, el){ return (el||document).querySelector(s); };
  var $$ = function(s, el){ return Array.prototype.slice.call((el||document).querySelectorAll(s)); };
  function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  var nf0 = new Intl.NumberFormat('pt-BR', {maximumFractionDigits:0});
  var nf1 = new Intl.NumberFormat('pt-BR', {minimumFractionDigits:1, maximumFractionDigits:1});
  var nf2 = new Intl.NumberFormat('pt-BR', {minimumFractionDigits:2, maximumFractionDigits:2});
  var nf3 = new Intl.NumberFormat('pt-BR', {minimumFractionDigits:2, maximumFractionDigits:3});
  var brl = new Intl.NumberFormat('pt-BR', {style:'currency', currency:'BRL'});
  function n0(v){ return v==null||v==='' ? '—' : nf0.format(Number(v)); }
  function n1(v){ return v==null||v==='' ? '—' : nf1.format(Number(v)); }
  function n2(v){ return v==null||v==='' ? '—' : nf2.format(Number(v)); }
  function pct(v){ return v==null||v==='' ? '—' : nf1.format(Number(v)*100) + '%'; }
  function hoje(){ var d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0,10); }
  function dataBR(iso){ if(!iso) return '—'; var p = String(iso).slice(0,10).split('-'); return p[2]+'/'+p[1]+'/'+p[0].slice(2); }
  function quandoBR(iso){ if(!iso) return 'nunca'; var d = new Date(iso); return d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit', minute:'2-digit'}); }
  function num(v){ if(v==null) return NaN; var s = String(v).trim().replace(/\s/g,''); if(s.indexOf(',')>=0) s = s.replace(/\./g,'').replace(',','.'); else if(/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g,''); return s==='' ? NaN : Number(s); }
  function toast(msg, erro){ var t = $('#toast'); t.textContent = msg; t.className = 'toast' + (erro?' err':''); t.hidden = false; clearTimeout(toast._t); toast._t = setTimeout(function(){ t.hidden = true; }, erro ? 6000 : 3200); }

  /* ---------------- dicionários dos cadastros ---------------- */
  var D = { ret:{}, pas:{}, lot:{}, cat:{}, rac:{}, cau:{}, can:{}, op:{}, par:{} };
  function indexar(){
    var c = store.cad || {};
    D = { ret:{}, pas:{}, lot:{}, cat:{}, rac:{}, cau:{}, can:{}, op:{}, par:{} };
    (c.retiros||[]).forEach(function(x){ D.ret[x.id] = x; });
    (c.pastos||[]).forEach(function(x){ D.pas[x.id] = x; });
    (c.lotes||[]).forEach(function(x){ D.lot[x.id] = x; });
    (c.categorias||[]).forEach(function(x){ D.cat[x.id] = x; });
    (c.racas||[]).forEach(function(x){ D.rac[x.id] = x; });
    (c.causas||[]).forEach(function(x){ D.cau[x.id] = x; });
    (c.canais||[]).forEach(function(x){ D.can[x.id] = x; });
    (c.operacoes||[]).forEach(function(x){ D.op[x.codigo] = x; });
    (c.parceiros||[]).forEach(function(x){ D.par[x.id] = x; });
  }
  var COR = { AgF:'agf', Pon:'pon', Pla:'pla', Ser:'ser', Que:'que', Pot:'pot', Conf:'conf', ILPPas:'ilp', ILPPot:'ilp' };
  function corRetiro(id){ var r = D.ret[id]; return 'var(--r-' + ((r && COR[r.sigla]) || 'out') + ')'; }
  function retiroTag(id){ var r = D.ret[id]; return '<span class="retiro" style="--rc:'+corRetiro(id)+'">'+esc(r ? r.nome : '—')+'</span>'; }
  function retirosLiberados(filtro){ return ((store.cad && store.cad.retiros) || []).filter(function(r){ return r.liberado && r.status === 'ATIVO' && (!filtro || filtro(r)); }); }
  function pastosDo(retiroId){ return ((store.cad && store.cad.pastos) || []).filter(function(p){ return p.retiro_id === retiroId && p.status === 'ATIVO'; })
                                  .sort(function(a,b){ return a.codigo.localeCompare(b.codigo, 'pt-BR', {numeric:true}); }); }
  function lotesDo(retiroId){ return ((store.cad && store.cad.lotes) || []).filter(function(l){ return l.retiro_id === retiroId && l.status === 'ATIVO'; }); }
  function categorias(f){ return ((store.cad && store.cad.categorias) || []).filter(function(c){ return c.status === 'ATIVO' && (!f || f(c)); }); }
  function opNome(cod){ var o = D.op[cod]; return o ? o.nome : cod; }
  function areaRetiro(id){
    var a = pastosDo(id).reduce(function(s,p){ return s + Number(p.area_ha||0); }, 0);
    return a > 0 ? a : Number((D.ret[id]||{}).area_informada_ha || 0);
  }
  function parametro(k, padrao){ var p = store.cad && store.cad.parametros; return p && p[k] != null ? Number(p[k]) : padrao; }

  /* estoque efetivo agregado */
  function estoque(){ return ui.estHist || store.estoqueEfetivo(); }
  function somar(rows, filtro){ return rows.filter(filtro || function(){ return true; }).reduce(function(a,r){ a.cab += Number(r.cabecas); a.ua += Number(r.ua||0); return a; }, {cab:0, ua:0}); }
  function pid(x){ return x === 'SEM' ? null : x; }
  function disponivel(pastoId, categoriaId, loteId){
    pastoId = pid(pastoId);
    return store.estoqueEfetivo().filter(function(r){ return (r.pasto_id || null) === pastoId && r.categoria_id === categoriaId && (!loteId || r.lote_id === loteId); })
           .reduce(function(s,r){ return s + Number(r.cabecas); }, 0);
  }
  function racaUnica(pastoId, categoriaId, loteId){
    var set = {}; pastoId = pid(pastoId);
    store.estoqueEfetivo().forEach(function(r){ if((r.pasto_id || null) === pastoId && r.categoria_id === categoriaId && (!loteId || r.lote_id === loteId) && Number(r.cabecas) > 0) set[r.raca_id || ''] = 1; });
    var k = Object.keys(set); return k.length === 1 && k[0] ? k[0] : null;
  }
  function loteUnico(pastoId, categoriaId){
    var set = {}; pastoId = pid(pastoId);
    store.estoqueEfetivo().forEach(function(r){ if((r.pasto_id || null) === pastoId && (!categoriaId || r.categoria_id === categoriaId) && Number(r.cabecas) > 0) set[r.lote_id || ''] = 1; });
    var k = Object.keys(set); return k.length === 1 && k[0] ? k[0] : null;
  }

  /* ---------------- status de sincronização ---------------- */
  function pintarStatus(s){
    var pill = $('#syncPill'); if(!pill) return;
    var txt, cls;
    if(s.recusados){ txt = '● ' + s.recusados + ' recusado' + (s.recusados>1?'s':''); cls = 'warn'; }
    else if(!s.online){ txt = '● Sem internet' + (s.pendentes ? ' · ' + s.pendentes + ' na fila' : ''); cls = 'busy'; }
    else if(s.enviando || s.atualizando){ txt = '● Sincronizando…'; cls = 'busy'; }
    else if(s.pendentes){ txt = '● ' + s.pendentes + ' na fila'; cls = 'busy'; }
    else { txt = '● Online'; cls = 'on'; }
    pill.textContent = txt; pill.className = 'sync-pill ' + cls;
    pill.title = 'Última atualização: ' + quandoBR(s.ultimaSync);
    var ss = $('#syncStatus'); if(ss) ss.textContent = 'Dados de ' + quandoBR(s.ultimaSync) + (s.erro ? ' · ' + s.erro : '');
    if(ui.tab === 'lancar') renderFila();
  }

  /* ============================================================================
     INÍCIO
     ============================================================================ */
  function renderInicio(){
    var el = $('#panel-inicio'); var r = store.resumo || {}; var ind = r.indicadores || {};
    var est = somar(store.estoqueEfetivo());
    var area = retirosLiberados().reduce(function(s,x){ return s + areaRetiro(x.id); }, 0);
    var criticos = (r.alertas||[]).filter(function(a){ return a.nivel === 'CRITICO'; }).length;
    function k(v, l, s, cls){ return '<div class="card kpi '+(cls||'')+'"><div class="v">'+v+'</div><div class="l">'+l+'</div>'+(s?'<div class="s">'+s+'</div>':'')+'</div>'; }
    var I = function(c){ return (ind[c] || {}).valor; };
    var html = '<div class="stack">';
    html += '<div class="kpi-grid">' +
      k(n0(est.cab), 'Cabeças no rebanho', store.status.pendentes ? 'inclui lançamentos na fila' : 'posição de hoje') +
      k(n1(est.ua), 'Unidades animais (UA)', area ? n3(est.ua/area) + ' UA/ha na área total' : '') +
      k(n0(I('NASCIMENTOS')), 'Nascimentos na safra ' + esc(r.safra||''), I('MORT_PRE_DESMAMA')!=null ? 'mortalidade pré-desmama ' + pct(I('MORT_PRE_DESMAMA')) : '') +
      k(n0(I('MORTES')), 'Mortes na safra', 'mortalidade ' + pct(I('MORTALIDADE')), Number(I('MORTES'))>0 ? '' : '') +
      k(n0(I('VENDAS_CAB')), 'Cabeças vendidas na safra', I('RECEITA')!=null && Number(I('RECEITA'))>0 ? brl.format(I('RECEITA')) : '') +
      k(n0(I('DESMAMADOS')), 'Desmamados na safra', '') +
      k(n0(r.pendencias_abertas), 'Pendências abertas', '', r.pendencias_abertas ? 'alert' : '') +
      k(n0((r.alertas||[]).length), 'Alertas', criticos ? criticos + ' crítico(s)' : 'nenhum crítico', criticos ? 'alert' : '') +
      '</div>';
    function n3(v){ return nf3.format(v); }

    var lmax = parametro('LOTACAO_MAX', 1.5), lmin = parametro('LOTACAO_MIN', 0.7);
    var lot = (r.lotacao||[]);
    var escala = Math.max(lmax * 1.25, Math.max.apply(null, lot.map(function(x){ return Number(x.ua_ha||0); }).concat([0])));
    html += '<div class="card panel-pad"><div class="spread"><h2 class="section-title">Lotação por retiro</h2><span class="muted" style="font-size:.8rem">meta ' + n1(lmin) + ' a ' + n1(lmax) + ' UA/ha · traço = máximo</span></div>';
    html += '<div class="table-scroll" style="margin-top:10px"><table><thead><tr><th>Retiro</th><th class="n">Área (ha)</th><th class="n">Cabeças</th><th class="n">UA</th><th class="n">UA/ha</th><th style="min-width:120px"></th><th>Situação</th></tr></thead><tbody>';
    lot.forEach(function(x){
      var st = x.status === 'ACIMA DA META' ? 'bad' : x.status === 'ADEQUADO' ? 'good' : x.status === 'ABAIXO DA META' ? 'warn' : 'neutral';
      var w = x.ua_ha ? Math.min(100, Number(x.ua_ha)/escala*100) : 0;
      html += '<tr><td>'+retiroTag(x.retiro_id)+'</td><td class="n">'+n1(x.area_ha)+'</td><td class="n'+(Number(x.cabecas)?'':' zero')+'">'+n0(x.cabecas)+'</td><td class="n">'+n1(x.ua)+'</td><td class="n">'+(x.ua_ha==null?'—':nf3.format(x.ua_ha))+'</td>' +
        '<td><div class="lot-bar" style="--rc:'+corRetiro(x.retiro_id)+'"><span style="width:'+w+'%"></span><i style="left:'+(lmax/escala*100)+'%"></i></div></td><td><span class="chip '+st+'">'+esc(x.status.toLowerCase())+'</span></td></tr>';
    });
    html += '</tbody></table></div>';
    if((r.pastos_criticos||[]).length){
      html += '<p class="section-hint" style="margin-top:12px"><b>Pastos acima da meta:</b> ' + r.pastos_criticos.map(function(p){ return esc(p.pasto) + ' (' + nf3.format(p.ua_ha||0) + ' UA/ha)'; }).join(' · ') + '</p>';
    }
    html += '</div>';

    html += '<div class="card panel-pad"><h2 class="section-title">Alertas</h2><p class="section-hint">Calculados pelo sistema a partir dos lançamentos. Resolva a causa e eles somem sozinhos.</p>';
    if(!(r.alertas||[]).length) html += '<div class="empty">Nenhum alerta.</div>';
    (r.alertas||[]).slice(0, 30).forEach(function(a){
      var c = a.nivel === 'CRITICO' ? 'bad' : a.nivel === 'ATENCAO' ? 'warn' : a.nivel === 'PENDENTE' ? 'info' : 'good';
      html += '<div class="alert-item"><span class="chip '+c+'">'+esc({CRITICO:'crítico', ATENCAO:'atenção', PENDENTE:'pendente', NORMAL:'normal'}[a.nivel]||a.nivel)+'</span><span>'+esc(a.mensagem)+'</span></div>';
    });
    html += '</div>';
    html += '<p class="faint" style="font-size:.76rem">Indicadores da safra calculados no servidor em ' + quandoBR(r.gerado_em) + '. Rebanho e UA incluem o que está na fila deste aparelho.</p>';
    html += '</div>';
    el.innerHTML = html;
  }

  /* ============================================================================
     LANÇAR — 6 botões + fila de envio
     ============================================================================ */
  function renderLancar(){
    var el = $('#panel-lancar');
    var pode = store.tem('MOV_LANCAR');
    function q(cls, ico, tit, sub, act, dis){ return '<button class="quick '+cls+'" data-act="'+act+'" type="button"'+(dis?' disabled':'')+'><span class="ico">'+ico+'</span><b>'+tit+'</b><span>'+sub+'</span></button>'; }
    var html = '<div class="stack">';
    if(!pode) html += '<div class="msg info">Seu perfil é de consulta: você vê o estoque e o livro, mas não lança movimentações.</div>';
    html += '<div class="quick-grid">' +
      q('k-nasc', '🐄', 'Novo nascimento', 'Bezerros machos e fêmeas de um lote', 'f-nasc', !pode) +
      q('k-morte', '✝', 'Nova morte', 'Com a causa da morte', 'f-morte', !pode) +
      q('k-venda', '💲', 'Nova venda', 'Canal, comprador, peso e valor', 'f-venda', !pode) +
      q('k-transf', '⇄', 'Nova transferência', 'Entre pastos, entre retiros ou refugo de cocho', 'f-transf', !pode) +
      q('k-conf', '☑', 'Nova conferência', 'Contar o Mapão no campo e conferir com o sistema', 'f-conf', !store.tem('INV_CONTAR')) +
      q('k-outro', '＋', 'Novo lançamento', 'Compra, desmama, mudança de era, ajuste', 'f-outro', !pode) +
      '</div>';
    html += '<div class="card panel-pad" id="filaBox"></div>';
    html += '</div>';
    el.innerHTML = html;
    renderFila();
  }
  function renderFila(){
    var box = $('#filaBox'); if(!box) return;
    var fila = store.fila;
    var html = '<div class="spread"><h2 class="section-title">Fila de envio deste aparelho</h2>' + (fila.length ? '<button class="icon-btn btn-sm" data-act="enviar" type="button">Enviar agora</button>' : '') + '</div>';
    if(!fila.length){ html += '<p class="section-hint">Tudo enviado. Sem internet, os lançamentos ficam aqui e seguem sozinhos quando a conexão voltar.</p>'; box.innerHTML = html; return; }
    html += '<p class="section-hint">Itens <b>recusados</b> não foram gravados: leia o motivo, corrija e reenvie — ou descarte.</p>';
    fila.forEach(function(e){
      html += '<div class="outbox-item '+(e.estado==='recusado'?'recusado':'')+'"><div><b>'+esc(e.resumo || e.tipo)+'</b><div class="muted" style="font-size:.8rem">'+
        (e.estado==='recusado' ? '<span style="color:var(--bad)">Recusado: '+esc(e.erro)+'</span>' : 'Aguardando envio · '+quandoBR(new Date(e.criado).toISOString()))+'</div></div>' +
        '<div class="row">' + (e.estado==='recusado' && e.tipo==='lancar' ? '<button class="icon-btn btn-sm" data-act="corrigir" data-id="'+e.id+'" type="button">Corrigir</button>' : '') +
        (e.estado==='recusado' ? '<button class="icon-btn btn-sm" data-act="reenviar" data-id="'+e.id+'" type="button">Reenviar</button>' : '') +
        '<button class="icon-btn btn-sm btn-danger" data-act="descartar" data-id="'+e.id+'" type="button">Descartar</button></div></div>';
    });
    box.innerHTML = html;
  }

  /* ---------------- folha (diálogo) ---------------- */
  var sheet = null;
  function abrirSheet(titulo, corpo, rodape){
    sheet = $('#sheet');
    sheet.innerHTML = '<div class="sheet-head"><h2>'+esc(titulo)+'</h2><button class="icon-btn btn-sm" data-act="fechar" type="button">Fechar</button></div>' +
      '<form class="sheet-body" id="sheetForm" novalidate>' + corpo + '<div class="msg err" id="sheetMsg" hidden></div></form>' +
      '<div class="sheet-foot">' + (rodape || '') + '</div>';
    if(!sheet.open) sheet.showModal();
    return $('#sheetForm');
  }
  function fecharSheet(){ if(sheet && sheet.open) sheet.close(); }
  function erroSheet(msg){ var m = $('#sheetMsg'); if(!m) return toast(msg, true); m.textContent = msg; m.hidden = !msg; if(msg) m.scrollIntoView({block:'nearest'}); }

  /* ---------------- campos ---------------- */
  function opt(v, t, sel){ return '<option value="'+esc(v)+'"'+(sel?' selected':'')+'>'+esc(t)+'</option>'; }
  function fData(nome, rotulo){ return '<div class="field"><label for="'+nome+'">'+(rotulo||'Data')+'</label><input class="input" type="date" id="'+nome+'" name="'+nome+'" value="'+hoje()+'" max="'+hoje()+'" required></div>'; }
  function fSel(nome, rotulo, opcoes, extra){ return '<div class="field"><label for="'+nome+'">'+rotulo+'</label><select class="select" id="'+nome+'" name="'+nome+'" '+(extra||'')+'>'+opcoes+'</select></div>'; }
  function fNum(nome, rotulo, extra, hint){ return '<div class="field"><label for="'+nome+'">'+rotulo+'</label><input class="input num" inputmode="decimal" id="'+nome+'" name="'+nome+'" autocomplete="off" '+(extra||'')+'>'+(hint?'<span class="hint" id="'+nome+'_hint">'+hint+'</span>':'')+'</div>'; }
  function fTxt(nome, rotulo, extra){ return '<div class="field"><label for="'+nome+'">'+rotulo+'</label><input class="input" id="'+nome+'" name="'+nome+'" autocomplete="off" '+(extra||'')+'></div>'; }
  function fObs(rotulo){ return '<div class="field"><label for="obs">'+(rotulo||'Observação')+'</label><textarea class="input" id="obs" name="obs" rows="2"></textarea></div>'; }
  function optRetiros(filtro, vazio){ return (vazio?opt('', vazio):'') + retirosLiberados(filtro).map(function(r){ return opt(r.id, r.nome); }).join(''); }
  function semPasto(retiroId){ return somar(store.estoqueEfetivo(), function(r){ return r.retiro_id === retiroId && !r.pasto_id; }).cab; }
  function optPastos(retiroId, origem){
    var sp = origem && retiroId ? semPasto(retiroId) : 0;
    return opt('', retiroId ? 'Escolha o pasto' : 'Escolha o retiro primeiro') + (retiroId ? pastosDo(retiroId).map(function(p){ return opt(p.id, p.codigo + (Number(p.area_ha) ? ' · ' + n1(p.area_ha) + ' ha' : '')); }).join('') : '') +
      (sp > 0 ? opt('SEM', 'Sem pasto informado (' + n0(sp) + ' cab.)') : '');
  }
  function optLotes(retiroId){ return opt('', '(sem lote)') + (retiroId ? lotesDo(retiroId).map(function(l){ return opt(l.id, l.codigo + (l.carimbo ? ' · ' + l.carimbo : '')); }).join('') : ''); }
  function optCats(f, vazio){ return opt('', vazio || 'Escolha a categoria') + categorias(f).map(function(c){ return opt(c.id, c.nome); }).join(''); }
  function optRacas(sel){ return opt('', '(não informada)') + ((store.cad && store.cad.racas) || []).map(function(r){ return opt(r.id, r.nome, r.id === sel || (!sel && r.nome === 'Nelore')); }).join(''); }
  function v(form, nome){ var e = form.elements[nome]; return e ? e.value : ''; }

  /* retiro → pasto → lote encadeados; prefixo para origem/destino */
  function ligarLocal(form, pre, aoMudar){
    var r = form.elements[pre+'retiro'], p = form.elements[pre+'pasto'], l = form.elements[pre+'lote'];
    function trocouRetiro(){ if(p) p.innerHTML = optPastos(r.value, r.getAttribute('data-origem') === '1'); if(l) l.innerHTML = optLotes(r.value); if(aoMudar) aoMudar(); }
    if(r){ r.addEventListener('change', trocouRetiro); trocouRetiro(); }
    if(p) p.addEventListener('change', function(){
      if(l && !l.value){ var u = loteUnico(p.value, null); if(u) l.value = u; }
      if(aoMudar) aoMudar();
    });
    if(l) l.addEventListener('change', function(){ if(aoMudar) aoMudar(); });
  }
  function blocoLocal(pre, rotulo, filtroRetiro, comLote, origem){
    return (rotulo ? '<div class="legend-box"><b>'+rotulo+'</b></div>' : '') +
      '<div class="grid-'+(comLote===false?'2':'3')+'">' +
      fSel(pre+'retiro', 'Retiro', optRetiros(filtroRetiro), origem ? 'data-origem="1"' : '') + fSel(pre+'pasto', 'Pasto', optPastos('')) +
      (comLote===false ? '' : fSel(pre+'lote', 'Lote', optLotes(''))) + '</div>';
  }
  function mostrarDisponivel(form, pre, catCampo, qtdCampo){
    var p = v(form, pre+'pasto'), c = v(form, catCampo), l = v(form, pre+'lote');
    var h = $('#'+qtdCampo+'_hint'); if(!h) return;
    if(!p || !c){ h.textContent = 'Escolha pasto e categoria para ver quanto há.'; return; }
    var d = disponivel(p, c, l || null), dt = disponivel(p, c, null);
    h.textContent = 'Disponível: ' + n0(d) + ' cab.' + (l && dt !== d ? ' no lote (' + n0(dt) + ' no pasto)' : '');
  }
  function exigir(cond, msg){ if(!cond) throw { mensagem: msg }; }
  function inteiro(form, nome, rotulo){ var q = num(v(form, nome)); exigir(Number.isInteger(q) && q > 0, 'Informe ' + rotulo + ' (número inteiro maior que zero).'); return q; }
  function checarSaida(pastoId, catId, qtd){
    var d = disponivel(pastoId, catId, null);
    exigir(qtd <= d, 'Estoque ficaria negativo: há ' + n0(d) + ' ' + (D.cat[catId]||{}).nome + ' em ' + ((D.pas[pastoId]||{}).codigo || 'sem pasto') + '. Confira a quantidade ou lance antes a entrada que falta.');
  }
  function periodoFechado(data){ return ((store.cad && store.cad.periodos_fechados) || []).some(function(c){ return String(c).slice(0,7) === String(data).slice(0,7); }); }
  function base(form, operacao){
    var data = v(form, 'data');
    exigir(data, 'Informe a data.');
    exigir(data <= hoje(), 'A data está no futuro.');
    exigir(!periodoFechado(data), 'O mês ' + dataBR(data).slice(3) + ' está fechado. Use uma data do mês aberto.');
    return { operacao: operacao, data: data, observacao: v(form, 'obs') || null, pernas: [] };
  }
  function perna(sentido, retiro, pasto, lote, cat, raca, qtd, peso){
    exigir(retiro, 'Escolha o retiro.'); exigir(pasto, 'Escolha o pasto (código do mapa).'); exigir(cat, 'Escolha a categoria.');
    exigir(!(sentido > 0 && pasto === 'SEM'), 'Animal que entra precisa de pasto. Escolha o pasto de destino.');
    return { sentido: sentido, retiro_id: retiro, pasto_id: pid(pasto), lote_id: lote || null, categoria_id: cat, raca_id: raca || null, quantidade: qtd, peso_kg: peso || null };
  }
  function resumoLanc(p){
    var partes = p.pernas.map(function(x){ return (x.sentido>0?'+':'−') + x.quantidade + ' ' + ((D.cat[x.categoria_id]||{}).nome||'') + ' ' + ((D.pas[x.pasto_id]||{}).codigo||'sem pasto'); });
    return opNome(p.operacao) + ' · ' + dataBR(p.data) + ' · ' + partes.join(', ');
  }
  function registrar(payload, formFn){
    var item = store.lancar(payload, resumoLanc(payload));
    fecharSheet();
    toast(store.status.online ? 'Lançado. Enviando…' : 'Salvo no aparelho. Será enviado quando a internet voltar.');
    renderTudo();
    return item;
  }
  function rodapeSalvar(rotulo){ return '<button class="icon-btn" data-act="fechar" type="button">Cancelar</button><button class="icon-btn btn-primary btn-lg" data-act="salvar" type="button">'+(rotulo||'Salvar lançamento')+'</button>'; }
  var aoSalvar = null;
  function montar(titulo, corpo, fnSalvar, fnMontar, rotulo){
    var form = abrirSheet(titulo, corpo, rodapeSalvar(rotulo));
    aoSalvar = function(){
      var btn = $('#sheet [data-act="salvar"]');
      try{ erroSheet(''); var r = fnSalvar(form);
        if(r && typeof r.then === 'function'){ if(btn) btn.disabled = true;
          r.catch(function(e){ erroSheet(e.mensagem || String(e)); }).finally(function(){ if(btn) btn.disabled = false; }); }
      }catch(e){ erroSheet(e.mensagem || String(e)); }
    };
    if(fnMontar) fnMontar(form);
    form.addEventListener('submit', function(ev){ ev.preventDefault(); aoSalvar(); });
    return form;
  }

  /* ---------------- formulários de lançamento ---------------- */
  function fNascimento(){
    var bez = categorias(function(c){ return c.permite_nascimento; });
    var linha = function(i, sexo){ return '<div class="grid-3" data-linha="'+i+'">' +
      fSel('n_cat'+i, 'Sexo', bez.map(function(c){ return opt(c.id, c.sexo==='M'?'Macho':'Fêmea', c.sexo===sexo); }).join('')) +
      fSel('n_raca'+i, 'Raça', optRacas()) + fNum('n_qtd'+i, 'Quantidade', 'placeholder="0"') + '</div>'; };
    montar('Novo nascimento',
      fData('data') + blocoLocal('', '', null, true) +
      '<div class="legend-box">Lance machos e fêmeas juntos. Bezerros de IATF com sêmen de outra raça: use uma linha por raça.</div>' +
      '<div id="nLinhas">' + linha(0,'M') + linha(1,'F') + '</div>' +
      '<button class="icon-btn btn-sm" type="button" id="nMais" style="align-self:flex-start">+ outra linha (raça diferente)</button>' + fObs(),
      function(form){
        var p = base(form, 'NASCIMENTO'); var tot = 0;
        $$('[data-linha]', form).forEach(function(div){
          var i = div.getAttribute('data-linha'); var q = num(v(form, 'n_qtd'+i));
          if(!q) return; exigir(Number.isInteger(q) && q > 0, 'Quantidade inválida.');
          p.pernas.push(perna(1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'n_cat'+i), v(form,'n_raca'+i), q)); tot += q;
        });
        exigir(tot > 0, 'Informe quantos machos e/ou fêmeas nasceram.');
        registrar(p);
      },
      function(form){
        ligarLocal(form, '');
        var i = 2;
        $('#nMais').addEventListener('click', function(){ $('#nLinhas').insertAdjacentHTML('beforeend', linha(i++, 'M')); });
      }, 'Salvar nascimento');
  }

  function fMorte(){
    montar('Nova morte',
      fData('data') + blocoLocal('', '', null, true, true) +
      '<div class="grid-2">' + fSel('cat', 'Categoria', optCats()) + fNum('qtd', 'Quantidade', 'value="1"', ' ') + '</div>' +
      fSel('causa', 'Causa da morte', opt('', 'Escolha a causa') + ((store.cad && store.cad.causas) || []).map(function(c){ return opt(c.id, c.nome); }).join('')) +
      fObs(),
      function(form){
        var p = base(form, 'MORTE'); var q = inteiro(form, 'qtd', 'a quantidade');
        exigir(v(form,'causa'), 'Informe a causa da morte (use "Não Identificada" se não souber).');
        checarSaida(v(form,'pasto'), v(form,'cat'), q);
        p.causa_morte_id = v(form,'causa');
        p.pernas.push(perna(-1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'cat'), racaUnica(v(form,'pasto'), v(form,'cat'), v(form,'lote')||null), q));
        registrar(p);
      },
      function(form){
        var upd = function(){ mostrarDisponivel(form, '', 'cat', 'qtd'); };
        ligarLocal(form, '', upd); form.elements.cat.addEventListener('change', upd); upd();
      }, 'Salvar morte');
  }

  function fVenda(){
    var fin = store.tem('MOV_FINANCEIRO');
    montar('Nova venda',
      fData('data') + blocoLocal('', '', null, true, true) +
      '<div class="grid-2">' + fSel('cat', 'Categoria', optCats()) + fNum('qtd', 'Quantidade (cab.)', '', ' ') + '</div>' +
      '<div class="grid-2">' + fSel('canal', 'Canal de venda', opt('', 'Escolha o canal') + ((store.cad && store.cad.canais) || []).map(function(c){ return opt(c.id, c.nome); }).join('')) +
      fTxt('comprador', 'Comprador', 'list="dlParceiros" placeholder="Nome do comprador ou frigorífico"') + '</div>' +
      '<datalist id="dlParceiros">' + ((store.cad && store.cad.parceiros) || []).map(function(x){ return opt(x.nome, x.nome); }).join('') + '</datalist>' +
      '<div class="grid-2">' + fNum('peso', 'Peso total (kg)', 'placeholder="ex.: 12.450"') + (fin ? fNum('valor', 'Valor total (R$)', 'placeholder="ex.: 98.500,00"') : '<div class="field"><label>Valor</label><span class="hint">O escritório informa o valor depois.</span></div>') + '</div>' +
      '<div class="calc" id="vCalc"></div>' +
      '<div class="grid-2">' + fTxt('nf', 'Nota fiscal') + fTxt('gta', 'GTA') + '</div>' + fObs(),
      function(form){
        var p = base(form, 'VENDA'); var q = inteiro(form, 'qtd', 'a quantidade');
        exigir(v(form,'canal'), 'Informe o canal de venda.');
        exigir(v(form,'comprador').trim(), 'Informe o comprador.');
        checarSaida(v(form,'pasto'), v(form,'cat'), q);
        var peso = num(v(form,'peso')); var valor = fin ? num(v(form,'valor')) : NaN;
        p.canal_venda_id = v(form,'canal'); p.parceiro_nome = v(form,'comprador').trim();
        p.peso_total_kg = isNaN(peso) ? null : peso; p.valor_total = isNaN(valor) ? null : valor;
        p.nota_fiscal = v(form,'nf') || null; p.gta = v(form,'gta') || null;
        p.pernas.push(perna(-1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'cat'), racaUnica(v(form,'pasto'), v(form,'cat'), v(form,'lote')||null), q));
        registrar(p);
      },
      function(form){
        var upd = function(){
          mostrarDisponivel(form, '', 'cat', 'qtd');
          var q = num(v(form,'qtd')), peso = num(v(form,'peso')), val = fin ? num(v(form,'valor')) : NaN; var t = [];
          if(q > 0 && peso > 0) t.push(n1(peso/q) + ' kg/cab');
          if(peso > 0 && val > 0) t.push(brl.format(val/peso) + '/kg');
          if(q > 0 && val > 0) t.push(brl.format(val/q) + '/cab');
          $('#vCalc').textContent = t.join(' · ');
        };
        ligarLocal(form, '', upd); ['cat','qtd','peso','valor'].forEach(function(n){ if(form.elements[n]) form.elements[n].addEventListener('input', upd); }); upd();
      }, 'Salvar venda');
  }

  function fTransferencia(modoIni){
    var modo = modoIni || 'TRANSF_PASTO';
    var titulos = { TRANSF_PASTO:'Entre pastos', TRANSF_RETIRO:'Entre retiros', REFUGO_COCHO:'Refugo de cocho' };
    var form = montar('Nova transferência',
      '<div class="seg" id="tModo">' + Object.keys(titulos).map(function(k){ return '<button type="button" data-modo="'+k+'" class="'+(k===modo?'on':'')+'">'+titulos[k]+'</button>'; }).join('') + '</div>' +
      '<div class="legend-box" id="tAjuda"></div>' + fData('data') +
      '<div id="tOrigem"></div><div id="tDestino"></div>' +
      '<div class="grid-2">' + fSel('cat', 'Categoria', optCats()) + fNum('qtd', 'Quantidade', '', ' ') + '</div>' + fObs(),
      function(form){
        var p = base(form, modo); var q = inteiro(form, 'qtd', 'a quantidade'); var c = v(form,'cat');
        var oR = v(form,'o_retiro'), oP = v(form,'o_pasto'), oL = v(form,'o_lote');
        var dR = modo === 'TRANSF_PASTO' ? oR : v(form,'d_retiro'), dP = v(form,'d_pasto'), dL = modo === 'TRANSF_PASTO' ? oL : v(form,'d_lote');
        exigir(oP && dP, 'Informe o pasto de origem e o de destino.');
        exigir(oP !== dP, 'Origem e destino são o mesmo pasto.');
        if(modo === 'TRANSF_RETIRO') exigir(oR !== dR, 'Origem e destino são o mesmo retiro. Use "Entre pastos".');
        checarSaida(oP, c, q);
        var raca = racaUnica(oP, c, oL||null);
        p.pernas.push(perna(-1, oR, oP, oL, c, raca, q));
        p.pernas.push(perna(1, dR, dP, dL, c, raca, q));
        registrar(p);
      }, null, 'Salvar transferência');
    function pintar(){
      $$('#tModo button').forEach(function(b){ b.classList.toggle('on', b.getAttribute('data-modo') === modo); });
      var conf = function(r){ return r.tipo === 'CONFINAMENTO'; }, naoConf = function(r){ return r.tipo !== 'CONFINAMENTO'; };
      $('#tAjuda').innerHTML = modo === 'TRANSF_PASTO' ? 'Muda o gado de pasto <b>dentro do mesmo retiro</b>. A categoria não muda.' :
        modo === 'TRANSF_RETIRO' ? 'Leva o gado <b>de um retiro para outro</b>. As duas pontas são gravadas juntas.' :
        'Animal refugado no cocho <b>volta do Confinamento para um pasto</b>.';
      var orig = modo === 'REFUGO_COCHO' ? conf : null;
      $('#tOrigem').innerHTML = blocoLocal('o_', 'De onde sai', orig, true, true);
      $('#tDestino').innerHTML = modo === 'TRANSF_PASTO'
        ? '<div class="legend-box"><b>Para onde vai</b> (mesmo retiro)</div><div class="grid-2">' + fSel('d_pasto', 'Pasto de destino', optPastos('')) + '<div></div></div>'
        : blocoLocal('d_', 'Para onde vai', modo === 'REFUGO_COCHO' ? naoConf : null, true);
      var upd = function(){
        if(modo === 'TRANSF_PASTO'){ var dp = form.elements.d_pasto, keep = dp.value; dp.innerHTML = optPastos(v(form,'o_retiro')); dp.value = keep; $$('option', dp).forEach(function(o){ if(o.value && o.value === v(form,'o_pasto')) o.disabled = true; }); }
        mostrarDisponivel(form, 'o_', 'cat', 'qtd');
      };
      ligarLocal(form, 'o_', upd);
      if(modo !== 'TRANSF_PASTO') ligarLocal(form, 'd_');
      form.elements.cat.onchange = upd; upd();
    }
    $('#tModo').addEventListener('click', function(ev){ var b = ev.target.closest('[data-modo]'); if(!b) return; modo = b.getAttribute('data-modo'); pintar(); });
    pintar();
  }

  function fOutro(){
    var form = abrirSheet('Novo lançamento',
      '<p class="section-hint">Escolha o tipo de lançamento.</p><div class="quick-grid">' +
      [['COMPRA','Compra','Entrada de animais comprados'],['DESMAMA','Desmama','Bezerros mamando → desmamados, com peso'],
       ['ERA','Mudança de era','Muda a categoria (ex.: Desmama → Garrote aos 13 meses)'],['AJUSTE_INVENTARIO','Ajuste de inventário','Diferença da contagem de campo, com motivo']]
      .map(function(x){ return '<button class="quick k-outro" type="button" data-outro="'+x[0]+'"><b>'+x[1]+'</b><span>'+x[2]+'</span></button>'; }).join('') + '</div>', '<button class="icon-btn" data-act="fechar" type="button">Cancelar</button>');
    form.addEventListener('click', function(ev){
      var b = ev.target.closest('[data-outro]'); if(!b) return;
      var t = b.getAttribute('data-outro');
      if(t === 'COMPRA') fCompra(); else if(t === 'DESMAMA') fDesmama(); else if(t === 'ERA') fEra(); else fAjuste();
    });
  }

  function fCompra(){
    var fin = store.tem('MOV_FINANCEIRO');
    montar('Compra de animais',
      fData('data') + blocoLocal('', 'Para onde vão', null, true) +
      '<div class="grid-3">' + fSel('cat', 'Categoria', optCats()) + fSel('raca', 'Raça', optRacas()) + fNum('qtd', 'Quantidade') + '</div>' +
      fTxt('fornecedor', 'Fornecedor', 'list="dlParceiros"') + '<datalist id="dlParceiros">' + ((store.cad && store.cad.parceiros) || []).map(function(x){ return opt(x.nome, x.nome); }).join('') + '</datalist>' +
      '<div class="grid-2">' + fNum('peso', 'Peso total (kg)') + (fin ? fNum('valor', 'Valor total (R$)') : '<div></div>') + '</div>' +
      '<div class="grid-2">' + fTxt('nf', 'Nota fiscal') + fTxt('gta', 'GTA') + '</div>' + fObs(),
      function(form){
        var p = base(form, 'COMPRA'); var q = inteiro(form, 'qtd', 'a quantidade');
        exigir(v(form,'fornecedor').trim(), 'Informe o fornecedor.');
        var peso = num(v(form,'peso')); exigir(peso > 0, 'Informe o peso total (kg).');
        var valor = fin ? num(v(form,'valor')) : NaN;
        p.parceiro_nome = v(form,'fornecedor').trim(); p.peso_total_kg = peso; p.valor_total = isNaN(valor) ? null : valor;
        p.nota_fiscal = v(form,'nf') || null; p.gta = v(form,'gta') || null;
        p.pernas.push(perna(1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'cat'), v(form,'raca'), q));
        registrar(p);
      }, function(form){ ligarLocal(form, ''); }, 'Salvar compra');
  }

  function fDesmama(){
    var bezM = categorias(function(c){ return c.fase === 'BEZERRO' && c.sexo === 'M'; })[0];
    var bezF = categorias(function(c){ return c.fase === 'BEZERRO' && c.sexo === 'F'; })[0];
    var trans = (store.cad && store.cad.transicoes) || [];
    var dest = function(de){ var t = trans.find(function(x){ return x.de === (de && de.id) && x.operacao === 'DESMAMA'; }); return t ? t.para : null; };
    montar('Desmama',
      fData('data') + blocoLocal('o_', 'Onde estão os bezerros', null, true, true) +
      '<div class="grid-2">' + fNum('qm', 'Machos desmamados', '', ' ') + fNum('pm', 'Peso total dos machos (kg)') + '</div>' +
      '<div class="grid-2">' + fNum('qf', 'Fêmeas desmamadas', '', ' ') + fNum('pf', 'Peso total das fêmeas (kg)') + '</div>' +
      '<div class="calc" id="dCalc"></div>' +
      '<div class="field"><label for="nascm">Data média de nascimento (opcional)</label><input class="input" type="date" id="nascm" name="nascm" max="'+hoje()+'"><span class="hint">Com ela o sistema calcula GMD e peso ajustado aos 205 dias (P205).</span></div>' +
      '<div class="legend-box"><b>Para onde vão os desmamados</b> (deixe igual se ficam no mesmo pasto)</div>' +
      '<div class="grid-2">' + fSel('d_pasto', 'Pasto de destino', optPastos('')) + fSel('d_lote', 'Lote de destino', optLotes('')) + '</div>' + fObs(),
      function(form){
        var p = base(form, 'DESMAMA'); var oR = v(form,'o_retiro'), oP = v(form,'o_pasto'), oL = v(form,'o_lote');
        var dP = v(form,'d_pasto') || oP, dL = v(form,'d_lote') || oL;
        var qm = num(v(form,'qm')) || 0, qf = num(v(form,'qf')) || 0, pm = num(v(form,'pm')) || 0, pf = num(v(form,'pf')) || 0;
        exigir(qm + qf > 0, 'Informe quantos machos e/ou fêmeas foram desmamados.');
        exigir((!qm || pm > 0) && (!qf || pf > 0), 'Informe o peso total de cada sexo desmamado (kg).');
        [[bezM, qm, pm], [bezF, qf, pf]].forEach(function(x){
          if(!x[1]) return;
          exigir(Number.isInteger(x[1]), 'Quantidade inválida.');
          checarSaida(oP, x[0].id, x[1]);
          var para = dest(x[0]); exigir(para, 'Falta cadastrar a transição de desmama para ' + x[0].nome + '.');
          var raca = racaUnica(oP, x[0].id, oL||null);
          p.pernas.push(perna(-1, oR, oP, oL, x[0].id, raca, x[1], x[2]));
          p.pernas.push(perna(1, oR, dP, dL, para, raca, x[1]));
        });
        p.peso_total_kg = pm + pf;
        if(v(form,'nascm')){ exigir(v(form,'nascm') < p.data, 'A data média de nascimento precisa ser antes da desmama.'); p.nascimento_medio = v(form,'nascm'); }
        registrar(p);
      },
      function(form){
        var upd = function(){
          var dp = form.elements.d_pasto, dl = form.elements.d_lote, kp = dp.value, kl = dl.value;
          dp.innerHTML = opt('', '(mesmo pasto)') + pastosDo(v(form,'o_retiro')).map(function(x){ return opt(x.id, x.codigo); }).join(''); dp.value = kp;
          dl.innerHTML = opt('', '(mesmo lote)') + lotesDo(v(form,'o_retiro')).map(function(x){ return opt(x.id, x.codigo); }).join(''); dl.value = kl;
          var p = v(form,'o_pasto'), l = v(form,'o_lote') || null;
          $('#qm_hint').textContent = p ? 'Mamando: ' + n0(disponivel(p, bezM.id, l)) : ' ';
          $('#qf_hint').textContent = p ? 'Mamando: ' + n0(disponivel(p, bezF.id, l)) : ' ';
          var t = [], qm = num(v(form,'qm')), qf = num(v(form,'qf')), pm = num(v(form,'pm')), pf = num(v(form,'pf'));
          if(qm > 0 && pm > 0) t.push('machos ' + n1(pm/qm) + ' kg/cab'); if(qf > 0 && pf > 0) t.push('fêmeas ' + n1(pf/qf) + ' kg/cab');
          $('#dCalc').textContent = t.join(' · ');
        };
        ligarLocal(form, 'o_', upd); ['qm','qf','pm','pf'].forEach(function(n){ form.elements[n].addEventListener('input', upd); }); upd();
      }, 'Salvar desmama');
  }

  function fEra(){
    var trans = ((store.cad && store.cad.transicoes) || []).filter(function(t){ return t.operacao === 'ERA'; });
    montar('Mudança de era (categoria)',
      fData('data') + blocoLocal('', '', null, true) +
      '<div class="grid-2">' + fSel('de', 'Categoria atual', optCats(function(c){ return trans.some(function(t){ return t.de === c.id; }); })) + fSel('para', 'Nova categoria', opt('', 'Escolha a categoria atual')) + '</div>' +
      '<div class="calc" id="eGat"></div>' + fNum('qtd', 'Quantidade', '', ' ') + fObs(),
      function(form){
        var p = base(form, 'ERA'); var q = inteiro(form, 'qtd', 'a quantidade');
        exigir(v(form,'de') && v(form,'para'), 'Escolha a categoria atual e a nova.');
        checarSaida(v(form,'pasto'), v(form,'de'), q);
        var raca = racaUnica(v(form,'pasto'), v(form,'de'), v(form,'lote')||null);
        p.pernas.push(perna(-1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'de'), raca, q));
        p.pernas.push(perna(1, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'para'), raca, q));
        registrar(p);
      },
      function(form){
        var upd = function(){ mostrarDisponivel(form, '', 'de', 'qtd'); };
        form.elements.de.addEventListener('change', function(){
          var opts = trans.filter(function(t){ return t.de === v(form,'de'); });
          form.elements.para.innerHTML = opt('', opts.length ? 'Escolha a nova categoria' : 'Escolha a categoria atual') + opts.map(function(t){ return opt(t.para, (D.cat[t.para]||{}).nome + (t.gatilho ? ' — ' + t.gatilho : '')); }).join('');
          upd();
        });
        ligarLocal(form, '', upd); upd();
      }, 'Salvar mudança');
  }

  function fAjuste(){
    var dir = -1;
    montar('Ajuste de inventário',
      '<div class="msg warn">Use só quando a contagem de campo não bater e não houver lançamento faltando (morte, nascimento, transferência). Fica registrado com seu nome.</div>' +
      fData('data') + blocoLocal('', '', null, true, true) +
      '<div class="seg" id="aDir"><button type="button" data-d="-1" class="on">Faltou no campo (−)</button><button type="button" data-d="1">Sobrou no campo (+)</button></div>' +
      '<div class="grid-3">' + fSel('cat', 'Categoria', optCats()) + fSel('raca', 'Raça', optRacas('none')) + fNum('qtd', 'Quantidade', '', ' ') + '</div>' + fObs('Motivo (obrigatório)'),
      function(form){
        var p = base(form, 'AJUSTE_INVENTARIO'); var q = inteiro(form, 'qtd', 'a quantidade');
        exigir((v(form,'obs')||'').trim().length >= 5, 'Explique o motivo do ajuste.');
        if(dir < 0) checarSaida(v(form,'pasto'), v(form,'cat'), q);
        p.pernas.push(perna(dir, v(form,'retiro'), v(form,'pasto'), v(form,'lote'), v(form,'cat'), v(form,'raca') || racaUnica(v(form,'pasto'), v(form,'cat'), v(form,'lote')||null), q));
        registrar(p);
      },
      function(form){
        var upd = function(){ mostrarDisponivel(form, '', 'cat', 'qtd'); };
        ligarLocal(form, '', upd); form.elements.cat.addEventListener('change', upd); upd();
        $('#aDir').addEventListener('click', function(ev){ var b = ev.target.closest('[data-d]'); if(!b) return; dir = Number(b.getAttribute('data-d')); $$('#aDir button').forEach(function(x){ x.classList.toggle('on', x === b); }); });
      }, 'Salvar ajuste');
  }

  /* ============================================================================
     ESTOQUE
     ============================================================================ */
  function renderEstoque(){
    var el = $('#panel-estoque');
    var rows = estoque().filter(function(r){ return !ui.estRetiro || r.retiro_id === ui.estRetiro; });
    var tot = somar(rows);
    var pend = !ui.estHist && store.fila.some(function(e){ return e.tipo === 'lancar' && e.estado === 'pendente'; });
    var html = '<div class="stack"><div class="card panel-pad"><div class="filters">' +
      '<div class="field"><label>Visão</label><div class="seg" id="estModo">' +
        [['retiro','Retiro e pasto'],['matriz','Categoria × retiro'],['lote','Por lote']].map(function(x){ return '<button type="button" data-modo="'+x[0]+'" class="'+(ui.estModo===x[0]?'on':'')+'">'+x[1]+'</button>'; }).join('') + '</div></div>' +
      '<div class="field"><label for="estRetiro">Retiro</label><select class="select" id="estRetiro">' + opt('', 'Todos') + retirosLiberados().map(function(r){ return opt(r.id, r.nome, r.id === ui.estRetiro); }).join('') + '</select></div>' +
      '<div class="field"><label for="estData">Posição em</label><input class="input" type="date" id="estData" value="'+(ui.estData || hoje())+'" max="'+hoje()+'"></div>' +
      '</div><div class="row" style="margin-top:12px; gap:18px"><span><b class="num" style="font-size:1.3rem">'+n0(tot.cab)+'</b> <span class="muted">cabeças</span></span><span><b class="num" style="font-size:1.3rem">'+n1(tot.ua)+'</b> <span class="muted">UA</span></span>' +
      (ui.estHist ? '<span class="chip info">posição em '+dataBR(ui.estData)+'</span>' : '') + (pend ? '<span class="chip warn">inclui lançamentos ainda na fila</span>' : '') + '</div></div>';

    if(!rows.length) html += '<div class="card empty">Sem animais' + (ui.estRetiro ? ' neste retiro' : '') + '.</div>';
    else if(ui.estModo === 'matriz') html += matriz(rows);
    else if(ui.estModo === 'lote') html += porLote(rows);
    else html += porRetiroPasto(rows);
    html += '</div>';
    el.innerHTML = html;
  }
  function composicao(rs){
    var by = {}; rs.forEach(function(r){ by[r.categoria_id] = (by[r.categoria_id]||0) + Number(r.cabecas); });
    return Object.keys(by).filter(function(k){ return by[k]; }).sort(function(a,b){ return (D.cat[a]||{}).ordem - (D.cat[b]||{}).ordem; })
      .map(function(k){ return n0(by[k]) + ' ' + esc((D.cat[k]||{}).nome || '?'); }).join(' · ');
  }
  function porRetiroPasto(rows){
    var html = ''; var total = somar(rows).cab || 1;
    retirosLiberados().forEach(function(ret){
      var rs = rows.filter(function(r){ return r.retiro_id === ret.id; }); if(!rs.length) return;
      var t = somar(rs), area = areaRetiro(ret.id);
      html += '<div class="card"><div class="panel-pad spread" style="padding-bottom:8px"><h2 class="section-title">'+retiroTag(ret.id)+'</h2><span class="muted num" style="font-size:.84rem">'+n0(t.cab)+' cab. · '+n1(t.ua)+' UA · '+(area ? nf3.format(t.ua/area)+' UA/ha' : 'sem área')+' · '+pct(t.cab/total)+' do rebanho</span></div>';
      html += '<div class="table-scroll" style="border:none; border-top:1px solid var(--border); border-radius:0 0 12px 12px"><table><thead><tr><th>Pasto</th><th class="n">Área</th><th class="n">Cab.</th><th class="n">UA</th><th class="n">UA/ha</th><th>Composição</th></tr></thead><tbody>';
      var pastos = {}; rs.forEach(function(r){ var k = r.pasto_id || ''; (pastos[k] = pastos[k] || []).push(r); });
      Object.keys(pastos).sort(function(a,b){ return a==='' ? 1 : b==='' ? -1 : ((D.pas[a]||{}).codigo||'').localeCompare((D.pas[b]||{}).codigo||'', 'pt-BR', {numeric:true}); }).forEach(function(k){
        var ps = pastos[k], s = somar(ps), p = D.pas[k], a = p ? Number(p.area_ha) : 0;
        var uah = a ? s.ua/a : null, lmax = parametro('LOTACAO_MAX', 1.5);
        html += '<tr'+(k===''?' style="background:var(--warn-bg)"':'')+'><td><b>'+(p ? esc(p.codigo) : 'SEM PASTO')+'</b></td><td class="n">'+(a?n1(a):'—')+'</td><td class="n">'+n0(s.cab)+'</td><td class="n">'+n1(s.ua)+'</td><td class="n"'+(uah>lmax?' style="color:var(--bad); font-weight:700"':'')+'>'+(uah==null?'—':nf3.format(uah))+'</td><td style="font-size:.8rem">'+composicao(ps)+'</td></tr>';
      });
      html += '</tbody></table></div></div>';
    });
    return html;
  }
  function matriz(rows){
    var rets = retirosLiberados().filter(function(r){ return rows.some(function(x){ return x.retiro_id === r.id; }); });
    var cats = categorias().filter(function(c){ return rows.some(function(x){ return x.categoria_id === c.id; }); });
    var tot = somar(rows).cab || 1;
    var html = '<div class="table-scroll"><table><thead><tr><th>Categoria</th>' + rets.map(function(r){ return '<th class="n">'+retiroTag(r.id)+'</th>'; }).join('') + '<th class="n">Total</th><th class="n">%</th><th class="n">UA</th></tr></thead><tbody>';
    cats.forEach(function(c){
      var linha = rows.filter(function(x){ return x.categoria_id === c.id; }); var s = somar(linha);
      html += '<tr><td>'+esc(c.nome)+'</td>' + rets.map(function(r){ var q = somar(linha, function(x){ return x.retiro_id === r.id; }).cab; return '<td class="n'+(q?'':' zero')+'">'+(q?n0(q):'·')+'</td>'; }).join('') +
        '<td class="n"><b>'+n0(s.cab)+'</b></td><td class="n">'+pct(s.cab/tot)+'</td><td class="n">'+n1(s.ua)+'</td></tr>';
    });
    var s = somar(rows);
    html += '</tbody><tfoot><tr><td>Total</td>' + rets.map(function(r){ return '<td class="n">'+n0(somar(rows, function(x){ return x.retiro_id === r.id; }).cab)+'</td>'; }).join('') + '<td class="n">'+n0(s.cab)+'</td><td class="n">100%</td><td class="n">'+n1(s.ua)+'</td></tr>' +
      '<tr><td>UA</td>' + rets.map(function(r){ return '<td class="n">'+n1(somar(rows, function(x){ return x.retiro_id === r.id; }).ua)+'</td>'; }).join('') + '<td class="n">'+n1(s.ua)+'</td><td></td><td></td></tr></tfoot></table></div>';
    return html;
  }
  function porLote(rows){
    var grupos = {}; rows.forEach(function(r){ var k = r.retiro_id + '|' + (r.lote_id || ''); (grupos[k] = grupos[k] || []).push(r); });
    var html = '<div class="table-scroll"><table><thead><tr><th>Retiro</th><th>Lote</th><th>Pastos</th><th class="n">Cab.</th><th class="n">UA</th><th>Composição</th></tr></thead><tbody>';
    Object.keys(grupos).sort().forEach(function(k){
      var rs = grupos[k], s = somar(rs), l = D.lot[rs[0].lote_id];
      var ps = {}; rs.forEach(function(r){ ps[(D.pas[r.pasto_id]||{}).codigo || 'sem pasto'] = 1; });
      html += '<tr><td>'+retiroTag(rs[0].retiro_id)+'</td><td><b>'+(l ? esc(l.codigo) : 'sem lote')+'</b>'+(l && l.carimbo ? ' <span class="faint">'+esc(l.carimbo)+'</span>' : '')+'</td><td>'+esc(Object.keys(ps).join(', '))+'</td><td class="n">'+n0(s.cab)+'</td><td class="n">'+n1(s.ua)+'</td><td style="font-size:.8rem">'+composicao(rs)+'</td></tr>';
    });
    return html + '</tbody></table></div>';
  }

  /* ============================================================================
     LIVRO
     ============================================================================ */
  function descPernas(pernas){
    return (pernas||[]).map(function(x){
      var s = x.estorno ? -x.sentido : x.sentido;
      return '<span class="'+(s>0?'leg-in':'leg-out')+'">'+(s>0?'+':'−')+n0(x.quantidade)+'</span> '+esc((D.cat[x.categoria_id]||{}).nome||'')+' <span class="faint">'+esc((D.pas[x.pasto_id]||{}).codigo || ((D.ret[x.retiro_id]||{}).sigla || '') + ' s/ pasto')+'</span>';
    }).join(' · ');
  }
  function renderLivro(){
    var el = $('#panel-livro');
    var lista = store.livroCache.filter(function(d){
      if(ui.livroOp && d.operacao !== ui.livroOp) return false;
      if(ui.livroRetiro && !(d.pernas||[]).some(function(p){ return p.retiro_id === ui.livroRetiro; })) return false;
      if(ui.livroBusca){ var b = ui.livroBusca.toLowerCase(); if(String(d.numero) !== b && (d.observacao||'').toLowerCase().indexOf(b) < 0 && (d.parceiro||'').toLowerCase().indexOf(b) < 0) return false; }
      return true;
    });
    var ops = (store.cad && store.cad.operacoes) || [];
    var html = '<div class="stack"><div class="card panel-pad"><div class="filters">' +
      '<div class="field"><label for="lvOp">Tipo</label><select class="select" id="lvOp">'+opt('', 'Todos')+ops.map(function(o){ return opt(o.codigo, o.nome, o.codigo===ui.livroOp); }).join('')+'</select></div>' +
      '<div class="field"><label for="lvRet">Retiro</label><select class="select" id="lvRet">'+opt('', 'Todos')+retirosLiberados().map(function(r){ return opt(r.id, r.nome, r.id===ui.livroRetiro); }).join('')+'</select></div>' +
      '<div class="field"><label for="lvBusca">Buscar</label><input class="input" id="lvBusca" placeholder="nº, comprador ou observação" value="'+esc(ui.livroBusca)+'"></div>' +
      '</div><p class="section-hint" style="margin:10px 0 0">Mostra os ' + n0(store.livroCache.length) + ' lançamentos mais recentes guardados no aparelho. Toque num lançamento para ver os detalhes ou estornar.</p></div>';
    var fila = store.fila.filter(function(e){ return e.tipo === 'lancar'; });
    html += '<div class="card">';
    fila.forEach(function(e){
      html += '<div class="doc pendente"><span class="nro">fila</span><span class="tit">'+esc(opNome(e.payload.operacao))+' · '+dataBR(e.payload.data)+'</span><span class="chip '+(e.estado==='recusado'?'bad':'warn')+'">'+(e.estado==='recusado'?'recusado':'aguardando envio')+'</span><span class="det legs">'+descPernas(e.payload.pernas)+'</span></div>';
    });
    if(!lista.length && !fila.length) html += '<div class="empty">Nenhum lançamento encontrado.</div>';
    lista.forEach(function(d){
      var st = d.status === 'ESTORNADO' ? '<span class="chip neutral">estornado pelo nº '+esc(d.estornado_por)+'</span>' : d.status === 'ESTORNO' ? '<span class="chip info">estorno do nº '+esc(d.estorna_numero)+'</span>' : '';
      html += '<div class="doc '+(d.status==='ESTORNADO'?'estornado':'')+'" data-act="doc" data-id="'+d.id+'"><span class="nro">nº '+d.numero+'</span><span class="tit">'+esc(opNome(d.operacao))+' · '+dataBR(d.data)+(d.parceiro?' · '+esc(d.parceiro):'')+'</span><span>'+st+'</span>' +
        '<span class="det legs">'+descPernas(d.pernas)+(d.observacao?' <span class="faint">— '+esc(d.observacao)+'</span>':'')+'</span></div>';
    });
    html += '</div></div>';
    el.innerHTML = html;
  }
  function abrirDoc(id){
    var d = store.livroCache.find(function(x){ return x.id === id; }); if(!d) return;
    var info = [['Data', dataBR(d.data)], ['Tipo', opNome(d.operacao)], ['Lançado por', (d.criado_por||'—') + ' · ' + quandoBR(d.criado_em)], ['Origem', d.origem + (d.linha_origem ? ' (' + d.linha_origem + ')' : '')]];
    if(d.causa_morte_id) info.push(['Causa da morte', (D.cau[d.causa_morte_id]||{}).nome]);
    if(d.canal_venda_id) info.push(['Canal', (D.can[d.canal_venda_id]||{}).nome]);
    if(d.parceiro) info.push(['Comprador / fornecedor', d.parceiro]);
    if(d.peso_total_kg) info.push(['Peso total', n1(d.peso_total_kg) + ' kg']);
    if(d.valor_total) info.push(['Valor total', brl.format(d.valor_total)]);
    if(d.observacao) info.push(['Observação', d.observacao]);
    var corpo = '<div class="table-scroll"><table><tbody>' + info.map(function(x){ return '<tr><td class="muted" style="width:40%">'+esc(x[0])+'</td><td>'+esc(x[1])+'</td></tr>'; }).join('') + '</tbody></table></div>' +
      '<div class="table-scroll"><table><thead><tr><th></th><th>Retiro</th><th>Pasto</th><th>Lote</th><th>Categoria</th><th>Raça</th><th class="n">Cab.</th></tr></thead><tbody>' +
      (d.pernas||[]).map(function(p){ var s = p.estorno ? -p.sentido : p.sentido; return '<tr><td class="'+(s>0?'leg-in':'leg-out')+'"><b>'+(s>0?'entra':'sai')+'</b></td><td>'+retiroTag(p.retiro_id)+'</td><td>'+esc((D.pas[p.pasto_id]||{}).codigo||'—')+'</td><td>'+esc((D.lot[p.lote_id]||{}).codigo||'—')+'</td><td>'+esc((D.cat[p.categoria_id]||{}).nome)+'</td><td>'+esc((D.rac[p.raca_id]||{}).nome||'—')+'</td><td class="n">'+n0(p.quantidade)+'</td></tr>'; }).join('') + '</tbody></table></div>';
    var pode = store.tem('MOV_ESTORNAR') && d.status === 'ATIVO';
    if(pode) corpo += fTxt('motivo', 'Motivo do estorno (para estornar)', 'placeholder="ex.: lançado em duplicidade"');
    abrirSheet('Lançamento nº ' + d.numero, corpo, '<button class="icon-btn" data-act="fechar" type="button">Fechar</button>' + (pode ? '<button class="icon-btn btn-danger" data-act="estornar" data-id="'+d.id+'" data-numero="'+d.numero+'" type="button">Estornar</button>' : ''));
  }

  /* ============================================================================
     PENDÊNCIAS
     ============================================================================ */
  function renderPendencias(){
    var el = $('#panel-pendencias');
    var pode = store.tem('PEND_EDITAR');
    var lista = store.pendencias.filter(function(p){ return ui.pendFiltro === 'todas' || p.status === 'ABERTA' || p.status === 'EM_ANDAMENTO'; });
    var html = '<div class="stack"><div class="card panel-pad spread"><div class="seg" id="pendFiltro"><button type="button" data-f="abertas" class="'+(ui.pendFiltro==='abertas'?'on':'')+'">Abertas</button><button type="button" data-f="todas" class="'+(ui.pendFiltro==='todas'?'on':'')+'">Todas</button></div>' +
      (pode ? '<button class="icon-btn btn-primary" data-act="pend-nova" type="button">+ Nova pendência</button>' : '') + '</div>';
    if(!lista.length) html += '<div class="card empty">Nenhuma pendência ' + (ui.pendFiltro==='abertas'?'aberta':'') + '.</div>';
    lista.forEach(function(p){
      var feita = p.status === 'RESOLVIDA' || p.status === 'CANCELADA';
      html += '<div class="card pend '+p.prioridade+(feita?' done':'')+'"><div class="spread"><b>nº '+p.numero+' · '+esc(p.titulo)+'</b><span class="row"><span class="chip '+(p.prioridade==='ALTA'?'bad':p.prioridade==='MEDIA'?'warn':'info')+'">'+esc(p.prioridade.toLowerCase().replace('media','média'))+'</span><span class="chip '+(feita?'good':'neutral')+'">'+esc({ABERTA:'aberta', EM_ANDAMENTO:'em andamento', RESOLVIDA:'resolvida', CANCELADA:'cancelada'}[p.status])+'</span></span></div>' +
        (p.descricao ? '<div style="margin-top:6px">'+esc(p.descricao)+'</div>' : '') +
        (p.acao_recomendada ? '<div class="muted" style="font-size:.84rem; margin-top:4px"><b>O que fazer:</b> '+esc(p.acao_recomendada)+'</div>' : '') +
        '<div class="faint" style="font-size:.76rem; margin-top:6px">'+(p.retiro_id ? retiroTag(p.retiro_id)+' · ' : '')+'origem '+esc(String(p.origem).toLowerCase())+(p.prazo ? ' · prazo '+dataBR(p.prazo) : '')+'</div>' +
        (p.resolucao ? '<div class="msg ok" style="margin-top:8px">'+esc(p.resolucao)+'</div>' : '') +
        (pode && !feita ? '<div class="row" style="margin-top:10px">'+(p.status==='ABERTA'?'<button class="icon-btn btn-sm" data-act="pend-st" data-st="EM_ANDAMENTO" data-id="'+p.id+'" type="button">Em andamento</button>':'')+'<button class="icon-btn btn-sm btn-primary" data-act="pend-resolver" data-id="'+p.id+'" type="button">Resolver</button><button class="icon-btn btn-sm" data-act="pend-st" data-st="CANCELADA" data-id="'+p.id+'" type="button">Cancelar</button></div>' : '') +
        (pode && feita ? '<div class="row" style="margin-top:10px"><button class="icon-btn btn-sm" data-act="pend-st" data-st="ABERTA" data-id="'+p.id+'" type="button">Reabrir</button></div>' : '') +
        '</div>';
    });
    el.innerHTML = html + '</div>';
  }
  function pendNova(){
    montar('Nova pendência',
      fTxt('titulo', 'O que precisa ser feito', 'placeholder="ex.: Conferir cerca do AgF-10"') +
      '<div class="field"><label for="desc">Detalhes</label><textarea class="input" id="desc" name="desc" rows="2"></textarea></div>' +
      '<div class="grid-3">' + fSel('retiro', 'Retiro', optRetiros(null, '(geral)')) + fSel('prio', 'Prioridade', opt('ALTA','Alta')+opt('MEDIA','Média',true)+opt('BAIXA','Baixa')) +
      '<div class="field"><label for="prazo">Prazo</label><input class="input" type="date" id="prazo" name="prazo"></div></div>',
      function(form){
        exigir(v(form,'titulo').trim(), 'Descreva a pendência.');
        store.salvarPendencia({ titulo: v(form,'titulo').trim(), descricao: v(form,'desc') || null, retiro_id: v(form,'retiro') || null, prioridade: v(form,'prio'), prazo: v(form,'prazo') || null }, 'Nova pendência: ' + v(form,'titulo').trim());
        fecharSheet(); toast('Pendência registrada.');
      }, null, 'Salvar pendência');
  }

  /* ============================================================================
     CADASTROS
     ============================================================================ */
  function renderCadastros(){
    var el = $('#panel-cadastros'); var c = store.cad || {}; var pode = store.tem('CAD_EDITAR');
    var abas = [['fazenda','Fazenda'],['retiros','Retiros'],['pastos','Pastos'],['lotes','Lotes'],['parceiros','Compradores e fornecedores']];
    if(store.tem('USUARIO_GERIR')) abas.push(['usuarios','Usuários']);
    abas.push(['conta','Minha conta']);
    var html = '<div class="stack"><div class="seg" id="cadAbas" style="flex-wrap:wrap">' + abas.map(function(a){ return '<button type="button" data-aba="'+a[0]+'" class="'+(ui.cadAba===a[0]?'on':'')+'">'+a[1]+'</button>'; }).join('') + '</div>';
    if(!pode && ['fazenda','retiros','pastos','lotes','parceiros'].indexOf(ui.cadAba) >= 0) html += '<div class="msg info">Somente leitura: seu perfil não edita cadastros.</div>';
    var est = store.estoqueEfetivo();
    if(ui.cadAba === 'fazenda'){
      var f = c.fazenda || {};
      html += '<form class="card panel-pad stack" id="fFaz"><h2 class="section-title">Dados da fazenda</h2><div class="grid-2">' +
        fTxt('nome', 'Nome da fazenda', 'value="'+esc(f.nome)+'" '+(pode?'':'disabled')) + fTxt('responsavel', 'Responsável', 'value="'+esc(f.responsavel||'')+'" '+(pode?'':'disabled')) + '</div><div class="grid-3">' +
        fTxt('municipio', 'Município', 'value="'+esc(f.municipio||'')+'" '+(pode?'':'disabled')) + fTxt('uf', 'UF', 'maxlength="2" value="'+esc(f.uf||'')+'" '+(pode?'':'disabled')) + fNum('area_total_ha', 'Área total (ha)', 'value="'+esc(f.area_total_ha||'')+'" '+(pode?'':'disabled')) + '</div>' +
        (pode ? '<div><button class="icon-btn btn-primary" data-act="salvar-faz" type="button">Salvar</button></div>' : '') + '</form>';
    }
    if(ui.cadAba === 'retiros'){
      html += '<div class="table-scroll"><table><thead><tr><th>Retiro</th><th>Tipo</th><th class="n">Pastos</th><th class="n">Área dos pastos (ha)</th><th class="n">Área informada (ha)</th><th class="n">Cab.</th>'+(pode?'<th></th>':'')+'</tr></thead><tbody>' +
        (c.retiros||[]).map(function(r){ var ps = pastosDo(r.id); var a = ps.reduce(function(s,p){ return s+Number(p.area_ha||0); },0);
          return '<tr><td>'+retiroTag(r.id)+'</td><td>'+esc(r.tipo.toLowerCase())+'</td><td class="n">'+ps.length+'</td><td class="n">'+n1(a)+'</td><td class="n">'+(r.area_informada_ha?n1(r.area_informada_ha):'—')+'</td><td class="n">'+n0(somar(est, function(x){ return x.retiro_id===r.id; }).cab)+'</td>' +
          (pode?'<td><button class="icon-btn btn-sm" data-act="ed-retiro" data-id="'+r.id+'" type="button">Área</button></td>':'')+'</tr>'; }).join('') + '</tbody></table></div>' +
        '<p class="section-hint">A área do retiro é a soma dos pastos. Para retiros sem mapa (Confinamento, ILP), informe a área total aqui.</p>';
    }
    if(ui.cadAba === 'pastos' || ui.cadAba === 'lotes'){
      var rsel = ui.cadRetiro || ((retirosLiberados()[0]||{}).id || '');
      html += '<div class="card panel-pad spread"><div class="field" style="min-width:200px"><label for="cadRet">Retiro</label><select class="select" id="cadRet">'+(c.retiros||[]).map(function(r){ return opt(r.id, r.nome, r.id===rsel); }).join('')+'</select></div>' +
        (pode ? '<button class="icon-btn btn-primary" data-act="'+(ui.cadAba==='pastos'?'ed-pasto':'ed-lote')+'" data-retiro="'+rsel+'" type="button">+ Novo '+(ui.cadAba==='pastos'?'pasto':'lote')+'</button>' : '') + '</div>';
      if(ui.cadAba === 'pastos'){
        var ps = ((c.pastos)||[]).filter(function(p){ return p.retiro_id === rsel; }).sort(function(a,b){ return a.codigo.localeCompare(b.codigo,'pt-BR',{numeric:true}); });
        html += '<div class="table-scroll"><table><thead><tr><th>Pasto</th><th class="n">Área (ha)</th><th class="n">Cab.</th><th class="n">UA/ha</th><th>Situação</th><th>Observação</th></tr></thead><tbody>' +
          ps.map(function(p){ var s = somar(est, function(x){ return x.pasto_id === p.id; }); var uah = Number(p.area_ha) ? s.ua/Number(p.area_ha) : null;
            return '<tr class="'+(pode?'clickable':'')+'" '+(pode?'data-act="ed-pasto" data-id="'+p.id+'"':'')+'><td><b>'+esc(p.codigo)+'</b></td><td class="n">'+n2(p.area_ha)+'</td><td class="n'+(s.cab?'':' zero')+'">'+n0(s.cab)+'</td><td class="n">'+(uah==null?'—':nf3.format(uah))+'</td><td><span class="chip '+(p.status==='ATIVO'?'good':'neutral')+'">'+esc(p.status.toLowerCase())+'</span></td><td style="font-size:.8rem">'+esc(p.observacao||'')+'</td></tr>'; }).join('') +
          '</tbody></table></div>';
      } else {
        var ls = ((c.lotes)||[]).filter(function(l){ return l.retiro_id === rsel; });
        html += '<div class="table-scroll"><table><thead><tr><th>Lote</th><th>Carimbo</th><th>Descrição</th><th class="n">Cab.</th><th>Situação</th></tr></thead><tbody>' +
          (ls.length ? ls.map(function(l){ var s = somar(est, function(x){ return x.lote_id === l.id; });
            return '<tr class="'+(pode?'clickable':'')+'" '+(pode?'data-act="ed-lote" data-id="'+l.id+'"':'')+'><td><b>'+esc(l.codigo)+'</b></td><td>'+esc(l.carimbo||'')+'</td><td>'+esc(l.descricao||'')+'</td><td class="n">'+n0(s.cab)+'</td><td><span class="chip '+(l.status==='ATIVO'?'good':'neutral')+'">'+esc(l.status.toLowerCase())+'</span></td></tr>'; }).join('') : '<tr><td colspan="5" class="empty">Nenhum lote neste retiro.</td></tr>') +
          '</tbody></table></div>';
      }
    }
    if(ui.cadAba === 'parceiros'){
      html += '<div class="card panel-pad spread"><span class="muted">Compradores, frigoríficos, leiloeiras e fornecedores. Também são criados sozinhos ao lançar uma venda ou compra.</span>' + (pode ? '<button class="icon-btn btn-primary" data-act="ed-parceiro" type="button">+ Novo</button>' : '') + '</div>' +
        '<div class="table-scroll"><table><thead><tr><th>Nome</th><th>Tipo</th><th>CPF/CNPJ</th><th>Cidade</th></tr></thead><tbody>' +
        ((c.parceiros||[]).length ? c.parceiros.map(function(p){ return '<tr class="'+(pode?'clickable':'')+'" '+(pode?'data-act="ed-parceiro" data-id="'+p.id+'"':'')+'><td><b>'+esc(p.nome)+'</b></td><td>'+esc((p.tipo||[]).join(', ').toLowerCase())+'</td><td>'+esc(p.documento||'')+'</td><td>'+esc([p.municipio,p.uf].filter(Boolean).join('/'))+'</td></tr>'; }).join('') : '<tr><td colspan="4" class="empty">Nenhum cadastrado ainda.</td></tr>') + '</tbody></table></div>';
    }
    if(ui.cadAba === 'usuarios') html += '<div class="card panel-pad" id="usuariosBox"><div class="empty">Carregando usuários…</div></div>';
    if(ui.cadAba === 'conta'){
      var s = store.sessao || {};
      html += '<div class="card panel-pad stack"><h2 class="section-title">'+esc((s.usuario||{}).nome)+'</h2><p class="muted">'+esc((s.usuario||{}).email)+' · perfil <b>'+esc((s.papel||{}).nome)+'</b>' + (s.retiros_permitidos ? ' · retiros: ' + s.retiros_permitidos.map(function(id){ return esc((D.ret[id]||{}).nome); }).join(', ') : ' · todos os retiros') + '</p>' +
        '<form id="fSenha" class="grid-2">' + '<div class="field"><label for="nova">Nova senha</label><input class="input" type="password" id="nova" name="nova" autocomplete="new-password" minlength="6"></div>' +
        '<div class="field"><label>&nbsp;</label><button class="icon-btn" data-act="trocar-senha" type="button">Trocar senha</button></div></form></div>';
    }
    el.innerHTML = html + '</div>';
    if(ui.cadAba === 'usuarios') carregarUsuarios();
  }
  async function carregarUsuarios(){
    var box = $('#usuariosBox'); if(!box) return;
    try{
      var u = await store.usuarios();
      var papeis = u.papeis || [];
      var html = '<h2 class="section-title">Usuários com acesso</h2><div class="table-scroll" style="margin-top:10px"><table><thead><tr><th>Nome</th><th>E-mail</th><th>Perfil</th><th>Retiros</th><th></th></tr></thead><tbody>' +
        u.usuarios.map(function(x){ return '<tr><td>'+esc(x.nome)+'</td><td>'+esc(x.email)+'</td><td>'+esc((papeis.find(function(p){ return p.codigo===x.papel; })||{}).nome||x.papel)+'</td><td>'+(x.retiro_ids ? x.retiro_ids.map(function(id){ return esc((D.ret[id]||{}).nome); }).join(', ') : 'todos')+'</td><td><span class="chip '+(x.status==='ATIVO'?'good':'neutral')+'">'+esc(x.status.toLowerCase())+'</span></td></tr>'; }).join('') +
        u.convites.map(function(x){ return '<tr><td>'+esc(x.nome)+'</td><td>'+esc(x.email)+'</td><td>'+esc((papeis.find(function(p){ return p.codigo===x.papel_codigo; })||{}).nome)+'</td><td>'+(x.retiro_ids ? x.retiro_ids.map(function(id){ return esc((D.ret[id]||{}).nome); }).join(', ') : 'todos')+'</td><td><span class="chip warn">convite: ainda não entrou</span></td></tr>'; }).join('') +
        '</tbody></table></div>' +
        '<h2 class="section-title" style="margin-top:20px">Dar acesso a alguém</h2><p class="section-hint">1) Autorize o e-mail aqui. 2) No painel do Supabase: <b>Authentication → Users → Add user → Create new user</b>, com o mesmo e-mail, uma senha e <b>Auto Confirm User</b>. Na primeira entrada o acesso é ligado sozinho. Para mudar perfil ou retiros de quem já entra, autorize de novo o mesmo e-mail.</p>' +
        '<form id="fConvite" class="stack"><div class="grid-3">' + fTxt('c_email', 'E-mail', 'type="email"') + fTxt('c_nome', 'Nome') +
        fSel('c_papel', 'Perfil', papeis.map(function(p){ return opt(p.codigo, p.nome + ' — ' + p.descricao, p.codigo==='ENCARREGADO'); }).join('')) + '</div>' +
        '<div class="field"><label>Retiros que pode ver e lançar (nenhum marcado = todos)</label><div class="row">' + ((store.cad && store.cad.retiros) || []).map(function(r){ return '<label class="chip neutral" style="cursor:pointer"><input type="checkbox" name="c_ret" value="'+r.id+'"> '+esc(r.nome)+'</label>'; }).join('') + '</div></div>' +
        '<div class="msg err" id="convMsg" hidden></div><div><button class="icon-btn btn-primary" data-act="convidar" type="button">Autorizar e-mail</button></div></form>';
      box.innerHTML = html;
    }catch(e){ box.innerHTML = '<div class="msg err">'+esc(e.mensagem || 'Não foi possível carregar. Precisa de internet.')+'</div>'; }
  }
  function edPasto(id, retiroId){
    var p = id ? D.pas[id] : { retiro_id: retiroId, status:'ATIVO' };
    montar(id ? 'Pasto ' + p.codigo : 'Novo pasto',
      '<div class="grid-2">' + fTxt('codigo', 'Código (como no mapa)', 'value="'+esc(p.codigo||'')+'" placeholder="ex.: Pla-3"') + fNum('area', 'Área (ha)', 'value="'+esc(p.area_ha||'')+'"') + '</div>' +
      '<div class="grid-3">' + fNum('lmin', 'Lotação mínima (UA/ha)', 'value="'+esc(p.lotacao_min_ua_ha||'')+'" placeholder="padrão da fazenda"') + fNum('lmax', 'Lotação máxima (UA/ha)', 'value="'+esc(p.lotacao_max_ua_ha||'')+'" placeholder="padrão da fazenda"') +
      fSel('status', 'Situação', opt('ATIVO','Ativo',p.status==='ATIVO')+opt('INATIVO','Inativo',p.status==='INATIVO')) + '</div>' +
      '<div class="field"><label for="obs">Observação</label><textarea class="input" id="obs" name="obs" rows="2">'+esc(p.observacao||'')+'</textarea></div>' +
      '<p class="section-hint">Retiro: '+retiroTag(p.retiro_id)+'. Pasto com animais não deve ser inativado — transfira o gado antes.</p>',
      function(form){ salvarCad('pasto', { id: id || null, retiro_id: p.retiro_id, codigo: v(form,'codigo'), area_ha: num(v(form,'area')) || 0,
        lotacao_min_ua_ha: isNaN(num(v(form,'lmin'))) ? null : num(v(form,'lmin')), lotacao_max_ua_ha: isNaN(num(v(form,'lmax'))) ? null : num(v(form,'lmax')),
        status: v(form,'status'), observacao: v(form,'obs') || null }); }, null, 'Salvar pasto');
  }
  function edLote(id, retiroId){
    var l = id ? D.lot[id] : { retiro_id: retiroId, status:'ATIVO' };
    montar(id ? 'Lote ' + l.codigo : 'Novo lote',
      '<div class="grid-2">' + fTxt('codigo', 'Nome do lote', 'value="'+esc(l.codigo||'')+'" placeholder="ex.: Lote 03"') + fTxt('carimbo', 'Carimbo dos bezerros', 'value="'+esc(l.carimbo||'')+'" placeholder="ex.: Cr8"') + '</div>' +
      fTxt('descricao', 'Descrição', 'value="'+esc(l.descricao||'')+'"') + fSel('status', 'Situação', opt('ATIVO','Ativo',l.status==='ATIVO')+opt('INATIVO','Inativo',l.status==='INATIVO')) +
      '<p class="section-hint">Retiro: '+retiroTag(l.retiro_id)+'</p>',
      function(form){ salvarCad('lote', { id: id || null, retiro_id: l.retiro_id, codigo: v(form,'codigo'), carimbo: v(form,'carimbo') || null, descricao: v(form,'descricao') || null, status: v(form,'status') }); }, null, 'Salvar lote');
  }
  function edParceiro(id){
    var p = id ? D.par[id] : { tipo:['COMPRADOR'], status:'ATIVO' };
    montar(id ? p.nome : 'Novo comprador ou fornecedor',
      fTxt('nome', 'Nome', 'value="'+esc(p.nome||'')+'"') + '<div class="grid-3">' + fTxt('doc', 'CPF/CNPJ', 'value="'+esc(p.documento||'')+'"') + fTxt('mun', 'Município', 'value="'+esc(p.municipio||'')+'"') + fTxt('uf', 'UF', 'maxlength="2" value="'+esc(p.uf||'')+'"') + '</div>' +
      '<div class="row"><label class="chip neutral"><input type="checkbox" name="tC" '+((p.tipo||[]).indexOf('COMPRADOR')>=0?'checked':'')+'> Comprador</label><label class="chip neutral"><input type="checkbox" name="tF" '+((p.tipo||[]).indexOf('FORNECEDOR')>=0?'checked':'')+'> Fornecedor</label></div>',
      function(form){ var t = []; if(form.elements.tC.checked) t.push('COMPRADOR'); if(form.elements.tF.checked) t.push('FORNECEDOR');
        salvarCad('parceiro', { id: id || null, nome: v(form,'nome'), documento: v(form,'doc') || null, municipio: v(form,'mun') || null, uf: v(form,'uf') || null, tipo: t, status: p.status }); }, null, 'Salvar');
  }
  function edRetiro(id){
    var r = D.ret[id];
    montar('Retiro ' + r.nome, fNum('area', 'Área informada (ha)', 'value="'+esc(r.area_informada_ha||'')+'"', 'Use para retiros sem mapa de pastos (Confinamento, ILP). Se o retiro tem pastos com área, vale a soma dos pastos.'),
      function(form){ salvarCad('retiro', { id: id, area_informada_ha: isNaN(num(v(form,'area'))) ? null : num(v(form,'area')), status: r.status }); }, null, 'Salvar');
  }
  async function salvarCad(tipo, dados){
    var btn = $('[data-act="salvar"]'); if(btn) btn.disabled = true;
    try{ await store.salvarCadastro(tipo, dados); fecharSheet(); toast('Cadastro salvo.'); }
    catch(e){ erroSheet(e.mensagem || 'Não foi possível salvar. Cadastros precisam de internet.'); }
    finally{ if(btn) btn.disabled = false; }
  }

  /* ============================================================================
     NAVEGAÇÃO, EVENTOS E INÍCIO
     ============================================================================ */
  function renderTudo(){
    indexar();
    var s = store.sessao; if(!s) return;
    $('#fazendaNome').textContent = (s.fazenda && s.fazenda.nome) || 'Fazenda';
    $('#userNome').textContent = (s.usuario && s.usuario.nome) + ' · ' + ((s.papel && s.papel.nome) || '');
    renderInicio(); renderLancar(); renderEstoque(); renderLivro(); renderPendencias();
    if(ui.cadAba !== 'usuarios' || !$('#usuariosBox')) renderCadastros();
    Ext.render.forEach(function(f){ try{ f(); }catch(e){ console.error(e); } });
    pintarStatus(store.status);
  }
  function irPara(tab){
    ui.tab = tab;
    $$('.tab-btn').forEach(function(b){ b.classList.toggle('active', b.getAttribute('data-tab') === tab); });
    $$('.tab-panel').forEach(function(p){ p.classList.toggle('active', p.id === 'panel-' + tab); });
    try{ localStorage.setItem('pec-jsrural-aba', tab); }catch(e){}
    window.scrollTo({top:0});
    if(Ext.abrir[tab]) Ext.abrir[tab]();
  }
  /* ganchos para os módulos da Entrega 3 (app3.js) */
  var Ext = { render: [], abrir: {}, acoes: {}, mudar: [] };

  document.addEventListener('click', async function(ev){
    var t = ev.target.closest('[data-act], .tab-btn, [data-modo], [data-f], [data-aba]');
    if(!t) return;
    if(t.classList.contains('tab-btn')) return irPara(t.getAttribute('data-tab'));
    if(t.closest('#estModo') && t.hasAttribute('data-modo')){ ui.estModo = t.getAttribute('data-modo'); return renderEstoque(); }
    if(t.closest('#pendFiltro')){ ui.pendFiltro = t.getAttribute('data-f'); return renderPendencias(); }
    if(t.closest('#cadAbas')){ ui.cadAba = t.getAttribute('data-aba'); return renderCadastros(); }
    var act = t.getAttribute('data-act'), id = t.getAttribute('data-id');
    switch(act){
      case 'fechar': fecharSheet(); break;
      case 'salvar': if(aoSalvar) aoSalvar(); break;
      case 'f-nasc': fNascimento(); break;
      case 'f-morte': fMorte(); break;
      case 'f-venda': fVenda(); break;
      case 'f-transf': fTransferencia(); break;
      case 'f-outro': fOutro(); break;
      case 'enviar': store.enviar(); break;
      case 'descartar': if(confirm('Descartar este item? Ele não será gravado.')) store.descartar(id); break;
      case 'reenviar': store.reenviar(id); break;
      case 'corrigir': corrigir(id); break;
      case 'doc': abrirDoc(id); break;
      case 'estornar': {
        var mot = (v($('#sheetForm'), 'motivo') || '').trim();
        if(mot.length < 4) return erroSheet('Escreva o motivo do estorno.');
        store.estornar(id, mot, 'Estorno do nº ' + t.getAttribute('data-numero') + ': ' + mot);
        fecharSheet(); toast('Estorno registrado.'); break;
      }
      case 'pend-nova': pendNova(); break;
      case 'pend-st': store.salvarPendencia({ id:id, status: t.getAttribute('data-st') }, 'Pendência: ' + t.getAttribute('data-st').toLowerCase()); otimistaPend(id, t.getAttribute('data-st')); break;
      case 'pend-resolver': {
        var p = store.pendencias.find(function(x){ return x.id === id; });
        montar('Resolver pendência nº ' + p.numero, '<p>'+esc(p.titulo)+'</p><div class="field"><label for="res">Como foi resolvida</label><textarea class="input" id="res" name="res" rows="3"></textarea></div>',
          function(form){ exigir((v(form,'res')||'').trim().length >= 3, 'Conte em uma frase como foi resolvida.');
            store.salvarPendencia({ id:id, status:'RESOLVIDA', resolucao: v(form,'res').trim() }, 'Pendência nº ' + p.numero + ' resolvida'); otimistaPend(id, 'RESOLVIDA', v(form,'res').trim()); fecharSheet(); }, null, 'Marcar como resolvida');
        break;
      }
      case 'salvar-faz': { var f = $('#fFaz'); try{ await store.salvarCadastro('fazenda', { nome: v(f,'nome'), responsavel: v(f,'responsavel'), municipio: v(f,'municipio'), uf: v(f,'uf'), area_total_ha: isNaN(num(v(f,'area_total_ha'))) ? null : num(v(f,'area_total_ha')) }); toast('Fazenda atualizada.'); }catch(e){ toast(e.mensagem || 'Precisa de internet.', true); } break; }
      case 'ed-pasto': edPasto(id, t.getAttribute('data-retiro')); break;
      case 'ed-lote': edLote(id, t.getAttribute('data-retiro')); break;
      case 'ed-parceiro': edParceiro(id); break;
      case 'ed-retiro': edRetiro(id); break;
      case 'convidar': {
        var cf = $('#fConvite'); var m = $('#convMsg');
        try{
          var ret = $$('input[name="c_ret"]:checked', cf).map(function(x){ return x.value; });
          await store.convidar({ email: v(cf,'c_email'), nome: v(cf,'c_nome'), papel: v(cf,'c_papel'), retiro_ids: ret });
          toast('E-mail autorizado. Agora crie o usuário no Supabase.'); carregarUsuarios();
        }catch(e){ m.textContent = e.mensagem || 'Não foi possível autorizar.'; m.hidden = false; }
        break;
      }
      case 'trocar-senha': { var nv = v($('#fSenha'), 'nova'); if((nv||'').length < 6) return toast('A senha precisa ter ao menos 6 caracteres.', true);
        try{ await store.trocarSenha(nv); toast('Senha alterada.'); $('#fSenha').reset(); }catch(e){ toast(e.mensagem, true); } break; }
      case 'f-conf': irPara('conferencia'); break;
      default: if(Ext.acoes[act]) await Ext.acoes[act](t, ev);
    }
  });
  document.addEventListener('change', async function(ev){
    var t = ev.target;
    if(t.id === 'estRetiro'){ ui.estRetiro = t.value; renderEstoque(); }
    if(t.id === 'estData'){
      ui.estData = t.value;
      if(!t.value || t.value === hoje()){ ui.estHist = null; ui.estData = ''; return renderEstoque(); }
      try{ ui.estHist = await store.estoqueEm(t.value); }catch(e){ ui.estHist = null; ui.estData = ''; toast(e.mensagem || 'Posição em outra data precisa de internet.', true); }
      renderEstoque();
    }
    if(t.id === 'lvOp'){ ui.livroOp = t.value; renderLivro(); }
    if(t.id === 'lvRet'){ ui.livroRetiro = t.value; renderLivro(); }
    if(t.id === 'cadRet'){ ui.cadRetiro = t.value; renderCadastros(); }
    Ext.mudar.forEach(function(f){ f(t, ev); });
  });
  document.addEventListener('input', function(ev){ if(ev.target.id === 'lvBusca'){ ui.livroBusca = ev.target.value.trim(); var pos = ev.target.selectionStart; renderLivro(); var i = $('#lvBusca'); i.focus(); i.setSelectionRange(pos,pos); } });

  function otimistaPend(id, st, res){ var p = store.pendencias.find(function(x){ return x.id === id; }); if(p){ p.status = st; if(res) p.resolucao = res; } renderPendencias(); }
  function corrigir(id){
    var e = store.fila.find(function(x){ return x.id === id; }); if(!e) return;
    var p = e.payload;
    var corpo = '<div class="msg err">'+esc(e.erro)+'</div><p class="section-hint">Corrija data e quantidades abaixo e reenvie. Para mudar pasto ou categoria, descarte e lance de novo.</p>' + fData('data') +
      p.pernas.map(function(x, i){ return '<div class="grid-2"><div class="field"><label>'+(x.sentido>0?'Entra':'Sai')+'</label><span>'+esc((D.cat[x.categoria_id]||{}).nome)+' · '+esc((D.pas[x.pasto_id]||{}).codigo||'')+'</span></div>' + fNum('q'+i, 'Quantidade', 'value="'+x.quantidade+'"') + '</div>'; }).join('');
    var form = montar('Corrigir lançamento recusado', corpo, function(form){
      var novo = JSON.parse(JSON.stringify(p)); novo.data = v(form,'data');
      novo.pernas.forEach(function(x, i){ var q = num(v(form,'q'+i)); exigir(Number.isInteger(q) && q > 0, 'Quantidade inválida.'); x.quantidade = q; });
      store.reenviar(id, novo); fecharSheet(); toast('Reenviando…');
    }, null, 'Reenviar');
    form.elements.data.value = p.data;
  }

  /* ---------------- login ---------------- */
  function mostrarLogin(msg){
    $('#app').hidden = true; $('#loginScreen').hidden = false;
    var m = $('#loginMsg'); m.textContent = msg || ''; m.hidden = !msg; m.className = 'msg err';
  }
  function mostrarApp(){
    $('#loginScreen').hidden = true; $('#app').hidden = false;
    var ab = null; try{ ab = localStorage.getItem('pec-jsrural-aba'); }catch(e){}
    renderTudo(); if(ab && $('#panel-' + ab)) irPara(ab);
  }
  $('#loginForm').addEventListener('submit', async function(ev){
    ev.preventDefault();
    var b = $('#loginBtn'); b.disabled = true; b.textContent = 'Entrando…';
    try{ await store.entrar($('#loginEmail').value, $('#loginSenha').value); mostrarApp(); }
    catch(e){ mostrarLogin(e.mensagem || 'Não foi possível entrar.'); }
    finally{ b.disabled = false; b.textContent = 'Entrar'; }
  });
  $('#loginEsqueci').addEventListener('click', async function(ev){
    ev.preventDefault();
    var em = $('#loginEmail').value; if(!em){ return mostrarLogin('Digite seu e-mail acima e toque de novo em "Esqueci a senha".'); }
    try{ await store.esqueciSenha(em); var m = $('#loginMsg'); m.className = 'msg ok'; m.textContent = 'Enviamos um link para ' + em + '. Abra o e-mail neste aparelho.'; m.hidden = false; }
    catch(e){ mostrarLogin(e.mensagem); }
  });
  $('#btnSair').addEventListener('click', async function(){
    var r = await store.sair(false);
    if(r.bloqueado){
      if(!confirm('Há ' + r.pendentes + ' lançamento(s) ainda não enviados. Se sair agora eles continuam guardados neste aparelho e serão enviados quando alguém entrar de novo. Sair mesmo assim?')) return;
      await store.sair(true);
    }
    mostrarLogin('');
  });
  $('#btnAtualizar').addEventListener('click', async function(){ await store.enviar(); var ok = await store.refresh(); toast(ok ? 'Dados atualizados.' : (store.status.erro || 'Sem internet — mostrando os dados guardados.'), !ok); });
  $('#sheet').addEventListener('click', function(ev){ if(ev.target.id === 'sheet') fecharSheet(); });

  document.addEventListener('DOMContentLoaded', async function iniciar(){
    try{
      var r = await store.init();
      if(r === 'config'){ $('#configScreen').hidden = false; return; }
      if(r === 'login') return mostrarLogin('');
      mostrarApp(); store.enviar(); store.refresh();
    }catch(e){ mostrarLogin(e.mensagem || 'Não foi possível abrir sua sessão.'); }
  });

  window.PecApp = { store: store, ui: ui, ext: Ext, h: {
    $: $, $$: $$, esc: esc, n0: n0, n1: n1, n2: n2, pct: pct, nf1: nf1, nf3: nf3, brl: brl, hoje: hoje, dataBR: dataBR, quandoBR: quandoBR,
    num: num, toast: toast, dic: function(){ return D; }, retiroTag: retiroTag, corRetiro: corRetiro, retirosLiberados: retirosLiberados,
    pastosDo: pastosDo, lotesDo: lotesDo, categorias: categorias, parametro: parametro, somar: somar,
    opt: opt, fData: fData, fSel: fSel, fNum: fNum, fTxt: fTxt, fObs: fObs, v: v,
    abrirSheet: abrirSheet, fecharSheet: fecharSheet, erroSheet: erroSheet, montar: montar, exigir: exigir, irPara: irPara, renderTudo: renderTudo
  } };
})();
