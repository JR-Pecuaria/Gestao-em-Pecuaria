-- =====================================================================
-- 06_api.sql — Camada de API para o app (Entrega 2)
--
-- O esquema pec NÃO é exposto na internet. O app só enxerga estas funções
-- public.pec_*: cada uma confere login, perfil e retiro antes de agir, e
-- toda escrita passa pelas mesmas regras do livro (02_regras.sql).
-- =====================================================================
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- Convites: quem pode entrar (o administrador cria o usuário no painel
-- do Supabase e o e-mail precisa estar aqui — mesmo modelo do Calendário IATF)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pec.convite (
  email         text PRIMARY KEY CHECK (email = lower(email)),
  nome          text NOT NULL,
  fazenda_id    uuid NOT NULL REFERENCES pec.fazenda,
  papel_codigo  text NOT NULL REFERENCES pec.papel,
  retiro_ids    uuid[],
  criado_em     timestamptz NOT NULL DEFAULT now(),
  aceito_em     timestamptz
);
ALTER TABLE pec.convite ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION pec.email_atual() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT lower(COALESCE(
    NULLIF(current_setting('request.jwt.claim.email', true), ''),
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))
$$;

-- fazenda do usuário logado (o sistema é de uma fazenda; o modelo aceita várias)
CREATE OR REPLACE FUNCTION pec.fazenda_atual() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT fazenda_id FROM pec.usuario_acesso WHERE usuario_id = pec.usuario_atual() ORDER BY fazenda_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pec.exigir(p_permissao text) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v_faz uuid := pec.fazenda_atual();
BEGIN
  IF pec.usuario_atual() IS NULL THEN
    PERFORM pec.erro('NAO_AUTENTICADO', 'Sua sessão expirou. Entre de novo.');
  END IF;
  IF v_faz IS NULL THEN
    PERFORM pec.erro('SEM_ACESSO', 'Seu usuário ainda não tem acesso a nenhuma fazenda. Fale com o administrador.');
  END IF;
  IF p_permissao IS NOT NULL AND NOT pec.tem_permissao(v_faz, p_permissao) THEN
    PERFORM pec.erro('SEM_PERMISSAO', 'Seu perfil não permite esta ação. Fale com o administrador.');
  END IF;
  RETURN v_faz;
END $$;

CREATE OR REPLACE FUNCTION pec.retiros_do_usuario() RETURNS uuid[]
LANGUAGE sql STABLE AS $$
  SELECT retiro_ids FROM pec.usuario_acesso WHERE usuario_id = pec.usuario_atual() AND fazenda_id = pec.fazenda_atual()
$$;

