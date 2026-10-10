-- =====================================================================
-- 08_entrega3.sql — Conferência do Mapão, Reprodução e Fechamento do mês
--
-- Como na 06: o app só chama funções public.pec_*; cada uma confere login,
-- perfil e retiro. As regras de estoque continuam no livro (02_regras.sql):
-- ajuste de inventário vira lançamento AJUSTE_INVENTARIO, rastreável à contagem.
-- =====================================================================
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- 0. Ajustes de estrutura
-- ---------------------------------------------------------------------
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS observacao        text;
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS contado_por_nome  text;      -- vaqueiro que contou (texto livre)
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS emitido_por       uuid REFERENCES pec.usuario;
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS emitido_em        timestamptz DEFAULT now();
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS concluido_em      timestamptz;
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS ajustado_por      uuid REFERENCES pec.usuario;
ALTER TABLE pec.inventario ADD COLUMN IF NOT EXISTS ajustado_em       timestamptz;
ALTER TABLE pec.inventario_item ADD COLUMN IF NOT EXISTS contado_em   timestamptz;

-- protocolo é cadastro simples; estação de monta e protocolo passam a ser auditados
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['estacao_monta','protocolo_iatf','periodo'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = t || '_audit') THEN
      EXECUTE format('CREATE TRIGGER %I_audit AFTER INSERT OR UPDATE OR DELETE ON pec.%I FOR EACH ROW EXECUTE FUNCTION pec.trg_auditoria()', t, t);
    END IF;
  END LOOP;
END $$;

-- Safra que contém a data; cria a safra julho–junho se ainda não existir
CREATE OR REPLACE FUNCTION pec.safra_garantir(p_fazenda uuid, p_data date) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid; a int;
BEGIN
  v := pec.safra_da_data(p_fazenda, p_data);
  IF v IS NOT NULL THEN RETURN v; END IF;
  a := CASE WHEN extract(month FROM p_data) >= 7 THEN extract(year FROM p_data)::int ELSE extract(year FROM p_data)::int - 1 END;
  INSERT INTO pec.safra (fazenda_id, nome, inicio, fim, status)
  VALUES (p_fazenda, a || '/' || (a + 1), make_date(a, 7, 1), make_date(a + 1, 6, 30),
          CASE WHEN make_date(a + 1, 6, 30) < current_date THEN 'ENCERRADA' ELSE 'ABERTA' END)
  RETURNING id INTO v;
  RETURN v;
END $$;

-- =====================================================================
-- 1. CONFERÊNCIA DO MAPÃO (inventário de campo)
--    emitir → contar (no celular, até sem internet) → concluir → aprovar ajustes
-- =====================================================================

-- Recalcula o "sistema" na data de posição. Lançamentos esquecidos que forem
-- feitos depois da emissão (ex.: uma morte não lançada) passam a contar, e a
-- divergência some sozinha — é para isso que serve procurar o lançamento faltante.
CREATE OR REPLACE FUNCTION pec.inv_recalcular(p_inv uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE inv pec.inventario%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_inv;
  WITH s AS (SELECT e.pasto_id, e.categoria_id, sum(e.cabecas)::int cab
               FROM pec.fn_estoque(inv.fazenda_id, inv.data_posicao) e
              WHERE e.retiro_id = inv.retiro_id GROUP BY 1, 2)
  INSERT INTO pec.inventario_item (inventario_id, pasto_id, categoria_id, qtd_sistema)
  SELECT p_inv, s.pasto_id, s.categoria_id, s.cab FROM s WHERE s.cab <> 0
  ON CONFLICT (inventario_id, pasto_id, categoria_id) DO NOTHING;

  UPDATE pec.inventario_item ii
     SET qtd_sistema = COALESCE((SELECT sum(e.cabecas)::int FROM pec.fn_estoque(inv.fazenda_id, inv.data_posicao) e
                                  WHERE e.retiro_id = inv.retiro_id AND e.pasto_id IS NOT DISTINCT FROM ii.pasto_id
                                    AND e.categoria_id = ii.categoria_id), 0)
   WHERE ii.inventario_id = p_inv AND ii.documento_ajuste_id IS NULL;
END $$;

CREATE OR REPLACE FUNCTION pec.inv_json(p_inv uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id', i.id, 'retiro_id', i.retiro_id, 'competencia', i.competencia, 'data_posicao', i.data_posicao,
    'data_contagem', i.data_contagem, 'contado_por_nome', i.contado_por_nome, 'observacao', i.observacao,
    'status', i.status, 'emitido_em', i.emitido_em, 'concluido_em', i.concluido_em, 'ajustado_em', i.ajustado_em,
    'emitido_por', (SELECT nome FROM pec.usuario WHERE id = i.emitido_por),
    'ajustado_por', (SELECT nome FROM pec.usuario WHERE id = i.ajustado_por),
    'itens', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'pasto_id', ii.pasto_id, 'categoria_id', ii.categoria_id, 'qtd_sistema', ii.qtd_sistema,
                'qtd_campo', ii.qtd_campo, 'diferenca', ii.diferenca, 'observacao', ii.observacao,
                'classe', pec.classificar_divergencia(i.fazenda_id, ii.qtd_sistema, ii.qtd_campo),
                'ajuste_numero', (SELECT numero FROM pec.documento WHERE id = ii.documento_ajuste_id))
              ORDER BY p.codigo NULLS LAST, c.ordem), '[]')
                FROM pec.inventario_item ii JOIN pec.categoria c ON c.id = ii.categoria_id
                LEFT JOIN pec.pasto p ON p.id = ii.pasto_id
               WHERE ii.inventario_id = i.id),
    'resumo', (SELECT jsonb_build_object(
                 'linhas', count(*), 'contadas', count(*) FILTER (WHERE qtd_campo IS NOT NULL),
                 'sistema', COALESCE(sum(qtd_sistema), 0), 'campo', COALESCE(sum(qtd_campo), 0),
                 'sistema_contado', COALESCE(sum(qtd_sistema) FILTER (WHERE qtd_campo IS NOT NULL), 0),
                 'divergentes', count(*) FILTER (WHERE diferenca <> 0),
                 'nao_contadas_com_gado', count(*) FILTER (WHERE qtd_campo IS NULL AND qtd_sistema <> 0),
                 'ajustadas', count(*) FILTER (WHERE documento_ajuste_id IS NOT NULL))
                 FROM pec.inventario_item WHERE inventario_id = i.id))
  FROM pec.inventario i WHERE i.id = p_inv
$$;

-- Lista dos Mapões (últimos 12 meses por padrão)
CREATE OR REPLACE FUNCTION public.pec_inventarios(p jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER');
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(pec.inv_json(i.id) - 'itens' ORDER BY i.competencia DESC, r.ordem), '[]')
            FROM pec.inventario i JOIN pec.retiro r ON r.id = i.retiro_id
           WHERE i.fazenda_id = v_faz AND pec.retiro_liberado(i.retiro_id) AND i.status <> 'CANCELADO'
             AND i.competencia >= COALESCE((p->>'desde')::date, (date_trunc('month', current_date) - interval '12 months')::date));
END $$;

