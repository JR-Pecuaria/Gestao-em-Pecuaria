#!/bin/bash
# Recria o banco local: planilha + 06 + 07 (Entrega 2) + 08 (Entrega 3) e convites de teste.
set -e
/home/claude/pg_start.sh
su postgres -c "export PGHOST=/tmp; cd /tmp && /home/claude/work/entrega1/rodar_tudo.sh /home/claude/pgin/Mapa_do_Gado_v3.xlsx" > /tmp/rebuild.log 2>&1
for f in /home/claude/work/entrega2/sql/06_api.sql /home/claude/work/entrega2/sql/07_ajustes_regras.sql /home/claude/work/entrega3/sql/08_entrega3.sql; do su postgres -c "psql -h /tmp -d pecuaria -v ON_ERROR_STOP=1 -qf $f"; done
su postgres -c "psql -h /tmp -d pecuaria -qc \"insert into pec.convite (email,nome,fazenda_id,papel_codigo) select 'admin@teste.com','Admin Teste',id,'ADMIN' from pec.fazenda; insert into pec.convite (email,nome,fazenda_id,papel_codigo,retiro_ids) select 'enc@teste.com','Zé Encarregado',id,'ENCARREGADO',array[(select id from pec.retiro where nome='Pontal')] from pec.fazenda; insert into pec.convite (email,nome,fazenda_id,papel_codigo,retiro_ids) select 'vaq@teste.com','Tião Vaqueiro',id,'VAQUEIRO',array[(select id from pec.retiro where nome='Pontal')] from pec.fazenda; insert into pec.convite (email,nome,fazenda_id,papel_codigo) select 'ger@teste.com','Gerente Teste',id,'GERENTE' from pec.fazenda;\""
echo "banco recriado"
