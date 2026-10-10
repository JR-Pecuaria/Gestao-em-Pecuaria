/* Teste de ponta a ponta do app (Playwright + Chromium) contra o mock do Supabase
   ligado ao Postgres local com a carga da planilha. Uso: node e2e.js [porta]       */
const { chromium } = require(process.env.PW || 'playwright');
const fs = require('fs');
const BASE = 'http://localhost:' + (process.argv[2] || 8787);
const OUT = __dirname + '/telas'; fs.mkdirSync(OUT, { recursive: true });
let falhas = 0, n = 0;
function ok(cond, nome, extra){ n++; if(cond) console.log('  ✔ ' + nome + (extra !== undefined ? ' → ' + extra : '')); else { falhas++; console.log('  ✘ ' + nome + (extra !== undefined ? ' → ' + extra : '')); } }
const total = (page) => page.evaluate(() => PecApp.store.estoqueEfetivo().reduce((s, r) => s + Number(r.cabecas), 0));
const filaVazia = async (page) => { await page.waitForFunction(() => (PecApp.store.fila.length === 0 || PecApp.store.fila.some(e => e.estado === 'recusado')) && !PecApp.store.status.enviando && !PecApp.store.status.atualizando, null, { timeout: 15000 });
  const rec = await page.evaluate(() => PecApp.store.fila.filter(e => e.estado === 'recusado').map(e => e.erro).join(' | ')); if(rec) console.log('    (recusado: ' + rec + ')'); };
async function pick(page, nome, prefixo){
  const r = await page.evaluate(([nome, prefixo]) => {
    const s = document.querySelector('#sheetForm [name="' + nome + '"]'); if(!s) return 'sem campo ' + nome;
    const o = Array.from(s.options).find((o) => o.textContent.trim().startsWith(prefixo)); if(!o) return 'sem opção ' + prefixo + ' em ' + nome + ': ' + Array.from(s.options).map(o=>o.textContent).join('|');
    s.value = o.value; s.dispatchEvent(new Event('change', { bubbles: true })); return 'ok';
  }, [nome, prefixo]);
  if(r !== 'ok') throw new Error(r);
}
const fill = (page, nome, v) => page.fill('#sheetForm [name="' + nome + '"]', String(v));
const salvar = async (page) => { await page.click('#sheet [data-act="salvar"]'); await page.waitForTimeout(150);
  if(await page.$('#sheet[open]')){ const m = await page.$eval('#sheetMsg', (e) => e.textContent); if(m && !/negativo/.test(m)) { console.log('    (formulário recusou: ' + m + ')'); await page.click('#sheet [data-act="fechar"]'); } } };
