-- =====================================================================
-- 03_views.sql — Camada de leitura: estoque, Mapão, fechamento,
-- lotação, alertas e indicadores. Tudo DERIVADO do livro; nada digitado.
-- =====================================================================
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- Livro enriquecido (base de todos os relatórios e do BI)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW pec.v_movimento WITH (security_invoker = on) AS
SELECT m.id, d.id AS documento_id, d.numero, d.data, date_trunc('month', d.data)::date AS competencia,
       d.fazenda_id, d.safra_id, s.nome AS safra,
       d.operacao_codigo, o.nome AS operacao, o.afeta_rebanho, o.grupo_mapao, o.muda_local, o.muda_categoria,
       m.sentido, m.estorno, m.quantidade, m.qtd_liquida, m.efeito,
       m.efeito * pec.fator_ua(m.categoria_id, d.data) AS ua_efeito,
       m.retiro_id, r.nome AS retiro, m.pasto_id, p.codigo AS pasto, m.lote_id, l.codigo AS lote,
       m.categoria_id, c.nome AS categoria, c.sexo, c.fase, c.grupo_dashboard,
       m.raca_id, ra.nome AS raca, m.animal_id, m.peso_kg,
       d.causa_morte_id, cm.nome AS causa_morte, d.canal_venda_id, cv.nome AS canal_venda, d.parceiro_id,
       d.peso_total_kg, d.valor_total, d.status AS status_documento, d.origem, d.observacao, d.criado_por, d.criado_em
  FROM pec.movimento m
  JOIN pec.documento d      ON d.id = m.documento_id
  JOIN pec.tipo_operacao o  ON o.codigo = d.operacao_codigo
  JOIN pec.retiro r         ON r.id = m.retiro_id
  JOIN pec.categoria c      ON c.id = m.categoria_id
  LEFT JOIN pec.pasto p     ON p.id = m.pasto_id
  LEFT JOIN pec.lote l      ON l.id = m.lote_id
  LEFT JOIN pec.raca ra     ON ra.id = m.raca_id
  LEFT JOIN pec.safra s     ON s.id = d.safra_id
  LEFT JOIN pec.causa_morte cm ON cm.id = d.causa_morte_id
  LEFT JOIN pec.canal_venda cv ON cv.id = d.canal_venda_id;

-- ---------------------------------------------------------------------
-- ESTOQUE EM QUALQUER DATA  (SALDO = Σ entradas − Σ saídas até a data)
-- granularidade máxima; telas agregam por fazenda/retiro/pasto/lote/categoria/sexo/raça
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.fn_estoque(p_fazenda uuid, p_data date)
RETURNS TABLE (retiro_id uuid, pasto_id uuid, lote_id uuid, categoria_id uuid, raca_id uuid, cabecas bigint, ua numeric)
LANGUAGE sql STABLE AS $$
  SELECT m.retiro_id, m.pasto_id, m.lote_id, m.categoria_id, m.raca_id,
         sum(m.efeito) AS cabecas,
         sum(m.efeito) * pec.fator_ua(m.categoria_id, p_data) AS ua
    FROM pec.movimento m
   WHERE m.fazenda_id = p_fazenda AND m.data <= p_data
   GROUP BY m.retiro_id, m.pasto_id, m.lote_id, m.categoria_id, m.raca_id
  HAVING sum(m.efeito) <> 0
$$;

CREATE OR REPLACE VIEW pec.v_estoque_atual WITH (security_invoker = on) AS
SELECT f.id AS fazenda_id, f.nome AS fazenda, e.retiro_id, r.nome AS retiro, e.pasto_id, p.codigo AS pasto,
       e.lote_id, l.codigo AS lote, e.categoria_id, c.nome AS categoria, c.sexo, c.ordem AS ordem_categoria,
       e.raca_id, ra.nome AS raca, e.cabecas, e.ua
  FROM pec.fazenda f
  CROSS JOIN LATERAL pec.fn_estoque(f.id, current_date) e
  JOIN pec.retiro r     ON r.id = e.retiro_id
  JOIN pec.categoria c  ON c.id = e.categoria_id
  LEFT JOIN pec.pasto p ON p.id = e.pasto_id
  LEFT JOIN pec.lote l  ON l.id = e.lote_id
  LEFT JOIN pec.raca ra ON ra.id = e.raca_id;

