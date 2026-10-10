-- =====================================================================
-- 04_seguranca_e_base.sql — Perfis (RBAC), RLS e dados-base do sistema
-- =====================================================================
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- Tipos de operação (de/para com a planilha v3)
-- sentido, partida dobrada e exigências vêm DAQUI, nunca do texto
-- ---------------------------------------------------------------------
INSERT INTO pec.tipo_operacao
 (codigo, nome, sentido_permitido, partida_dobrada, muda_categoria, muda_local, afeta_rebanho, grupo_mapao,
  exige_causa, exige_canal, exige_parceiro, exige_peso, exige_valor, so_categoria_nascimento,
  rotulo_planilha_entrada, rotulo_planilha_saida, ordem) VALUES
 ('SALDO_INICIAL','Saldo Inicial',            '{1}',    false,false,false,true ,'E', false,false,false,false,false,false,'Entrada - Saldo Inicial',NULL,1),
 ('NASCIMENTO','Nascimento',                  '{1}',    false,false,false,true ,'N', false,false,false,false,false,true ,'Entrada - Nascimento',NULL,2),
 ('COMPRA','Compra',                          '{1}',    false,false,false,true ,'E', false,false,true ,true ,true ,false,'Entrada - Compra',NULL,3),
 ('VENDA','Venda',                            '{-1}',   false,false,false,true ,'V', false,true ,true ,true ,true ,false,NULL,'Saída - Venda',4),
 ('MORTE','Morte',                            '{-1}',   false,false,false,true ,'M', true ,false,false,false,false,false,NULL,'Saída - Morte',5),
 ('TRANSF_PASTO','Transferência de Pasto',    '{1,-1}', true ,false,true ,false,'E', false,false,false,false,false,false,'Entrada - Transferência de Pasto','Saída - Transferência de Pasto',6),
 ('TRANSF_RETIRO','Transferência de Retiro',  '{1,-1}', true ,false,true ,false,'E', false,false,false,false,false,false,'Entrada - Transferência de Retiro','Saída - Transferência de Retiro',7),
 ('TRANSF_FAZENDA','Transferência de Fazenda','{1,-1}', false,false,true ,true ,'E', false,false,false,false,false,false,NULL,NULL,8),
 ('DESMAMA','Desmama',                        '{1,-1}', true ,true ,false,false,'E', false,false,false,true ,false,false,'Entrada - Desmama','Saída - Desmama',9),
 ('ERA','Mudança de Era (categoria)',         '{1,-1}', true ,true ,false,false,'E', false,false,false,false,false,false,'Entrada - Transferência de Era','Saída - Transferência de Era',10),
 ('REFUGO_COCHO','Refugo de Cocho',           '{1,-1}', true ,false,true ,false,'E', false,false,false,false,false,false,'Entrada - Réfugo de Cocho','Saída - Réfugo de Cocho',11),
 ('AJUSTE_INVENTARIO','Ajuste de Inventário', '{1,-1}', false,false,false,true ,'E', false,false,false,false,false,false,'Entrada - Ajuste de Inventário','Saída - Ajuste de Inventário',12);
-- Obs.: TRANSF_FAZENDA não é dobrada dentro da fazenda (cada fazenda lança sua perna; o elo é o documento-par).
-- REFUGO_COCHO (confirmado em 09/10/2026): animal refugado no cocho VOLTA do Confinamento para o pasto.
-- Partida dobrada: −1 num retiro CONFINAMENTO, +1 num pasto de retiro que não é confinamento; categoria preservada.

-- ---------------------------------------------------------------------
-- Perfis e permissões
-- ---------------------------------------------------------------------
INSERT INTO pec.papel VALUES
 ('ADMIN','Administrador','Acesso total, parâmetros, reabertura de mês'),
 ('GERENTE','Gerente','Dashboards, movimentações, relatórios, fechamento'),
 ('ESCRITORIO','Escritório','Cadastros, lançamentos, relatórios'),
 ('ENCARREGADO','Encarregado','Lançamentos operacionais do(s) seu(s) retiro(s)'),
 ('VAQUEIRO','Vaqueiro','Consulta, contagem de campo, pendências'),
 ('DIRETORIA','Diretoria','Somente dashboards e relatórios estratégicos');

INSERT INTO pec.permissao VALUES
 ('DASH_VER','Ver dashboards'), ('REL_VER','Ver/exportar relatórios'),
 ('EST_VER','Consultar estoque e Mapão'),
 ('MOV_LANCAR','Lançar movimentações'), ('MOV_ESTORNAR','Estornar/corrigir lançamentos'),
 ('MOV_FINANCEIRO','Informar/ver valores de venda e compra'),
 ('CAD_EDITAR','Editar cadastros'), ('PARAM_EDITAR','Editar parâmetros (UA, metas, lotação)'),
 ('INV_CONTAR','Registrar contagem de campo'), ('INV_AJUSTAR','Aprovar ajuste de inventário'),
 ('PEND_VER','Ver pendências'), ('PEND_EDITAR','Criar/resolver pendências'),
 ('REPRO_LANCAR','Lançar reprodução (IATF, DG, partos)'),
 ('PERIODO_FECHAR','Fechar mês'), ('PERIODO_REABRIR','Reabrir mês'), ('PERIODO_EDITAR_FECHADO','Editar em mês fechado'),
 ('AUDIT_VER','Ver auditoria'), ('USUARIO_GERIR','Gerir usuários e acessos');