const msgSheet = (page) => page.$eval('#sheetMsg', (e) => e.hidden ? '' : e.textContent);
const offline = (v) => fetch(BASE + '/__offline?v=' + (v ? 1 : 0));

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'pt-BR', serviceWorkers: 'block' });
  const page = await ctx.newPage();
  const erros = []; page.on('pageerror', (e) => erros.push(e.message)); page.on('console', (m) => { if(m.type() === 'error' && !/Failed to load resource|ERR_|fonts/.test(m.text())) erros.push(m.text()); });
  page.on('dialog', (d) => d.accept());

  console.log('1. Login');
  await page.goto(BASE + '/');
  await page.waitForSelector('#loginScreen:not([hidden])');
  await page.fill('#loginEmail', 'admin@teste.com'); await page.fill('#loginSenha', 'errada'); await page.click('#loginBtn');
  await page.waitForSelector('#loginMsg:not([hidden])');
  ok(true, 'senha errada recusada', await page.textContent('#loginMsg'));
  await page.fill('#loginSenha', 'teste123'); await page.click('#loginBtn');
  await page.waitForSelector('#app:not([hidden])');
  await page.waitForFunction(() => PecApp.store.resumo && PecApp.store.cad);
  ok(await total(page) === 774, 'rebanho inicial 774', await total(page));
  ok((await page.textContent('#userNome')).includes('Administrador'), 'perfil admin', await page.textContent('#userNome'));
  await page.screenshot({ path: OUT + '/01_inicio.png', fullPage: true });

  console.log('2. Nova morte (AgF-10, 1 vaca, raio)');
  await page.click('.tab-btn[data-tab="lancar"]');
  await page.screenshot({ path: OUT + '/02_lancar.png' });
  await page.click('[data-act="f-morte"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca'); await pick(page, 'causa', 'Raio');
  ok((await page.textContent('#qtd_hint')).includes('72'), 'mostra disponível', await page.textContent('#qtd_hint'));
  await page.screenshot({ path: OUT + '/03_form_morte.png' });
  await salvar(page); await filaVazia(page);
  ok(await total(page) === 773, 'estoque 773 após morte', await total(page));

  console.log('3. Validação no aparelho: morte de 500 vacas');
  await page.click('[data-act="f-morte"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca'); await pick(page, 'causa', 'Raio');
  await fill(page, 'qtd', 500); await salvar(page);
  ok((await msgSheet(page)).includes('negativo'), 'bloqueia estoque negativo', await msgSheet(page));
  await page.click('#sheet [data-act="fechar"]');

  console.log('4. Nascimento (3 machos + 2 fêmeas em AgF-12)');
  await page.click('[data-act="f-nasc"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-12');
  await fill(page, 'n_qtd0', 3); await fill(page, 'n_qtd1', 2);
  await salvar(page); await filaVazia(page);
  ok(await total(page) === 778, 'estoque 778 após nascimento', await total(page));

  console.log('5. Venda com comprador novo e cálculo R$/kg');
  await page.click('[data-act="f-venda"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-12'); await pick(page, 'cat', 'Vaca'); await pick(page, 'canal', 'Frigor');
  await fill(page, 'qtd', 4); await fill(page, 'comprador', 'Frigorífico Teste'); await fill(page, 'peso', '1.800'); await fill(page, 'valor', '18.000,00');
  await page.dispatchEvent('#sheetForm [name="valor"]', 'input');
  const calc = await page.textContent('#vCalc'); ok(calc.includes('450') && calc.includes('10,00'), 'calcula kg/cab e R$/kg', calc);
  await page.screenshot({ path: OUT + '/04_form_venda.png' });
  await salvar(page); await filaVazia(page);
  ok(await total(page) === 774, 'estoque 774 após venda', await total(page));
  ok(await page.evaluate(() => PecApp.store.cad.parceiros.some((p) => p.nome === 'Frigorífico Teste')), 'comprador criado sozinho');

  console.log('6. Transferências');
  await page.click('[data-act="f-transf"]');
  await pick(page, 'o_retiro', 'Água Funda'); await pick(page, 'o_pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca');
  await pick(page, 'd_pasto', 'AgF-12'); await fill(page, 'qtd', 5); await salvar(page); await filaVazia(page);
  ok(await page.evaluate(() => PecApp.store.estoqueEfetivo().filter(r => r.pasto_id === Object.values(PecApp.store.cad.pastos).find(p => p.codigo === 'AgF-10').id && PecApp.store.cad.categorias.find(c => c.id === r.categoria_id).nome === 'Vaca').reduce((s, r) => s + r.cabecas, 0)) === 66, 'AgF-10 com 66 vacas (72−1−5)');
  // entre retiros: sem pasto da Placa → Pontal Pon-1
  await page.click('[data-act="f-transf"]'); await page.click('#tModo [data-modo="TRANSF_RETIRO"]');
  await pick(page, 'o_retiro', 'Placa'); await pick(page, 'o_pasto', 'Sem pasto'); await pick(page, 'cat', 'Vaca');
  await pick(page, 'd_retiro', 'Pontal'); await pick(page, 'd_pasto', 'Pon-1'); await fill(page, 'qtd', 3); await salvar(page); await filaVazia(page);
  ok(await total(page) === 774, 'entre retiros (sem pasto → Pon-1) mantém total', await total(page));
  // refugo de cocho: origem só Confinamento
  await page.click('[data-act="f-transf"]'); await page.click('#tModo [data-modo="REFUGO_COCHO"]');
  const origens = await page.$$eval('#sheetForm [name="o_retiro"] option', (o) => o.map((x) => x.textContent));
  ok(origens.length === 1 && origens[0] === 'Confinamento', 'refugo: origem só Confinamento', origens.join(','));
  await pick(page, 'o_pasto', 'Conf'); await pick(page, 'cat', 'Bez. Macho'); await pick(page, 'd_retiro', 'Água Funda'); await pick(page, 'd_pasto', 'AgF-10');
  await fill(page, 'qtd', 2); await page.screenshot({ path: OUT + '/05_form_refugo.png' }); await salvar(page); await filaVazia(page);
  ok(await total(page) === 774, 'refugo de cocho gravado', await total(page));

  console.log('7. Desmama e mudança de era');
  await page.click('[data-act="f-outro"]'); await page.click('[data-outro="DESMAMA"]');
  await pick(page, 'o_retiro', 'Água Funda'); await pick(page, 'o_pasto', 'AgF-12');
  await fill(page, 'qm', 10); await fill(page, 'pm', 2100); await fill(page, 'qf', 8); await fill(page, 'pf', 1520);
  await page.dispatchEvent('#sheetForm [name="pf"]', 'input');
  ok((await page.textContent('#dCalc')).includes('210'), 'peso médio machos', await page.textContent('#dCalc'));
  await salvar(page); await filaVazia(page);
  const erroDesm = await page.evaluate(() => PecApp.store.fila.map(e => e.erro).join(';'));
  ok(await total(page) === 774 && !erroDesm, 'desmama gravada (4 pernas)', erroDesm || await total(page));
  await page.click('[data-act="f-outro"]'); await page.click('[data-outro="ERA"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-12');
  const deOps = await page.$$eval('#sheetForm [name="de"] option', (o) => o.map((x) => x.textContent).slice(1));
  ok(deOps.length > 0, 'categorias com transição de era', deOps.join(', '));
  await pick(page, 'de', deOps.find(x => /Desmama M|Desm/.test(x)) || deOps[0]);
  const paraOps = await page.$$eval('#sheetForm [name="para"] option', (o) => o.map((x) => x.textContent).slice(1));
  ok(paraOps.length > 0, 'nova categoria sugerida', paraOps.join(', '));
  await pick(page, 'para', paraOps[0]); await fill(page, 'qtd', 2); await salvar(page); await filaVazia(page);
  const erroEra = await page.evaluate(() => PecApp.store.fila.map(e => e.erro).join(';'));
  ok(!erroEra, 'mudança de era gravada', erroEra || 'ok');

  console.log('8. Sem internet: fila e envio automático');
  await offline(true); await page.evaluate(() => window.dispatchEvent(new Event('offline')));
  await page.click('[data-act="f-morte"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca'); await pick(page, 'causa', 'Raio');
  await salvar(page); await page.waitForTimeout(1500);
  ok(await page.evaluate(() => PecApp.store.fila.length) === 1, 'lançamento ficou na fila', await page.textContent('#syncPill'));
  ok(await total(page) === 773, 'estoque já desconta o que está na fila', await total(page));
  await page.screenshot({ path: OUT + '/06_fila_offline.png' });
  await offline(false); await page.evaluate(() => window.dispatchEvent(new Event('online'))); await filaVazia(page);
  ok(await total(page) === 773, 'fila enviada ao voltar a internet', await page.textContent('#syncPill'));

  console.log('9. Recusado pelo banco (mês fechado) → reenviar');
  await offline(true); await page.evaluate(() => window.dispatchEvent(new Event('offline')));
  await page.click('[data-act="f-morte"]');
  await pick(page, 'retiro', 'Água Funda'); await pick(page, 'pasto', 'AgF-10'); await pick(page, 'cat', 'Vaca'); await pick(page, 'causa', 'Raio');
  await salvar(page); await page.waitForTimeout(500);
  require('child_process').execSync(`su postgres -c "psql -h /tmp -d pecuaria -qc \\"insert into pec.periodo (fazenda_id, competencia, status) select id, date_trunc('month', current_date)::date, 'FECHADO' from pec.fazenda on conflict (fazenda_id, competencia) do update set status='FECHADO'\\""`);
  await offline(false); await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForFunction(() => PecApp.store.fila.some((e) => e.estado === 'recusado'), null, { timeout: 10000 });
  const motivo = await page.evaluate(() => PecApp.store.fila[0].erro); ok(/fechad/i.test(motivo), 'recusado com motivo claro', motivo);
  await page.screenshot({ path: OUT + '/07_recusado.png' });
  require('child_process').execSync(`su postgres -c "psql -h /tmp -d pecuaria -qc \\"update pec.periodo set status='ABERTO' where competencia = date_trunc('month', current_date)::date\\""`);
  await page.click('[data-act="reenviar"]'); await filaVazia(page);
  ok(await total(page) === 772, 'reenviado após reabrir o mês', await total(page));

  console.log('10. Livro e estorno');
  await page.click('.tab-btn[data-tab="livro"]');
  await page.click('#panel-livro .doc[data-act="doc"]');
  await page.screenshot({ path: OUT + '/08_doc_detalhe.png' });
  await page.fill('#sheetForm [name="motivo"]', 'teste de estorno'); await page.click('#sheet [data-act="estornar"]'); await filaVazia(page);
  ok(await total(page) === 773, 'estorno devolve a vaca', await total(page));
  ok(await page.evaluate(() => PecApp.store.livroCache[0].status === 'ESTORNO' && PecApp.store.livroCache[1].status === 'ESTORNADO'), 'livro mostra estorno e estornado');
  await page.screenshot({ path: OUT + '/09_livro.png', fullPage: true });

  console.log('11. Estoque, pendências e cadastros');
  await page.click('.tab-btn[data-tab="estoque"]'); await page.screenshot({ path: OUT + '/10_estoque.png', fullPage: true });
  await page.click('#estModo [data-modo="matriz"]'); await page.screenshot({ path: OUT + '/11_matriz.png', fullPage: true });
  ok((await page.textContent('#panel-estoque tfoot')).includes('773'), 'matriz soma 773');
  await page.click('.tab-btn[data-tab="pendencias"]');
  const pend0 = await page.evaluate(() => PecApp.store.pendencias.length);
  await page.click('[data-act="pend-nova"]'); await fill(page, 'titulo', 'Conferir cerca do AgF-10'); await salvar(page); await filaVazia(page);
  ok(await page.evaluate(() => PecApp.store.pendencias.length) === pend0 + 1, 'pendência criada', pend0 + 1);
  await page.screenshot({ path: OUT + '/12_pendencias.png', fullPage: true });
  await page.click('.tab-btn[data-tab="cadastros"]');
  await page.fill('#fFaz [name="nome"]', 'Fazenda Teste E2E'); await page.click('[data-act="salvar-faz"]');
  await page.waitForFunction(() => document.querySelector('#fazendaNome').textContent === 'Fazenda Teste E2E', null, { timeout: 8000 });
  ok(true, 'fazenda renomeada');
  await page.click('#cadAbas [data-aba="pastos"]'); await page.click('[data-act="ed-pasto"][data-retiro]');
  await fill(page, 'codigo', 'Pla-99'); await fill(page, 'area', '12,5'); await salvar(page);
  await page.waitForFunction(() => PecApp.store.cad.pastos.some((p) => p.codigo === 'Pla-99' || p.codigo === 'AgF-99'), null, { timeout: 8000 }).then(() => ok(true, 'pasto novo salvo'), async () => ok(false, 'pasto novo salvo', await msgSheet(page)));
  if(await page.$('#sheet[open]')) await page.click('#sheet [data-act="fechar"]');
  await page.click('#cadAbas [data-aba="usuarios"]'); await page.waitForSelector('#fConvite');
  await page.screenshot({ path: OUT + '/13_usuarios.png', fullPage: true });

  console.log('12. Encarregado do Pontal');
  await page.click('#btnSair'); await page.waitForSelector('#loginScreen:not([hidden])');
  await page.fill('#loginEmail', 'enc@teste.com'); await page.fill('#loginSenha', 'teste123'); await page.click('#loginBtn');
  await page.waitForSelector('#app:not([hidden])'); await filaVazia(page);
  await page.waitForFunction(() => PecApp.store.sessao && PecApp.store.sessao.usuario.email === 'enc@teste.com');
  const encTot = await total(page); ok(encTot === 245, 'vê só o Pontal (242 + 3 transferidas)', encTot);
  await page.click('.tab-btn[data-tab="lancar"]'); await page.click('[data-act="f-venda"]');
  const rets = await page.$$eval('#sheetForm [name="retiro"] option', (o) => o.map((x) => x.textContent));
  ok(rets.join() === 'Pontal', 'só lança no Pontal', rets.join());
  ok(!(await page.$('#sheetForm [name="valor"]')), 'não vê campo de valor');
  await page.click('#sheet [data-act="fechar"]');

  console.log('13. Celular');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.click('.tab-btn[data-tab="inicio"]'); await page.screenshot({ path: OUT + '/14_celular_inicio.png', fullPage: true });
  await page.click('.tab-btn[data-tab="lancar"]'); await page.click('[data-act="f-nasc"]'); await page.screenshot({ path: OUT + '/15_celular_nascimento.png' });
  const larg = await page.evaluate(() => document.documentElement.scrollWidth); ok(larg <= 390, 'sem rolagem lateral no celular', larg);

  ok(erros.length === 0, 'sem erros de JavaScript', erros.join(' | '));
  console.log(`\n${n - falhas}/${n} verificações ok`);
  await browser.close(); process.exit(falhas ? 1 : 0);
})().catch((e) => { console.error('FALHOU:', e); process.exit(2); });