-- ---------------------------------------------------------------------
-- MAPÃO PECUÁRIO: pasto × categoria no último dia do mês (+ linha SEM PASTO)
-- formato longo; a tela/PDF pivota nas colunas de categoria (ordem do cadastro)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.fn_mapao(p_fazenda uuid, p_retiro uuid, p_competencia date)
RETURNS TABLE (pasto_id uuid, pasto text, area_ha numeric, categoria_id uuid, categoria text, coluna_mapao text,
               ordem int, cabecas bigint, ua numeric)
LANGUAGE sql STABLE AS $$
  WITH fim AS (SELECT (date_trunc('month', p_competencia) + interval '1 month - 1 day')::date AS d),
  est AS (SELECT e.pasto_id, e.categoria_id, sum(e.cabecas) cab, sum(e.ua) ua
            FROM fim, pec.fn_estoque(p_fazenda, fim.d) e WHERE e.retiro_id = p_retiro
           GROUP BY e.pasto_id, e.categoria_id)
  SELECT p.id, COALESCE(p.codigo, 'SEM PASTO'), p.area_ha, c.id, c.nome, c.coluna_mapao, c.ordem,
         COALESCE(est.cab, 0), COALESCE(est.ua, 0)
    FROM (SELECT id, codigo, area_ha FROM pec.pasto WHERE retiro_id = p_retiro AND status = 'ATIVO'
          UNION ALL SELECT NULL, NULL, NULL) p
   CROSS JOIN pec.categoria c
    LEFT JOIN est ON est.pasto_id IS NOT DISTINCT FROM p.id AND est.categoria_id = c.id
   WHERE c.status = 'ATIVO'
     AND (p.id IS NOT NULL OR EXISTS (SELECT 1 FROM est WHERE est.pasto_id IS NULL))
$$;

-- ---------------------------------------------------------------------
-- FECHAMENTO DO MÊS: saldo anterior + entradas − saídas = saldo final
-- por retiro × categoria, com o "contado pelo estoque" para conferência
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.fn_fechamento(p_fazenda uuid, p_competencia date)
RETURNS TABLE (retiro_id uuid, retiro text, categoria_id uuid, categoria text,
               saldo_anterior bigint, nascimentos bigint, compras bigint, entradas_internas bigint, outras_entradas bigint,
               total_entradas bigint, mortes bigint, vendas bigint, saidas_internas bigint, outras_saidas bigint,
               total_saidas bigint, saldo_final bigint, saldo_estoque bigint, confere boolean)