CREATE OR REPLACE FUNCTION public.pec_inventario(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER'); v_ret uuid;
BEGIN
  SELECT retiro_id INTO v_ret FROM pec.inventario WHERE id = p_id AND fazenda_id = v_faz;
  IF v_ret IS NULL THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado.'); END IF;
  IF NOT pec.retiro_liberado(v_ret) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  RETURN pec.inv_json(p_id);
END $$;

-- Emite (ou devolve o já emitido) o Mapão de um retiro num mês
CREATE OR REPLACE FUNCTION public.pec_inventario_emitir(p_retiro uuid, p_competencia date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('INV_CONTAR');
  v_comp date := date_trunc('month', p_competencia)::date;
  v_pos date := LEAST((date_trunc('month', p_competencia) + interval '1 month - 1 day')::date, current_date);
  v_id uuid; v_st text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pec.retiro WHERE id = p_retiro AND fazenda_id = v_faz) THEN
    PERFORM pec.erro('NAO_ENCONTRADO', 'Retiro não encontrado.');
  END IF;
  IF NOT pec.retiro_liberado(p_retiro) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF v_comp > current_date THEN PERFORM pec.erro('MES_FUTURO', 'Não dá para emitir o Mapão de um mês que ainda não começou.'); END IF;

  SELECT id, status INTO v_id, v_st FROM pec.inventario WHERE retiro_id = p_retiro AND competencia = v_comp;
  IF v_id IS NOT NULL AND v_st <> 'CANCELADO' THEN
    RETURN pec.inv_json(v_id) || jsonb_build_object('ja_existia', true);
  END IF;
  IF v_id IS NOT NULL THEN       -- cancelado: reaproveita, com fotografia nova
    DELETE FROM pec.inventario_item WHERE inventario_id = v_id;
    UPDATE pec.inventario SET status = 'EMITIDO', data_posicao = v_pos, data_contagem = NULL, contado_por_nome = NULL,
           observacao = NULL, emitido_por = pec.usuario_atual(), emitido_em = now(), concluido_em = NULL WHERE id = v_id;
  ELSE
    INSERT INTO pec.inventario (fazenda_id, retiro_id, competencia, data_posicao, emitido_por)
    VALUES (v_faz, p_retiro, v_comp, v_pos, pec.usuario_atual()) RETURNING id INTO v_id;
  END IF;
  PERFORM pec.inv_recalcular(v_id);
  RETURN pec.inv_json(v_id) || jsonb_build_object('ja_existia', false);
END $$;

-- Grava a contagem (parcial ou completa). Pode ser chamado várias vezes;
-- cada chamada grava só as linhas enviadas. qtd_campo null = "não contei".
CREATE OR REPLACE FUNCTION public.pec_inventario_contar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('INV_CONTAR'); inv pec.inventario%ROWTYPE; it jsonb; n int := 0;
  v_pasto uuid; v_cat uuid; v_qtd int;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = (p->>'inventario_id')::uuid AND fazenda_id = v_faz FOR UPDATE;
  IF NOT FOUND THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado. Ele pode ter sido cancelado.'); END IF;
  IF NOT pec.retiro_liberado(inv.retiro_id) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF inv.status NOT IN ('EMITIDO','EM_CONTAGEM') THEN
    PERFORM pec.erro('INV_CONCLUIDO', format('A contagem do Mapão %s já foi concluída. Peça ao gerente para reabrir a contagem se precisar corrigir.',
                     to_char(inv.competencia, 'MM/YYYY')));
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p->'itens', '[]')) LOOP
    v_pasto := NULLIF(it->>'pasto_id', '')::uuid;
    v_cat   := (it->>'categoria_id')::uuid;
    v_qtd   := NULLIF(it->>'qtd_campo', '')::int;
    IF v_qtd IS NOT NULL AND v_qtd < 0 THEN PERFORM pec.erro('QTD_INVALIDA', 'A contagem não pode ser negativa.'); END IF;
    IF v_pasto IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pec.pasto WHERE id = v_pasto AND retiro_id = inv.retiro_id) THEN
      PERFORM pec.erro('PASTO_FORA_DO_RETIRO', 'Um dos pastos contados não é deste retiro.');
    END IF;
    INSERT INTO pec.inventario_item (inventario_id, pasto_id, categoria_id, qtd_sistema, qtd_campo, observacao, contado_em)
    VALUES (inv.id, v_pasto, v_cat,
            COALESCE((SELECT sum(e.cabecas)::int FROM pec.fn_estoque(inv.fazenda_id, inv.data_posicao) e
                       WHERE e.retiro_id = inv.retiro_id AND e.pasto_id IS NOT DISTINCT FROM v_pasto AND e.categoria_id = v_cat), 0),
            v_qtd, NULLIF(trim(it->>'observacao'), ''), now())
    ON CONFLICT (inventario_id, pasto_id, categoria_id) DO UPDATE
       SET qtd_campo = EXCLUDED.qtd_campo, observacao = EXCLUDED.observacao, contado_em = now();
    n := n + 1;
  END LOOP;

  UPDATE pec.inventario SET status = 'EM_CONTAGEM',
         data_contagem    = COALESCE(NULLIF(p->>'data_contagem', '')::date, data_contagem, current_date),
         contado_por_nome = COALESCE(NULLIF(trim(p->>'contado_por_nome'), ''), contado_por_nome),
         observacao       = CASE WHEN p ? 'observacao' THEN NULLIF(trim(p->>'observacao'), '') ELSE observacao END
   WHERE id = inv.id;
  RETURN jsonb_build_object('ok', true, 'linhas', n);
END $$;

-- Conclui a contagem: recalcula o sistema, divergências viram pendências
CREATE OR REPLACE FUNCTION public.pec_inventario_concluir(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('INV_CONTAR'); inv pec.inventario%ROWTYPE; n int;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_id AND fazenda_id = v_faz FOR UPDATE;
  IF NOT FOUND THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado.'); END IF;
  IF NOT pec.retiro_liberado(inv.retiro_id) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF inv.status = 'EMITIDO' THEN PERFORM pec.erro('INV_SEM_CONTAGEM', 'Nenhuma linha foi contada ainda.'); END IF;
  IF inv.status <> 'EM_CONTAGEM' THEN PERFORM pec.erro('INV_CONCLUIDO', 'Esta contagem já foi concluída.'); END IF;
  PERFORM pec.inv_recalcular(p_id);
  n := pec.concluir_contagem(p_id);
  UPDATE pec.inventario SET concluido_em = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'divergencias', n) || jsonb_build_object('inventario', pec.inv_json(p_id));
END $$;