CREATE OR REPLACE FUNCTION pec.retiro_liberado(p_retiro uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT pec.retiros_do_usuario() IS NULL OR p_retiro = ANY (pec.retiros_do_usuario())
$$;

-- ---------------------------------------------------------------------
-- SESSÃO: primeiro acesso vincula o login ao convite; depois devolve o perfil
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_sessao() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE
  v_uid uuid := pec.usuario_atual(); v_email text := pec.email_atual();
  c pec.convite%ROWTYPE; v_faz uuid; v_papel text;
BEGIN
  IF v_uid IS NULL THEN PERFORM pec.erro('NAO_AUTENTICADO', 'Entre com seu e-mail e senha.'); END IF;

  IF NOT EXISTS (SELECT 1 FROM pec.usuario WHERE id = v_uid) THEN
    SELECT * INTO c FROM pec.convite WHERE email = v_email;
    IF NOT FOUND THEN
      PERFORM pec.erro('SEM_ACESSO', format('O e-mail %s não está autorizado neste sistema. Peça acesso ao administrador.', COALESCE(v_email,'(sem e-mail)')));
    END IF;
    INSERT INTO pec.usuario (id, organizacao_id, nome, email)
    SELECT v_uid, f.organizacao_id, c.nome, c.email FROM pec.fazenda f WHERE f.id = c.fazenda_id;
    INSERT INTO pec.usuario_acesso (usuario_id, fazenda_id, papel_codigo, retiro_ids)
    VALUES (v_uid, c.fazenda_id, c.papel_codigo, c.retiro_ids);
    UPDATE pec.convite SET aceito_em = now() WHERE email = c.email;
  END IF;

  IF EXISTS (SELECT 1 FROM pec.usuario WHERE id = v_uid AND status = 'INATIVO') THEN
    PERFORM pec.erro('SEM_ACESSO', 'Seu usuário está desativado. Fale com o administrador.');
  END IF;

  v_faz := pec.fazenda_atual();
  SELECT papel_codigo INTO v_papel FROM pec.usuario_acesso WHERE usuario_id = v_uid AND fazenda_id = v_faz;

  RETURN jsonb_build_object(
    'usuario',    (SELECT jsonb_build_object('id', id, 'nome', nome, 'email', email) FROM pec.usuario WHERE id = v_uid),
    'papel',      (SELECT jsonb_build_object('codigo', codigo, 'nome', nome) FROM pec.papel WHERE codigo = v_papel),
    'permissoes', (SELECT COALESCE(jsonb_agg(permissao_codigo ORDER BY permissao_codigo), '[]') FROM pec.papel_permissao WHERE papel_codigo = v_papel),
    'fazenda',    (SELECT jsonb_build_object('id', id, 'nome', nome, 'municipio', municipio, 'uf', uf) FROM pec.fazenda WHERE id = v_faz),
    'retiros_permitidos', to_jsonb(pec.retiros_do_usuario()),
    'safra',      (SELECT jsonb_build_object('id', id, 'nome', nome, 'inicio', inicio, 'fim', fim) FROM pec.safra
                    WHERE fazenda_id = v_faz AND current_date BETWEEN inicio AND fim),
    'hoje',       current_date);
END $$;

-- ---------------------------------------------------------------------
-- CADASTROS de uma vez (o app guarda no aparelho para funcionar offline)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_cadastros() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir(NULL); v_org uuid;
BEGIN
  SELECT organizacao_id INTO v_org FROM pec.fazenda WHERE id = v_faz;
  RETURN jsonb_build_object(
    'fazenda', (SELECT to_jsonb(f) - 'criado_em' FROM pec.fazenda f WHERE id = v_faz),
    'retiros', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'nome', r.nome, 'sigla', r.sigla, 'tipo', r.tipo,
                  'area_informada_ha', r.area_informada_ha, 'status', r.status, 'ordem', r.ordem,
                  'liberado', pec.retiro_liberado(r.id)) ORDER BY r.ordem), '[]')
                FROM pec.retiro r WHERE r.fazenda_id = v_faz),
    'pastos',  (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'retiro_id', p.retiro_id, 'codigo', p.codigo, 'area_ha', p.area_ha,
                  'status', p.status, 'generico', p.generico, 'observacao', p.observacao,
                  'lotacao_min_ua_ha', p.lotacao_min_ua_ha, 'lotacao_max_ua_ha', p.lotacao_max_ua_ha)
                  ORDER BY p.retiro_id, length(p.codigo), p.codigo), '[]')
                FROM pec.pasto p WHERE p.fazenda_id = v_faz),
    'lotes',   (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', l.id, 'retiro_id', l.retiro_id, 'codigo', l.codigo,
                  'descricao', l.descricao, 'carimbo', l.carimbo, 'status', l.status) ORDER BY l.codigo), '[]')
                FROM pec.lote l WHERE l.fazenda_id = v_faz),
    'categorias', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'sexo', c.sexo, 'fase', c.fase,
                  'permite_nascimento', c.permite_nascimento, 'eh_matriz', c.eh_matriz, 'grupo', c.grupo_dashboard,
                  'ordem', c.ordem, 'status', c.status, 'fator_ua', pec.fator_ua(c.id, current_date)) ORDER BY c.ordem), '[]')
                FROM pec.categoria c WHERE c.organizacao_id = v_org),
    'transicoes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('de', t.de_categoria_id, 'para', t.para_categoria_id,
                  'operacao', t.operacao_codigo, 'gatilho', t.gatilho)), '[]') FROM pec.categoria_transicao t
                  JOIN pec.categoria c ON c.id = t.de_categoria_id WHERE c.organizacao_id = v_org),
    'racas',   (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) ORDER BY nome), '[]') FROM pec.raca WHERE organizacao_id = v_org AND status = 'ATIVO'),
    'causas',  (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'grupo', grupo) ORDER BY nome), '[]') FROM pec.causa_morte WHERE organizacao_id = v_org AND status = 'ATIVO'),
    'canais',  (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) ORDER BY nome), '[]') FROM pec.canal_venda WHERE organizacao_id = v_org AND status = 'ATIVO'),
    'parceiros', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'tipo', tipo, 'documento', documento,
                  'municipio', municipio, 'uf', uf, 'status', status) ORDER BY nome), '[]') FROM pec.parceiro WHERE organizacao_id = v_org),
    'colaboradores', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao, 'status', status) ORDER BY nome), '[]')
                  FROM pec.colaborador WHERE organizacao_id = v_org),
    'operacoes', (SELECT jsonb_agg(to_jsonb(o) ORDER BY o.ordem) FROM pec.tipo_operacao o WHERE o.ativo),
    'parametros', (SELECT COALESCE(jsonb_object_agg(chave, valor), '{}') FROM pec.parametro WHERE fazenda_id = v_faz),
    'periodos_fechados', (SELECT COALESCE(jsonb_agg(competencia ORDER BY competencia), '[]') FROM pec.periodo WHERE fazenda_id = v_faz AND status = 'FECHADO'),
    'gerado_em', now());