LANGUAGE sql STABLE AS $$
  WITH lim AS (SELECT date_trunc('month', p_competencia)::date ini,
                      (date_trunc('month', p_competencia) + interval '1 month - 1 day')::date fim),
  mv AS (SELECT m.retiro_id, m.categoria_id, m.data, m.efeito, m.sentido, m.qtd_liquida, d.operacao_codigo, o.afeta_rebanho
           FROM pec.movimento m JOIN pec.documento d ON d.id = m.documento_id
           JOIN pec.tipo_operacao o ON o.codigo = d.operacao_codigo, lim
          WHERE m.fazenda_id = p_fazenda AND m.data <= lim.fim),
  ag AS (
    SELECT mv.retiro_id, mv.categoria_id,
      sum(efeito) FILTER (WHERE data < lim.ini)                                                         AS sa,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = 1 AND operacao_codigo = 'NASCIMENTO') AS nasc,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = 1 AND operacao_codigo = 'COMPRA')     AS comp,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = 1 AND NOT afeta_rebanho)              AS ent_int,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = 1 AND afeta_rebanho
                                 AND operacao_codigo NOT IN ('NASCIMENTO','COMPRA'))                     AS ent_out,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = -1 AND operacao_codigo = 'MORTE')     AS mor,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = -1 AND operacao_codigo = 'VENDA')     AS ven,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = -1 AND NOT afeta_rebanho)             AS sai_int,
      sum(qtd_liquida) FILTER (WHERE data >= lim.ini AND sentido = -1 AND afeta_rebanho
                                 AND operacao_codigo NOT IN ('MORTE','VENDA'))                           AS sai_out,
      sum(efeito)                                                                                       AS saldo
    FROM mv, lim GROUP BY mv.retiro_id, mv.categoria_id)
  SELECT ag.retiro_id, r.nome, ag.categoria_id, c.nome,
         COALESCE(sa,0), COALESCE(nasc,0), COALESCE(comp,0), COALESCE(ent_int,0), COALESCE(ent_out,0),
         COALESCE(nasc,0)+COALESCE(comp,0)+COALESCE(ent_int,0)+COALESCE(ent_out,0),
         COALESCE(mor,0), COALESCE(ven,0), COALESCE(sai_int,0), COALESCE(sai_out,0),
         COALESCE(mor,0)+COALESCE(ven,0)+COALESCE(sai_int,0)+COALESCE(sai_out,0),
         COALESCE(sa,0) + (COALESCE(nasc,0)+COALESCE(comp,0)+COALESCE(ent_int,0)+COALESCE(ent_out,0))
                        - (COALESCE(mor,0)+COALESCE(ven,0)+COALESCE(sai_int,0)+COALESCE(sai_out,0)),
         COALESCE(ag.saldo,0),
         COALESCE(sa,0) + (COALESCE(nasc,0)+COALESCE(comp,0)+COALESCE(ent_int,0)+COALESCE(ent_out,0))
                        - (COALESCE(mor,0)+COALESCE(ven,0)+COALESCE(sai_int,0)+COALESCE(sai_out,0)) = COALESCE(ag.saldo,0)
    FROM ag JOIN pec.retiro r ON r.id = ag.retiro_id JOIN pec.categoria c ON c.id = ag.categoria_id
   WHERE COALESCE(sa,0) <> 0 OR COALESCE(ag.saldo,0) <> 0
      OR COALESCE(nasc,0)+COALESCE(comp,0)+COALESCE(ent_int,0)+COALESCE(ent_out,0)
        +COALESCE(mor,0)+COALESCE(ven,0)+COALESCE(sai_int,0)+COALESCE(sai_out,0) <> 0
$$;