-- Volta a contagem para edição (antes do ajuste); cancela as pendências geradas
CREATE OR REPLACE FUNCTION public.pec_inventario_reabrir(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('INV_AJUSTAR'); inv pec.inventario%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_id AND fazenda_id = v_faz FOR UPDATE;
  IF NOT FOUND THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado.'); END IF;
  IF inv.status <> 'CONTADO' THEN PERFORM pec.erro('INV_STATUS', 'Só dá para reabrir uma contagem concluída e ainda não ajustada.'); END IF;
  UPDATE pec.inventario SET status = 'EM_CONTAGEM', concluido_em = NULL WHERE id = p_id;
  UPDATE pec.pendencia SET status = 'CANCELADA', resolucao = 'Contagem reaberta para correção', resolvida_em = now()
   WHERE referencia_tabela = 'inventario' AND referencia_id = p_id AND status IN ('ABERTA','EM_ANDAMENTO');
  RETURN jsonb_build_object('ok', true);
END $$;

-- Cancela um Mapão ainda não ajustado (ex.: emitido no mês errado)
CREATE OR REPLACE FUNCTION public.pec_inventario_cancelar(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('INV_AJUSTAR'); inv pec.inventario%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_id AND fazenda_id = v_faz FOR UPDATE;
  IF NOT FOUND THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado.'); END IF;
  IF inv.status = 'AJUSTADO' THEN PERFORM pec.erro('INV_STATUS', 'Mapão já ajustado não pode ser cancelado. Estorne os ajustes no Livro.'); END IF;
  UPDATE pec.inventario SET status = 'CANCELADO' WHERE id = p_id;
  UPDATE pec.pendencia SET status = 'CANCELADA', resolucao = 'Mapão cancelado', resolvida_em = now()
   WHERE referencia_tabela = 'inventario' AND referencia_id = p_id AND status IN ('ABERTA','EM_ANDAMENTO');
  RETURN jsonb_build_object('ok', true);
END $$;

-- Aprova: cada linha divergente vira um Ajuste de Inventário no livro
CREATE OR REPLACE FUNCTION public.pec_inventario_aprovar(p_id uuid, p_motivo text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('INV_AJUSTAR'); inv pec.inventario%ROWTYPE; n int;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_id AND fazenda_id = v_faz FOR UPDATE;
  IF NOT FOUND THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Mapão não encontrado.'); END IF;
  IF NOT pec.retiro_liberado(inv.retiro_id) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF inv.status <> 'CONTADO' THEN PERFORM pec.erro('INV_STATUS', 'Conclua a contagem antes de aprovar os ajustes.'); END IF;
  -- recalcula de novo: se alguém lançou o que faltava depois da conclusão, a diferença já diminuiu
  PERFORM pec.inv_recalcular(p_id);
  IF EXISTS (SELECT 1 FROM pec.inventario_item WHERE inventario_id = p_id AND pasto_id IS NULL AND diferenca > 0) THEN
    PERFORM pec.erro('AJUSTE_SEM_PASTO', 'Sobrou gado na linha "sem pasto". Anote esses animais no pasto onde foram encontrados e conclua de novo.');
  END IF;
  n := pec.aprovar_ajustes_inventario(p_id, COALESCE(NULLIF(trim(p_motivo), ''), 'Conferência de campo'));
  UPDATE pec.inventario SET ajustado_por = pec.usuario_atual(), ajustado_em = now() WHERE id = p_id;
  SET CONSTRAINTS ALL IMMEDIATE;     -- valida agora (estoque negativo etc.)
  SET CONSTRAINTS ALL DEFERRED;
  RETURN jsonb_build_object('ok', true, 'ajustes', n, 'inventario', pec.inv_json(p_id));
END $$;

-- Mapão de qualquer mês (para imprimir), pasto × categoria no fim do mês
CREATE OR REPLACE FUNCTION public.pec_mapao(p_retiro uuid, p_competencia date) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER'); v_comp date := date_trunc('month', p_competencia)::date; v_inv uuid;
BEGIN
  IF NOT pec.retiro_liberado(p_retiro) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  SELECT id INTO v_inv FROM pec.inventario WHERE retiro_id = p_retiro AND competencia = v_comp AND status <> 'CANCELADO';
  RETURN jsonb_build_object(
    'retiro_id', p_retiro, 'competencia', v_comp,
    'posicao', LEAST((v_comp + interval '1 month - 1 day')::date, current_date),
    'linhas', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pasto_id', m.pasto_id, 'categoria_id', m.categoria_id, 'cabecas', m.cabecas)), '[]')
                 FROM pec.fn_estoque(v_faz, LEAST((v_comp + interval '1 month - 1 day')::date, current_date)) m
                WHERE m.retiro_id = p_retiro AND m.cabecas <> 0),
    'inventario', CASE WHEN v_inv IS NOT NULL THEN pec.inv_json(v_inv) END);
END $$;

-- =====================================================================
-- 2. REPRODUÇÃO — estação de monta, lotes expostos, IATF, DG
-- =====================================================================

-- Safra de parição de uma estação: onde caem os partos (início + ~285 dias de gestação)
CREATE OR REPLACE FUNCTION pec.safra_paricao(p_estacao uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT pec.safra_da_data(em.fazenda_id, em.inicio + 285) FROM pec.estacao_monta em WHERE em.id = p_estacao
$$;

CREATE OR REPLACE FUNCTION public.pec_reproducao(p_estacao uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('EST_VER'); v_org uuid; em pec.estacao_monta%ROWTYPE;
  v_par pec.safra%ROWTYPE; v_dias int;
BEGIN
  SELECT organizacao_id INTO v_org FROM pec.fazenda WHERE id = v_faz;
  v_dias := COALESCE((pec.param(v_faz, 'DIAS_ATE_DG') #>> '{}')::int, 30);
  IF p_estacao IS NOT NULL THEN
    SELECT * INTO em FROM pec.estacao_monta WHERE id = p_estacao AND fazenda_id = v_faz;
  ELSE
    SELECT * INTO em FROM pec.estacao_monta WHERE fazenda_id = v_faz ORDER BY (inicio <= current_date) DESC, inicio DESC LIMIT 1;
  END IF;
  IF em.id IS NOT NULL THEN
    SELECT * INTO v_par FROM pec.safra WHERE id = pec.safra_paricao(em.id);
  END IF;

  RETURN jsonb_build_object(
    'estacoes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'inicio', e.inicio, 'fim', e.fim,
                   'safra', (SELECT nome FROM pec.safra WHERE id = e.safra_id),
                   'lotes', (SELECT count(*) FROM pec.lote_reprodutivo WHERE estacao_id = e.id)) ORDER BY e.inicio DESC), '[]')
                 FROM pec.estacao_monta e WHERE e.fazenda_id = v_faz),
    'protocolos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'dias', dias, 'descricao', descricao) ORDER BY nome), '[]')
                   FROM pec.protocolo_iatf WHERE organizacao_id = v_org),
    'dias_ate_dg', v_dias,
    'estacao', CASE WHEN em.id IS NULL THEN NULL ELSE jsonb_build_object(
        'id', em.id, 'nome', em.nome, 'inicio', em.inicio, 'fim', em.fim,
        'safra', (SELECT nome FROM pec.safra WHERE id = em.safra_id),
        'safra_paricao', v_par.nome, 'paricao_inicio', v_par.inicio, 'paricao_fim', v_par.fim) END,
    'lotes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', lr.id, 'retiro_id', lr.retiro_id, 'lote_id', lr.lote_id, 'categoria_id', lr.categoria_id,
                'qtd_expostas', lr.qtd_expostas, 'ecc_medio', lr.ecc_medio, 'carimbo_bezerro', lr.carimbo_bezerro,
                'observacao', lr.observacao,
                'rodadas', (SELECT COALESCE(jsonb_agg(to_jsonb(ir) - 'lote_reprodutivo_id' ORDER BY ir.rodada), '[]')
                              FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = lr.id),
                'dg_final', (SELECT to_jsonb(df) - 'lote_reprodutivo_id' FROM pec.diagnostico_final df WHERE df.lote_reprodutivo_id = lr.id),
                'prenhes', v.prenhes, 'vazias', v.vazias, 'taxa_prenhez', v.taxa_prenhez, 'concepcao_1a_iatf', v.concepcao_1a_iatf)
              ORDER BY r.ordem, c.ordem, l.codigo), '[]')
                FROM pec.lote_reprodutivo lr JOIN pec.retiro r ON r.id = lr.retiro_id JOIN pec.categoria c ON c.id = lr.categoria_id
                LEFT JOIN pec.lote l ON l.id = lr.lote_id
                JOIN pec.v_reproducao_lote v ON v.lote_reprodutivo_id = lr.id
               WHERE lr.estacao_id = em.id AND pec.retiro_liberado(lr.retiro_id)),
    -- quadro 1 da planilha: exposição e prenhez por retiro × categoria
    'prenhez', (SELECT COALESCE(jsonb_agg(x ORDER BY x->>'ordem_r', x->>'ordem_c'), '[]') FROM (
                  SELECT jsonb_build_object('retiro_id', v.retiro_id, 'categoria_id', v.categoria_id,
                           'ordem_r', lpad(r.ordem::text, 3, '0'), 'ordem_c', lpad(c.ordem::text, 3, '0'),
                           'expostas', sum(v.qtd_expostas), 'prenhes', sum(v.prenhes),
                           'inseminadas_1a', sum((SELECT qtd_inseminadas FROM pec.iatf_rodada WHERE lote_reprodutivo_id = v.lote_reprodutivo_id AND rodada = 1)),
                           'prenhes_1a', sum((SELECT qtd_prenhes FROM pec.iatf_rodada WHERE lote_reprodutivo_id = v.lote_reprodutivo_id AND rodada = 1)),
                           'com_dg', bool_and(v.prenhes IS NOT NULL)) x
                    FROM pec.v_reproducao_lote v JOIN pec.retiro r ON r.id = v.retiro_id JOIN pec.categoria c ON c.id = v.categoria_id
                    JOIN pec.lote_reprodutivo lr ON lr.id = v.lote_reprodutivo_id
                   WHERE lr.estacao_id = em.id AND pec.retiro_liberado(v.retiro_id)
                   GROUP BY v.retiro_id, v.categoria_id, r.ordem, c.ordem) t),
    -- quadro 2 da planilha: parição e desmama na safra de parição desta estação
    'paricao', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'retiro_id', r.id, 'expostas', COALESCE(ex.expostas, 0), 'prenhes', ex.prenhes,
                   'nascimentos', COALESCE(mv.nasc, 0), 'mortes_bezerros', COALESCE(mv.mortes_bez, 0),
                   'desmamados', COALESCE(mv.desm, 0), 'peso_desmama', COALESCE(dm.kg, 0)) ORDER BY r.ordem), '[]')
                  FROM pec.retiro r
                  LEFT JOIN (SELECT lr.retiro_id, sum(lr.qtd_expostas) expostas, sum(v.prenhes) prenhes
                               FROM pec.lote_reprodutivo lr JOIN pec.v_reproducao_lote v ON v.lote_reprodutivo_id = lr.id
                              WHERE lr.estacao_id = em.id GROUP BY 1) ex ON ex.retiro_id = r.id
                  LEFT JOIN (SELECT m.retiro_id,
                                    sum(m.qtd_liquida) FILTER (WHERE m.operacao_codigo = 'NASCIMENTO') nasc,
                                    sum(m.qtd_liquida) FILTER (WHERE m.operacao_codigo = 'MORTE' AND m.fase = 'BEZERRO') mortes_bez,
                                    sum(m.qtd_liquida) FILTER (WHERE m.operacao_codigo = 'DESMAMA' AND m.sentido = -1) desm
                               FROM pec.v_movimento m
                              WHERE m.fazenda_id = v_faz AND m.data BETWEEN v_par.inicio AND v_par.fim GROUP BY 1) mv ON mv.retiro_id = r.id
                  LEFT JOIN (SELECT d.retiro_id, sum(d.peso_total_kg) kg FROM pec.v_desmama d
                              WHERE d.fazenda_id = v_faz AND d.data_desmama BETWEEN v_par.inicio AND v_par.fim GROUP BY 1) dm ON dm.retiro_id = r.id
                 WHERE r.fazenda_id = v_faz AND pec.retiro_liberado(r.id) AND r.status = 'ATIVO'
                   AND (ex.expostas IS NOT NULL OR mv.nasc IS NOT NULL OR mv.desm IS NOT NULL)),
    'desmama', (SELECT COALESCE(jsonb_agg(jsonb_build_object('retiro_id', d.retiro_id, 'sexo', d.sexo, 'data', d.data_desmama,
                   'quantidade', d.quantidade, 'peso_total_kg', d.peso_total_kg, 'peso_medio_kg', d.peso_medio_kg,
                   'idade_dias', d.idade_dias, 'gmd_kg_dia', d.gmd_kg_dia, 'p205_kg', d.p205_kg) ORDER BY d.data_desmama DESC), '[]')
                  FROM pec.v_desmama d
                 WHERE d.fazenda_id = v_faz AND v_par.id IS NOT NULL AND d.data_desmama BETWEEN v_par.inicio AND v_par.fim
                   AND (d.retiro_id IS NULL OR pec.retiro_liberado(d.retiro_id))),
    -- agenda de manejo: D8, IATF e DG previstos (atrasados e próximos 45 dias), todas as estações
    'agenda', (SELECT COALESCE(jsonb_agg(a ORDER BY a->>'data'), '[]') FROM (
                 SELECT jsonb_build_object('data', ev.data, 'evento', ev.evento, 'rodada', ir.rodada, 'lote_reprodutivo_id', lr.id,
                          'retiro_id', lr.retiro_id, 'categoria_id', lr.categoria_id, 'lote_id', lr.lote_id,
                          'atrasado', ev.data < current_date) a
                   FROM pec.iatf_rodada ir JOIN pec.lote_reprodutivo lr ON lr.id = ir.lote_reprodutivo_id
                   JOIN pec.estacao_monta e ON e.id = lr.estacao_id AND e.fazenda_id = v_faz
                   CROSS JOIN LATERAL (VALUES
                     ('D8', ir.data_d8, ir.data_iatf IS NULL OR ir.qtd_inseminadas IS NULL),
                     ('IATF', ir.data_iatf, ir.qtd_inseminadas IS NULL),
                     ('DG', COALESCE(ir.data_iatf + v_dias, NULL), ir.data_dg IS NULL AND ir.qtd_inseminadas IS NOT NULL)) ev(evento, data, pendente)
                  WHERE ev.data IS NOT NULL AND ev.pendente AND pec.retiro_liberado(lr.retiro_id)
                    AND ev.data BETWEEN current_date - 60 AND current_date + 45
                    AND (ev.evento = 'DG' OR ev.data >= current_date)) t));
