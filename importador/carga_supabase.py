"""Gera uma carga compacta (chaves naturais) a partir do banco local já importado — para colar no Supabase."""
import subprocess, csv, io, sys
DB = sys.argv[1] if len(sys.argv) > 1 else 'pecuaria'
def q(sql):
    out = subprocess.run(['psql','-h','/tmp','-d',DB,'-At','--csv','-c',sql], capture_output=True, text=True, check=True).stdout
    return list(csv.reader(io.StringIO(out)))
def lit(v):
    if v is None or v == '': return 'NULL'
    return "'" + v.replace("'", "''") + "'"
L = ["BEGIN;", "SET search_path = pec, public, extensions;"]
org, = q("select nome from pec.organizacao")
faz, = q("select nome from pec.fazenda")
L.append(f"INSERT INTO pec.organizacao (nome) VALUES ({lit(org[0])});")
L.append(f"INSERT INTO pec.fazenda (organizacao_id, nome) SELECT id, {lit(faz[0])} FROM pec.organizacao;")
L.append("CREATE TEMP VIEW k AS SELECT (SELECT id FROM pec.organizacao) org, (SELECT id FROM pec.fazenda) faz;")
imp = q("select arquivo, hash_arquivo from pec.importacao")[0]
L.append(f"INSERT INTO pec.importacao (fazenda_id, arquivo, hash_arquivo) SELECT faz, {lit(imp[0])}, {lit(imp[1])} FROM k;")
par = q("select chave, valor::text, descricao from pec.parametro order by chave")
L.append("INSERT INTO pec.parametro SELECT k.faz, v.c, v.val::jsonb, v.d FROM k, (VALUES " + ",".join(
    f"({lit(c)},{lit('\"ALERTAR\"' if c=='ESTOQUE_NEGATIVO' else v)},{lit(d)})" for c,v,d in par) + ") v(c,val,d);")
ret = q("select nome, sigla, area_informada_ha, tipo, ordem from pec.retiro order by ordem")
L.append("INSERT INTO pec.retiro (fazenda_id, nome, sigla, area_informada_ha, tipo, ordem) SELECT k.faz, v.* FROM k, (VALUES " + ",".join(
    f"({lit(n)},{lit(s)},{a or 'NULL'}::numeric,{lit(t)},{o})" for n,s,a,t,o in ret) + ") v;")
cat = q("select c.nome, sexo, fase, coalesce(idade_min_meses::text,''), coalesce(idade_max_meses::text,''), permite_nascimento, eh_matriz, grupo_dashboard, coluna_mapao, ordem, p.fator_ua, p.meta_mortalidade from pec.categoria c join pec.categoria_parametro p on p.categoria_id=c.id order by ordem")
L.append("INSERT INTO pec.categoria (organizacao_id, nome, sexo, fase, idade_min_meses, idade_max_meses, permite_nascimento, eh_matriz, grupo_dashboard, coluna_mapao, ordem) SELECT k.org, v.n, v.s::pec.sexo_t, v.f::pec.fase_cat_t, v.i1, v.i2, v.pn, v.m, v.g, v.cm, v.o FROM k, (VALUES " + ",".join(
    f"({lit(r[0])},{lit(r[1])},{lit(r[2])},{r[3] or 'NULL'}::int,{r[4] or 'NULL'}::int,{r[5]=='t'},{r[6]=='t'},{lit(r[7])},{lit(r[8])},{r[9]})" for r in cat) + ") v(n,s,f,i1,i2,pn,m,g,cm,o);")
L.append("INSERT INTO pec.categoria_parametro (categoria_id, vigente_desde, fator_ua, meta_mortalidade) SELECT c.id, '2000-01-01', v.ua, v.meta FROM pec.categoria c JOIN (VALUES " + ",".join(
    f"({lit(r[0])},{r[10]},{r[11]})" for r in cat) + ") v(n,ua,meta) ON v.n = c.nome;")
tr = q("select a.nome, b.nome, operacao_codigo, gatilho from pec.categoria_transicao t join pec.categoria a on a.id=de_categoria_id join pec.categoria b on b.id=para_categoria_id")
L.append("INSERT INTO pec.categoria_transicao SELECT a.id, b.id, v.op, v.g FROM (VALUES " + ",".join(
    f"({lit(x)},{lit(y)},{lit(o)},{lit(g)})" for x,y,o,g in tr) + ") v(de,para,op,g) JOIN pec.categoria a ON a.nome=v.de JOIN pec.categoria b ON b.nome=v.para;")
for tab, cols in (("raca","nome"),("causa_morte","nome, grupo"),("canal_venda","nome")):
    rows = q(f"select {cols} from pec.{tab}")
    L.append(f"INSERT INTO pec.{tab} (organizacao_id, {cols}) SELECT k.org, v.* FROM k, (VALUES " + ",".join("(" + ",".join(lit(x) for x in r) + ")" for r in rows) + ") v;")