END $$;

-- ---------------------------------------------------------------------
-- ESTOQUE numa data (só os retiros que o usuário enxerga)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_estoque(p_data date DEFAULT current_date)
RETURNS TABLE (retiro_id uuid, pasto_id uuid, lote_id uuid, categoria_id uuid, raca_id uuid, cabecas bigint, ua numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER');
BEGIN
  RETURN QUERY SELECT e.* FROM pec.fn_estoque(v_faz, p_data) e WHERE pec.retiro_liberado(e.retiro_id);
END $$;

-- ---------------------------------------------------------------------
-- LANÇAR: um fato de negócio com suas pernas, numa transação só.
-- Idempotente: o app gera o id no aparelho; reenviar o mesmo id não duplica.
-- ---------------------------------------------------------------------
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
  IF v_origem = 'IMPORTACAO' THEN v_origem := 'APP'; END IF;   -- importação só pelo importador
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
  -- valores em R$ só para quem tem permissão financeira (os demais lançam sem valor; o escritório completa)
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

  SET CONSTRAINTS ALL IMMEDIATE;     -- valida o documento inteiro agora (partida dobrada, estoque, peso...)
  SET CONSTRAINTS ALL DEFERRED;      -- volta ao normal (várias chamadas na mesma transação)
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'pernas', n, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- ESTORNAR
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_estornar(p_documento uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('MOV_ESTORNAR'); v_novo uuid; v_num bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pec.documento WHERE id = p_documento AND fazenda_id = v_faz) THEN
    PERFORM pec.erro('NAO_ENCONTRADO', 'Lançamento não encontrado.');
  END IF;
  IF EXISTS (SELECT 1 FROM pec.movimento WHERE documento_id = p_documento AND NOT pec.retiro_liberado(retiro_id)) THEN
    PERFORM pec.erro('RETIRO_NAO_LIBERADO', 'Você não tem acesso a um dos retiros deste lançamento.');
  END IF;
  v_novo := pec.estornar_documento(p_documento, p_motivo);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT numero INTO v_num FROM pec.documento WHERE id = v_novo;
  RETURN jsonb_build_object('ok', true, 'estorno_id', v_novo, 'numero', v_num);
END $$;

-- ---------------------------------------------------------------------
-- LIVRO: lançamentos com suas pernas, do mais novo para o mais antigo
-- filtros: operacao, retiro_id, de, ate, busca, limite
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_livro(p jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER'); v_fin boolean;
BEGIN
  v_fin := pec.tem_permissao(v_faz, 'MOV_FINANCEIRO');
  RETURN (
    SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'numero')::bigint DESC), '[]') FROM (
      SELECT jsonb_build_object(
        'id', d.id, 'numero', d.numero, 'data', d.data, 'operacao', d.operacao_codigo, 'status', d.status,
        'estorna_numero', (SELECT e.numero FROM pec.documento e WHERE e.id = d.estorna_documento_id),
        'estornado_por', (SELECT e.numero FROM pec.documento e WHERE e.estorna_documento_id = d.id),
        'causa_morte_id', d.causa_morte_id, 'canal_venda_id', d.canal_venda_id,
        'parceiro', (SELECT nome FROM pec.parceiro WHERE id = d.parceiro_id),
        'peso_total_kg', d.peso_total_kg, 'valor_total', CASE WHEN v_fin THEN d.valor_total END,
        'observacao', d.observacao, 'origem', d.origem, 'linha_origem', d.linha_origem,
        'criado_por', (SELECT nome FROM pec.usuario WHERE id = d.criado_por), 'criado_em', d.criado_em,
        'pernas', (SELECT jsonb_agg(jsonb_build_object('sentido', m.sentido, 'estorno', m.estorno, 'retiro_id', m.retiro_id,
                     'pasto_id', m.pasto_id, 'lote_id', m.lote_id, 'categoria_id', m.categoria_id, 'raca_id', m.raca_id,
                     'quantidade', m.quantidade, 'peso_kg', m.peso_kg) ORDER BY m.sentido)
                   FROM pec.movimento m WHERE m.documento_id = d.id)) AS x
        FROM pec.documento d
       WHERE d.fazenda_id = v_faz
         AND (p->>'operacao' IS NULL OR d.operacao_codigo = p->>'operacao')
         AND (p->>'de'  IS NULL OR d.data >= (p->>'de')::date)
         AND (p->>'ate' IS NULL OR d.data <= (p->>'ate')::date)
         AND (p->>'busca' IS NULL OR d.observacao ILIKE '%'||(p->>'busca')||'%' OR d.numero::text = p->>'busca')
         AND EXISTS (SELECT 1 FROM pec.movimento m WHERE m.documento_id = d.id AND pec.retiro_liberado(m.retiro_id)
                       AND (p->>'retiro_id' IS NULL OR m.retiro_id = (p->>'retiro_id')::uuid))
       ORDER BY d.numero DESC
       LIMIT COALESCE((p->>'limite')::int, 150)) t);