END $$;

CREATE OR REPLACE FUNCTION public.pec_estacao_salvar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('REPRO_LANCAR'); v_id uuid := COALESCE(NULLIF(p->>'id','')::uuid, gen_random_uuid());
  v_ini date := NULLIF(p->>'inicio','')::date; v_fim date := NULLIF(p->>'fim','')::date;
BEGIN
  IF COALESCE(trim(p->>'nome'),'') = '' THEN PERFORM pec.erro('SEM_NOME', 'Dê um nome à estação (ex.: Estação 26/27).'); END IF;
  IF v_ini IS NULL OR v_fim IS NULL OR v_fim <= v_ini THEN
    PERFORM pec.erro('DATAS_INVALIDAS', 'Informe início e fim da estação (o fim depois do início).');
  END IF;
  IF v_fim - v_ini > 366 THEN PERFORM pec.erro('DATAS_INVALIDAS', 'A estação de monta passa de um ano. Confira as datas.'); END IF;
  INSERT INTO pec.estacao_monta (id, fazenda_id, safra_id, nome, inicio, fim)
  VALUES (v_id, v_faz, pec.safra_garantir(v_faz, v_ini), trim(p->>'nome'), v_ini, v_fim)
  ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome, inicio = EXCLUDED.inicio, fim = EXCLUDED.fim, safra_id = EXCLUDED.safra_id;
  PERFORM pec.safra_garantir(v_faz, v_ini + 285);       -- garante a safra de parição
  RETURN jsonb_build_object('ok', true, 'id', v_id);
EXCEPTION WHEN unique_violation THEN
  PERFORM pec.erro('NOME_REPETIDO', format('Já existe uma estação chamada "%s".', trim(p->>'nome')));
END $$;

CREATE OR REPLACE FUNCTION public.pec_lote_reprodutivo_salvar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('REPRO_LANCAR'); v_id uuid := COALESCE(NULLIF(p->>'id','')::uuid, gen_random_uuid());
  v_ret uuid := (p->>'retiro_id')::uuid; v_cat uuid := (p->>'categoria_id')::uuid; v_exp int := NULLIF(p->>'qtd_expostas','')::int;
  v_maior int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pec.estacao_monta WHERE id = (p->>'estacao_id')::uuid AND fazenda_id = v_faz) THEN
    PERFORM pec.erro('NAO_ENCONTRADO', 'Estação de monta não encontrada.');
  END IF;
  IF v_ret IS NULL OR NOT pec.retiro_liberado(v_ret) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Escolha um retiro que você pode acessar.'); END IF;
  IF NOT EXISTS (SELECT 1 FROM pec.categoria WHERE id = v_cat AND (eh_matriz OR fase = 'RECRIA') AND sexo = 'F') THEN
    PERFORM pec.erro('CATEGORIA_INVALIDA', 'Lote reprodutivo é de fêmeas: Vaca, Primípara, Novilha Matriz ou Novilha.');
  END IF;
  IF v_exp IS NULL OR v_exp <= 0 THEN PERFORM pec.erro('QTD_INVALIDA', 'Informe quantas fêmeas foram expostas.'); END IF;
  SELECT max(COALESCE(ir.qtd_inseminadas, 0)) INTO v_maior FROM pec.iatf_rodada ir WHERE ir.lote_reprodutivo_id = v_id AND ir.rodada = 1;
  IF v_maior > v_exp THEN
    PERFORM pec.erro('QTD_INVALIDA', format('A 1ª IATF deste lote já tem %s inseminadas; as expostas não podem ser menos que isso.', v_maior));
  END IF;
  INSERT INTO pec.lote_reprodutivo (id, estacao_id, lote_id, retiro_id, categoria_id, qtd_expostas, ecc_medio, carimbo_bezerro, observacao)
  VALUES (v_id, (p->>'estacao_id')::uuid, NULLIF(p->>'lote_id','')::uuid, v_ret, v_cat, v_exp,
          NULLIF(p->>'ecc_medio','')::numeric, NULLIF(trim(p->>'carimbo_bezerro'),''), NULLIF(trim(p->>'observacao'),''))
  ON CONFLICT (id) DO UPDATE SET lote_id = EXCLUDED.lote_id, retiro_id = EXCLUDED.retiro_id, categoria_id = EXCLUDED.categoria_id,
         qtd_expostas = EXCLUDED.qtd_expostas, ecc_medio = EXCLUDED.ecc_medio, carimbo_bezerro = EXCLUDED.carimbo_bezerro,
         observacao = EXCLUDED.observacao;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

