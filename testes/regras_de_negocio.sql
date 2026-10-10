-- Testes das regras de negócio: cada caso DEVE ser bloqueado com a mensagem certa.
-- Rodar após a carga. Imprime OK/FALHOU por caso; não deixa resíduos (tudo em ROLLBACK).
SET search_path = pec, public;
\set QUIET on
\o /dev/null
CREATE TEMP TABLE resultado (caso text, esperado text, obtido text, ok boolean);

CREATE OR REPLACE FUNCTION pg_temp.espera_erro(p_caso text, p_esperado text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_hint text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;   -- dispara as validações de documento (deferred) aqui
    RAISE EXCEPTION 'desfaz';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT;
  END;
  IF v_msg = 'desfaz' THEN
    INSERT INTO resultado VALUES (p_caso, p_esperado, 'NÃO BLOQUEOU', false);
  ELSE
    INSERT INTO resultado VALUES (p_caso, p_esperado, COALESCE(NULLIF(v_hint,''), '') || ' — ' || v_msg,
                                  COALESCE(v_hint,'') = p_esperado OR v_msg ILIKE '%'||p_esperado||'%');
  END IF;
END $$;

-- atalhos
CREATE TEMP VIEW k AS SELECT
  (SELECT id FROM fazenda LIMIT 1) faz,
  (SELECT id FROM retiro WHERE nome='Água Funda') agf, (SELECT id FROM retiro WHERE nome='Pontal') pon,
  (SELECT id FROM pasto WHERE codigo='AgF-10') agf10, (SELECT id FROM pasto WHERE codigo='AgF-11') agf11,
  (SELECT id FROM pasto WHERE codigo='Pon-1') pon1,
  (SELECT id FROM categoria WHERE nome='Vaca') vaca, (SELECT id FROM categoria WHERE nome='Bez. Macho') bzm,
  (SELECT id FROM categoria WHERE nome='Desmama Macho') dmm, (SELECT id FROM categoria WHERE nome='Garrote') garrote,
  (SELECT id FROM causa_morte WHERE nome='Raio') raio, (SELECT id FROM canal_venda WHERE nome='Leilão') leilao;

SELECT pg_temp.espera_erro('Morte sem causa', 'MORTE_SEM_CAUSA', format($q$
  INSERT INTO documento (id,fazenda_id,operacao_codigo,data) VALUES (gen_random_uuid(),'%s','MORTE','2026-10-01')$q$, faz)) FROM k;

SELECT pg_temp.espera_erro('Venda sem canal', 'VENDA_SEM_CANAL', format($q$
  INSERT INTO documento (id,fazenda_id,operacao_codigo,data) VALUES (gen_random_uuid(),'%s','VENDA','2026-10-01')$q$, faz)) FROM k;

SELECT pg_temp.espera_erro('Movimentação sem data', 'SEM_DATA', format($q$
  INSERT INTO documento (id,fazenda_id,operacao_codigo,data) VALUES (gen_random_uuid(),'%s','NASCIMENTO',NULL)$q$, faz)) FROM k;

SELECT pg_temp.espera_erro('Quantidade zero', 'QTD_INVALIDA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','NASCIMENTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,0,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, bzm)) FROM k;

SELECT pg_temp.espera_erro('Nascimento em vaca', 'NASCIMENTO_CATEGORIA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','NASCIMENTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,3,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, vaca)) FROM k;

SELECT pg_temp.espera_erro('Pasto de outro retiro', 'PASTO_FORA_DO_RETIRO', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','NASCIMENTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,3,'2026-10-01'::date FROM d$q$, faz, faz, agf, pon1, bzm)) FROM k;

SELECT pg_temp.espera_erro('Lançamento sem pasto (fora da importação)', 'SEM_PASTO', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','NASCIMENTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,categoria_id,quantidade,data)
  SELECT id,1,'%s','%s','%s',3,'2026-10-01'::date FROM d$q$, faz, faz, agf, bzm)) FROM k;

SELECT pg_temp.espera_erro('Morte que deixa estoque negativo', 'ESTOQUE_NEGATIVO', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data,causa_morte_id) VALUES ('%s','MORTE','2026-10-01','%s') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,500,'2026-10-01'::date FROM d$q$, faz, raio, faz, agf, agf10, vaca)) FROM k;