END $$;

-- ---------------------------------------------------------------------
-- RESUMO (tela Início): indicadores da safra, lotação, alertas, pendências
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_resumo() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('EST_VER'); s pec.safra%ROWTYPE; v_fin boolean;
BEGIN
  v_fin := pec.tem_permissao(v_faz, 'MOV_FINANCEIRO');
  SELECT * INTO s FROM pec.safra WHERE fazenda_id = v_faz AND current_date BETWEEN inicio AND fim;
  RETURN jsonb_build_object(
    'safra', s.nome,
    'indicadores', (SELECT COALESCE(jsonb_object_agg(codigo, jsonb_build_object('valor', valor, 'numerador', numerador,
                      'denominador', denominador, 'unidade', unidade, 'formula', formula, 'nome', indicador)), '{}')
                    FROM pec.fn_indicadores(v_faz, COALESCE(s.inicio, date_trunc('year', current_date)::date), current_date)
                    WHERE v_fin OR codigo NOT IN ('RECEITA','PRECO_KG','PRECO_CAB')),
    'lotacao', (SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY r.ordem), '[]') FROM pec.v_lotacao_retiro l
                  JOIN pec.retiro r ON r.id = l.retiro_id WHERE l.fazenda_id = v_faz AND pec.retiro_liberado(l.retiro_id)),
    'pastos_criticos', (SELECT COALESCE(jsonb_agg(to_jsonb(lp) ORDER BY lp.ua_ha DESC NULLS LAST), '[]') FROM pec.v_lotacao_pasto lp
                  WHERE lp.fazenda_id = v_faz AND lp.status IN ('ACIMA DA META','ESTOQUE NEGATIVO') AND pec.retiro_liberado(lp.retiro_id)),
    'alertas', (SELECT COALESCE(jsonb_agg(jsonb_build_object('nivel', a.nivel, 'regra', a.regra, 'mensagem', a.mensagem,
                  'retiro_id', a.retiro_id, 'data', a.data) ORDER BY a.nivel, a.regra), '[]')
                FROM pec.v_alertas a WHERE a.fazenda_id = v_faz AND (a.retiro_id IS NULL OR pec.retiro_liberado(a.retiro_id))),
    'pendencias_abertas', (SELECT count(*) FROM pec.pendencia WHERE fazenda_id = v_faz AND status IN ('ABERTA','EM_ANDAMENTO')),
    'gerado_em', now());