INSERT INTO pec.papel_permissao
SELECT 'ADMIN', codigo FROM pec.permissao
UNION ALL SELECT 'GERENTE', unnest('{DASH_VER,REL_VER,EST_VER,MOV_LANCAR,MOV_ESTORNAR,MOV_FINANCEIRO,INV_CONTAR,INV_AJUSTAR,PEND_VER,PEND_EDITAR,REPRO_LANCAR,PERIODO_FECHAR,AUDIT_VER}'::text[])
UNION ALL SELECT 'ESCRITORIO', unnest('{REL_VER,EST_VER,MOV_LANCAR,MOV_ESTORNAR,MOV_FINANCEIRO,CAD_EDITAR,INV_CONTAR,PEND_VER,PEND_EDITAR,REPRO_LANCAR}'::text[])
UNION ALL SELECT 'ENCARREGADO', unnest('{EST_VER,MOV_LANCAR,INV_CONTAR,PEND_VER,PEND_EDITAR,REPRO_LANCAR}'::text[])
UNION ALL SELECT 'VAQUEIRO', unnest('{EST_VER,INV_CONTAR,PEND_VER}'::text[])
UNION ALL SELECT 'DIRETORIA', unnest('{DASH_VER,REL_VER,EST_VER,MOV_FINANCEIRO}'::text[]);

-- ---------------------------------------------------------------------
-- Row Level Security (Supabase): cada usuário só enxerga as fazendas
-- (e, se restrito, os retiros) do seu acesso; escrita exige permissão.
-- ---------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END $$;

CREATE OR REPLACE FUNCTION pec.pode_ver(p_fazenda uuid, p_retiro uuid DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pec, public AS $$
  SELECT EXISTS (SELECT 1 FROM pec.usuario_acesso ua
                  WHERE ua.usuario_id = pec.usuario_atual() AND ua.fazenda_id = p_fazenda
                    AND (ua.retiro_ids IS NULL OR p_retiro IS NULL OR p_retiro = ANY (ua.retiro_ids)))
$$;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'pec' LOOP     -- RLS em TODAS as tabelas
    EXECUTE format('ALTER TABLE pec.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['retiro','pasto','lote','animal','documento','safra','periodo','parametro','inventario',
                           'pendencia','estacao_monta','pesagem']
  LOOP
    EXECUTE format('CREATE POLICY %I_ler ON pec.%I FOR SELECT TO authenticated USING (pec.pode_ver(fazenda_id))', t, t);
  END LOOP;
END $$;

CREATE POLICY movimento_ler    ON pec.movimento FOR SELECT TO authenticated USING (pec.pode_ver(fazenda_id, retiro_id));
CREATE POLICY movimento_lancar ON pec.movimento FOR INSERT TO authenticated
  WITH CHECK (pec.pode_ver(fazenda_id, retiro_id) AND pec.tem_permissao(fazenda_id, 'MOV_LANCAR'));
CREATE POLICY documento_lancar ON pec.documento FOR INSERT TO authenticated
  WITH CHECK (pec.tem_permissao(fazenda_id, 'MOV_LANCAR'));
CREATE POLICY documento_editar ON pec.documento FOR UPDATE TO authenticated
  USING (pec.tem_permissao(fazenda_id, 'MOV_LANCAR'));
CREATE POLICY pasto_editar ON pec.pasto FOR ALL TO authenticated
  USING (pec.tem_permissao(fazenda_id, 'CAD_EDITAR')) WITH CHECK (pec.tem_permissao(fazenda_id, 'CAD_EDITAR'));
CREATE POLICY pendencia_editar ON pec.pendencia FOR ALL TO authenticated
  USING (pec.tem_permissao(fazenda_id, 'PEND_EDITAR')) WITH CHECK (pec.tem_permissao(fazenda_id, 'PEND_EDITAR'));
CREATE POLICY parametro_editar ON pec.parametro FOR ALL TO authenticated
  USING (pec.tem_permissao(fazenda_id, 'PARAM_EDITAR')) WITH CHECK (pec.tem_permissao(fazenda_id, 'PARAM_EDITAR'));
CREATE POLICY fazenda_ler ON pec.fazenda FOR SELECT TO authenticated USING (pec.pode_ver(id));
CREATE POLICY fazenda_editar ON pec.fazenda FOR UPDATE TO authenticated
  USING (pec.tem_permissao(id, 'CAD_EDITAR')) WITH CHECK (pec.tem_permissao(id, 'CAD_EDITAR'));
-- Valores financeiros: a Diretoria/Gerência vê; Encarregado/Vaqueiro leem pela view abaixo, sem R$.
CREATE OR REPLACE VIEW pec.v_documento_operacional WITH (security_invoker = on) AS
SELECT id, numero, fazenda_id, operacao_codigo, data, safra_id, causa_morte_id, canal_venda_id, peso_total_kg,
       CASE WHEN pec.tem_permissao(fazenda_id,'MOV_FINANCEIRO') THEN valor_total END AS valor_total,
       responsavel_id, observacao, status, origem, criado_em
  FROM pec.documento;

-- Fixa o search_path de todas as funções do esquema pec (recomendação de segurança do Supabase)
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pec'
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pec, public, extensions', f.sig);
  END LOOP;
END $$;
-- Observação: tabelas sem política ficam fechadas para o app (RLS nega tudo). As políticas de
-- cadastros, reprodução e auditoria entram na Entrega 2, junto com as telas que as usam.