-- Rodada de IATF (1ª, ressincronização, repasse). Datas e quantidades conferidas.
CREATE OR REPLACE FUNCTION public.pec_rodada_salvar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('REPRO_LANCAR'); v_org uuid;
  v_id uuid := COALESCE(NULLIF(p->>'id','')::uuid, gen_random_uuid());
  lr pec.lote_reprodutivo%ROWTYPE; v_rod int := COALESCE(NULLIF(p->>'rodada','')::int, 1);
  d0 date := NULLIF(p->>'data_d0','')::date; d8 date := NULLIF(p->>'data_d8','')::date;
  di date := NULLIF(p->>'data_iatf','')::date; ddg date := NULLIF(p->>'data_dg','')::date;
  ins int := NULLIF(p->>'qtd_inseminadas','')::int; pre int := NULLIF(p->>'qtd_prenhes','')::int;
  vaz int := NULLIF(p->>'qtd_vazias','')::int; per int := COALESCE(NULLIF(p->>'qtd_perdas','')::int, 0);
  v_prot uuid := NULLIF(p->>'protocolo_id','')::uuid; v_disp int;
BEGIN
  SELECT lr0.* INTO lr FROM pec.lote_reprodutivo lr0 JOIN pec.estacao_monta e ON e.id = lr0.estacao_id
   WHERE lr0.id = (p->>'lote_reprodutivo_id')::uuid AND e.fazenda_id = v_faz;
  IF lr.id IS NULL THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Lote reprodutivo não encontrado.'); END IF;
  IF NOT pec.retiro_liberado(lr.retiro_id) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF v_rod NOT BETWEEN 1 AND 5 THEN PERFORM pec.erro('RODADA_INVALIDA', 'A rodada vai de 1 a 5.'); END IF;

  IF d8 < d0 OR di < COALESCE(d8, d0) THEN PERFORM pec.erro('DATAS_INVALIDAS', 'As datas precisam seguir a ordem D0 → D8 → IATF.'); END IF;
  IF di - d0 > 15 THEN PERFORM pec.erro('DATAS_INVALIDAS', 'Do D0 à IATF passam mais de 15 dias. Confira as datas.'); END IF;
  IF ddg IS NOT NULL AND (di IS NULL OR ddg < di + 25) THEN
    PERFORM pec.erro('DATAS_INVALIDAS', 'O DG precisa ser pelo menos 25 dias depois da IATF.');
  END IF;
  IF COALESCE(d0, d8, di, ddg) > current_date + 60 THEN PERFORM pec.erro('DATAS_INVALIDAS', 'Data muito no futuro. Confira o ano.'); END IF;

  -- disponíveis para esta rodada: expostas − prenhes das rodadas anteriores − perdas anteriores
  SELECT lr.qtd_expostas - COALESCE(sum(COALESCE(qtd_prenhes, 0) + COALESCE(qtd_perdas, 0)), 0) INTO v_disp
    FROM pec.iatf_rodada WHERE lote_reprodutivo_id = lr.id AND rodada < v_rod;
  IF ins IS NOT NULL AND (ins < 0 OR ins > v_disp) THEN
    PERFORM pec.erro('QTD_INVALIDA', format('Inseminadas (%s) passa das fêmeas disponíveis nesta rodada (%s = expostas menos prenhes e perdas das rodadas anteriores).', ins, v_disp));
  END IF;
  IF (pre IS NOT NULL OR vaz IS NOT NULL) AND ins IS NULL THEN PERFORM pec.erro('QTD_INVALIDA', 'Informe quantas foram inseminadas antes do DG.'); END IF;
  IF pre IS NOT NULL AND COALESCE(pre, 0) + COALESCE(vaz, 0) + per <> ins THEN
    PERFORM pec.erro('DG_NAO_FECHA', format('No DG, prenhes + vazias + perdas (%s) precisa dar o total inseminado (%s).', COALESCE(pre,0) + COALESCE(vaz,0) + per, ins));
  END IF;
  IF pre IS NOT NULL AND ddg IS NULL THEN PERFORM pec.erro('SEM_DATA', 'Informe a data do DG.'); END IF;

  SELECT organizacao_id INTO v_org FROM pec.fazenda WHERE id = v_faz;
  IF v_prot IS NULL AND COALESCE(trim(p->>'protocolo_nome'),'') <> '' THEN
    SELECT id INTO v_prot FROM pec.protocolo_iatf WHERE organizacao_id = v_org AND lower(nome) = lower(trim(p->>'protocolo_nome'));
    IF v_prot IS NULL THEN
      INSERT INTO pec.protocolo_iatf (organizacao_id, nome) VALUES (v_org, trim(p->>'protocolo_nome')) RETURNING id INTO v_prot;
    END IF;
  END IF;

  INSERT INTO pec.iatf_rodada (id, lote_reprodutivo_id, rodada, tipo, protocolo_id, data_d0, data_d8, data_iatf, qtd_inseminadas,
                               touro_semen, raca_touro_id, data_dg, qtd_prenhes, qtd_vazias, qtd_perdas)
  VALUES (v_id, lr.id, v_rod, COALESCE(NULLIF(p->>'tipo',''), CASE WHEN v_rod = 1 THEN 'IATF' ELSE 'RESSINCRONIZACAO' END),
          v_prot, d0, d8, di, ins, NULLIF(trim(p->>'touro_semen'),''), NULLIF(p->>'raca_touro_id','')::uuid, ddg, pre, vaz, per)
  ON CONFLICT (id) DO UPDATE SET rodada = EXCLUDED.rodada, tipo = EXCLUDED.tipo, protocolo_id = EXCLUDED.protocolo_id,
         data_d0 = EXCLUDED.data_d0, data_d8 = EXCLUDED.data_d8, data_iatf = EXCLUDED.data_iatf, qtd_inseminadas = EXCLUDED.qtd_inseminadas,
         touro_semen = EXCLUDED.touro_semen, raca_touro_id = EXCLUDED.raca_touro_id, data_dg = EXCLUDED.data_dg,
         qtd_prenhes = EXCLUDED.qtd_prenhes, qtd_vazias = EXCLUDED.qtd_vazias, qtd_perdas = EXCLUDED.qtd_perdas;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
EXCEPTION WHEN unique_violation THEN
  PERFORM pec.erro('RODADA_REPETIDA', format('Este lote já tem a %sª rodada. Abra a existente para editar.', v_rod));
END $$;

-- DG final da estação (fim da monta, inclui repasse com touro)
CREATE OR REPLACE FUNCTION public.pec_dg_final_salvar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('REPRO_LANCAR'); lr pec.lote_reprodutivo%ROWTYPE;
  pre int := NULLIF(p->>'qtd_prenhes','')::int; vaz int := NULLIF(p->>'qtd_vazias','')::int; desc_ int := COALESCE(NULLIF(p->>'qtd_descarte','')::int, 0);