END $$;

-- ---------------------------------------------------------------------
-- PENDÊNCIAS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_pendencias() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('PEND_VER');
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'numero', p.numero, 'origem', p.origem, 'titulo', p.titulo,
            'descricao', p.descricao, 'acao_recomendada', p.acao_recomendada, 'retiro_id', p.retiro_id, 'pasto_id', p.pasto_id,
            'lote_id', p.lote_id, 'prioridade', p.prioridade, 'responsavel_id', p.responsavel_id, 'prazo', p.prazo,
            'status', p.status, 'resolucao', p.resolucao, 'criado_em', p.criado_em, 'resolvida_em', p.resolvida_em)
            ORDER BY (p.status IN ('RESOLVIDA','CANCELADA')), CASE p.prioridade WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 ELSE 3 END, p.numero), '[]')
          FROM pec.pendencia p WHERE p.fazenda_id = v_faz AND (p.retiro_id IS NULL OR pec.retiro_liberado(p.retiro_id)));
END $$;

CREATE OR REPLACE FUNCTION public.pec_pendencia_salvar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('PEND_EDITAR'); v_id uuid := NULLIF(p->>'id','')::uuid; v_num bigint;
BEGIN
  IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pec.pendencia WHERE id = v_id) THEN
    IF COALESCE(trim(p->>'titulo'),'') = '' THEN PERFORM pec.erro('SEM_TITULO', 'Descreva a pendência em poucas palavras.'); END IF;
    INSERT INTO pec.pendencia (id, fazenda_id, origem, titulo, descricao, acao_recomendada, retiro_id, pasto_id, lote_id,
                               prioridade, responsavel_id, prazo, criado_por)
    VALUES (COALESCE(v_id, gen_random_uuid()), v_faz, 'MANUAL', trim(p->>'titulo'), NULLIF(p->>'descricao',''), NULLIF(p->>'acao_recomendada',''),
            NULLIF(p->>'retiro_id','')::uuid, NULLIF(p->>'pasto_id','')::uuid, NULLIF(p->>'lote_id','')::uuid,
            COALESCE(NULLIF(p->>'prioridade',''),'MEDIA')::pec.prioridade_t, NULLIF(p->>'responsavel_id','')::uuid,
            NULLIF(p->>'prazo','')::date, pec.usuario_atual())
    RETURNING id, numero INTO v_id, v_num;
  ELSE
    UPDATE pec.pendencia SET
      status        = COALESCE(NULLIF(p->>'status','')::pec.status_pend_t, status),
      prioridade    = COALESCE(NULLIF(p->>'prioridade','')::pec.prioridade_t, prioridade),
      prazo         = CASE WHEN p ? 'prazo' THEN NULLIF(p->>'prazo','')::date ELSE prazo END,
      responsavel_id= CASE WHEN p ? 'responsavel_id' THEN NULLIF(p->>'responsavel_id','')::uuid ELSE responsavel_id END,
      resolucao     = CASE WHEN p ? 'resolucao' THEN NULLIF(p->>'resolucao','') ELSE resolucao END,
      resolvida_em  = CASE WHEN NULLIF(p->>'status','') = 'RESOLVIDA' THEN now()
                           WHEN NULLIF(p->>'status','') IN ('ABERTA','EM_ANDAMENTO') THEN NULL ELSE resolvida_em END
     WHERE id = v_id AND fazenda_id = v_faz
    RETURNING numero INTO v_num;
    IF COALESCE(p->>'status','') = 'RESOLVIDA' AND COALESCE(trim(p->>'resolucao'),'') = ''
       AND (SELECT resolucao FROM pec.pendencia WHERE id = v_id) IS NULL THEN
      PERFORM pec.erro('SEM_RESOLUCAO', 'Conte em uma frase como a pendência foi resolvida.');
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num);
END $$;

