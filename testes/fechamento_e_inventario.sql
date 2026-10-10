-- Fluxo: fechar julho, emitir Mapão de set/26 do Pontal, contar no campo, gerar pendências. Tudo desfeito no fim.
SET search_path = pec, public;
BEGIN;
\echo '== Fechar jul/2026 (há alertas só de ATENÇÃO → fecha)'
SELECT fechar_periodo((SELECT id FROM fazenda), '2026-07-01');
SELECT competencia, status, jsonb_array_length(snapshot) AS linhas_snapshot FROM periodo;
\echo '== Emitir Mapão Pontal set/2026 e registrar contagem (Pon-1: 47 vacas no campo; SEM PASTO: 80 → 80)'
SELECT emitir_inventario((SELECT id FROM retiro WHERE nome='Pontal'), '2026-09-01') AS inv \gset
UPDATE inventario_item ii SET qtd_campo = CASE WHEN p.codigo='Pon-1' AND c.nome='Vaca' THEN 47 ELSE ii.qtd_sistema END
  FROM categoria c, pasto p WHERE ii.inventario_id = :'inv' AND c.id = ii.categoria_id AND p.id = ii.pasto_id;
UPDATE inventario_item SET qtd_campo = qtd_sistema WHERE inventario_id = :'inv' AND pasto_id IS NULL;
SELECT COALESCE(p.codigo,'SEM PASTO') pasto, c.nome, qtd_sistema, qtd_campo, diferenca,
       classificar_divergencia(i.fazenda_id, qtd_sistema, qtd_campo) classe
  FROM inventario_item ii JOIN inventario i ON i.id=ii.inventario_id JOIN categoria c ON c.id=ii.categoria_id LEFT JOIN pasto p ON p.id=ii.pasto_id
 WHERE ii.inventario_id = :'inv' ORDER BY 1, c.ordem;
SELECT concluir_contagem(:'inv') AS pendencias_geradas;
SELECT numero, origem, prioridade, titulo, descricao FROM pendencia WHERE origem='INVENTARIO';
SELECT nivel, regra, mensagem FROM v_alertas WHERE regra='INVENTARIO_DIVERGENTE';
\echo '== Aprovar ajuste: gera AJUSTE_INVENTARIO de −2 vacas no Pon-1 e resolve a pendência'
SELECT aprovar_ajustes_inventario(:'inv') AS ajustes;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT sum(cabecas) AS vacas_pon1_hoje FROM v_estoque_atual WHERE pasto='Pon-1' AND categoria='Vaca';
SELECT status FROM pendencia WHERE origem='INVENTARIO';
ROLLBACK;