BEGIN
  SELECT lr0.* INTO lr FROM pec.lote_reprodutivo lr0 JOIN pec.estacao_monta e ON e.id = lr0.estacao_id
   WHERE lr0.id = (p->>'lote_reprodutivo_id')::uuid AND e.fazenda_id = v_faz;
  IF lr.id IS NULL THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Lote reprodutivo não encontrado.'); END IF;
  IF NOT pec.retiro_liberado(lr.retiro_id) THEN PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a este retiro.'); END IF;
  IF p ? 'remover' AND (p->>'remover')::boolean THEN
    DELETE FROM pec.diagnostico_final WHERE lote_reprodutivo_id = lr.id;
    RETURN jsonb_build_object('ok', true, 'removido', true);
  END IF;
  IF pre IS NULL OR vaz IS NULL OR pre < 0 OR vaz < 0 THEN PERFORM pec.erro('QTD_INVALIDA', 'Informe prenhes e vazias no DG final.'); END IF;
  IF pre + vaz > lr.qtd_expostas THEN
    PERFORM pec.erro('DG_NAO_FECHA', format('Prenhes + vazias (%s) passa das fêmeas expostas no lote (%s).', pre + vaz, lr.qtd_expostas));
  END IF;
  IF NULLIF(p->>'data_dg','') IS NULL THEN PERFORM pec.erro('SEM_DATA', 'Informe a data do DG final.'); END IF;
  INSERT INTO pec.diagnostico_final (lote_reprodutivo_id, data_dg, qtd_prenhes, qtd_vazias, qtd_descarte)
  VALUES (lr.id, (p->>'data_dg')::date, pre, vaz, desc_)
  ON CONFLICT (lote_reprodutivo_id) DO UPDATE SET data_dg = EXCLUDED.data_dg, qtd_prenhes = EXCLUDED.qtd_prenhes,
         qtd_vazias = EXCLUDED.qtd_vazias, qtd_descarte = EXCLUDED.qtd_descarte;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Exclusão em reprodução (não é livro de estoque): rodada, lote sem rodadas, estação sem lotes
CREATE OR REPLACE FUNCTION public.pec_reproducao_excluir(p_tipo text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('REPRO_LANCAR'); v_ret uuid;
BEGIN
  CASE p_tipo
  WHEN 'rodada' THEN
    SELECT lr.retiro_id INTO v_ret FROM pec.iatf_rodada ir JOIN pec.lote_reprodutivo lr ON lr.id = ir.lote_reprodutivo_id
      JOIN pec.estacao_monta e ON e.id = lr.estacao_id WHERE ir.id = p_id AND e.fazenda_id = v_faz;
    IF v_ret IS NULL OR NOT pec.retiro_liberado(v_ret) THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Rodada não encontrada.'); END IF;
    IF EXISTS (SELECT 1 FROM pec.iatf_rodada a JOIN pec.iatf_rodada b ON b.lote_reprodutivo_id = a.lote_reprodutivo_id AND b.rodada > a.rodada WHERE a.id = p_id) THEN
      PERFORM pec.erro('TEM_SEGUINTE', 'Exclua antes as rodadas seguintes deste lote.');
    END IF;
    DELETE FROM pec.iatf_rodada WHERE id = p_id;
  WHEN 'lote' THEN
    SELECT lr.retiro_id INTO v_ret FROM pec.lote_reprodutivo lr JOIN pec.estacao_monta e ON e.id = lr.estacao_id
     WHERE lr.id = p_id AND e.fazenda_id = v_faz;
    IF v_ret IS NULL OR NOT pec.retiro_liberado(v_ret) THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Lote não encontrado.'); END IF;
    IF EXISTS (SELECT 1 FROM pec.iatf_rodada WHERE lote_reprodutivo_id = p_id) OR EXISTS (SELECT 1 FROM pec.diagnostico_final WHERE lote_reprodutivo_id = p_id) THEN
      PERFORM pec.erro('TEM_DADOS', 'Este lote já tem IATF ou DG. Exclua esses registros antes.');
    END IF;
    DELETE FROM pec.lote_reprodutivo WHERE id = p_id;
  WHEN 'estacao' THEN
    IF NOT EXISTS (SELECT 1 FROM pec.estacao_monta WHERE id = p_id AND fazenda_id = v_faz) THEN PERFORM pec.erro('NAO_ENCONTRADO', 'Estação não encontrada.'); END IF;
    IF EXISTS (SELECT 1 FROM pec.lote_reprodutivo WHERE estacao_id = p_id) THEN PERFORM pec.erro('TEM_DADOS', 'A estação tem lotes. Exclua os lotes antes.'); END IF;
    DELETE FROM pec.estacao_monta WHERE id = p_id;
  ELSE PERFORM pec.erro('TIPO_INVALIDO', 'Tipo inválido.');
  END CASE;
  RETURN jsonb_build_object('ok', true);
END $$;

-- =====================================================================
-- 3. FECHAMENTO DO MÊS
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pec_fechamento(p_competencia date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('EST_VER');
  v_comp date := date_trunc('month', COALESCE(p_competencia, (current_date - interval '1 month')::date))::date;
  v_fim date := (date_trunc('month', COALESCE(p_competencia, (current_date - interval '1 month')::date)) + interval '1 month - 1 day')::date;
  v_primeiro date; per pec.periodo%ROWTYPE; v_bloq jsonb := '[]'; v_avisos jsonb := '[]'; v_snap_tot bigint; v_live_tot bigint;
BEGIN
  SELECT date_trunc('month', min(data))::date INTO v_primeiro FROM pec.documento WHERE fazenda_id = v_faz;
  SELECT * INTO per FROM pec.periodo WHERE fazenda_id = v_faz AND competencia = v_comp;

  -- bloqueios
  IF v_comp >= date_trunc('month', current_date) THEN
    v_bloq := v_bloq || jsonb_build_object('codigo', 'MES_EM_ANDAMENTO', 'mensagem', 'O mês ainda não terminou.');
  END IF;
  IF EXISTS (SELECT 1 FROM generate_series(v_primeiro, v_comp - interval '1 month', interval '1 month') g(m)
              WHERE NOT pec.periodo_fechado(v_faz, g.m::date)) THEN
    v_bloq := v_bloq || jsonb_build_object('codigo', 'MESES_ANTERIORES', 'mensagem',
               'Há meses anteriores abertos: ' || (SELECT string_agg(to_char(g.m, 'MM/YYYY'), ', ' ORDER BY g.m)
                 FROM generate_series(v_primeiro, v_comp - interval '1 month', interval '1 month') g(m) WHERE NOT pec.periodo_fechado(v_faz, g.m::date)) || '.');
  END IF;
  v_bloq := v_bloq || COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', a.regra, 'mensagem', a.mensagem))
                                  FROM pec.v_alertas a WHERE a.fazenda_id = v_faz AND a.nivel = 'CRITICO' AND (a.data IS NULL OR a.data <= v_fim)), '[]');

  -- avisos (não impedem)
  v_avisos := v_avisos || COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', 'SEM_PASTO', 'mensagem',
                    format('%s cab. em %s sem pasto informado no fim do mês.', s.cab, r.nome)))
                  FROM (SELECT retiro_id, sum(cabecas) cab FROM pec.fn_estoque(v_faz, v_fim) WHERE pasto_id IS NULL GROUP BY 1 HAVING sum(cabecas) <> 0) s
                  JOIN pec.retiro r ON r.id = s.retiro_id), '[]');
  v_avisos := v_avisos || COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', 'SEM_MAPAO', 'mensagem',
                    format('%s: Mapão de %s não conferido no campo%s.', r.nome, to_char(v_comp, 'MM/YYYY'),
                           CASE WHEN i.status IS NULL THEN '' ELSE ' (situação: ' || lower(replace(i.status, '_', ' ')) || ')' END)) ORDER BY r.ordem)
                  FROM pec.retiro r
                  LEFT JOIN pec.inventario i ON i.retiro_id = r.id AND i.competencia = v_comp AND i.status <> 'CANCELADO'
                 WHERE r.fazenda_id = v_faz AND COALESCE(i.status, '') NOT IN ('CONTADO','AJUSTADO')
                   AND EXISTS (SELECT 1 FROM pec.fn_estoque(v_faz, v_fim) e WHERE e.retiro_id = r.id AND e.cabecas <> 0)), '[]');
  v_avisos := v_avisos || COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', a.regra, 'mensagem', a.mensagem))
                  FROM pec.v_alertas a WHERE a.fazenda_id = v_faz AND a.regra IN ('VENDA_INCOMPLETA','MORTE_SEM_CAUSA','INVENTARIO_DIVERGENTE')
                   AND (a.data IS NULL OR a.data BETWEEN v_comp AND v_fim)), '[]');

  IF per.snapshot IS NOT NULL THEN
    SELECT sum((x->>'saldo_final')::bigint) INTO v_snap_tot FROM jsonb_array_elements(per.snapshot) x;
    SELECT sum(saldo_final) INTO v_live_tot FROM pec.fn_fechamento(v_faz, v_comp);
  END IF;

  RETURN jsonb_build_object(
    'competencia', v_comp, 'fim', v_fim,
    'status', COALESCE(per.status::text, 'ABERTO'),
    'fechado_em', per.fechado_em, 'fechado_por', (SELECT nome FROM pec.usuario WHERE id = per.fechado_por),
    'reaberto_em', per.reaberto_em, 'reaberto_por', (SELECT nome FROM pec.usuario WHERE id = per.reaberto_por),
    'motivo_reabertura', per.motivo_reabertura,
    'fotografia_total', v_snap_tot, 'total_atual', v_live_tot,
    'linhas', (SELECT COALESCE(jsonb_agg(to_jsonb(f) - 'retiro' - 'categoria'), '[]')
                 FROM pec.fn_fechamento(v_faz, v_comp) f WHERE pec.retiro_liberado(f.retiro_id)),
    'sem_pasto', (SELECT COALESCE(jsonb_object_agg(retiro_id, cab), '{}')
                    FROM (SELECT retiro_id, sum(cabecas) cab FROM pec.fn_estoque(v_faz, v_fim) WHERE pasto_id IS NULL GROUP BY 1) s),
    'mapoes', (SELECT COALESCE(jsonb_object_agg(i.retiro_id, jsonb_build_object('id', i.id, 'status', i.status)), '{}')
                 FROM pec.inventario i WHERE i.fazenda_id = v_faz AND i.competencia = v_comp AND i.status <> 'CANCELADO'),
    'bloqueios', v_bloq, 'avisos', v_avisos,
    'meses', (SELECT COALESCE(jsonb_agg(jsonb_build_object('competencia', g.m::date,
                 'status', COALESCE((SELECT status::text FROM pec.periodo WHERE fazenda_id = v_faz AND competencia = g.m::date), 'ABERTO'))
               ORDER BY g.m DESC), '[]')
                FROM generate_series(COALESCE(v_primeiro, date_trunc('month', current_date)::date), date_trunc('month', current_date), interval '1 month') g(m)));