-- ---------------------------------------------------------------------
-- CADASTROS: salvar (fazenda, retiro, pasto, lote, parceiro, colaborador)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_cadastro_salvar(p_tipo text, p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('CAD_EDITAR'); v_org uuid; v_id uuid := NULLIF(p->>'id','')::uuid;
BEGIN
  SELECT organizacao_id INTO v_org FROM pec.fazenda WHERE id = v_faz;
  CASE p_tipo
  WHEN 'fazenda' THEN
    IF COALESCE(trim(p->>'nome'),'') = '' THEN PERFORM pec.erro('SEM_NOME', 'Informe o nome da fazenda.'); END IF;
    UPDATE pec.fazenda SET nome = trim(p->>'nome'), municipio = NULLIF(p->>'municipio',''), uf = NULLIF(upper(p->>'uf'),''),
           area_total_ha = NULLIF(p->>'area_total_ha','')::numeric, responsavel = NULLIF(p->>'responsavel','')
     WHERE id = v_faz;
    v_id := v_faz;
  WHEN 'retiro' THEN
    UPDATE pec.retiro SET area_informada_ha = NULLIF(p->>'area_informada_ha','')::numeric,
           status = COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, status)
     WHERE id = v_id AND fazenda_id = v_faz;
  WHEN 'pasto' THEN
    IF COALESCE(trim(p->>'codigo'),'') = '' THEN PERFORM pec.erro('SEM_CODIGO', 'Informe o código do pasto (como no mapa, ex.: Pla-3).'); END IF;
    INSERT INTO pec.pasto (id, fazenda_id, retiro_id, codigo, area_ha, status, observacao, lotacao_min_ua_ha, lotacao_max_ua_ha)
    VALUES (COALESCE(v_id, gen_random_uuid()), v_faz, (p->>'retiro_id')::uuid, trim(p->>'codigo'),
            COALESCE(NULLIF(p->>'area_ha','')::numeric, 0), COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, 'ATIVO'),
            NULLIF(p->>'observacao',''), NULLIF(p->>'lotacao_min_ua_ha','')::numeric, NULLIF(p->>'lotacao_max_ua_ha','')::numeric)
    ON CONFLICT (id) DO UPDATE SET codigo = EXCLUDED.codigo, area_ha = EXCLUDED.area_ha, status = EXCLUDED.status,
           observacao = EXCLUDED.observacao, lotacao_min_ua_ha = EXCLUDED.lotacao_min_ua_ha, lotacao_max_ua_ha = EXCLUDED.lotacao_max_ua_ha
    RETURNING id INTO v_id;
  WHEN 'lote' THEN
    IF COALESCE(trim(p->>'codigo'),'') = '' THEN PERFORM pec.erro('SEM_CODIGO', 'Informe o nome do lote (ex.: Lote 03).'); END IF;
    INSERT INTO pec.lote (id, fazenda_id, retiro_id, codigo, descricao, carimbo, status, safra_id)
    VALUES (COALESCE(v_id, gen_random_uuid()), v_faz, (p->>'retiro_id')::uuid, trim(p->>'codigo'), NULLIF(p->>'descricao',''),
            NULLIF(p->>'carimbo',''), COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, 'ATIVO'), pec.safra_da_data(v_faz, current_date))
    ON CONFLICT (id) DO UPDATE SET codigo = EXCLUDED.codigo, descricao = EXCLUDED.descricao, carimbo = EXCLUDED.carimbo, status = EXCLUDED.status
    RETURNING id INTO v_id;
  WHEN 'parceiro' THEN
    IF COALESCE(trim(p->>'nome'),'') = '' THEN PERFORM pec.erro('SEM_NOME', 'Informe o nome do comprador/fornecedor.'); END IF;
    INSERT INTO pec.parceiro (id, organizacao_id, nome, documento, tipo, municipio, uf, status)
    VALUES (COALESCE(v_id, gen_random_uuid()), v_org, trim(p->>'nome'), NULLIF(p->>'documento',''),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(p->'tipo')), '{}'), NULLIF(p->>'municipio',''), NULLIF(upper(p->>'uf'),''),
            COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, 'ATIVO'))
    ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome, documento = EXCLUDED.documento, tipo = EXCLUDED.tipo,
           municipio = EXCLUDED.municipio, uf = EXCLUDED.uf, status = EXCLUDED.status
    RETURNING id INTO v_id;
  WHEN 'colaborador' THEN
    IF COALESCE(trim(p->>'nome'),'') = '' THEN PERFORM pec.erro('SEM_NOME', 'Informe o nome.'); END IF;
    INSERT INTO pec.colaborador (id, organizacao_id, nome, funcao, status)
    VALUES (COALESCE(v_id, gen_random_uuid()), v_org, trim(p->>'nome'), NULLIF(p->>'funcao',''),
            COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, 'ATIVO'))
    ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome, funcao = EXCLUDED.funcao, status = EXCLUDED.status
    RETURNING id INTO v_id;
  ELSE
    PERFORM pec.erro('TIPO_INVALIDO', format('Cadastro "%s" não existe.', p_tipo));
  END CASE;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

