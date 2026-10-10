-- =====================================================================
-- 02_regras.sql — Regras de negócio no banco (a última linha de defesa)
-- O app valida antes (mensagens amigáveis, offline); o banco garante.
-- =====================================================================
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- Utilitários
-- ---------------------------------------------------------------------
-- Usuário da sessão: Supabase (JWT) ou variável de sessão (scripts/testes)
CREATE OR REPLACE FUNCTION pec.usuario_atual() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid,
    NULLIF((NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid,
    NULLIF(current_setting('pec.usuario_id', true), '')::uuid)
$$;

CREATE OR REPLACE FUNCTION pec.param(p_fazenda uuid, p_chave text, p_padrao jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT valor FROM pec.parametro WHERE fazenda_id = p_fazenda AND chave = p_chave), p_padrao)
$$;

-- Fator de UA vigente na data (parâmetros com vigência)
CREATE OR REPLACE FUNCTION pec.fator_ua(p_categoria uuid, p_data date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT fator_ua FROM pec.categoria_parametro
   WHERE categoria_id = p_categoria AND vigente_desde <= p_data
   ORDER BY vigente_desde DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pec.meta_mortalidade(p_categoria uuid, p_data date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT meta_mortalidade FROM pec.categoria_parametro
   WHERE categoria_id = p_categoria AND vigente_desde <= p_data
   ORDER BY vigente_desde DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pec.safra_da_data(p_fazenda uuid, p_data date) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM pec.safra WHERE fazenda_id = p_fazenda AND p_data BETWEEN inicio AND fim LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pec.periodo_fechado(p_fazenda uuid, p_data date) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pec.periodo
                  WHERE fazenda_id = p_fazenda
                    AND competencia = date_trunc('month', p_data)::date
                    AND status = 'FECHADO')
$$;

CREATE OR REPLACE FUNCTION pec.tem_permissao(p_fazenda uuid, p_permissao text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pec, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM pec.usuario_acesso ua
      JOIN pec.papel_permissao pp ON pp.papel_codigo = ua.papel_codigo
     WHERE ua.usuario_id = pec.usuario_atual()
       AND ua.fazenda_id = p_fazenda
       AND pp.permissao_codigo = p_permissao)
$$;

-- Erro padronizado: código + mensagem orientada à ação
CREATE OR REPLACE FUNCTION pec.erro(p_codigo text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%', p_msg USING ERRCODE = 'P0001', HINT = p_codigo;
END $$;

-- ---------------------------------------------------------------------
-- DOCUMENTO: validações de cabeçalho, safra automática, período fechado
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.trg_documento_antes() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  op pec.tipo_operacao%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM pec.erro('DOC_SEM_EXCLUSAO', 'Lançamentos não podem ser excluídos. Use "Estornar" — o histórico fica preservado.');
  END IF;

  SELECT * INTO op FROM pec.tipo_operacao WHERE codigo = NEW.operacao_codigo;
  IF NOT FOUND OR NOT op.ativo THEN
    PERFORM pec.erro('OPERACAO_INVALIDA', format('Tipo de movimentação "%s" não existe ou está inativo.', NEW.operacao_codigo));
  END IF;

  IF NEW.data IS NULL THEN
    PERFORM pec.erro('SEM_DATA', 'Informe a data da movimentação.');
  END IF;
  IF NEW.data > current_date + 1 THEN
    PERFORM pec.erro('DATA_FUTURA', format('A data %s está no futuro. Confira o dia e o mês.', to_char(NEW.data,'DD/MM/YYYY')));
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- campos que mexem em estoque/indicadores são imutáveis: corrija com estorno
    IF (NEW.fazenda_id, NEW.operacao_codigo, NEW.data) IS DISTINCT FROM (OLD.fazenda_id, OLD.operacao_codigo, OLD.data) THEN
      PERFORM pec.erro('DOC_IMUTAVEL', 'Data, fazenda e tipo não podem ser alterados. Estorne o lançamento e lance de novo.');
    END IF;
    IF pec.periodo_fechado(NEW.fazenda_id, NEW.data)
       AND (NEW.causa_morte_id, NEW.canal_venda_id, NEW.peso_total_kg, NEW.valor_total, NEW.parceiro_id)
           IS DISTINCT FROM (OLD.causa_morte_id, OLD.canal_venda_id, OLD.peso_total_kg, OLD.valor_total, OLD.parceiro_id)
       AND NOT pec.tem_permissao(NEW.fazenda_id, 'PERIODO_EDITAR_FECHADO') THEN
      PERFORM pec.erro('PERIODO_FECHADO', format('O mês %s está fechado. Peça ao administrador para reabrir.', to_char(NEW.data,'MM/YYYY')));
    END IF;
  ELSE
    IF pec.periodo_fechado(NEW.fazenda_id, NEW.data) THEN
      PERFORM pec.erro('PERIODO_FECHADO', format('O mês %s está fechado. Lance com data do mês aberto ou peça reabertura.', to_char(NEW.data,'MM/YYYY')));
    END IF;
  END IF;

  IF op.exige_causa AND NEW.causa_morte_id IS NULL THEN
    PERFORM pec.erro('MORTE_SEM_CAUSA', 'Informe a causa da morte (use "Não identificada" se não souber).');
  END IF;
  IF op.exige_canal AND NEW.canal_venda_id IS NULL THEN
    PERFORM pec.erro('VENDA_SEM_CANAL', 'Informe o canal de venda (Leilão, Frigorífico, Venda Direta...).');
  END IF;
  IF op.exige_parceiro AND NEW.parceiro_id IS NULL AND NEW.origem <> 'IMPORTACAO' THEN
    PERFORM pec.erro('SEM_PARCEIRO', 'Informe o comprador/fornecedor.');
  END IF;

  NEW.safra_id := COALESCE(NEW.safra_id, pec.safra_da_data(NEW.fazenda_id, NEW.data));
  NEW.criado_por := COALESCE(NEW.criado_por, pec.usuario_atual());
  RETURN NEW;
END $$;

CREATE TRIGGER documento_antes
  BEFORE INSERT OR UPDATE OR DELETE ON pec.documento
  FOR EACH ROW EXECUTE FUNCTION pec.trg_documento_antes();

-- ---------------------------------------------------------------------
-- MOVIMENTO (perna): validações linha a linha
-- ---------------------------------------------------------------------
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
  IF NEW.pasto_id IS NULL AND d.origem <> 'IMPORTACAO' THEN
    PERFORM pec.erro('SEM_PASTO', 'Informe o pasto (código do mapa, ex.: Pla-3).');
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

CREATE TRIGGER movimento_antes
  BEFORE INSERT OR UPDATE OR DELETE ON pec.movimento
  FOR EACH ROW EXECUTE FUNCTION pec.trg_movimento_antes();

-- ---------------------------------------------------------------------
-- Integridade do DOCUMENTO inteiro (roda no COMMIT — todas as pernas já existem)
--  • partida dobrada: Σ efeito = 0, com saída e entrada
--  • transferência: categoria preservada; pasto→pasto no mesmo retiro; retiro→retiro diferente
--  • era/desmama: pares de categoria permitidos em categoria_transicao
--  • peso obrigatório (venda/desmama), estoque negativo
-- ---------------------------------------------------------------------
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
    FOR r IN
      SELECT DISTINCT s.categoria_id AS de, e.categoria_id AS para
        FROM pec.movimento s JOIN pec.movimento e ON e.documento_id = s.documento_id AND e.sentido = 1
       WHERE s.documento_id = p_doc AND s.sentido = -1
    LOOP
      IF NOT EXISTS (SELECT 1 FROM pec.categoria_transicao t
                      WHERE t.de_categoria_id = r.de AND t.para_categoria_id = r.para AND t.operacao_codigo = op.codigo) THEN
        PERFORM pec.erro('TRANSICAO_INVALIDA', format('%s: "%s" → "%s" não é uma mudança permitida.', op.nome,
                         (SELECT nome FROM pec.categoria WHERE id = r.de), (SELECT nome FROM pec.categoria WHERE id = r.para)));
      END IF;
    END LOOP;
  END IF;

  IF op.exige_peso AND d.origem <> 'IMPORTACAO'
     AND COALESCE(d.peso_total_kg, (SELECT sum(peso_kg) FROM pec.movimento WHERE documento_id = p_doc), 0) = 0 THEN
    PERFORM pec.erro('SEM_PESO', format('Informe o peso total (kg) em "%s".', op.nome));
  END IF;

  PERFORM pec.validar_estoque_documento(p_doc);
END $$;

-- Estoque negativo: verifica o saldo ACUMULADO no tempo de cada chave tocada
-- (fazenda × retiro × pasto × categoria). Política por fazenda: BLOQUEAR | ALERTAR.
CREATE OR REPLACE FUNCTION pec.validar_estoque_documento(p_doc uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_faz uuid; v_pol text; r record;
BEGIN
  SELECT fazenda_id INTO v_faz FROM pec.documento WHERE id = p_doc;
  v_pol := COALESCE(pec.param(v_faz, 'ESTOQUE_NEGATIVO') #>> '{}', 'BLOQUEAR');
  IF v_pol <> 'BLOQUEAR' THEN RETURN; END IF;

  FOR r IN
    WITH chaves AS (SELECT DISTINCT retiro_id, pasto_id, categoria_id FROM pec.movimento WHERE documento_id = p_doc),
    saldo AS (
      SELECT m.retiro_id, m.pasto_id, m.categoria_id, m.data,
             sum(sum(m.efeito)) OVER (PARTITION BY m.retiro_id, m.pasto_id, m.categoria_id ORDER BY m.data) AS saldo
        FROM pec.movimento m JOIN chaves k
          ON k.retiro_id = m.retiro_id AND k.pasto_id IS NOT DISTINCT FROM m.pasto_id AND k.categoria_id = m.categoria_id
       WHERE m.fazenda_id = v_faz
       GROUP BY m.retiro_id, m.pasto_id, m.categoria_id, m.data)
    SELECT s.*, c.nome AS cat, p.codigo AS pasto FROM saldo s
      JOIN pec.categoria c ON c.id = s.categoria_id
      LEFT JOIN pec.pasto p ON p.id = s.pasto_id
     WHERE s.saldo < 0 ORDER BY s.data LIMIT 1
  LOOP
    PERFORM pec.erro('ESTOQUE_NEGATIVO', format('Estoque ficaria negativo: %s em %s no dia %s (saldo %s). Confira a quantidade ou lance antes a entrada que falta.',
                     r.cat, COALESCE(r.pasto,'(sem pasto)'), to_char(r.data,'DD/MM/YYYY'), r.saldo));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pec.trg_movimento_depois() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pec.validar_documento(NEW.documento_id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER movimento_documento_valido
  AFTER INSERT ON pec.movimento
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION pec.trg_movimento_depois();

-- ---------------------------------------------------------------------
-- ESTORNO: nunca apaga; cria documento-espelho que anula o original
-- Data do estorno = data original se o mês estiver aberto; senão, hoje.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.estornar_documento(p_doc uuid, p_motivo text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  d pec.documento%ROWTYPE; v_novo uuid := gen_random_uuid(); v_data date;
BEGIN
  SELECT * INTO d FROM pec.documento WHERE id = p_doc FOR UPDATE;
  IF d.status <> 'ATIVO' THEN
    PERFORM pec.erro('ESTORNO_INVALIDO', format('O lançamento nº %s já está %s.', d.numero, lower(d.status::text)));
  END IF;
  IF COALESCE(trim(p_motivo),'') = '' THEN
    PERFORM pec.erro('ESTORNO_SEM_MOTIVO', 'Informe o motivo do estorno.');
  END IF;
  v_data := CASE WHEN pec.periodo_fechado(d.fazenda_id, d.data) THEN current_date ELSE d.data END;

  INSERT INTO pec.documento (id, fazenda_id, operacao_codigo, data, causa_morte_id, canal_venda_id, parceiro_id,
                             peso_total_kg, valor_total, observacao, status, estorna_documento_id, origem)
  VALUES (v_novo, d.fazenda_id, d.operacao_codigo, v_data, d.causa_morte_id, d.canal_venda_id, d.parceiro_id,
          d.peso_total_kg, d.valor_total, 'ESTORNO do nº '||d.numero||': '||p_motivo, 'ESTORNO', d.id, 'SISTEMA');

  INSERT INTO pec.movimento (documento_id, sentido, fazenda_id, retiro_id, pasto_id, lote_id, categoria_id, raca_id,
                             animal_id, quantidade, peso_kg, data, estorno)
  SELECT v_novo, sentido, fazenda_id, retiro_id, pasto_id, lote_id, categoria_id, raca_id,
         animal_id, quantidade, peso_kg, v_data, true
    FROM pec.movimento WHERE documento_id = p_doc;

  UPDATE pec.documento SET status = 'ESTORNADO' WHERE id = p_doc;
  INSERT INTO pec.auditoria (usuario_id, tabela, registro_id, acao, valor_anterior, contexto)
  VALUES (pec.usuario_atual(), 'documento', p_doc::text, 'ESTORNO', to_jsonb(d), jsonb_build_object('motivo', p_motivo, 'estorno_id', v_novo));
  RETURN v_novo;
END $$;

-- ---------------------------------------------------------------------
-- FECHAMENTO / REABERTURA DE MÊS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.fechar_periodo(p_fazenda uuid, p_competencia date, p_forcar boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_comp date := date_trunc('month', p_competencia)::date;
  v_fim  date := (date_trunc('month', p_competencia) + interval '1 month - 1 day')::date;
  v_bloq jsonb; v_snap jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM pec.periodo WHERE fazenda_id = p_fazenda AND competencia < v_comp AND status <> 'FECHADO')
     AND EXISTS (SELECT 1 FROM pec.documento WHERE fazenda_id = p_fazenda AND data < v_comp) THEN
    PERFORM pec.erro('FECHAMENTO_FORA_ORDEM', 'Feche primeiro os meses anteriores.');
  END IF;

  -- Checklist: alertas CRÍTICOS do mês impedem o fechamento (salvo p_forcar com permissão)
  SELECT COALESCE(jsonb_agg(to_jsonb(a)), '[]') INTO v_bloq
    FROM pec.v_alertas a
   WHERE a.fazenda_id = p_fazenda AND a.nivel = 'CRITICO' AND (a.data IS NULL OR a.data <= v_fim);
  IF jsonb_array_length(v_bloq) > 0 AND NOT p_forcar THEN
    RETURN jsonb_build_object('fechado', false, 'motivo', 'Há alertas críticos', 'alertas', v_bloq);
  END IF;

  SELECT jsonb_agg(to_jsonb(f)) INTO v_snap FROM pec.fn_fechamento(p_fazenda, v_comp) f;

  INSERT INTO pec.periodo (fazenda_id, competencia, status, fechado_por, fechado_em, snapshot)
  VALUES (p_fazenda, v_comp, 'FECHADO', pec.usuario_atual(), now(), v_snap)
  ON CONFLICT (fazenda_id, competencia) DO UPDATE
     SET status = 'FECHADO', fechado_por = EXCLUDED.fechado_por, fechado_em = now(), snapshot = EXCLUDED.snapshot;

  INSERT INTO pec.auditoria (usuario_id, tabela, registro_id, acao, valor_novo)
  VALUES (pec.usuario_atual(), 'periodo', p_fazenda||'/'||v_comp, 'FECHAMENTO', jsonb_build_object('forcado', p_forcar, 'alertas', v_bloq));
  RETURN jsonb_build_object('fechado', true, 'competencia', v_comp, 'retiros', jsonb_array_length(v_snap));
END $$;

CREATE OR REPLACE FUNCTION pec.reabrir_periodo(p_fazenda uuid, p_competencia date, p_motivo text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(trim(p_motivo),'') = '' THEN PERFORM pec.erro('SEM_MOTIVO','Informe o motivo da reabertura.'); END IF;
  UPDATE pec.periodo SET status = 'ABERTO', reaberto_por = pec.usuario_atual(), reaberto_em = now(), motivo_reabertura = p_motivo
   WHERE fazenda_id = p_fazenda AND competencia = date_trunc('month', p_competencia)::date;
  INSERT INTO pec.auditoria (usuario_id, tabela, registro_id, acao, contexto)
  VALUES (pec.usuario_atual(), 'periodo', p_fazenda||'/'||date_trunc('month', p_competencia)::date, 'REABERTURA', jsonb_build_object('motivo', p_motivo));
END $$;

-- ---------------------------------------------------------------------
-- AUDITORIA genérica (valor anterior × valor novo)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.trg_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pec.auditoria (usuario_id, tabela, registro_id, acao, valor_anterior, valor_novo)
  VALUES (pec.usuario_atual(), TG_TABLE_NAME,
          COALESCE((CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END)->>'id', '?'),
          TG_OP,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['documento','movimento','fazenda','retiro','pasto','lote','animal','categoria',
                           'categoria_parametro','tipo_operacao','parametro','safra','lote_reprodutivo','iatf_rodada',
                           'diagnostico_final','parto','desmama_registro','inventario','inventario_item','pendencia',
                           'usuario_acesso','causa_morte','canal_venda','raca']
  LOOP
    EXECUTE format('CREATE TRIGGER %I_audit AFTER INSERT OR UPDATE OR DELETE ON pec.%I FOR EACH ROW EXECUTE FUNCTION pec.trg_auditoria()', t, t);
  END LOOP;
END $$;

-- Auditoria é somente-leitura
CREATE OR REPLACE FUNCTION pec.trg_bloqueia() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM pec.erro('SOMENTE_LEITURA', 'Registro de auditoria não pode ser alterado nem excluído.'); RETURN NULL; END $$;
CREATE TRIGGER auditoria_imutavel BEFORE UPDATE OR DELETE ON pec.auditoria FOR EACH ROW EXECUTE FUNCTION pec.trg_bloqueia();

-- ---------------------------------------------------------------------
-- INVENTÁRIO: emitir Mapão (fotografia) e gerar ajustes das divergências
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pec.emitir_inventario(p_retiro uuid, p_competencia date) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_faz uuid; v_fim date := (date_trunc('month', p_competencia) + interval '1 month - 1 day')::date;
BEGIN
  SELECT fazenda_id INTO v_faz FROM pec.retiro WHERE id = p_retiro;
  INSERT INTO pec.inventario (fazenda_id, retiro_id, competencia, data_posicao)
  VALUES (v_faz, p_retiro, date_trunc('month', p_competencia)::date, v_fim) RETURNING id INTO v_id;
  INSERT INTO pec.inventario_item (inventario_id, pasto_id, categoria_id, qtd_sistema)
  SELECT v_id, s.pasto_id, s.categoria_id, s.cabecas
    FROM pec.fn_estoque(v_faz, v_fim) s
   WHERE s.retiro_id = p_retiro AND s.cabecas <> 0;
  RETURN v_id;
END $$;

-- Classificação da divergência (limites parametrizáveis por fazenda)
CREATE OR REPLACE FUNCTION pec.classificar_divergencia(p_fazenda uuid, p_sistema int, p_campo int) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_campo IS NULL THEN 'NAO_CONTADO'
    WHEN p_campo = p_sistema THEN 'OK'
    WHEN abs(p_campo - p_sistema) <= COALESCE((pec.param(p_fazenda,'DIV_BAIXA_CAB') #>> '{}')::int, 2)
      OR abs(p_campo - p_sistema)::numeric / NULLIF(p_sistema,0) <= COALESCE((pec.param(p_fazenda,'DIV_BAIXA_PCT') #>> '{}')::numeric, 0.02)
      THEN 'BAIXA'
    WHEN abs(p_campo - p_sistema)::numeric / NULLIF(p_sistema,0) <= COALESCE((pec.param(p_fazenda,'DIV_MEDIA_PCT') #>> '{}')::numeric, 0.05)
      THEN 'MEDIA'
    ELSE 'ALTA' END
$$;

-- Fecha a contagem: divergências viram pendências; ajustes só com aprovação (gerar_ajustes)
CREATE OR REPLACE FUNCTION pec.concluir_contagem(p_inventario uuid) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v int := 0; i record; inv pec.inventario%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_inventario;
  FOR i IN SELECT ii.*, c.nome cat, p.codigo pasto,
                  pec.classificar_divergencia(inv.fazenda_id, ii.qtd_sistema, ii.qtd_campo) AS classe
             FROM pec.inventario_item ii JOIN pec.categoria c ON c.id = ii.categoria_id
             LEFT JOIN pec.pasto p ON p.id = ii.pasto_id
            WHERE ii.inventario_id = p_inventario AND ii.qtd_campo IS NOT NULL AND ii.diferenca <> 0
  LOOP
    INSERT INTO pec.pendencia (fazenda_id, origem, referencia_tabela, referencia_id, titulo, descricao, acao_recomendada,
                               retiro_id, pasto_id, prioridade)
    VALUES (inv.fazenda_id, 'INVENTARIO', 'inventario', p_inventario,
            format('Divergência %s: %s em %s', i.classe, i.cat, COALESCE(i.pasto,'SEM PASTO')),
            format('Sistema %s × campo %s (diferença %s).', i.qtd_sistema, i.qtd_campo, i.diferenca),
            'Procurar lançamento faltante (morte, nascimento, transferência). Se não houver, aprovar Ajuste de Inventário.',
            inv.retiro_id, i.pasto_id,
            CASE i.classe WHEN 'ALTA' THEN 'ALTA' WHEN 'MEDIA' THEN 'MEDIA' ELSE 'BAIXA' END::pec.prioridade_t);
    v := v + 1;
  END LOOP;
  UPDATE pec.inventario SET status = 'CONTADO' WHERE id = p_inventario;
  RETURN v;
END $$;

-- Aprovação do ajuste: cada divergência vira um lançamento AJUSTE_INVENTARIO (rastreável ao item contado)
CREATE OR REPLACE FUNCTION pec.aprovar_ajustes_inventario(p_inventario uuid, p_motivo text DEFAULT 'Conferência de campo') RETURNS int
LANGUAGE plpgsql AS $$
DECLARE inv pec.inventario%ROWTYPE; i record; v_doc uuid; n int := 0;
BEGIN
  SELECT * INTO inv FROM pec.inventario WHERE id = p_inventario;
  IF inv.status NOT IN ('CONTADO') THEN PERFORM pec.erro('INV_STATUS', 'Conclua a contagem antes de aprovar ajustes.'); END IF;
  FOR i IN SELECT * FROM pec.inventario_item WHERE inventario_id = p_inventario AND diferenca <> 0 AND documento_ajuste_id IS NULL
  LOOP
    v_doc := gen_random_uuid();
    INSERT INTO pec.documento (id, fazenda_id, operacao_codigo, data, observacao, origem)
    VALUES (v_doc, inv.fazenda_id, 'AJUSTE_INVENTARIO',
            CASE WHEN pec.periodo_fechado(inv.fazenda_id, inv.data_posicao) THEN current_date ELSE inv.data_posicao END,
            format('%s — Mapão %s (sistema %s × campo %s)', p_motivo, to_char(inv.competencia,'MM/YYYY'), i.qtd_sistema, i.qtd_campo), 'SISTEMA');
    INSERT INTO pec.movimento (documento_id, sentido, fazenda_id, retiro_id, pasto_id, categoria_id, quantidade, data)
    VALUES (v_doc, sign(i.diferenca)::smallint, inv.fazenda_id, inv.retiro_id, i.pasto_id, i.categoria_id, abs(i.diferenca), inv.data_posicao);
    UPDATE pec.inventario_item SET documento_ajuste_id = v_doc
     WHERE inventario_id = p_inventario AND pasto_id IS NOT DISTINCT FROM i.pasto_id AND categoria_id = i.categoria_id;
    n := n + 1;
  END LOOP;
  UPDATE pec.inventario SET status = 'AJUSTADO' WHERE id = p_inventario;
  UPDATE pec.pendencia SET status = 'RESOLVIDA', resolucao = 'Ajuste de inventário aprovado', resolvida_em = now()
   WHERE referencia_tabela = 'inventario' AND referencia_id = p_inventario AND status IN ('ABERTA','EM_ANDAMENTO');
  RETURN n;
END $$;