END $$;

CREATE OR REPLACE FUNCTION public.pec_fechar_mes(p_competencia date, p_forcar boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('PERIODO_FECHAR'); v_comp date := date_trunc('month', p_competencia)::date; r jsonb;
BEGIN
  IF v_comp >= date_trunc('month', current_date) THEN
    PERFORM pec.erro('MES_EM_ANDAMENTO', format('O mês %s ainda não terminou.', to_char(v_comp, 'MM/YYYY')));
  END IF;
  IF pec.periodo_fechado(v_faz, v_comp) THEN PERFORM pec.erro('JA_FECHADO', format('O mês %s já está fechado.', to_char(v_comp, 'MM/YYYY'))); END IF;
  IF EXISTS (SELECT 1 FROM generate_series((SELECT date_trunc('month', min(data)) FROM pec.documento WHERE fazenda_id = v_faz),
                                           v_comp - interval '1 month', interval '1 month') g(m)
              WHERE NOT pec.periodo_fechado(v_faz, g.m::date)) THEN
    PERFORM pec.erro('FECHAMENTO_FORA_ORDEM', 'Feche primeiro os meses anteriores (do mais antigo para o mais novo).');
  END IF;
  IF p_forcar AND NOT pec.tem_permissao(v_faz, 'PERIODO_EDITAR_FECHADO') THEN
    PERFORM pec.erro('SEM_PERMISSAO', 'Só o administrador pode fechar o mês com alertas críticos.');
  END IF;
  r := pec.fechar_periodo(v_faz, v_comp, p_forcar);
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.pec_reabrir_mes(p_competencia date, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('PERIODO_REABRIR'); v_comp date := date_trunc('month', p_competencia)::date;
BEGIN
  IF NOT pec.periodo_fechado(v_faz, v_comp) THEN PERFORM pec.erro('NAO_FECHADO', 'Este mês não está fechado.'); END IF;
  IF EXISTS (SELECT 1 FROM pec.periodo WHERE fazenda_id = v_faz AND competencia > v_comp AND status = 'FECHADO') THEN
    PERFORM pec.erro('MESES_SEGUINTES', 'Há meses seguintes fechados. Reabra primeiro o mais recente.');
  END IF;
  IF length(COALESCE(trim(p_motivo), '')) < 5 THEN PERFORM pec.erro('SEM_MOTIVO', 'Explique em uma frase por que o mês precisa ser reaberto.'); END IF;
  PERFORM pec.reabrir_periodo(v_faz, v_comp, trim(p_motivo));
  RETURN jsonb_build_object('ok', true);
END $$;

-- Evolução mensal da safra (aba "Evolução Mensal" da planilha)
CREATE OR REPLACE FUNCTION public.pec_evolucao(p_safra uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER'); s pec.safra%ROWTYPE;
BEGIN
  IF p_safra IS NOT NULL THEN SELECT * INTO s FROM pec.safra WHERE id = p_safra AND fazenda_id = v_faz;
  ELSE SELECT * INTO s FROM pec.safra WHERE fazenda_id = v_faz AND current_date BETWEEN inicio AND fim; END IF;
  IF s.id IS NULL THEN RETURN jsonb_build_object('safra', NULL, 'meses', '[]'::jsonb); END IF;
  RETURN jsonb_build_object('safra', s.nome, 'safras', (SELECT jsonb_agg(jsonb_build_object('id', id, 'nome', nome) ORDER BY inicio DESC) FROM pec.safra WHERE fazenda_id = v_faz),
    'meses', (SELECT COALESCE(jsonb_agg(x ORDER BY x->>'mes'), '[]') FROM (
      SELECT jsonb_build_object('mes', g.m::date,
        'nascimentos', COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'NASCIMENTO'), 0),
        'compras',     COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'COMPRA'), 0),
        'saldo_inicial', COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'SALDO_INICIAL'), 0),
        'entradas_transf', COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.sentido = 1 AND mv.operacao_codigo IN ('TRANSF_RETIRO','TRANSF_FAZENDA','REFUGO_COCHO')), 0),
        'mortes',      COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'MORTE'), 0),
        'vendas',      COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'VENDA'), 0),
        'saidas_transf', COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.sentido = -1 AND mv.operacao_codigo IN ('TRANSF_RETIRO','TRANSF_FAZENDA','REFUGO_COCHO')), 0),
        'ajustes',     COALESCE(sum(mv.efeito) FILTER (WHERE mv.operacao_codigo = 'AJUSTE_INVENTARIO'), 0),
        'desmamados',  COALESCE(sum(mv.qtd_liquida) FILTER (WHERE mv.operacao_codigo = 'DESMAMA' AND mv.sentido = -1), 0),
        'estoque_fim', (SELECT COALESCE(sum(m2.efeito), 0) FROM pec.movimento m2 WHERE m2.fazenda_id = v_faz AND pec.retiro_liberado(m2.retiro_id)
                          AND m2.data < (g.m + interval '1 month')::date),
        'estoque_ini', (SELECT COALESCE(sum(m2.efeito), 0) FROM pec.movimento m2 WHERE m2.fazenda_id = v_faz AND pec.retiro_liberado(m2.retiro_id)
                          AND m2.data < g.m::date),
        'fechado', pec.periodo_fechado(v_faz, g.m::date)) x
        FROM generate_series(s.inicio, LEAST(s.fim, current_date), interval '1 month') g(m)
        LEFT JOIN pec.v_movimento mv ON mv.fazenda_id = v_faz AND pec.retiro_liberado(mv.retiro_id)
             AND mv.data >= g.m::date AND mv.data < (g.m + interval '1 month')::date
       GROUP BY g.m) t));
