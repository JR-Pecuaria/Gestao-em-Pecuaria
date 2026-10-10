-- Confere o banco contra os valores que o Excel mostrava (cache de 09/10/2026)
SET search_path = pec, public;
\echo '== Rebanho total (Excel: 774 cab / 519,75 UA)'
SELECT sum(cabecas) cab, sum(ua) ua FROM v_estoque_atual;
\echo '== Categoria x Retiro (Excel Dashboard B20:L35)'
SELECT categoria, retiro, sum(cabecas) FROM v_estoque_atual GROUP BY 1,2, ordem_categoria ORDER BY ordem_categoria, 2;
\echo '== Fechamento set/2026 por retiro (Excel Mapão-Fechamento: SA 614, nasc 160, final 774, sem pasto 375)'
SELECT retiro, sum(saldo_anterior) sa, sum(nascimentos) nasc, sum(total_entradas) ent, sum(total_saidas) sai, sum(saldo_final) sf, bool_and(confere) ok
  FROM fn_fechamento((SELECT id FROM fazenda LIMIT 1), '2026-09-01') GROUP BY retiro ORDER BY retiro;
SELECT sum(cabecas) AS sem_pasto FROM v_estoque_atual WHERE pasto_id IS NULL;
\echo '== Lotação por retiro (Excel: AgF 0,087 · Pon 0,068 · Pla 0,078 · total 0,036)'
SELECT retiro, area_ha, ua, ua_ha, status FROM v_lotacao_retiro ORDER BY retiro;
\echo '== Indicadores safra 2026/27 até hoje (Excel: nascimentos 295, mortes 0)'
SELECT codigo, valor, numerador, denominador FROM fn_indicadores((SELECT id FROM fazenda LIMIT 1), '2026-07-01', '2027-06-30');
\echo '== Mapão Pontal set/2026 (linhas com gado)'
SELECT pasto, categoria, cabecas FROM fn_mapao((SELECT id FROM fazenda LIMIT 1), (SELECT id FROM retiro WHERE nome='Pontal'), '2026-09-01') WHERE cabecas<>0 ORDER BY pasto, ordem;
\echo '== Alertas'
SELECT nivel, regra, mensagem FROM v_alertas ORDER BY nivel, regra;
