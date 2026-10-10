/* Teste de ponta a ponta da Entrega 3 (Mapão, Reprodução, Mês) no Chromium,
   contra o mock do Supabase ligado ao Postgres local recém-carregado.
   Uso: node e2e_entrega3.js [porta]                                               */
const { chromium } = require(process.env.PW || 'playwright');
const fs = require('fs');
const { execSync } = require('child_process');
const BASE = 'http://localhost:' + (process.argv[2] || 8787);
const OUT = __dirname + '/telas'; fs.mkdirSync(OUT, { recursive: true });
let falhas = 0, n = 0;
function ok(cond, nome, extra){ n++; console.log((cond ? '  ✔ ' : '  ✘ ') + nome + (extra !== undefined ? ' → ' + extra : '')); if(!cond) falhas++; }
const sql = (q) => require('child_process').spawnSync('su', ['postgres', '-c', `psql -h /tmp -d pecuaria -tAc "${q}"`]).stdout.toString().trim();
const total = (page) => page.evaluate(() => PecApp.store.estoqueEfetivo().reduce((s, r) => s + Number(r.cabecas), 0));
const filaVazia = async (page) => { await page.waitForFunction(() => (PecApp.store.fila.length === 0 || PecApp.store.fila.some(e => e.estado === 'recusado')) && !PecApp.store.status.enviando && !PecApp.store.status.atualizando, null, { timeout: 15000 }).catch(async (e) => { console.log('    DEBUG', await page.evaluate(async () => JSON.stringify({ env: await Promise.race([PecApp.store.enviar(), new Promise(r => setTimeout(() => r('TRAVADO'), 4000))]), st: PecApp.store.status, fila: PecApp.store.fila.map(f => [f.tipo, f.estado, f.erro]) }))); throw e; });
  const rec = await page.evaluate(() => PecApp.store.fila.filter(e => e.estado === 'recusado').map(e => e.erro).join(' | ')); if(rec) console.log('    (recusado: ' + rec + ')'); return rec; };
