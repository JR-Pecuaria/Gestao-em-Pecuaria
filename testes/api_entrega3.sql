-- Testes da API da Entrega 3 (conferência, reprodução, fechamento).
-- Rodar num banco recém-carregado da planilha + 06, 07 e 08. Tudo dentro de uma transação desfeita no fim.
\set ON_ERROR_STOP 1
BEGIN;
SET search_path = pec, public;
CREATE TEMP TABLE r (n serial, teste text, ok boolean, obtido text);

-- helpers --------------------------------------------------------------
CREATE FUNCTION pg_temp.como(p_email text, p_sub text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'email', p_email, 'role', 'authenticated')::text, false);
  PERFORM public.pec_sessao();
END $$;
CREATE FUNCTION pg_temp.ok(p_teste text, p_cond boolean, p_obtido anyelement) RETURNS void LANGUAGE sql AS $$
  INSERT INTO r (teste, ok, obtido) VALUES (p_teste, COALESCE(p_cond, false), p_obtido::text);
$$;
CREATE FUNCTION pg_temp.ok(p_teste text, p_cond boolean, p_obtido text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO r (teste, ok, obtido) VALUES (p_teste, COALESCE(p_cond, false), p_obtido);
$$;
-- executa SQL e devolve o código de erro (HINT) ou 'OK'
CREATE FUNCTION pg_temp.codigo(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE h text; m text;
BEGIN
  EXECUTE p_sql; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT, m = MESSAGE_TEXT; RETURN COALESCE(NULLIF(h,''), 'SQL') || ': ' || m;
END $$;
CREATE FUNCTION pg_temp.id(p_tab text, p_nome text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid; BEGIN EXECUTE format('SELECT id FROM pec.%I WHERE %s = $1', p_tab, CASE p_tab WHEN 'pasto' THEN 'codigo' ELSE 'nome' END) INTO v USING p_nome; RETURN v; END $$;
CREATE FUNCTION pg_temp.est(p_pasto text, p_cat text, p_data date) RETURNS bigint LANGUAGE sql AS $$
  SELECT COALESCE(sum(cabecas),0) FROM pec.fn_estoque((SELECT id FROM pec.fazenda), p_data)
   WHERE pasto_id = pg_temp.id('pasto', p_pasto) AND categoria_id = pg_temp.id('categoria', p_cat)
$$;

INSERT INTO pec.convite (email, nome, fazenda_id, papel_codigo) SELECT 'adm@t.com', 'Adm', id, 'ADMIN' FROM pec.fazenda ON CONFLICT DO NOTHING;
INSERT INTO pec.convite (email, nome, fazenda_id, papel_codigo, retiro_ids) SELECT 'vaq@t.com', 'Vaqueiro Pontal', id, 'VAQUEIRO', ARRAY[pg_temp.id('retiro','Pontal')] FROM pec.fazenda ON CONFLICT DO NOTHING;
INSERT INTO pec.convite (email, nome, fazenda_id, papel_codigo, retiro_ids) SELECT 'enc@t.com', 'Enc Pontal', id, 'ENCARREGADO', ARRAY[pg_temp.id('retiro','Pontal')] FROM pec.fazenda ON CONFLICT DO NOTHING;

-- 1. CONFERÊNCIA ---------------------------------------------------------
SELECT pg_temp.como('adm@t.com', 'a0000000-0000-4000-8000-000000000001');
CREATE TEMP TABLE inv AS SELECT public.pec_inventario_emitir(pg_temp.id('retiro','Água Funda'), '2026-09-15') AS j;
SELECT pg_temp.ok('emitir: posição no fim do mês', (SELECT j->>'data_posicao' FROM inv) = '2026-09-30', (SELECT j->>'data_posicao' FROM inv));
SELECT pg_temp.ok('emitir: sistema = estoque do retiro em 30/09',
  (SELECT (j->'resumo'->>'sistema')::int FROM inv) = (SELECT sum(cabecas) FROM pec.fn_estoque((SELECT id FROM pec.fazenda), '2026-09-30') WHERE retiro_id = pg_temp.id('retiro','Água Funda')),
  (SELECT j->'resumo'->>'sistema' FROM inv));
SELECT pg_temp.ok('emitir de novo devolve o mesmo', (public.pec_inventario_emitir(pg_temp.id('retiro','Água Funda'), '2026-09-01')->>'id') = (SELECT j->>'id' FROM inv) , 'mesmo id');
SELECT pg_temp.ok('não emite mês futuro', pg_temp.codigo($$SELECT public.pec_inventario_emitir(pg_temp.id('retiro','Água Funda'), '2027-01-01')$$) LIKE 'MES_FUTURO%', 'MES_FUTURO');
SELECT pg_temp.ok('concluir sem contar é recusado', pg_temp.codigo(format($$SELECT public.pec_inventario_concluir(%L)$$, (SELECT j->>'id' FROM inv))) LIKE 'INV_SEM_CONTAGEM%', '');

-- contagem: tudo bate, menos AgF-10 Vaca (−2) e 1 vaca achada no AgF-11 (sem gado no sistema)
SELECT pg_temp.ok('contar', (public.pec_inventario_contar(jsonb_build_object(
  'inventario_id', (SELECT j->>'id' FROM inv), 'data_contagem', '2026-10-02', 'contado_por_nome', 'Zé do Campo',
  'itens', (SELECT jsonb_agg(jsonb_build_object('pasto_id', it->>'pasto_id', 'categoria_id', it->>'categoria_id',
              'qtd_campo', (it->>'qtd_sistema')::int - CASE WHEN it->>'pasto_id' = pg_temp.id('pasto','AgF-10')::text AND it->>'categoria_id' = pg_temp.id('categoria','Vaca')::text THEN 2 ELSE 0 END))
              || jsonb_build_array(jsonb_build_object('pasto_id', pg_temp.id('pasto','AgF-11'), 'categoria_id', pg_temp.id('categoria','Vaca'), 'qtd_campo', 1, 'observacao', 'vaca de outro pasto'))
            FROM inv, jsonb_array_elements(j->'itens') it)))->>'ok')::boolean, 'ok');
SELECT pg_temp.ok('contagem negativa recusada', pg_temp.codigo(format($$SELECT public.pec_inventario_contar('{"inventario_id":"%s","itens":[{"pasto_id":null,"categoria_id":"%s","qtd_campo":-1}]}')$$,
   (SELECT j->>'id' FROM inv), pg_temp.id('categoria','Vaca'))) LIKE 'QTD_INVALIDA%', '');

CREATE TEMP TABLE conc AS SELECT public.pec_inventario_concluir((SELECT (j->>'id')::uuid FROM inv)) AS j;
SELECT pg_temp.ok('concluir: 2 divergências → 2 pendências', (SELECT (j->>'divergencias')::int FROM conc) = 2, (SELECT j->>'divergencias' FROM conc));
SELECT pg_temp.ok('contar depois de concluir é recusado', pg_temp.codigo(format($$SELECT public.pec_inventario_contar('{"inventario_id":"%s","itens":[]}')$$, (SELECT j->>'id' FROM inv))) LIKE 'INV_CONCLUIDO%', '');

-- vaqueiro do Pontal
SELECT pg_temp.como('vaq@t.com', 'a0000000-0000-4000-8000-000000000002');
SELECT pg_temp.ok('vaqueiro emite Mapão do Pontal', (public.pec_inventario_emitir(pg_temp.id('retiro','Pontal'), '2026-09-01')->>'status') = 'EMITIDO', '');
SELECT pg_temp.ok('vaqueiro não emite Água Funda', pg_temp.codigo($$SELECT public.pec_inventario_emitir(pg_temp.id('retiro','Água Funda'), '2026-09-01')$$) LIKE 'RETIRO_NAO_LIBERADO%', '');
SELECT pg_temp.ok('vaqueiro não aprova ajuste', pg_temp.codigo(format($$SELECT public.pec_inventario_aprovar(%L)$$, (SELECT j->>'id' FROM inv))) LIKE 'SEM_PERMISSAO%', '');
SELECT pg_temp.ok('vaqueiro só vê o Mapão do Pontal', jsonb_array_length(public.pec_inventarios()) = 1, jsonb_array_length(public.pec_inventarios()));

-- escritório lembra de uma morte esquecida em 20/09 no AgF-10 → a divergência cai para −1
SELECT pg_temp.como('adm@t.com', 'a0000000-0000-4000-8000-000000000001');
SELECT public.pec_lancar(jsonb_build_object('operacao','MORTE','data','2026-09-20','causa_morte_id',(SELECT id FROM pec.causa_morte WHERE nome='Raio'),
  'pernas', jsonb_build_array(jsonb_build_object('sentido',-1,'retiro_id',pg_temp.id('retiro','Água Funda'),'pasto_id',pg_temp.id('pasto','AgF-10'),'categoria_id',pg_temp.id('categoria','Vaca'),'quantidade',1))));
CREATE TEMP TABLE apr AS SELECT public.pec_inventario_aprovar((SELECT (j->>'id')::uuid FROM inv), 'Mapão set/26') AS j;
SELECT pg_temp.ok('aprovar: 2 ajustes (−1 AgF-10, +1 AgF-11)', (SELECT (j->>'ajustes')::int FROM apr) = 2, (SELECT j->>'ajustes' FROM apr));
SELECT pg_temp.ok('AgF-10 vacas em 30/09 = contado no campo',
  pg_temp.est('AgF-10','Vaca','2026-09-30') = (SELECT (it->>'qtd_campo')::int FROM apr, jsonb_array_elements(j->'inventario'->'itens') it
                                             WHERE it->>'pasto_id' = pg_temp.id('pasto','AgF-10')::text AND it->>'categoria_id' = pg_temp.id('categoria','Vaca')::text),
  pg_temp.est('AgF-10','Vaca','2026-09-30'));
SELECT pg_temp.ok('AgF-11 ganhou 1 vaca', pg_temp.est('AgF-11','Vaca','2026-09-30') - pg_temp.est('AgF-11','Vaca','2026-09-29') = 1, '');
SELECT pg_temp.ok('Mapão AJUSTADO e pendências resolvidas', (SELECT j->'inventario'->>'status' FROM apr) = 'AJUSTADO'
   AND NOT EXISTS (SELECT 1 FROM pec.pendencia WHERE referencia_id = (SELECT (j->>'id')::uuid FROM inv) AND status IN ('ABERTA','EM_ANDAMENTO')), '');
SELECT pg_temp.ok('ajuste aparece no livro', (SELECT count(*) FROM pec.documento WHERE operacao_codigo = 'AJUSTE_INVENTARIO' AND observacao LIKE 'Mapão set/26%') = 2, '');
SELECT pg_temp.ok('pec_mapao traz posição e contagem', (public.pec_mapao(pg_temp.id('retiro','Água Funda'), '2026-09-01')->'inventario'->>'status') = 'AJUSTADO', '');

-- 2. REPRODUÇÃO ---------------------------------------------------------
CREATE TEMP TABLE est AS SELECT public.pec_estacao_salvar('{"nome":"Estação 25/26","inicio":"2025-11-01","fim":"2026-02-28"}') AS j;
SELECT pg_temp.ok('estação cria a safra 2025/2026', EXISTS (SELECT 1 FROM pec.safra WHERE nome = '2025/2026'), '');
SELECT pg_temp.ok('estação com datas trocadas é recusada', pg_temp.codigo($$SELECT public.pec_estacao_salvar('{"nome":"X","inicio":"2026-02-01","fim":"2025-11-01"}')$$) LIKE 'DATAS_INVALIDAS%', '');
CREATE TEMP TABLE lr AS SELECT public.pec_lote_reprodutivo_salvar(jsonb_build_object('estacao_id', (SELECT j->>'id' FROM est),
   'retiro_id', pg_temp.id('retiro','Água Funda'), 'categoria_id', pg_temp.id('categoria','Vaca'), 'qtd_expostas', 150, 'carimbo_bezerro', 'Cr8')) AS j;
SELECT pg_temp.ok('lote de bezerro é recusado', pg_temp.codigo(format($$SELECT public.pec_lote_reprodutivo_salvar('{"estacao_id":"%s","retiro_id":"%s","categoria_id":"%s","qtd_expostas":5}')$$,
   (SELECT j->>'id' FROM est), pg_temp.id('retiro','Água Funda'), pg_temp.id('categoria','Bez. Macho'))) LIKE 'CATEGORIA_INVALIDA%', '');
SELECT pg_temp.ok('1ª IATF + DG', (public.pec_rodada_salvar(jsonb_build_object('lote_reprodutivo_id', (SELECT j->>'id' FROM lr), 'rodada', 1,
   'protocolo_nome', 'P4 9 dias', 'data_d0', '2025-11-03', 'data_d8', '2025-11-11', 'data_iatf', '2025-11-13', 'qtd_inseminadas', 140,
   'touro_semen', 'Nelore A', 'data_dg', '2025-12-20', 'qtd_prenhes', 80, 'qtd_vazias', 58, 'qtd_perdas', 2))->>'ok')::boolean, '');
SELECT pg_temp.ok('protocolo criado pelo nome', EXISTS (SELECT 1 FROM pec.protocolo_iatf WHERE nome = 'P4 9 dias'), '');
SELECT pg_temp.ok('2ª rodada acima das disponíveis (68) recusada', pg_temp.codigo(format($$SELECT public.pec_rodada_salvar('{"lote_reprodutivo_id":"%s","rodada":2,"data_d0":"2025-12-21","data_iatf":"2026-01-01","qtd_inseminadas":70}')$$, (SELECT j->>'id' FROM lr))) LIKE 'QTD_INVALIDA%', '');
SELECT pg_temp.ok('DG que não fecha recusado', pg_temp.codigo(format($$SELECT public.pec_rodada_salvar('{"lote_reprodutivo_id":"%s","rodada":2,"data_d0":"2025-12-21","data_iatf":"2026-01-01","qtd_inseminadas":58,"data_dg":"2026-02-05","qtd_prenhes":30,"qtd_vazias":20}')$$, (SELECT j->>'id' FROM lr))) LIKE 'DG_NAO_FECHA%', '');
SELECT pg_temp.ok('datas fora de ordem recusadas', pg_temp.codigo(format($$SELECT public.pec_rodada_salvar('{"lote_reprodutivo_id":"%s","rodada":2,"data_d0":"2026-01-05","data_iatf":"2026-01-01"}')$$, (SELECT j->>'id' FROM lr))) LIKE 'DATAS_INVALIDAS%', '');
SELECT pg_temp.ok('2ª rodada válida', (public.pec_rodada_salvar(jsonb_build_object('lote_reprodutivo_id', (SELECT j->>'id' FROM lr), 'rodada', 2,
   'data_d0', '2025-12-21', 'data_iatf', '2026-01-01', 'qtd_inseminadas', 58, 'data_dg', '2026-02-05', 'qtd_prenhes', 30, 'qtd_vazias', 28))->>'ok')::boolean, '');
SELECT pg_temp.ok('DG final', (public.pec_dg_final_salvar(jsonb_build_object('lote_reprodutivo_id', (SELECT j->>'id' FROM lr), 'data_dg', '2026-04-10', 'qtd_prenhes', 120, 'qtd_vazias', 28, 'qtd_descarte', 10))->>'ok')::boolean, '');
CREATE TEMP TABLE rep AS SELECT public.pec_reproducao((SELECT (j->>'id')::uuid FROM est)) AS j;
SELECT pg_temp.ok('taxa de prenhez 120/150 = 80%', (SELECT (j->'lotes'->0->>'taxa_prenhez')::numeric FROM rep) = 0.8, (SELECT j->'lotes'->0->>'taxa_prenhez' FROM rep));
SELECT pg_temp.ok('concepção 1ª IATF 80/140', round((SELECT (j->'lotes'->0->>'concepcao_1a_iatf')::numeric FROM rep), 3) = round(80/140.0, 3), (SELECT j->'lotes'->0->>'concepcao_1a_iatf' FROM rep));
SELECT pg_temp.ok('safra de parição = 2026/2027', (SELECT j->'estacao'->>'safra_paricao' FROM rep) = '2026/2027', (SELECT j->'estacao'->>'safra_paricao' FROM rep));
SELECT pg_temp.ok('parição Água Funda: nascimentos da safra 26/27',
   (SELECT (x->>'nascimentos')::int FROM rep, jsonb_array_elements(j->'paricao') x WHERE x->>'retiro_id' = pg_temp.id('retiro','Água Funda')::text)
   = (SELECT sum(qtd_liquida) FROM pec.v_movimento WHERE operacao_codigo='NASCIMENTO' AND retiro_id = pg_temp.id('retiro','Água Funda') AND data >= '2026-07-01'),
   (SELECT x->>'nascimentos' FROM rep, jsonb_array_elements(j->'paricao') x WHERE x->>'retiro_id' = pg_temp.id('retiro','Água Funda')::text));
SELECT pg_temp.ok('natalidade da safra usa expostas da estação anterior (150)',
   (SELECT denominador FROM pec.fn_indicadores((SELECT id FROM pec.fazenda), '2026-07-01', '2027-06-30') WHERE codigo = 'TX_NATALIDADE') = 150, '');
SELECT pg_temp.ok('excluir lote com IATF é recusado', pg_temp.codigo(format($$SELECT public.pec_reproducao_excluir('lote', %L)$$, (SELECT j->>'id' FROM lr))) LIKE 'TEM_DADOS%', '');
SELECT pg_temp.como('vaq@t.com', 'a0000000-0000-4000-8000-000000000002');
SELECT pg_temp.ok('vaqueiro não lança reprodução', pg_temp.codigo($$SELECT public.pec_estacao_salvar('{"nome":"Y","inicio":"2026-11-01","fim":"2027-02-28"}')$$) LIKE 'SEM_PERMISSAO%', '');
SELECT pg_temp.ok('vaqueiro não vê lote da Água Funda', jsonb_array_length(public.pec_reproducao((SELECT (j->>'id')::uuid FROM est))->'lotes') = 0, '');
SELECT pg_temp.como('adm@t.com', 'a0000000-0000-4000-8000-000000000001');

-- desmama com peso por sexo → desmama_registro, GMD e P205
SELECT public.pec_lancar(jsonb_build_object('operacao','DESMAMA','data','2026-10-05','nascimento_medio','2026-02-10','peso_total_kg', 3700,
  'pernas', jsonb_build_array(
    jsonb_build_object('sentido',-1,'retiro_id',pg_temp.id('retiro','Água Funda'),'pasto_id',pg_temp.id('pasto','AgF-12'),'categoria_id',pg_temp.id('categoria','Bez. Macho'),'quantidade',10,'peso_kg',2100),
    jsonb_build_object('sentido',-1,'retiro_id',pg_temp.id('retiro','Água Funda'),'pasto_id',pg_temp.id('pasto','AgF-12'),'categoria_id',pg_temp.id('categoria','Bez. Fêmea'),'quantidade',8,'peso_kg',1600),
    jsonb_build_object('sentido',1,'retiro_id',pg_temp.id('retiro','Água Funda'),'pasto_id',pg_temp.id('pasto','AgF-12'),'categoria_id',pg_temp.id('categoria','Desmama Macho'),'quantidade',10),
    jsonb_build_object('sentido',1,'retiro_id',pg_temp.id('retiro','Água Funda'),'pasto_id',pg_temp.id('pasto','AgF-12'),'categoria_id',pg_temp.id('categoria','Desmama Fêmea'),'quantidade',8))));
SELECT pg_temp.ok('desmama gera registro por sexo', (SELECT count(*) FROM pec.v_desmama) = 2, (SELECT count(*) FROM pec.v_desmama));
SELECT pg_temp.ok('P205 do macho calculado', (SELECT p205_kg FROM pec.v_desmama WHERE sexo='M') BETWEEN 150 AND 260, (SELECT p205_kg FROM pec.v_desmama WHERE sexo='M'));
SELECT pg_temp.ok('kg desmamado/matriz = 3700/150', (SELECT valor FROM pec.fn_indicadores((SELECT id FROM pec.fazenda), '2026-07-01', '2027-06-30') WHERE codigo='KG_DESM_MATRIZ') = round(3700/150.0, 1), '');

-- 3. FECHAMENTO -----------------------------------------------------------
CREATE TEMP TABLE fch AS SELECT public.pec_fechamento('2026-09-01') AS j;
SELECT pg_temp.ok('setembro bloqueado por meses anteriores abertos', (SELECT j->'bloqueios' @> '[{"codigo":"MESES_ANTERIORES"}]' FROM fch), (SELECT j->'bloqueios' FROM fch));
SELECT pg_temp.ok('aviso de Mapão não conferido em outros retiros', (SELECT j->'avisos' @> '[{"codigo":"SEM_MAPAO"}]' FROM fch), '');
SELECT pg_temp.ok('fechamento confere linha a linha', (SELECT bool_and((x->>'confere')::boolean) FROM fch, jsonb_array_elements(j->'linhas') x), '');
SELECT pg_temp.ok('saldo final = estoque em 30/09',
  (SELECT sum((x->>'saldo_final')::int) FROM fch, jsonb_array_elements(j->'linhas') x) = (SELECT sum(cabecas) FROM pec.fn_estoque((SELECT id FROM pec.fazenda), '2026-09-30')), '');
SELECT pg_temp.ok('fechar fora de ordem é recusado', pg_temp.codigo($$SELECT public.pec_fechar_mes('2026-09-01')$$) LIKE 'FECHAMENTO_FORA_ORDEM%', '');
SELECT pg_temp.ok('fechar julho', (public.pec_fechar_mes('2026-07-01')->>'fechado')::boolean, '');
SELECT pg_temp.ok('fechar agosto', (public.pec_fechar_mes('2026-08-01')->>'fechado')::boolean, '');
SELECT pg_temp.ok('fechar setembro', (public.pec_fechar_mes('2026-09-01')->>'fechado')::boolean, '');
SELECT pg_temp.ok('mês em andamento não fecha', pg_temp.codigo($$SELECT public.pec_fechar_mes(current_date)$$) LIKE 'MES_EM_ANDAMENTO%', '');
SELECT pg_temp.ok('lançar em setembro fechado é recusado', pg_temp.codigo(format($$SELECT public.pec_lancar('{"operacao":"MORTE","data":"2026-09-25","causa_morte_id":"%s","pernas":[{"sentido":-1,"retiro_id":"%s","pasto_id":"%s","categoria_id":"%s","quantidade":1}]}')$$,
   (SELECT id FROM pec.causa_morte WHERE nome='Raio'), pg_temp.id('retiro','Água Funda'), pg_temp.id('pasto','AgF-10'), pg_temp.id('categoria','Vaca'))) LIKE 'PERIODO_FECHADO%', '');
SELECT pg_temp.ok('reabrir agosto com setembro fechado é recusado', pg_temp.codigo($$SELECT public.pec_reabrir_mes('2026-08-01', 'teste de ordem')$$) LIKE 'MESES_SEGUINTES%', '');
SELECT pg_temp.ok('reabrir sem motivo é recusado', pg_temp.codigo($$SELECT public.pec_reabrir_mes('2026-09-01', '')$$) LIKE 'SEM_MOTIVO%', '');
SELECT pg_temp.ok('fotografia guardada no fechamento', (SELECT (j->>'fotografia_total')::int = (j->>'total_atual')::int FROM (SELECT public.pec_fechamento('2026-09-01') j) t), '');
SELECT pg_temp.ok('reabrir setembro', (public.pec_reabrir_mes('2026-09-01', 'Faltou lançar uma venda')->>'ok')::boolean, '');
SELECT pg_temp.ok('status volta a ABERTO com motivo', (SELECT j->>'status' = 'ABERTO' AND j->>'motivo_reabertura' = 'Faltou lançar uma venda' FROM (SELECT public.pec_fechamento('2026-09-01') j) t), '');
CREATE TEMP TABLE evo AS SELECT public.pec_evolucao() AS j;
SELECT pg_temp.ok('evolução: jul a out', jsonb_array_length((SELECT j->'meses' FROM evo)) = 4, jsonb_array_length((SELECT j->'meses' FROM evo)));
SELECT pg_temp.ok('evolução: estoque de outubro = rebanho de hoje',
   (SELECT (j->'meses'->3->>'estoque_fim')::int FROM evo) = (SELECT sum(cabecas) FROM pec.fn_estoque((SELECT id FROM pec.fazenda), current_date)), '');
SELECT pg_temp.ok('evolução: variação fecha com movimentos',
   (SELECT bool_and((m->>'estoque_fim')::int - (m->>'estoque_ini')::int =
       (m->>'saldo_inicial')::int + (m->>'nascimentos')::int + (m->>'compras')::int + (m->>'entradas_transf')::int
     - (m->>'mortes')::int - (m->>'vendas')::int - (m->>'saidas_transf')::int + (m->>'ajustes')::int) FROM evo, jsonb_array_elements(j->'meses') m), '');
SELECT pg_temp.como('enc@t.com', 'a0000000-0000-4000-8000-000000000003');
SELECT pg_temp.ok('encarregado não fecha mês', pg_temp.codigo($$SELECT public.pec_fechar_mes('2026-09-01')$$) LIKE 'SEM_PERMISSAO%', '');
SELECT pg_temp.ok('encarregado vê fechamento só do Pontal',
   (SELECT bool_and(x->>'retiro_id' = pg_temp.id('retiro','Pontal')::text) FROM jsonb_array_elements(public.pec_fechamento('2026-09-01')->'linhas') x), '');

SELECT n, CASE WHEN ok THEN 'OK   ' ELSE 'FALHA' END AS res, teste, left(obtido, 140) AS obtido FROM r ORDER BY n;
SELECT count(*) FILTER (WHERE ok) AS passaram, count(*) FILTER (WHERE NOT ok) AS falharam FROM r;
ROLLBACK;