-- ---------------------------------------------------------------------
-- USUÁRIOS: listar e convidar (Administrador)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pec_usuarios() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('USUARIO_GERIR');
BEGIN
  RETURN jsonb_build_object(
    'usuarios', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', u.id, 'nome', u.nome, 'email', u.email, 'status', u.status,
                   'papel', ua.papel_codigo, 'retiro_ids', ua.retiro_ids) ORDER BY u.nome), '[]')
                 FROM pec.usuario u JOIN pec.usuario_acesso ua ON ua.usuario_id = u.id AND ua.fazenda_id = v_faz),
    'convites', (SELECT COALESCE(jsonb_agg(to_jsonb(c) - 'fazenda_id' ORDER BY c.nome), '[]') FROM pec.convite c
                 WHERE c.fazenda_id = v_faz AND c.aceito_em IS NULL),
    'papeis', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.codigo) FROM pec.papel p));
END $$;

CREATE OR REPLACE FUNCTION public.pec_convidar(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pec, public, extensions AS $$
DECLARE v_faz uuid := pec.exigir('USUARIO_GERIR'); v_email text := lower(trim(p->>'email'));
  v_ret uuid[] := CASE WHEN jsonb_typeof(p->'retiro_ids') = 'array' AND jsonb_array_length(p->'retiro_ids') > 0
                       THEN ARRAY(SELECT jsonb_array_elements_text(p->'retiro_ids')::uuid) END;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN PERFORM pec.erro('EMAIL_INVALIDO', 'Confira o e-mail.'); END IF;
  -- usuário que já entrou: troca o perfil/retiros direto
  IF EXISTS (SELECT 1 FROM pec.usuario WHERE email = v_email) THEN
    UPDATE pec.usuario_acesso ua SET papel_codigo = p->>'papel', retiro_ids = v_ret
      FROM pec.usuario u WHERE u.id = ua.usuario_id AND u.email = v_email AND ua.fazenda_id = v_faz;
    UPDATE pec.usuario SET status = COALESCE(NULLIF(p->>'status','')::pec.status_cad_t, status) WHERE email = v_email;
    RETURN jsonb_build_object('ok', true, 'atualizado', true);
  END IF;
  INSERT INTO pec.convite (email, nome, fazenda_id, papel_codigo, retiro_ids)
  VALUES (v_email, COALESCE(NULLIF(trim(p->>'nome'),''), v_email), v_faz, p->>'papel', v_ret)
  ON CONFLICT (email) DO UPDATE SET nome = EXCLUDED.nome, papel_codigo = EXCLUDED.papel_codigo, retiro_ids = EXCLUDED.retiro_ids;
  RETURN jsonb_build_object('ok', true, 'convidado', true);
END $$;

-- ---------------------------------------------------------------------
-- Permissões de execução: só usuário logado chama a API
-- ---------------------------------------------------------------------
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