SELECT pg_temp.espera_erro('Transferência só com a saída', 'TRANSF_INCOMPLETA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','TRANSF_PASTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,10,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, vaca)) FROM k;

SELECT pg_temp.espera_erro('Transferência desbalanceada (−10 / +8)', 'TRANSF_DESBALANCEADA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','TRANSF_PASTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,10,'2026-10-01'::date FROM d UNION ALL
  SELECT id, 1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid, 8,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, vaca, faz, agf, agf11, vaca)) FROM k;

SELECT pg_temp.espera_erro('Transf. de pasto entre retiros diferentes', 'TRANSF_PASTO_RETIRO', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','TRANSF_PASTO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,10,'2026-10-01'::date FROM d UNION ALL
  SELECT id, 1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,10,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, vaca, faz, pon, pon1, vaca)) FROM k;

SELECT pg_temp.espera_erro('Mudança de era não permitida (Bez. Macho → Garrote)', 'TRANSICAO_INVALIDA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','ERA','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d UNION ALL
  SELECT id, 1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, bzm, faz, agf, agf10, garrote)) FROM k;

SELECT pg_temp.espera_erro('Desmama sem peso', 'SEM_PESO', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','DESMAMA','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d UNION ALL
  SELECT id, 1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, bzm, faz, agf, agf11, dmm)) FROM k;

SELECT pg_temp.espera_erro('Refugo de cocho saindo de pasto (não do Confinamento)', 'REFUGO_ORIGEM', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','REFUGO_COCHO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d UNION ALL
  SELECT id, 1,'%s'::uuid,'%s'::uuid,'%s'::uuid,'%s'::uuid,5,'2026-10-01'::date FROM d$q$, faz, faz, agf, agf10, vaca, faz, agf, agf11, vaca)) FROM k;