async function pick(page, nome, prefixo, escopo){
  const r = await page.evaluate(([nome, prefixo, escopo]) => {
    const s = document.querySelector((escopo || '#sheetForm') + ' [name="' + nome + '"], ' + (escopo || '#sheetForm') + ' #' + nome); if(!s) return 'sem campo ' + nome;
    const o = Array.from(s.options).find((o) => o.textContent.trim().startsWith(prefixo)); if(!o) return 'sem opção ' + prefixo + ' em ' + nome + ': ' + Array.from(s.options).map(o => o.textContent).join('|');
    s.value = o.value; s.dispatchEvent(new Event('change', { bubbles: true })); return 'ok';
  }, [nome, prefixo, escopo]);
  if(r !== 'ok') throw new Error(r);
}
const fill = (page, nome, v) => page.fill('#sheetForm [name="' + nome + '"]', String(v));
const salvar = (page) => page.click('#sheet [data-act="salvar"]');
const msgSheet = (page) => page.$eval('#sheetMsg', (e) => e.hidden ? '' : e.textContent);
const fechada = (page) => page.waitForFunction(() => !document.querySelector('#sheet').open, null, { timeout: 10000 });
const offline = (v) => fetch(BASE + '/__offline?v=' + (v ? 1 : 0));
const pid = (cod) => sql(`select id from pec.pasto where codigo='${cod}'`);
const cid = (nome) => sql(`select id from pec.categoria where nome='${nome}'`);
async function entrar(page, email){
  if(await page.$('#app:not([hidden])')){ await page.click('#btnSair'); await page.waitForSelector('#loginScreen:not([hidden])'); }
  await page.fill('#loginEmail', email); await page.fill('#loginSenha', 'teste123'); await page.click('#loginBtn');
  await page.waitForSelector('#app:not([hidden])'); await page.waitForFunction((em) => PecApp.store.sessao && PecApp.store.sessao.usuario.email === em && PecApp.store.cad, email);
  await filaVazia(page);
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'pt-BR', serviceWorkers: 'block' });
  const page = await ctx.newPage();
  const erros = []; page.on('pageerror', (e) => erros.push(e.message)); page.on('console', (m) => { if(m.type() === 'error' && !/Failed to load resource|ERR_|fonts/.test(m.text())) erros.push(m.text()); });
  page.on('dialog', (d) => d.accept());
  await page.addInitScript(() => { window.PEC_SEM_IMPRESSAO = true; });
  await page.goto(BASE + '/');
  await entrar(page, 'admin@teste.com');

  console.log('1. Mapão: emitir e contar no celular');
  await page.click('.tab-btn[data-tab="conferencia"]');
  await page.waitForSelector('#mpRet');
  await pick(page, 'mpRet', 'Água Funda', '#panel-conferencia'); await page.fill('#mpMes', '2026-09');
  await page.dispatchEvent('#mpMes', 'change');
  await page.click('[data-act="mp-emitir"]');
  await page.waitForSelector('[data-pasto-card]');
  const cards = await page.$$eval('[data-pasto-card]', (e) => e.map((x) => x.getAttribute('data-pasto-card')));
  ok(cards.length >= 2, 'um cartão por pasto com gado', cards.length);
  await page.screenshot({ path: OUT + '/01_mapao_contagem.png', fullPage: true });

  // AgF-10: tudo igual, menos Vaca −2
  const agf10 = pid('AgF-10'), agf12 = pid('AgF-12'), agf11 = pid('AgF-11'), vaca = cid('Vaca'), bm = cid('Bez. Macho');
  await page.fill('#mpQuem', 'Zé do Campo');
  const linhas10 = await page.$$eval(`[data-pasto-card="${agf10}"] .conta-row[data-k]`, (rows) => rows.map((r) => [r.getAttribute('data-k'), r.querySelector('.sis').textContent]));
  for(const [k, s] of linhas10){ const v = Number(s.replace(/\./g, '')) - (k.endsWith(vaca) ? 2 : 0); await page.fill(`[data-campo="${k}"]`, String(v)); }
  await page.fill(`[data-obs="${agf10}|${vaca}"]`, 'faltaram 2 na contagem');
  ok((await page.textContent(`[data-k="${agf10}|${vaca}"] .dif`)).includes('-2'), 'diferença aparece ao digitar', await page.textContent(`[data-k="${agf10}|${vaca}"] .dif`));
  await page.click(`[data-act="mp-salvar-pasto"][data-pasto="${agf10}"]`); await filaVazia(page);
  await page.waitForFunction((p) => document.querySelector(`[data-pasto-card="${p}"] .pasto-head .chip`).textContent === 'contado', agf10, { timeout: 8000 });
  ok(true, 'AgF-10 salvo e marcado como contado');

  // AgF-12 sem internet: "bate com o sistema" + 1 bezerro a mais
  await offline(true); await page.evaluate(() => window.dispatchEvent(new Event('offline')));
  await page.click(`[data-act="mp-bate"][data-pasto="${agf12}"]`);
  await page.waitForTimeout(400);
  ok(await page.evaluate(() => PecApp.store.fila.filter(e => e.tipo === 'rpc').length) === 1, 'sem internet: contagem do AgF-12 vai para a fila');
  const k12 = `${agf12}|${bm}`; const s12 = Number((await page.textContent(`[data-k="${k12}"] .sis`)).replace(/\./g, ''));
  await page.fill(`[data-campo="${k12}"]`, String(s12 + 1)); await page.click(`[data-act="mp-salvar-pasto"][data-pasto="${agf12}"]`); await page.waitForTimeout(300);
  ok((await page.textContent(`[data-k="${k12}"] .dif`)).includes('+1'), 'valor da fila aparece na tela offline');
  await page.screenshot({ path: OUT + '/02_mapao_offline.png', fullPage: true });
  await offline(false); await page.evaluate(() => window.dispatchEvent(new Event('online'))); await filaVazia(page);
  await page.waitForTimeout(800);
  ok(sql(`select qtd_campo - qtd_sistema from pec.inventario_item where pasto_id='${agf12}' and categoria_id='${bm}'`) === '1', 'fila enviada: AgF-12 Bez. Macho +1 no banco');

  // vaca encontrada num pasto vazio (AgF-11)
  await page.click('details.mais summary'); await page.click(`[data-act="mp-add-pasto"][data-pasto="${agf11}"]`);
  await pick(page, 'cat', 'Vaca'); await fill(page, 'qtd', 1); await salvar(page); await fechada(page);
  await page.click(`[data-act="mp-salvar-pasto"][data-pasto="${agf11}"]`); await filaVazia(page); await page.waitForTimeout(600);
  ok(sql(`select qtd_campo from pec.inventario_item where pasto_id='${agf11}' and categoria_id='${vaca}'`) === '1', 'vaca achada no AgF-11 anotada');

  console.log('2. Imprimir o Mapão (A4 deitado)');
  await page.click('[data-act="mp-imprimir-inv"]');
  await page.waitForSelector('#printArea.preview .mapa-print');
  const folha = await page.textContent('#printArea');
  ok(/MAPA DE EFETIVO PECUÁRIO/.test(folha) && /CONTADO NO CAMPO/.test(folha) && /SEM PASTO|TOTAL/.test(folha), 'folha com cabeçalho, colunas e total');
  await page.emulateMedia({ media: 'print' });
  await page.pdf({ path: OUT + '/mapao_agua_funda_09-2026.pdf', format: 'A4', landscape: true, printBackground: true });
  await page.screenshot({ path: OUT + '/03_mapao_impresso.png', fullPage: true });
  await page.emulateMedia({ media: 'screen' });
  await page.evaluate(() => { const a = document.querySelector('#printArea'); a.classList.remove('preview'); a.innerHTML = ''; });
  ok(fs.statSync(OUT + '/mapao_agua_funda_09-2026.pdf').size > 10000, 'PDF da folha gerado');

  console.log('3. Concluir, achar o lançamento esquecido e aprovar ajustes');
  const pend0 = Number(sql("select count(*) from pec.pendencia where status='ABERTA'"));
  await page.click('[data-act="mp-concluir"]'); await page.waitForSelector('#sheet[open]');
  await salvar(page); await fechada(page);
  await page.waitForFunction(() => /contado/.test(document.querySelector('#panel-conferencia .chip').textContent), null, { timeout: 8000 });
  ok(Number(sql("select count(*) from pec.pendencia where status='ABERTA'")) === pend0 + 3, '3 divergências viraram pendências', sql("select count(*) from pec.pendencia where status='ABERTA'"));
  await page.screenshot({ path: OUT + '/04_mapao_divergencias.png', fullPage: true });
  // a morte de uma vaca em 20/09 não tinha sido lançada
  await page.click('.tab-btn[data-tab="lancar"]'); await page.click('[data-act="f-morte"]');
  await page.fill('#sheetForm [name="data"]', '2026-09-20');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca'); await pick(page, 'causa', 'Raio');
  await salvar(page); await filaVazia(page);
  await page.click('.tab-btn[data-tab="conferencia"]'); await page.waitForSelector('[data-act="mp-aprovar"]');
  await page.click('[data-act="mp-aprovar"]'); await salvar(page); await fechada(page);
  await page.waitForFunction(() => /ajustado/.test(document.querySelector('#panel-conferencia .chip').textContent), null, { timeout: 8000 });
  const ajustes = sql("select string_agg(m.sentido*m.quantidade||' '||c.nome||' '||p.codigo, ', ' order by p.codigo) from pec.documento d join pec.movimento m on m.documento_id=d.id join pec.categoria c on c.id=m.categoria_id join pec.pasto p on p.id=m.pasto_id where d.operacao_codigo='AJUSTE_INVENTARIO'");
  ok(ajustes === '-1 Vaca AgF-10, 1 Vaca AgF-11, 1 Bez. Macho AgF-12', 'ajustes certos (a morte lançada reduziu o do AgF-10)', ajustes);
  ok(Number(sql("select count(*) from pec.pendencia where status='ABERTA'")) === pend0, 'pendências do Mapão resolvidas');
  await page.screenshot({ path: OUT + '/05_mapao_ajustado.png', fullPage: true });
  await page.click('[data-act="mp-voltar"]'); await page.waitForSelector('.inv-row');
  ok((await page.textContent('.inv-row')).includes('conferido e ajustado'), 'lista mostra o Mapão conferido');

  console.log('4. Reprodução');
  await page.click('.tab-btn[data-tab="reproducao"]'); await page.waitForSelector('[data-act="rp-estacao"]');
  await page.click('[data-act="rp-estacao"]'); await fill(page, 'nome', 'Estação 25/26'); await fill(page, 'ini', '2025-11-01'); await fill(page, 'fim', '2026-02-28');
  await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForSelector('[data-act="rp-lote"]');
  await page.click('[data-act="rp-lote"]'); await pick(page, 'ret', 'Água Funda'); await pick(page, 'cat', 'Vaca');
  ok(/No estoque hoje/.test(await page.textContent('#exp_hint')), 'mostra vacas no estoque', await page.textContent('#exp_hint'));
  await fill(page, 'exp', 150); await fill(page, 'ecc', '3,5'); await fill(page, 'carimbo', 'Cr8'); await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForSelector('.lote-card');
  const loteId = sql("select id from pec.lote_reprodutivo limit 1");
  await page.click(`[data-act="rp-rodada"][data-lote="${loteId}"]`);
  await fill(page, 'prot', 'P4 9 dias'); await fill(page, 'd0', '2025-11-03'); await page.dispatchEvent('#sheetForm [name="d0"]', 'change');
  ok(await page.inputValue('#sheetForm [name="di"]') === '2025-11-13', 'IATF calculada a partir do D0', await page.inputValue('#sheetForm [name="di"]'));
  await fill(page, 'ins', 140); await fill(page, 'touro', 'Nelore A'); await fill(page, 'ddg', '2025-12-20'); await fill(page, 'per', 2); await fill(page, 'pre', 80);
  await page.dispatchEvent('#sheetForm [name="pre"]', 'input');
  ok(await page.inputValue('#sheetForm [name="vaz"]') === '58', 'vazias calculadas (140 − 80 − 2)', await page.inputValue('#sheetForm [name="vaz"]'));
  await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForFunction(() => document.querySelectorAll('.lote-card tbody tr').length >= 1);
  await page.click(`[data-act="rp-rodada"][data-lote="${loteId}"]:not([data-id])`);
  await fill(page, 'd0', '2025-12-21'); await page.dispatchEvent('#sheetForm [name="d0"]', 'change'); await fill(page, 'ins', 70); await salvar(page);
  ok(/68/.test(await msgSheet(page)), '2ª rodada acima das disponíveis é barrada', await msgSheet(page));
  await fill(page, 'ins', 58); await fill(page, 'ddg', '2026-02-05'); await fill(page, 'pre', 30); await page.dispatchEvent('#sheetForm [name="pre"]', 'input');
  await salvar(page); await fechada(page); await filaVazia(page);
  await page.click(`[data-act="rp-dg"][data-lote="${loteId}"]`); await fill(page, 'ddg', '2026-04-10'); await fill(page, 'pre', 120); await fill(page, 'vaz', 28); await fill(page, 'desc', 10);
  await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForFunction(() => /80,0%/.test(document.querySelector('#panel-reproducao .kpi-grid').textContent), null, { timeout: 8000 });
  ok(true, 'taxa de prenhez 80,0% no painel');
  const conc = await page.textContent('#panel-reproducao .kpi-grid');
  ok(/57,1%/.test(conc), 'concepção na 1ª IATF 57,1%');
  ok(/2026\/2027/.test(await page.textContent('#panel-reproducao')), 'mostra a safra de parição');
  await page.screenshot({ path: OUT + '/06_reproducao.png', fullPage: true });
  // estação atual com IATF marcada há 2 dias → agenda
  const hoje = new Date(); const d0 = new Date(hoje - 2 * 864e5).toISOString().slice(0, 10);
  await page.click('[data-act="rp-estacao"]:not([data-id])'); await fill(page, 'nome', 'Estação 26/27'); await fill(page, 'ini', '2026-10-01'); await fill(page, 'fim', '2027-01-31');
  await salvar(page); await fechada(page); await filaVazia(page); await page.waitForTimeout(500);
  await page.click('[data-act="rp-lote"]'); await pick(page, 'ret', 'Água Funda'); await pick(page, 'cat', 'Primípara'); await fill(page, 'exp', 40); await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForSelector('.lote-card');
  const lote2 = sql("select lr.id from pec.lote_reprodutivo lr join pec.estacao_monta e on e.id=lr.estacao_id where e.nome='Estação 26/27'");
  await page.click(`[data-act="rp-rodada"][data-lote="${lote2}"]`); await fill(page, 'd0', d0); await page.dispatchEvent('#sheetForm [name="d0"]', 'change');
  await salvar(page); await fechada(page); await filaVazia(page);
  await page.waitForFunction(() => document.querySelectorAll('.agenda-item').length >= 2, null, { timeout: 8000 });
  ok(/D8/.test(await page.textContent('#panel-reproducao')) && /IATF · 1ª/.test(await page.textContent('#panel-reproducao')), 'agenda mostra D8 e IATF que vêm aí');
  await page.screenshot({ path: OUT + '/07_reproducao_agenda.png', fullPage: true });

  console.log('5. Desmama com data de nascimento → P205');
  await page.click('.tab-btn[data-tab="lancar"]'); await page.click('[data-act="f-outro"]'); await page.click('[data-outro="DESMAMA"]');
  await pick(page, 'o_retiro', 'Água Funda'); await pick(page, 'o_pasto', 'AgF-12');
  await fill(page, 'qm', 10); await fill(page, 'pm', 2100); await fill(page, 'qf', 8); await fill(page, 'pf', 1600); await fill(page, 'nascm', '2026-02-10');
  await salvar(page); await filaVazia(page);
  ok(sql("select count(*) from pec.v_desmama where p205_kg is not null") === '2', 'desmama gravou peso por sexo com P205');

  console.log('6. Fechamento do mês');
  await page.click('.tab-btn[data-tab="mes"]'); await page.waitForSelector('.mes-chip');
  ok(/meses anteriores abertos/i.test(await page.textContent('#panel-mes')), 'setembro mostra o bloqueio de meses anteriores');
  ok(await page.$eval('[data-act="fm-fechar"]', (b) => b.disabled), 'botão de fechar desativado');
  for(const m of ['2026-07-01', '2026-08-01', '2026-09-01']){
    await page.click(`[data-act="fm-mes"][data-mes="${m}"]`); await page.waitForFunction((m) => document.querySelector('.mes-chip.on') && document.querySelector('.mes-chip.on').getAttribute('data-mes') === m, m);
    await page.waitForSelector('[data-act="fm-fechar"]:not([disabled])', { timeout: 8000 });
    await page.click('[data-act="fm-fechar"]'); await salvar(page); await fechada(page);
    await page.waitForFunction((m) => document.querySelector(`.mes-chip[data-mes="${m}"]`).classList.contains('fechado'), m, { timeout: 8000 });
  }
  ok(sql("select count(*) from pec.periodo where status='FECHADO'") === '3', 'julho, agosto e setembro fechados');
  ok(/Fechamento por retiro/.test(await page.textContent('#panel-mes')) && /Evolução mensal/.test(await page.textContent('#panel-mes')), 'tabelas de fechamento e evolução');
  await page.screenshot({ path: OUT + '/08_mes_fechado.png', fullPage: true });
  await page.click('[data-act="fm-reabrir"]'); await salvar(page);
  ok(/Explique/.test(await msgSheet(page)), 'reabrir exige motivo');
  await page.fill('#sheetForm [name="obs"]', 'Faltou lançar uma venda de setembro'); await salvar(page); await fechada(page);
  await page.waitForFunction(() => /Reaberto em/.test(document.querySelector('#panel-mes').textContent), null, { timeout: 8000 });
  ok(sql("select motivo_reabertura from pec.periodo where competencia='2026-09-01'") === 'Faltou lançar uma venda de setembro', 'reabertura registrada com motivo');
  await page.click('[data-act="fm-visao"][data-v="cat"]');
  ok(/Vaca/.test(await page.textContent('#panel-mes table')), 'visão por categoria');
  await page.click('[data-act="fm-imprimir"]'); await page.waitForSelector('#printArea.preview .mapa-print');
  ok((await page.$$('#printArea .mapa-print')).length >= 3, 'imprime um Mapão por retiro com gado', (await page.$$('#printArea .mapa-print')).length);
  await page.evaluate(() => { const a = document.querySelector('#printArea'); a.classList.remove('preview'); a.innerHTML = ''; });

  console.log('7. Vaqueiro do Pontal');
  await entrar(page, 'vaq@teste.com');
  await page.click('.tab-btn[data-tab="conferencia"]'); await page.waitForSelector('#mpRet');
  const retOpts = await page.$$eval('#mpRet option', (o) => o.map((x) => x.textContent));
  ok(retOpts.join() === 'Pontal', 'só o Pontal para emitir', retOpts.join());
  await page.fill('#mpMes', '2026-09'); await page.dispatchEvent('#mpMes', 'change'); await page.click('[data-act="mp-emitir"]'); await page.waitForSelector('[data-pasto-card]');
  ok(!(await page.$('[data-act="mp-aprovar"]')) && !(await page.$('[data-act="mp-cancelar"]')), 'vaqueiro não aprova nem cancela');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: OUT + '/09_celular_contagem.png', fullPage: true });
  ok(await page.evaluate(() => document.documentElement.scrollWidth) <= 390, 'contagem cabe no celular');
  await page.click('.tab-btn[data-tab="reproducao"]'); await page.waitForTimeout(800);
  ok(!(await page.$('[data-act="rp-lote"]')), 'vaqueiro não edita reprodução');
  await page.click('.tab-btn[data-tab="mes"]'); await page.waitForSelector('.mes-chip');
  ok(!(await page.$('[data-act="fm-fechar"]')) && !(await page.$('[data-act="fm-reabrir"]')), 'vaqueiro não fecha nem reabre mês');
  await page.screenshot({ path: OUT + '/10_celular_mes.png', fullPage: true });

  ok(erros.length === 0, 'sem erros de JavaScript', erros.join(' | '));
  console.log(`\n${n - falhas}/${n} verificações ok`);
  await browser.close(); process.exit(falhas ? 1 : 0);
})().catch((e) => { console.error('FALHOU:', e); process.exit(2); });