sf = q("select nome, inicio, fim, status from pec.safra")[0]
L.append(f"INSERT INTO pec.safra (fazenda_id, nome, inicio, fim, status) SELECT faz, {lit(sf[0])}, {lit(sf[1])}, {lit(sf[2])}, {lit(sf[3])} FROM k;")
ps = q("select r.sigla, p.codigo, p.area_ha, p.generico, coalesce(p.observacao,'') from pec.pasto p join pec.retiro r on r.id=p.retiro_id order by r.ordem, p.codigo")
L.append("INSERT INTO pec.pasto (fazenda_id, retiro_id, codigo, area_ha, generico, observacao) SELECT r.fazenda_id, r.id, v.c, v.a, v.g, v.o FROM (VALUES " + ",".join(
    f"({lit(s)},{lit(c)},{a},{g=='t'},{lit(o)})" for s,c,a,g,o in ps) + ") v(s,c,a,g,o) JOIN pec.retiro r ON r.sigla = v.s;")
lt = q("select r.sigla, l.codigo from pec.lote l join pec.retiro r on r.id=l.retiro_id")
L.append("INSERT INTO pec.lote (fazenda_id, retiro_id, codigo, safra_id) SELECT r.fazenda_id, r.id, v.c, (SELECT id FROM pec.safra) FROM (VALUES " + ",".join(
    f"({lit(s)},{lit(c)})" for s,c in lt) + ") v(s,c) JOIN pec.retiro r ON r.sigla = v.s;")
mv = q("""select d.linha_origem, d.data, d.operacao_codigo, coalesce(d.observacao,''), m.sentido, r.sigla, coalesce(p.codigo,''), coalesce(l.codigo,''), c.nome, coalesce(ra.nome,''), m.quantidade, coalesce(m.status_reprodutivo,'')
          from pec.movimento m join pec.documento d on d.id=m.documento_id join pec.retiro r on r.id=m.retiro_id join pec.categoria c on c.id=m.categoria_id
          left join pec.pasto p on p.id=m.pasto_id left join pec.lote l on l.id=m.lote_id left join pec.raca ra on ra.id=m.raca_id order by d.numero""")
L.append("CREATE TEMP TABLE carga (linha text, data date, op text, obs text, sentido smallint, sigla text, pasto text, lote text, cat text, raca text, qtd int, strep text);")
L.append("INSERT INTO carga VALUES " + ",".join(
    f"({lit(a)},{lit(b)},{lit(c)},{lit(d)},{e},{lit(f)},{lit(g)},{lit(h)},{lit(i)},{lit(j)},{k},{lit(l)})" for a,b,c,d,e,f,g,h,i,j,k,l in mv) + ";")
L.append("INSERT INTO pec.documento (fazenda_id, operacao_codigo, data, observacao, origem, importacao_id, linha_origem) SELECT k.faz, op, data, obs, 'IMPORTACAO', (SELECT id FROM pec.importacao), linha FROM k, carga ORDER BY data, linha;")
L.append("""INSERT INTO pec.movimento (documento_id, sentido, fazenda_id, retiro_id, pasto_id, lote_id, categoria_id, raca_id, quantidade, data, status_reprodutivo)
SELECT d.id, c.sentido, d.fazenda_id, r.id, p.id, l.id, ct.id, ra.id, c.qtd, c.data, NULLIF(c.strep,'')
  FROM carga c JOIN pec.documento d ON d.linha_origem = c.linha JOIN pec.retiro r ON r.sigla = c.sigla
  JOIN pec.categoria ct ON ct.nome = c.cat LEFT JOIN pec.raca ra ON ra.nome = c.raca
  LEFT JOIN pec.pasto p ON p.codigo = c.pasto LEFT JOIN pec.lote l ON l.retiro_id = r.id AND l.codigo = c.lote;""")
pd = q("select titulo, descricao, acao_recomendada, coalesce(r.nome,''), prioridade, p.status from pec.pendencia p left join pec.retiro r on r.id=p.retiro_id order by numero")
L.append("INSERT INTO pec.pendencia (fazenda_id, origem, titulo, descricao, acao_recomendada, retiro_id, prioridade, status) SELECT k.faz, 'IMPORTACAO', v.t, v.d, v.a, r.id, v.p::pec.prioridade_t, v.s::pec.status_pend_t FROM k, (VALUES " + ",".join(
    "(" + ",".join(lit(x) for x in row) + ")" for row in pd) + ") v(t,d,a,rn,p,s) LEFT JOIN pec.retiro r ON r.nome = v.rn;")
oc = q("select aba, coalesce(linha::text,''), coalesce(coluna,''), severidade, regra, mensagem, coalesce(valor,'') from pec.importacao_ocorrencia order by id")
L.append("INSERT INTO pec.importacao_ocorrencia (importacao_id, aba, linha, coluna, severidade, regra, mensagem, valor) SELECT (SELECT id FROM pec.importacao), v.ab, NULLIF(v.li,'')::int, NULLIF(v.co,''), v.se::pec.nivel_alerta_t, v.re, v.me, NULLIF(v.va,'') FROM (VALUES " + ",".join(
    "(" + ",".join(lit(x) for x in row) + ")" for row in oc) + ") v(ab,li,co,se,re,me,va);")
L.append("UPDATE pec.parametro SET valor = '\"BLOQUEAR\"' WHERE chave = 'ESTOQUE_NEGATIVO';")
L.append("COMMIT;")
print("\n".join(L))