SELECT pg_temp.espera_erro('Refugo de cocho só com a saída', 'TRANSF_INCOMPLETA', format($q$
  WITH d AS (INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','REFUGO_COCHO','2026-10-01') RETURNING id)
  INSERT INTO movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
  SELECT id,-1,'%s'::uuid,(SELECT id FROM retiro WHERE nome='Confinamento'),(SELECT id FROM pasto WHERE codigo='Conf-Geral'),'%s'::uuid,5,'2026-10-01'::date FROM d$q$, faz, faz, bzm)) FROM k;

SELECT pg_temp.espera_erro('Excluir lançamento', 'DOC_SEM_EXCLUSAO',
  $q$DELETE FROM documento WHERE id = (SELECT id FROM documento LIMIT 1)$q$);

SELECT pg_temp.espera_erro('Alterar quantidade de movimento já gravado', 'MOV_IMUTAVEL',
  $q$UPDATE movimento SET quantidade = quantidade + 1 WHERE id = (SELECT id FROM movimento LIMIT 1)$q$);

SELECT pg_temp.espera_erro('Lançar em mês fechado', 'PERIODO_FECHADO', format($q$
  INSERT INTO periodo (fazenda_id, competencia, status) VALUES ('%s','2026-08-01','FECHADO');
  INSERT INTO documento (fazenda_id,operacao_codigo,data) VALUES ('%s','NASCIMENTO','2026-08-20')$q$, faz, faz)) FROM k;

SELECT pg_temp.espera_erro('Apagar auditoria', 'SOMENTE_LEITURA', $q$DELETE FROM auditoria WHERE id = (SELECT min(id) FROM auditoria)$q$);

-- Casos que DEVEM passar (e conferir efeito), sempre desfeitos ao final
DO $$
DECLARE f uuid := (SELECT id FROM pec.fazenda LIMIT 1);
        d uuid := gen_random_uuid(); e uuid; antes bigint; depois bigint; apos_estorno bigint; st text; na int; err text;
BEGIN
  BEGIN
    SELECT sum(cabecas) INTO antes FROM pec.v_estoque_atual WHERE pasto = 'AgF-10' AND categoria = 'Vaca';
    INSERT INTO pec.documento (id,fazenda_id,operacao_codigo,data) VALUES (d,f,'TRANSF_PASTO','2026-10-01');
    INSERT INTO pec.movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
    SELECT d,-1,f,r.id,(SELECT id FROM pec.pasto WHERE codigo='AgF-10'),(SELECT id FROM pec.categoria WHERE nome='Vaca'),10,'2026-10-01'::date
      FROM pec.retiro r WHERE r.nome='Água Funda'
    UNION ALL
    SELECT d, 1,f,r.id,(SELECT id FROM pec.pasto WHERE codigo='AgF-11'),(SELECT id FROM pec.categoria WHERE nome='Vaca'),10,'2026-10-01'::date
      FROM pec.retiro r WHERE r.nome='Água Funda';
    SET CONSTRAINTS ALL IMMEDIATE;
    SELECT sum(cabecas) INTO depois FROM pec.v_estoque_atual WHERE pasto = 'AgF-10' AND categoria = 'Vaca';
    e := pec.estornar_documento(d, 'teste de estorno');
    SET CONSTRAINTS ALL IMMEDIATE;
    SELECT sum(cabecas) INTO apos_estorno FROM pec.v_estoque_atual WHERE pasto = 'AgF-10' AND categoria = 'Vaca';
    SELECT status::text INTO st FROM pec.documento WHERE id = d;
    SELECT count(*) INTO na FROM pec.auditoria WHERE acao='ESTORNO' AND registro_id = d::text;
    RAISE EXCEPTION 'desfaz';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'desfaz' THEN err := SQLERRM; END IF;
  END;
  IF err IS NOT NULL THEN
    INSERT INTO resultado VALUES ('Fluxo transferência+estorno', 'sem erro', err, false);
  ELSE
    INSERT INTO resultado VALUES ('Transferência válida AgF-10→AgF-11 (−10 vacas)', (antes-10)::text, depois::text, depois = antes - 10),
                                 ('Estorno devolve o estoque', antes::text, apos_estorno::text, apos_estorno = antes),
                                 ('Estorno não apaga: original fica ESTORNADO', 'ESTORNADO', st, st = 'ESTORNADO'),
                                 ('Estorno registrado na auditoria', '1', na::text, na = 1);
  END IF;
END $$;

DO $$
DECLARE f uuid := (SELECT id FROM pec.fazenda LIMIT 1); d uuid := gen_random_uuid(); conf bigint; pon bigint; err text; nome_novo text; aud int;
BEGIN
  BEGIN
    INSERT INTO pec.documento (id,fazenda_id,operacao_codigo,data) VALUES (d,f,'REFUGO_COCHO','2026-10-01');
    INSERT INTO pec.movimento (documento_id,sentido,fazenda_id,retiro_id,pasto_id,categoria_id,quantidade,data)
    SELECT d,-1,f,(SELECT id FROM pec.retiro WHERE nome='Confinamento'),(SELECT id FROM pec.pasto WHERE codigo='Conf-Geral'),(SELECT id FROM pec.categoria WHERE nome='Bez. Macho'),4,'2026-10-01'::date
    UNION ALL
    SELECT d, 1,f,(SELECT id FROM pec.retiro WHERE nome='Pontal'),(SELECT id FROM pec.pasto WHERE codigo='Pon-1'),(SELECT id FROM pec.categoria WHERE nome='Bez. Macho'),4,'2026-10-01'::date;
    SET CONSTRAINTS ALL IMMEDIATE;
    SELECT sum(cabecas) INTO conf FROM pec.v_estoque_atual WHERE pasto='Conf-Geral';
    SELECT sum(cabecas) INTO pon FROM pec.v_estoque_atual WHERE pasto='Pon-1' AND categoria='Bez. Macho';
    UPDATE pec.fazenda SET nome = 'Fazenda Teste' WHERE id = f;
    SELECT nome INTO nome_novo FROM pec.fazenda WHERE id = f;
    SELECT count(*) INTO aud FROM pec.auditoria WHERE tabela='fazenda' AND acao='UPDATE' AND registro_id = f::text;
    RAISE EXCEPTION 'desfaz';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'desfaz' THEN err := SQLERRM; END IF;
  END;
  IF err IS NOT NULL THEN INSERT INTO resultado VALUES ('Refugo de cocho válido', 'sem erro', err, false);
  ELSE
    INSERT INTO resultado VALUES ('Refugo válido: Confinamento 10 → 6', '6', conf::text, conf = 6),
                                 ('Refugo válido: Pon-1 Bez. Macho 23 → 27', '27', pon::text, pon = 27),
                                 ('Nome da fazenda editável', 'Fazenda Teste', nome_novo, nome_novo = 'Fazenda Teste'),
                                 ('Renomear fazenda fica na auditoria', '1', aud::text, aud = 1);
  END IF;
END $$;

\set QUIET off
\o
SELECT CASE WHEN ok THEN 'OK     ' ELSE 'FALHOU ' END AS r, caso, obtido FROM resultado;
SELECT count(*) FILTER (WHERE ok) AS passaram, count(*) FILTER (WHERE NOT ok) AS falharam FROM resultado;
