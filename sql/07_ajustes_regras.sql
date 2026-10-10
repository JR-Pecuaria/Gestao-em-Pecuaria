-- 07 (Entrega 2): (a) saída de animais "sem pasto" passa a ser permitida (entrada continua exigindo pasto);
--                 (b) mudança de categoria com várias categorias no mesmo documento (desmama de machos e fêmeas juntos).
SET search_path = pec, public, extensions;
CREATE OR REPLACE FUNCTION pec.trg_movimento_antes() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  d   pec.documento%ROWTYPE;
  op  pec.tipo_operacao%ROWTYPE;
  c   pec.categoria%ROWTYPE;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    PERFORM pec.erro('MOV_IMUTAVEL', 'Movimentos do livro são imutáveis. Use "Corrigir" (estorno + novo lançamento).');
  END IF;

  SELECT * INTO d  FROM pec.documento     WHERE id = NEW.documento_id;
  SELECT * INTO op FROM pec.tipo_operacao WHERE codigo = d.operacao_codigo;
  SELECT * INTO c  FROM pec.categoria     WHERE id = NEW.categoria_id;

  NEW.data       := d.data;
  NEW.fazenda_id := d.fazenda_id;

  IF NEW.retiro_id IS NULL THEN
    PERFORM pec.erro('SEM_RETIRO', 'Informe o retiro.');
  END IF;
  IF NEW.quantidade IS NULL OR NEW.quantidade <= 0 THEN
    PERFORM pec.erro('QTD_INVALIDA', 'A quantidade precisa ser maior que zero (cabeças inteiras).');
  END IF;
  IF NEW.pasto_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pec.pasto WHERE id = NEW.pasto_id AND retiro_id = NEW.retiro_id) THEN
    PERFORM pec.erro('PASTO_FORA_DO_RETIRO', format('O pasto %s não pertence ao retiro %s. Confira o código no mapa.',
                     COALESCE((SELECT codigo FROM pec.pasto WHERE id = NEW.pasto_id), '(inexistente)'),
                     (SELECT nome FROM pec.retiro WHERE id = NEW.retiro_id)));
  END IF;
  IF NOT (NEW.sentido = ANY (op.sentido_permitido)) THEN
    PERFORM pec.erro('SENTIDO_INVALIDO', format('"%s" não admite %s.', op.nome, CASE NEW.sentido WHEN 1 THEN 'entrada' ELSE 'saída' END));
  END IF;
  -- Entrada sempre com pasto. Saída pode vir de "sem pasto" (gado importado sem pasto
  -- informado: distribuir com Transferência de Pasto, ou registrar morte/venda dele).
  IF NEW.pasto_id IS NULL AND d.origem <> 'IMPORTACAO' AND NEW.sentido = 1 AND NOT NEW.estorno THEN
    PERFORM pec.erro('SEM_PASTO', 'Informe o pasto de destino (código do mapa, ex.: Pla-3).');
  END IF;

  -- cadastros inativos (exceto em estorno, que precisa poder desfazer o passado)
  IF NOT NEW.estorno THEN
    IF c.status = 'INATIVO' THEN
      PERFORM pec.erro('CADASTRO_INATIVO', format('A categoria "%s" está inativa.', c.nome));
    END IF;
    IF EXISTS (SELECT 1 FROM pec.retiro WHERE id = NEW.retiro_id AND status = 'INATIVO') THEN
      PERFORM pec.erro('CADASTRO_INATIVO', 'O retiro está inativo.');
    END IF;
    IF NEW.pasto_id IS NOT NULL AND EXISTS (SELECT 1 FROM pec.pasto WHERE id = NEW.pasto_id AND status = 'INATIVO') THEN
      PERFORM pec.erro('CADASTRO_INATIVO', 'O pasto está inativo. Reative-o em Cadastros ou escolha outro.');
    END IF;
    IF NEW.lote_id IS NOT NULL AND EXISTS (SELECT 1 FROM pec.lote WHERE id = NEW.lote_id AND status = 'INATIVO') THEN
      PERFORM pec.erro('CADASTRO_INATIVO', 'O lote está inativo.');
    END IF;
  END IF;

  IF op.so_categoria_nascimento AND NOT c.permite_nascimento THEN
    PERFORM pec.erro('NASCIMENTO_CATEGORIA', format('Nascimento só pode ser lançado em bezerro (Bez. Macho / Bez. Fêmea), não em "%s".', c.nome));
  END IF;
  IF op.codigo = 'DESMAMA' AND NEW.sentido = -1 AND c.fase <> 'BEZERRO' THEN
    PERFORM pec.erro('DESMAMA_CATEGORIA', format('A desmama sai de bezerro mamando, não de "%s".', c.nome));
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION pec.validar_documento(p_doc uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  d  pec.documento%ROWTYPE;
  op pec.tipo_operacao%ROWTYPE;
  n_pernas int; soma int; n_ent int; n_sai int;
  r record;
BEGIN
  SELECT * INTO d  FROM pec.documento     WHERE id = p_doc;
  SELECT * INTO op FROM pec.tipo_operacao WHERE codigo = d.operacao_codigo;
  SELECT count(*), COALESCE(sum(efeito),0), count(*) FILTER (WHERE sentido=1), count(*) FILTER (WHERE sentido=-1)
    INTO n_pernas, soma, n_ent, n_sai
    FROM pec.movimento WHERE documento_id = p_doc;

  IF n_pernas = 0 THEN
    PERFORM pec.erro('DOC_SEM_MOVIMENTO', format('O lançamento nº %s não tem nenhuma linha de animais.', d.numero));
  END IF;

  IF op.partida_dobrada THEN
    IF n_ent = 0 OR n_sai = 0 THEN
      PERFORM pec.erro('TRANSF_INCOMPLETA', format('"%s" precisa de origem (saída) e destino (entrada).', op.nome));
    END IF;
    IF soma <> 0 THEN
      PERFORM pec.erro('TRANSF_DESBALANCEADA', format('"%s": saíram %s e entraram %s cabeças. As quantidades precisam bater.',
                       op.nome, -(SELECT sum(efeito) FROM pec.movimento WHERE documento_id=p_doc AND sentido=-1),
                       (SELECT sum(efeito) FROM pec.movimento WHERE documento_id=p_doc AND sentido=1)));
    END IF;
  END IF;

  IF op.muda_local AND NOT op.muda_categoria THEN
    -- categoria preservada (por categoria, Σ efeito = 0)
    IF EXISTS (SELECT 1 FROM pec.movimento WHERE documento_id = p_doc GROUP BY categoria_id HAVING sum(efeito) <> 0) THEN
      PERFORM pec.erro('TRANSF_CATEGORIA', 'Na transferência a categoria não muda. Para mudar de categoria use "Mudança de Era".');
    END IF;
    IF op.codigo = 'TRANSF_PASTO' THEN
      IF (SELECT count(DISTINCT retiro_id) FROM pec.movimento WHERE documento_id = p_doc) > 1 THEN
        PERFORM pec.erro('TRANSF_PASTO_RETIRO', 'Transferência de pasto é dentro do mesmo retiro. Entre retiros use "Transferência de Retiro".');
      END IF;
      IF EXISTS (SELECT 1 FROM pec.movimento s JOIN pec.movimento e
                   ON e.documento_id = s.documento_id AND e.sentido = 1 AND s.sentido = -1
                  WHERE s.documento_id = p_doc AND e.pasto_id IS NOT DISTINCT FROM s.pasto_id) THEN
        PERFORM pec.erro('TRANSF_MESMO_PASTO', 'Pasto de origem e destino são o mesmo.');
      END IF;
    ELSIF op.codigo = 'TRANSF_RETIRO' THEN
      IF EXISTS (SELECT 1 FROM pec.movimento s JOIN pec.movimento e
                   ON e.documento_id = s.documento_id AND e.sentido = 1 AND s.sentido = -1
                  WHERE s.documento_id = p_doc AND e.retiro_id = s.retiro_id) THEN
        PERFORM pec.erro('TRANSF_MESMO_RETIRO', 'Retiro de origem e destino são o mesmo. Dentro do retiro use "Transferência de Pasto".');
      END IF;
    ELSIF op.codigo = 'REFUGO_COCHO' THEN
      -- refugo de cocho: sai do Confinamento e volta para o pasto
      IF EXISTS (SELECT 1 FROM pec.movimento m JOIN pec.retiro rt ON rt.id = m.retiro_id
                  WHERE m.documento_id = p_doc AND m.sentido = -1 AND rt.tipo <> 'CONFINAMENTO') THEN
        PERFORM pec.erro('REFUGO_ORIGEM', 'Refugo de cocho sai do Confinamento. Para outras mudanças de local use Transferência de Retiro ou de Pasto.');
      END IF;
      IF EXISTS (SELECT 1 FROM pec.movimento m JOIN pec.retiro rt ON rt.id = m.retiro_id
                  WHERE m.documento_id = p_doc AND m.sentido = 1 AND rt.tipo = 'CONFINAMENTO') THEN
        PERFORM pec.erro('REFUGO_DESTINO', 'O refugo de cocho volta para um pasto, fora do Confinamento. Informe o pasto de destino.');
      END IF;
    END IF;
  END IF;

  IF op.muda_categoria THEN
    -- Um documento pode mudar várias categorias de uma vez (ex.: desmama de machos e
    -- fêmeas juntos). Cada categoria que sai precisa ter, no mesmo documento, uma
    -- categoria de chegada permitida (e vice-versa), e o sexo não muda.
    FOR r IN
      SELECT s.categoria_id AS de, NULL::uuid AS para FROM pec.movimento s
       WHERE s.documento_id = p_doc AND s.sentido = -1
         AND NOT EXISTS (SELECT 1 FROM pec.movimento e JOIN pec.categoria_transicao t
                           ON t.de_categoria_id = s.categoria_id AND t.para_categoria_id = e.categoria_id AND t.operacao_codigo = op.codigo
                          WHERE e.documento_id = p_doc AND e.sentido = 1)
      UNION ALL
      SELECT NULL, e.categoria_id FROM pec.movimento e
       WHERE e.documento_id = p_doc AND e.sentido = 1
         AND NOT EXISTS (SELECT 1 FROM pec.movimento s JOIN pec.categoria_transicao t
                           ON t.de_categoria_id = s.categoria_id AND t.para_categoria_id = e.categoria_id AND t.operacao_codigo = op.codigo
                          WHERE s.documento_id = p_doc AND s.sentido = -1)
      LIMIT 1
    LOOP
      PERFORM pec.erro('TRANSICAO_INVALIDA', format('%s: %s não é uma mudança permitida.', op.nome,
                       CASE WHEN r.de IS NOT NULL THEN format('sair de "%s" para %s', (SELECT nome FROM pec.categoria WHERE id = r.de),
                              COALESCE((SELECT string_agg(DISTINCT '"' || c.nome || '"', ', ') FROM pec.movimento e JOIN pec.categoria c ON c.id = e.categoria_id
                                         WHERE e.documento_id = p_doc AND e.sentido = 1), 'nenhuma categoria'))
                            ELSE format('chegar em "%s"', (SELECT nome FROM pec.categoria WHERE id = r.para)) END));
    END LOOP;
    IF EXISTS (SELECT 1 FROM pec.movimento m JOIN pec.categoria c ON c.id = m.categoria_id
                WHERE m.documento_id = p_doc GROUP BY c.sexo HAVING sum(m.efeito) <> 0) THEN
      PERFORM pec.erro('TRANSICAO_SEXO', format('%s: as quantidades de machos e de fêmeas que saem e chegam precisam bater.', op.nome));
    END IF;
  END IF;

  IF op.exige_peso AND d.origem <> 'IMPORTACAO'
     AND COALESCE(d.peso_total_kg, (SELECT sum(peso_kg) FROM pec.movimento WHERE documento_id = p_doc), 0) = 0 THEN
    PERFORM pec.erro('SEM_PESO', format('Informe o peso total (kg) em "%s".', op.nome));
  END IF;

  PERFORM pec.validar_estoque_documento(p_doc);
END $$;
ALTER FUNCTION pec.trg_movimento_antes() SET search_path = pec, public, extensions;
ALTER FUNCTION pec.validar_documento(uuid) SET search_path = pec, public, extensions;

-- (c) alerta de lotação com número no formato brasileiro (1,82 e não 1.820)
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
       CASE status WHEN 'ACIMA DA META' THEN format('%s (%s): %s UA/ha, acima da meta', pasto, retiro, replace(round(ua_ha, 2)::text, '.', ','))
                   ELSE format('%s (%s) tem animais e não tem área cadastrada', pasto, retiro) END, retiro_id, pasto_id, NULL, NULL
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