END $$;

-- =====================================================================
-- 4. DESMAMA com registro de peso (para GMD, P205 e kg desmamado/matriz)
--    pec_lancar passa a gravar desmama_registro por sexo a partir da perna de saída
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pec_lancar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_faz uuid := pec.exigir('MOV_LANCAR');
  v_id uuid := COALESCE(NULLIF(p->>'id','')::uuid, gen_random_uuid());
  v_org uuid; v_parc uuid; v_num bigint; v_valor numeric; perna jsonb; n int := 0;
  v_origem pec.origem_reg_t := COALESCE(NULLIF(p->>'origem',''), 'APP')::pec.origem_reg_t;
BEGIN
  SELECT numero INTO v_num FROM pec.documento WHERE id = v_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'duplicado', true);
  END IF;
  IF v_origem = 'IMPORTACAO' THEN v_origem := 'APP'; END IF;
  IF jsonb_typeof(p->'pernas') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'pernas') = 0 THEN
    PERFORM pec.erro('DOC_SEM_MOVIMENTO', 'Informe ao menos uma linha de animais.');
  END IF;

  SELECT organizacao_id INTO v_org FROM pec.fazenda WHERE id = v_faz;
  v_parc := NULLIF(p->>'parceiro_id','')::uuid;
  IF v_parc IS NULL AND COALESCE(trim(p->>'parceiro_nome'),'') <> '' THEN
    SELECT id INTO v_parc FROM pec.parceiro WHERE organizacao_id = v_org AND lower(nome) = lower(trim(p->>'parceiro_nome')) LIMIT 1;
    IF v_parc IS NULL THEN
      INSERT INTO pec.parceiro (organizacao_id, nome, tipo)
      VALUES (v_org, trim(p->>'parceiro_nome'),
              CASE p->>'operacao' WHEN 'COMPRA' THEN '{FORNECEDOR}'::text[] ELSE '{COMPRADOR}'::text[] END)
      RETURNING id INTO v_parc;
    END IF;
  END IF;
  v_valor := CASE WHEN pec.tem_permissao(v_faz, 'MOV_FINANCEIRO') THEN NULLIF(p->>'valor_total','')::numeric END;

  INSERT INTO pec.documento (id, fazenda_id, operacao_codigo, data, causa_morte_id, canal_venda_id, parceiro_id,
                             peso_total_kg, valor_total, nota_fiscal, gta, observacao, origem, dispositivo_id, sincronizado_em)
  VALUES (v_id, v_faz, p->>'operacao', NULLIF(p->>'data','')::date,
          NULLIF(p->>'causa_morte_id','')::uuid, NULLIF(p->>'canal_venda_id','')::uuid, v_parc,
          NULLIF(p->>'peso_total_kg','')::numeric, v_valor, NULLIF(p->>'nota_fiscal',''), NULLIF(p->>'gta',''),
          NULLIF(trim(p->>'observacao'),''), v_origem, NULLIF(p->>'dispositivo_id',''), now())
  RETURNING numero INTO v_num;

  FOR perna IN SELECT * FROM jsonb_array_elements(p->'pernas') LOOP
    IF NOT pec.retiro_liberado(NULLIF(perna->>'retiro_id','')::uuid) THEN
      PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a um dos retiros deste lançamento.');
    END IF;
    INSERT INTO pec.movimento (documento_id, sentido, fazenda_id, retiro_id, pasto_id, lote_id, categoria_id, raca_id,
                               quantidade, peso_kg, data)
    VALUES (v_id, (perna->>'sentido')::smallint, v_faz, NULLIF(perna->>'retiro_id','')::uuid, NULLIF(perna->>'pasto_id','')::uuid,
            NULLIF(perna->>'lote_id','')::uuid, NULLIF(perna->>'categoria_id','')::uuid, NULLIF(perna->>'raca_id','')::uuid,
            (perna->>'quantidade')::int, NULLIF(perna->>'peso_kg','')::numeric, NULLIF(p->>'data','')::date);
    n := n + 1;
  END LOOP;

  IF p->>'operacao' = 'DESMAMA' THEN
    INSERT INTO pec.desmama_registro (documento_id, sexo, quantidade, data_nascimento_media, data_desmama, peso_total_kg, lote_id, retiro_id)
    SELECT v_id, c.sexo, sum(m.quantidade), NULLIF(p->>'nascimento_medio','')::date, NULLIF(p->>'data','')::date,
           sum(m.peso_kg), min(m.lote_id::text)::uuid, min(m.retiro_id::text)::uuid
      FROM pec.movimento m JOIN pec.categoria c ON c.id = m.categoria_id
     WHERE m.documento_id = v_id AND m.sentido = -1
     GROUP BY c.sexo HAVING sum(m.peso_kg) > 0;
  END IF;

  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'pernas', n, 'duplicado', false);
END $$;

-- =====================================================================
-- 5. INDICADORES: natalidade e desmame usam as fêmeas expostas na estação
--    que GEROU os bezerros do período (parição = início da estação + 285 dias)
-- =====================================================================
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
            FROM pec.v_reproducao_lote v JOIN pec.lote_reprodutivo lr ON lr.id = v.lote_reprodutivo_id
            JOIN pec.estacao_monta em ON em.id = lr.estacao_id
           WHERE em.fazenda_id = p_fazenda AND em.inicio BETWEEN p_ini AND p_fim),
  par AS (SELECT COALESCE(sum(lr.qtd_expostas),0) expostas
            FROM pec.lote_reprodutivo lr JOIN pec.estacao_monta em ON em.id = lr.estacao_id
           WHERE em.fazenda_id = p_fazenda AND em.inicio + 285 BETWEEN p_ini AND p_fim),
  dm AS (SELECT COALESCE(sum(peso_total_kg),0) kg FROM pec.v_desmama WHERE fazenda_id = p_fazenda AND data_desmama BETWEEN p_ini AND p_fim)
  SELECT v.* FROM est_ini, est_fim, area, k, doc, rep, par, dm, LATERAL (VALUES
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
    ('TX_PRENHEZ','Taxa de prenhez', round(rep.prenhes / NULLIF(rep.expostas,0),4), rep.prenhes, rep.expostas, '%',
       'prenhes no DG ÷ fêmeas expostas nas estações de monta que começaram no período'),
    ('TX_NATALIDADE','Taxa de natalidade', round(k.nasc / NULLIF(par.expostas,0),4), k.nasc, par.expostas, '%',
       'nascimentos do período ÷ fêmeas expostas na estação que gerou esses partos (início da estação + 285 dias cai no período)'),
    ('DESMAMADOS','Bezerros desmamados', k.desm, k.desm, NULL, 'cab', 'Σ perna de saída das operações DESMAMA'),
    ('TX_DESMAME','Taxa de desmame', round(k.desm / NULLIF(par.expostas,0),4), k.desm, par.expostas, '%',
       'desmamados do período ÷ fêmeas expostas na estação que gerou esses bezerros'),
    ('KG_DESM_MATRIZ','kg desmamado por matriz exposta', round(dm.kg / NULLIF(par.expostas,0),1), dm.kg, par.expostas, 'kg',
       'peso total desmamado ÷ fêmeas expostas na estação que gerou esses bezerros')
  ) v(codigo, indicador, valor, numerador, denominador, unidade, formula)
$$;

-- =====================================================================
-- Permissões: só usuário logado chama a API; search_path fixo
-- =====================================================================
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname LIKE 'pec\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f.sig); END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pec'
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pec, public, extensions', f.sig);
  END LOOP;
END $$;