-- ---------------------------------------------------------------------
-- LOTAÇÃO por pasto (hoje) e por retiro
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW pec.v_lotacao_pasto WITH (security_invoker = on) AS
WITH e AS (SELECT fazenda_id, pasto_id, sum(cabecas) cab, sum(ua) ua FROM pec.v_estoque_atual GROUP BY 1,2)
SELECT p.fazenda_id, p.retiro_id, r.nome AS retiro, p.id AS pasto_id, p.codigo AS pasto, p.area_ha,
       COALESCE(e.cab,0) AS cabecas, COALESCE(e.ua,0) AS ua,
       CASE WHEN p.area_ha > 0 THEN round(COALESCE(e.ua,0) / p.area_ha, 3) END AS ua_ha,
       COALESCE(p.lotacao_min_ua_ha, (pec.param(p.fazenda_id,'LOTACAO_MIN') #>> '{}')::numeric) AS lot_min,
       COALESCE(p.lotacao_max_ua_ha, (pec.param(p.fazenda_id,'LOTACAO_MAX') #>> '{}')::numeric) AS lot_max,
       CASE WHEN p.area_ha > 0 THEN round(p.area_ha * COALESCE(p.lotacao_max_ua_ha, (pec.param(p.fazenda_id,'LOTACAO_MAX') #>> '{}')::numeric), 1) END AS capacidade_ua,
       CASE
         WHEN COALESCE(e.cab,0) < 0 THEN 'ESTOQUE NEGATIVO'
         WHEN COALESCE(e.cab,0) = 0 THEN 'VAZIO / DESCANSO'
         WHEN p.area_ha = 0         THEN 'SEM ÁREA'
         WHEN e.ua / p.area_ha > COALESCE(p.lotacao_max_ua_ha, (pec.param(p.fazenda_id,'LOTACAO_MAX') #>> '{}')::numeric) THEN 'ACIMA DA META'
         WHEN e.ua / p.area_ha < COALESCE(p.lotacao_min_ua_ha, (pec.param(p.fazenda_id,'LOTACAO_MIN') #>> '{}')::numeric) THEN 'ABAIXO DA META'
         ELSE 'ADEQUADO' END AS status
  FROM pec.pasto p
  JOIN pec.retiro r ON r.id = p.retiro_id
  LEFT JOIN e ON e.pasto_id = p.id
 WHERE p.status = 'ATIVO';

CREATE OR REPLACE VIEW pec.v_lotacao_retiro WITH (security_invoker = on) AS
WITH area AS (SELECT r.id, r.fazenda_id, r.nome,
                     COALESCE(NULLIF((SELECT sum(area_ha) FROM pec.pasto p WHERE p.retiro_id = r.id AND p.status='ATIVO'),0),
                              r.area_informada_ha, 0) AS area_ha
                FROM pec.retiro r),
     e AS (SELECT retiro_id, sum(cabecas) cab, sum(ua) ua FROM pec.v_estoque_atual GROUP BY 1)
SELECT a.fazenda_id, a.id AS retiro_id, a.nome AS retiro, a.area_ha, COALESCE(e.cab,0) cabecas, COALESCE(e.ua,0) ua,
       CASE WHEN a.area_ha > 0 THEN round(COALESCE(e.ua,0)/a.area_ha, 3) END AS ua_ha,
       CASE WHEN a.area_ha = 0 THEN 'SEM ÁREA' WHEN COALESCE(e.ua,0) = 0 THEN 'VAZIO'
            WHEN e.ua/a.area_ha > (pec.param(a.fazenda_id,'LOTACAO_MAX') #>> '{}')::numeric THEN 'ACIMA DA META'
            WHEN e.ua/a.area_ha < (pec.param(a.fazenda_id,'LOTACAO_MIN') #>> '{}')::numeric THEN 'ABAIXO DA META'
            ELSE 'ADEQUADO' END AS status
  FROM area a LEFT JOIN e ON e.retiro_id = a.id;

-- ---------------------------------------------------------------------
-- REPRODUÇÃO por lote reprodutivo (estação de monta / IATF / DG)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW pec.v_reproducao_lote WITH (security_invoker = on) AS
SELECT lr.id AS lote_reprodutivo_id, em.fazenda_id, em.safra_id, em.nome AS estacao, lr.retiro_id, r.nome AS retiro,
       lr.lote_id, l.codigo AS lote, lr.categoria_id, c.nome AS categoria, lr.qtd_expostas, lr.ecc_medio, lr.carimbo_bezerro,
       (SELECT count(*) FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = lr.id) AS n_rodadas,
       (SELECT qtd_prenhes::numeric / NULLIF(qtd_inseminadas,0) FROM pec.iatf_rodada ir
         WHERE ir.lote_reprodutivo_id = lr.id AND ir.rodada = 1) AS concepcao_1a_iatf,
       COALESCE(df.qtd_prenhes, (SELECT sum(qtd_prenhes) FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = lr.id)) AS prenhes,
       COALESCE(df.qtd_vazias, lr.qtd_expostas - (SELECT sum(qtd_prenhes) FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = lr.id)) AS vazias,
       round(COALESCE(df.qtd_prenhes, (SELECT sum(qtd_prenhes) FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = lr.id))::numeric
             / lr.qtd_expostas, 4) AS taxa_prenhez,
       (df.lote_reprodutivo_id IS NOT NULL) AS dg_final_lancado
  FROM pec.lote_reprodutivo lr
  JOIN pec.estacao_monta em ON em.id = lr.estacao_id
  JOIN pec.retiro r ON r.id = lr.retiro_id
  JOIN pec.categoria c ON c.id = lr.categoria_id
  LEFT JOIN pec.lote l ON l.id = lr.lote_id
  LEFT JOIN pec.diagnostico_final df ON df.lote_reprodutivo_id = lr.id;

-- ---------------------------------------------------------------------
-- DESMAMA com peso ajustado (P205) e GMD
--   GMD = (peso − peso ao nascer) ÷ idade(dias)
--   P205 = PN + GMD × 205      (PN padrão por sexo em parâmetro PN_PADRAO_M / PN_PADRAO_F)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW pec.v_desmama WITH (security_invoker = on) AS
SELECT dr.id, d.fazenda_id, d.safra_id, dr.documento_id, dr.data_desmama, dr.retiro_id, dr.lote_id, dr.sexo, dr.quantidade,
       dr.peso_total_kg, round(dr.peso_total_kg / dr.quantidade, 1) AS peso_medio_kg,
       (dr.data_desmama - dr.data_nascimento_media) AS idade_dias,
       COALESCE(dr.peso_nascimento_kg,
                (pec.param(d.fazenda_id, CASE dr.sexo WHEN 'M' THEN 'PN_PADRAO_M' ELSE 'PN_PADRAO_F' END) #>> '{}')::numeric) AS pn_kg,
       round((dr.peso_total_kg / dr.quantidade - COALESCE(dr.peso_nascimento_kg,
                (pec.param(d.fazenda_id, CASE dr.sexo WHEN 'M' THEN 'PN_PADRAO_M' ELSE 'PN_PADRAO_F' END) #>> '{}')::numeric))
             / NULLIF(dr.data_desmama - dr.data_nascimento_media, 0), 3) AS gmd_kg_dia,
       round(COALESCE(dr.peso_nascimento_kg, (pec.param(d.fazenda_id, CASE dr.sexo WHEN 'M' THEN 'PN_PADRAO_M' ELSE 'PN_PADRAO_F' END) #>> '{}')::numeric)
             + 205 * (dr.peso_total_kg / dr.quantidade - COALESCE(dr.peso_nascimento_kg,
                (pec.param(d.fazenda_id, CASE dr.sexo WHEN 'M' THEN 'PN_PADRAO_M' ELSE 'PN_PADRAO_F' END) #>> '{}')::numeric))
             / NULLIF(dr.data_desmama - dr.data_nascimento_media, 0), 1) AS p205_kg
  FROM pec.desmama_registro dr JOIN pec.documento d ON d.id = dr.documento_id
 WHERE d.status = 'ATIVO';

-- ---------------------------------------------------------------------
-- CENTRAL DE ALERTAS (calculada; nunca digitada)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW pec.v_alertas WITH (security_invoker = on) AS
-- estoque negativo hoje (pasto × categoria)
SELECT e.fazenda_id, 'CRITICO'::pec.nivel_alerta_t AS nivel, 'ESTOQUE_NEGATIVO' AS regra,
       format('%s com %s cab. em %s / %s', e.categoria, e.cabecas, e.retiro, COALESCE(e.pasto,'sem pasto')) AS mensagem,
       e.retiro_id, e.pasto_id, NULL::date AS data, NULL::uuid AS referencia_id
  FROM (SELECT fazenda_id, retiro_id, retiro, pasto_id, pasto, categoria, sum(cabecas) cabecas
          FROM pec.v_estoque_atual GROUP BY 1,2,3,4,5,6) e
 WHERE e.cabecas < 0
UNION ALL
-- animais sem pasto (lote sem localização)
SELECT fazenda_id, 'ATENCAO', 'SEM_PASTO', format('%s cab. de %s em %s sem pasto informado', sum(cabecas), categoria, retiro),
       retiro_id, NULL, NULL, NULL
  FROM pec.v_estoque_atual WHERE pasto_id IS NULL GROUP BY fazenda_id, retiro_id, retiro, categoria HAVING sum(cabecas) <> 0
UNION ALL
-- pastos superlotados / com gado e sem área
SELECT fazenda_id, CASE status WHEN 'ACIMA DA META' THEN 'ATENCAO' ELSE 'PENDENTE' END::pec.nivel_alerta_t,
       CASE status WHEN 'ACIMA DA META' THEN 'PASTO_SUPERLOTADO' ELSE 'PASTO_SEM_AREA' END,
       format('%s (%s): %s UA/ha — %s', pasto, retiro, COALESCE(ua_ha::text,'—'), status), retiro_id, pasto_id, NULL, NULL
  FROM pec.v_lotacao_pasto WHERE status IN ('ACIMA DA META','SEM ÁREA') AND cabecas > 0
UNION ALL
-- venda sem valor ou sem peso
SELECT d.fazenda_id, 'PENDENTE', 'VENDA_INCOMPLETA',
       format('Venda nº %s de %s sem %s', d.numero, to_char(d.data,'DD/MM/YY'),
              concat_ws(' e ', CASE WHEN d.valor_total IS NULL THEN 'valor' END, CASE WHEN d.peso_total_kg IS NULL THEN 'peso' END)),
       NULL, NULL, d.data, d.id
  FROM pec.documento d WHERE d.operacao_codigo = 'VENDA' AND d.status = 'ATIVO' AND (d.valor_total IS NULL OR d.peso_total_kg IS NULL)
UNION ALL
-- morte sem causa (só possível em dados importados)
SELECT d.fazenda_id, 'PENDENTE', 'MORTE_SEM_CAUSA', format('Morte nº %s de %s sem causa', d.numero, to_char(d.data,'DD/MM/YY')),
       NULL, NULL, d.data, d.id
  FROM pec.documento d WHERE d.operacao_codigo = 'MORTE' AND d.status = 'ATIVO' AND d.causa_morte_id IS NULL
UNION ALL
-- DG pendente: IATF há mais de N dias (padrão 30) sem diagnóstico
SELECT em.fazenda_id, 'PENDENTE', 'DG_PENDENTE',
       format('%s / %s: %sª IATF em %s sem DG', r.nome, COALESCE(l.codigo,'—'), ir.rodada, to_char(ir.data_iatf,'DD/MM/YY')),
       lr.retiro_id, NULL, ir.data_iatf, ir.id
  FROM pec.iatf_rodada ir JOIN pec.lote_reprodutivo lr ON lr.id = ir.lote_reprodutivo_id
  JOIN pec.estacao_monta em ON em.id = lr.estacao_id JOIN pec.retiro r ON r.id = lr.retiro_id
  LEFT JOIN pec.lote l ON l.id = lr.lote_id
 WHERE ir.data_iatf IS NOT NULL AND ir.data_dg IS NULL
   AND ir.data_iatf + COALESCE((pec.param(em.fazenda_id,'DIAS_ATE_DG') #>> '{}')::int, 30) < current_date
UNION ALL
-- inventário com divergência não resolvida
SELECT i.fazenda_id, 'ATENCAO', 'INVENTARIO_DIVERGENTE',
       format('Mapão %s de %s: %s linhas divergentes', to_char(i.competencia,'MM/YYYY'), r.nome, count(*)),
       i.retiro_id, NULL, i.data_posicao, i.id
  FROM pec.inventario i JOIN pec.inventario_item ii ON ii.inventario_id = i.id JOIN pec.retiro r ON r.id = i.retiro_id
 WHERE ii.diferenca <> 0 AND ii.documento_ajuste_id IS NULL AND i.status IN ('CONTADO','EM_CONTAGEM')
 GROUP BY i.fazenda_id, i.competencia, r.nome, i.retiro_id, i.data_posicao, i.id
UNION ALL
-- pendências atrasadas
SELECT fazenda_id, CASE prioridade WHEN 'ALTA' THEN 'CRITICO' ELSE 'ATENCAO' END::pec.nivel_alerta_t, 'PENDENCIA_ATRASADA',
       format('Pendência nº %s atrasada: %s', numero, titulo), retiro_id, pasto_id, prazo, id
  FROM pec.pendencia WHERE status IN ('ABERTA','EM_ANDAMENTO') AND prazo < current_date;

-- ---------------------------------------------------------------------
-- INDICADORES DA SAFRA (biblioteca de KPIs com fórmula explícita)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.fn_indicadores(p_fazenda uuid, p_ini date, p_fim date)
RETURNS TABLE (codigo text, indicador text, valor numeric, numerador numeric, denominador numeric, unidade text, formula text)
LANGUAGE sql STABLE AS $$
  WITH mv AS (SELECT * FROM pec.v_movimento WHERE fazenda_id = p_fazenda AND data BETWEEN p_ini AND p_fim),
  est_ini AS (SELECT COALESCE(sum(cabecas),0) cab FROM pec.fn_estoque(p_fazenda, p_ini - 1)),
  est_fim AS (SELECT COALESCE(sum(cabecas),0) cab, COALESCE(sum(ua),0) ua FROM pec.fn_estoque(p_fazenda, p_fim)),
  area AS (SELECT COALESCE(sum(area_ha) FILTER (WHERE area_ha > 0),0) a FROM pec.v_lotacao_retiro WHERE fazenda_id = p_fazenda),
  k AS (SELECT
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='NASCIMENTO'),0)                       nasc,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='MORTE'),0)                            mortes,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='COMPRA'),0)                           compras,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='SALDO_INICIAL'),0)                    saldo_ini,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='VENDA'),0)                            vendas,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='DESMAMA' AND sentido=-1),0)           desm,
     COALESCE(sum(qtd_liquida) FILTER (WHERE operacao_codigo='MORTE' AND fase='BEZERRO'),0)          mortes_bez
     FROM mv),
  doc AS (SELECT COALESCE(sum(CASE WHEN status='ESTORNO' THEN -valor_total ELSE valor_total END) FILTER (WHERE operacao_codigo='VENDA'),0) receita,
                 COALESCE(sum(CASE WHEN status='ESTORNO' THEN -peso_total_kg ELSE peso_total_kg END) FILTER (WHERE operacao_codigo='VENDA'),0) kg_vend
            FROM pec.documento WHERE fazenda_id = p_fazenda AND data BETWEEN p_ini AND p_fim),
  rep AS (SELECT COALESCE(sum(v.qtd_expostas),0) expostas, COALESCE(sum(v.prenhes),0) prenhes
            FROM pec.v_reproducao_lote v JOIN pec.estacao_monta em ON em.nome = v.estacao AND em.fazenda_id = v.fazenda_id
           WHERE v.fazenda_id = p_fazenda AND em.inicio BETWEEN p_ini AND p_fim),
  dm AS (SELECT COALESCE(sum(peso_total_kg),0) kg FROM pec.v_desmama WHERE fazenda_id = p_fazenda AND data_desmama BETWEEN p_ini AND p_fim)
  SELECT v.* FROM est_ini, est_fim, area, k, doc, rep, dm, LATERAL (VALUES
    ('REBANHO_CAB','Rebanho (cab)', est_fim.cab::numeric, est_fim.cab::numeric, NULL::numeric, 'cab', 'Σ efeito dos movimentos até o fim do período'),
    ('REBANHO_UA','Rebanho (UA)', round(est_fim.ua,2), est_fim.ua, NULL, 'UA', 'Σ (cabeças × fator UA da categoria vigente na data)'),
    ('LOTACAO','Lotação (UA/ha)', round(est_fim.ua / NULLIF(area.a,0),3), est_fim.ua, area.a, 'UA/ha', 'UA ÷ área considerada (retiros com área)'),
    ('NASCIMENTOS','Nascimentos', k.nasc, k.nasc, NULL, 'cab', 'Σ quantidade das operações NASCIMENTO'),
    ('MORTES','Mortes', k.mortes, k.mortes, NULL, 'cab', 'Σ quantidade das operações MORTE'),
    ('MORTALIDADE','Mortalidade (%)', round(k.mortes / NULLIF(est_ini.cab + k.saldo_ini + k.nasc + k.compras,0),4), k.mortes,
       est_ini.cab + k.saldo_ini + k.nasc + k.compras, '%', 'mortes ÷ (estoque no início + saldo inicial lançado + nascimentos + compras do período)'),
    ('MORTALIDADE_PLANILHA','Mortalidade (fórmula da planilha v3)', round(k.mortes / NULLIF(est_fim.cab + k.mortes,0),4), k.mortes,
       est_fim.cab + k.mortes, '%', 'mortes ÷ (estoque final + mortes) — mantida só para comparação na transição'),
    ('MORT_PRE_DESMAMA','Mortalidade pré-desmama (%)', round(k.mortes_bez / NULLIF(k.nasc,0),4), k.mortes_bez, k.nasc, '%',
       'mortes de bezerros mamando ÷ nascimentos'),
    ('VENDAS_CAB','Vendas (cab)', k.vendas, k.vendas, NULL, 'cab', 'Σ quantidade VENDA'),
    ('RECEITA','Receita de vendas (R$)', doc.receita, doc.receita, NULL, 'R$', 'Σ valor_total das vendas'),
    ('KG_VENDIDOS','Peso vendido (kg)', doc.kg_vend, doc.kg_vend, NULL, 'kg', 'Σ peso_total das vendas'),
    ('PRECO_KG','Preço médio (R$/kg vivo)', round(doc.receita / NULLIF(doc.kg_vend,0),2), doc.receita, doc.kg_vend, 'R$/kg', 'receita ÷ kg vendidos'),
    ('PRECO_CAB','Preço médio (R$/cab)', round(doc.receita / NULLIF(k.vendas,0),2), doc.receita, k.vendas, 'R$/cab', 'receita ÷ cabeças vendidas'),
    ('TX_PRENHEZ','Taxa de prenhez', round(rep.prenhes / NULLIF(rep.expostas,0),4), rep.prenhes, rep.expostas, '%', 'prenhes no DG ÷ fêmeas expostas'),
    ('TX_NATALIDADE','Taxa de natalidade', round(k.nasc / NULLIF(rep.expostas,0),4), k.nasc, rep.expostas, '%', 'nascimentos ÷ fêmeas expostas'),
    ('DESMAMADOS','Bezerros desmamados', k.desm, k.desm, NULL, 'cab', 'Σ perna de saída das operações DESMAMA'),
    ('TX_DESMAME','Taxa de desmame', round(k.desm / NULLIF(rep.expostas,0),4), k.desm, rep.expostas, '%', 'desmamados ÷ fêmeas expostas'),
    ('KG_DESM_MATRIZ','kg desmamado por matriz exposta', round(dm.kg / NULLIF(rep.expostas,0),1), dm.kg, rep.expostas, 'kg', 'peso total desmamado ÷ fêmeas expostas')
  ) v(codigo, indicador, valor, numerador, denominador, unidade, formula)
$$;
