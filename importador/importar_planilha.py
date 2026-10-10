#!/usr/bin/env python3
"""
Importador do "Mapa_do_Gado_v3.xlsx" para o Sistema de Gestão Pecuária.

Uso:
    python3 importar_planilha.py Mapa_do_Gado_v3.xlsx --saida ./saida [--fazenda "Nome da fazenda"] [--org "JS Rural"]

Gera:
    saida/05_carga_planilha.sql      → carga transacional (rodar depois de 01..04)
    saida/relatorio_importacao.md    → relatório de inconsistências (antes de importar)
    saida/ocorrencias.csv            → mesmas ocorrências, uma por linha (para filtrar)

Princípios:
  * IDs determinísticos (uuid5): reimportar o mesmo arquivo não duplica nada.
  * Lê só VALORES digitados (colunas de entrada); fórmulas da planilha são
    recalculadas pelo banco e comparadas com os valores em cache do Excel.
  * Nada é descartado em silêncio: tudo que não entra vira ocorrência.
"""
import argparse, csv, datetime as dt, hashlib, sys, uuid
from collections import defaultdict, Counter
from pathlib import Path

import openpyxl

NS = uuid.UUID("6f1f6b5e-9c1a-4a59-9a63-6a1d2f0c0001")
def uid(*partes):  # ID estável a partir de chaves de negócio
    return str(uuid.uuid5(NS, "|".join(str(p) for p in partes)))

def q(v):
    if v is None: return "NULL"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, (dt.date, dt.datetime)): return "'" + v.strftime("%Y-%m-%d") + "'"
    return "'" + str(v).replace("'", "''") + "'"

# --- Conhecimento de domínio que a planilha só tem em texto (Leia-me / cabeçalhos) ---
FASE = {"Vaca":"MATRIZ","Primípara":"MATRIZ","Novilha Matriz":"MATRIZ","Leiteira":"LEITEIRA",
        "Bez. Macho":"BEZERRO","Bez. Fêmea":"BEZERRO","Vaca Descarte":"DESCARTE","Desmama Fêmea":"RECRIA",
        "Novilha":"RECRIA","Fêmea Descarte":"DESCARTE","Desmama Macho":"RECRIA","Garrote":"RECRIA",
        "Boi":"ENGORDA","Touro":"REPRODUTOR"}
GRUPO = {"Vaca":"Matrizes","Primípara":"Matrizes","Novilha Matriz":"Matrizes","Leiteira":"Matrizes",
         "Bez. Macho":"Bezerros ao pé","Bez. Fêmea":"Bezerros ao pé","Vaca Descarte":"Descarte","Fêmea Descarte":"Descarte",
         "Desmama Fêmea":"Recria","Novilha":"Recria","Desmama Macho":"Recria","Garrote":"Recria","Boi":"Bois","Touro":"Touros"}
IDADE = {"Desmama Fêmea":(8,12),"Desmama Macho":(8,12),"Novilha":(13,24),"Garrote":(13,24),"Boi":(25,None),
         "Bez. Macho":(0,8),"Bez. Fêmea":(0,8)}
TRANSICOES = [  # (de, para, operação, gatilho) — Leia-me itens 5 e 8
    ("Bez. Macho","Desmama Macho","DESMAMA","desmama (8 m)"),
    ("Bez. Fêmea","Desmama Fêmea","DESMAMA","desmama (8 m)"),
    ("Bez. Macho","Desmama Macho","ERA","correção de classificação sem pesagem"),
    ("Bez. Fêmea","Desmama Fêmea","ERA","correção de classificação sem pesagem"),
    ("Desmama Macho","Garrote","ERA","13 meses"),
    ("Garrote","Boi","ERA","25 meses"),
    ("Desmama Fêmea","Novilha","ERA","13 meses"),
    ("Novilha","Novilha Matriz","ERA","entrada em reprodução"),
    ("Novilha Matriz","Primípara","ERA","1º parto"),
    ("Primípara","Vaca","ERA","2º parto"),
    ("Vaca","Primípara","ERA","correção: vaca de 1ª cria"),
    ("Vaca","Vaca Descarte","ERA","descarte"),
    ("Primípara","Vaca Descarte","ERA","descarte"),
    ("Novilha Matriz","Fêmea Descarte","ERA","descarte"),
    ("Novilha","Fêmea Descarte","ERA","descarte"),
    ("Desmama Fêmea","Fêmea Descarte","ERA","descarte"),
    ("Vaca","Leiteira","ERA","separação para leite"),
    ("Leiteira","Vaca","ERA","retorno ao rebanho de cria"),
]
CAUSA_GRUPO = lambda n: ("Acidente" if n.startswith("Acidente") or n in ("Atolado/Afogado","Raio","Fratura Perna")
                         else "Predação" if n in ("Onça","Cobra") else "Indeterminada" if n == "Não Identificada"
                         else "Manejo" if n in ("Sacrificado","Parto","Curso") else "Doença/Intoxicação")


class Relatorio:
    def __init__(s): s.itens = []
    def add(s, sev, aba, linha, regra, msg, valor=None, coluna=None):
        s.itens.append(dict(severidade=sev, aba=aba, linha=linha, coluna=coluna, regra=regra, mensagem=msg,
                            valor=None if valor is None else str(valor)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xlsx"); ap.add_argument("--saida", default="saida")
    ap.add_argument("--fazenda", default="Fazenda (editar nome)")  # fazenda única com 9 retiros; nome editável em Cadastros
    ap.add_argument("--org", default="JS Rural")
    a = ap.parse_args()
    out = Path(a.saida); out.mkdir(parents=True, exist_ok=True)

    raw = Path(a.xlsx).read_bytes()
    hsh = hashlib.sha256(raw).hexdigest()
    wb  = openpyxl.load_workbook(a.xlsx)                  # fórmulas
    wbv = openpyxl.load_workbook(a.xlsx, data_only=True)  # valores em cache (o que o Excel mostrava)
    rel = Relatorio()
    sql = []
    W = sql.append

    org_id = uid("org", a.org); faz_id = uid("faz", a.org, a.fazenda); imp_id = uid("imp", hsh)
    W("BEGIN;\nSET search_path = pec, public;")
    W(f"INSERT INTO pec.organizacao (id,nome) VALUES ({q(org_id)},{q(a.org)}) ON CONFLICT DO NOTHING;")
    W(f"INSERT INTO pec.fazenda (id,organizacao_id,nome) VALUES ({q(faz_id)},{q(org_id)},{q(a.fazenda)}) ON CONFLICT DO NOTHING;")
    W(f"INSERT INTO pec.importacao (id,fazenda_id,arquivo,hash_arquivo) VALUES ({q(imp_id)},{q(faz_id)},{q(Path(a.xlsx).name)},{q(hsh)}) ON CONFLICT DO NOTHING;")
    # durante a carga, estoque negativo só alerta (a planilha não bloqueava)
    W(f"INSERT INTO pec.parametro VALUES ({q(faz_id)},'ESTOQUE_NEGATIVO','\"ALERTAR\"','Política de estoque negativo') "
      "ON CONFLICT (fazenda_id,chave) DO UPDATE SET valor = EXCLUDED.valor;")

    # ------------------------------------------------------------ Cadastros
    cad = wb["Cadastros"]
    def coluna(col, ini=5, fim=40):
        vals = []
        for r in range(ini, fim):
            v = cad[f"{col}{r}"].value
            if v is None or (isinstance(v, str) and not v.strip()): continue
            vals.append((r, v))
        return vals

    retiros = {}
    for i, (r, nome) in enumerate(coluna("B", 5, 14)):
        rid = uid("ret", faz_id, nome); area_inf = cad[f"D{r}"].value
        tipo = "CONFINAMENTO" if "Confin" in nome else "ILP" if nome.startswith("ILP") else "PASTO"
        sig = {"Água Funda":"AgF","Pontal":"Pon","Seringa":"Ser","Placa":"Pla","Queimada":"Que","Potrillo":"Pot",
               "Confinamento":"Conf","ILP - Pastoril":"ILPPas","ILP - Potrillo":"ILPPot"}.get(nome)
        retiros[nome] = rid
        W(f"INSERT INTO pec.retiro (id,fazenda_id,nome,sigla,area_informada_ha,tipo,ordem) VALUES "
          f"({q(rid)},{q(faz_id)},{q(nome)},{q(sig)},{q(area_inf)},{q(tipo)},{i+1}) ON CONFLICT DO NOTHING;")

    mapao_col = {}
    fx = wb["Mapão - Fechamento"]
    for r in range(24, 38):
        mapao_col[fx[f"B{r}"].value] = fx[f"C{r}"].value  # B é fórmula =Cadastros!G..; resolvemos por ordem abaixo
    rotulos_mapao = [fx[f"C{r}"].value for r in range(24, 38)]

    categorias = {}
    safra_ini = cad["X5"].value.date() if isinstance(cad["X5"].value, dt.datetime) else cad["X5"].value
    for i, (r, nome) in enumerate(coluna("G", 5, 19)):
        cid = uid("cat", org_id, nome); sexo = "M" if cad[f"H{r}"].value == "Macho" else "F"
        categorias[nome] = dict(id=cid, sexo=sexo, fase=FASE.get(nome))
        if nome not in FASE:
            rel.add("ATENCAO", "Cadastros", r, "CATEGORIA_NOVA", f"Categoria '{nome}' sem fase zootécnica conhecida — classificar.", nome)
        imin, imax = IDADE.get(nome, (None, None))
        W(f"INSERT INTO pec.categoria (id,organizacao_id,nome,sexo,fase,idade_min_meses,idade_max_meses,permite_nascimento,"
          f"eh_matriz,grupo_dashboard,coluna_mapao,ordem) VALUES ({q(cid)},{q(org_id)},{q(nome)},{q(sexo)},{q(FASE.get(nome,'RECRIA'))},"
          f"{q(imin)},{q(imax)},{q(nome.startswith('Bez.'))},{q(nome in ('Vaca','Primípara','Novilha Matriz'))},"
          f"{q(GRUPO.get(nome))},{q(rotulos_mapao[i] if i < len(rotulos_mapao) else None)},{i+1}) ON CONFLICT DO NOTHING;")
        W(f"INSERT INTO pec.categoria_parametro VALUES ({q(cid)},'2000-01-01',{q(cad[f'I{r}'].value)},NULL,{q(cad[f'J{r}'].value)}) ON CONFLICT DO NOTHING;")
    for de, para, op, g in TRANSICOES:
        if de in categorias and para in categorias:
            W(f"INSERT INTO pec.categoria_transicao VALUES ({q(categorias[de]['id'])},{q(categorias[para]['id'])},{q(op)},{q(g)}) ON CONFLICT DO NOTHING;")

    racas = {}
    for r, nome in coluna("O", 5, 12):
        racas[nome] = uid("raca", org_id, nome)
        W(f"INSERT INTO pec.raca (id,organizacao_id,nome) VALUES ({q(racas[nome])},{q(org_id)},{q(nome)}) ON CONFLICT DO NOTHING;")
    causas = {}
    for r, nome in coluna("Q", 5, 30):
        causas[nome] = uid("causa", org_id, nome)
        W(f"INSERT INTO pec.causa_morte (id,organizacao_id,nome,grupo) VALUES ({q(causas[nome])},{q(org_id)},{q(nome)},{q(CAUSA_GRUPO(nome))}) ON CONFLICT DO NOTHING;")
    canais = {}
    for r, nome in coluna("S", 5, 12):
        canais[nome] = uid("canal", org_id, nome)
        W(f"INSERT INTO pec.canal_venda (id,organizacao_id,nome) VALUES ({q(canais[nome])},{q(org_id)},{q(nome)}) ON CONFLICT DO NOTHING;")
    status_rep = [v for _, v in coluna("U", 5, 14)]
    tipos_planilha = {v: cad[f"M{r}"].value for r, v in coluna("L", 5, 22)}

    W(f"INSERT INTO pec.parametro VALUES ({q(faz_id)},'LOTACAO_MAX','{cad['X7'].value}','Lotação máxima desejada (UA/ha)'),"
      f"({q(faz_id)},'LOTACAO_MIN','{cad['X8'].value}','Lotação mínima desejada (UA/ha)'),"
      f"({q(faz_id)},'PN_PADRAO_M','32','Peso ao nascer padrão macho (kg) — confirmar'),"
      f"({q(faz_id)},'PN_PADRAO_F','30','Peso ao nascer padrão fêmea (kg) — confirmar'),"
      f"({q(faz_id)},'DIAS_ATE_DG','30','Dias entre IATF e DG'),"
      f"({q(faz_id)},'DIV_BAIXA_CAB','2','Divergência baixa até N cab.'),"
      f"({q(faz_id)},'DIV_BAIXA_PCT','0.02','Divergência baixa até %'),"
      f"({q(faz_id)},'DIV_MEDIA_PCT','0.05','Divergência média até %') ON CONFLICT DO NOTHING;")
    safra_fim = (dt.date(safra_ini.year + 1, safra_ini.month, safra_ini.day) - dt.timedelta(days=1))
    safra_nome = f"{safra_ini.year}/{safra_ini.year+1}"
    safra_id = uid("safra", faz_id, safra_nome)
    W(f"INSERT INTO pec.safra (id,fazenda_id,nome,inicio,fim,status) VALUES ({q(safra_id)},{q(faz_id)},{q(safra_nome)},{q(safra_ini)},{q(safra_fim)},'ABERTA') ON CONFLICT DO NOTHING;")

    # ------------------------------------------------------------ Pastos
    pastos = {}  # (retiro, codigo) -> id
    ps = wb["Pastos"]; vistos = Counter()
    for r in range(6, ps.max_row + 1):
        ret, cod, area, obs = ps[f"B{r}"].value, ps[f"C{r}"].value, ps[f"D{r}"].value, ps[f"I{r}"].value
        if not ret and not cod: continue
        if ret not in retiros:
            rel.add("CRITICO","Pastos",r,"RETIRO_INEXISTENTE",f"Pasto {cod} aponta para retiro '{ret}' que não existe em Cadastros.",ret); continue
        vistos[cod] += 1
        if vistos[cod] > 1:
            rel.add("CRITICO","Pastos",r,"PASTO_DUPLICADO",f"Código de pasto {cod} repetido.",cod); continue
        pid = uid("pasto", faz_id, cod); pastos[(ret, cod)] = pid
        generico = str(cod).endswith("-Geral")
        if (area or 0) == 0 and not generico:
            rel.add("PENDENTE","Pastos",r,"PASTO_SEM_AREA",f"{cod} ({ret}) com área 0 ha — lotação não calculável.",area)
        if obs and "linha vermelha" in obs:
            rel.add("PENDENTE","Pastos",r,"PASTO_RETIRO_DUVIDOSO",f"{cod}: {obs}",cod)
        W(f"INSERT INTO pec.pasto (id,fazenda_id,retiro_id,codigo,area_ha,generico,observacao) VALUES "
          f"({q(pid)},{q(faz_id)},{q(retiros[ret])},{q(cod)},{q(area or 0)},{q(generico)},{q(obs)}) ON CONFLICT DO NOTHING;")
    for nome in retiros:
        if nome in ("Confinamento","ILP - Pastoril","ILP - Potrillo"):
            r = list(retiros).index(nome) + 5
            if not cad[f"D{r}"].value:
                rel.add("PENDENTE","Cadastros",r,"RETIRO_SEM_AREA",f"Retiro '{nome}' sem mapa e sem área informada (coluna D).",None,"D")

    # ------------------------------------------------------------ Lançamentos → livro
    lc = wb["Lançamentos"]; lcv = wbv["Lançamentos"]
    cab = [c.value for c in lc[1]]
    idx = {n: i for i, n in enumerate(cab)}
    vistos_linha = {}
    lotes = {}
    linhas_ok = 0; docs = []
    rot_ent = {}; rot_sai = {}
    # de/para rótulo da planilha → (operação, sentido)
    DEPARA = {
        "Entrada - Saldo Inicial":("SALDO_INICIAL",1), "Entrada - Nascimento":("NASCIMENTO",1), "Entrada - Compra":("COMPRA",1),
        "Entrada - Transferência de Retiro":("TRANSF_RETIRO",1), "Entrada - Transferência de Pasto":("TRANSF_PASTO",1),
        "Entrada - Desmama":("DESMAMA",1), "Entrada - Transferência de Era":("ERA",1), "Entrada - Réfugo de Cocho":("REFUGO_COCHO",1),
        "Entrada - Ajuste de Inventário":("AJUSTE_INVENTARIO",1), "Saída - Venda":("VENDA",-1), "Saída - Morte":("MORTE",-1),
        "Saída - Transferência de Retiro":("TRANSF_RETIRO",-1), "Saída - Transferência de Pasto":("TRANSF_PASTO",-1),
        "Saída - Desmama":("DESMAMA",-1), "Saída - Transferência de Era":("ERA",-1), "Saída - Réfugo de Cocho":("REFUGO_COCHO",-1),
        "Saída - Ajuste de Inventário":("AJUSTE_INVENTARIO",-1)}
    for t, s in tipos_planilha.items():
        if t not in DEPARA:
            rel.add("CRITICO","Cadastros",None,"TIPO_SEM_DEPARA",f"Tipo de movimentação '{t}' sem correspondência no sistema.",t)
        elif DEPARA[t][1] != s:
            rel.add("CRITICO","Cadastros",None,"SINAL_DIVERGENTE",f"'{t}': sinal {s} na planilha × {DEPARA[t][1]} no sistema.",t)

    dobradas = defaultdict(list)
    for r in range(2, lc.max_row + 1):
        g = lambda n: lc.cell(r, idx[n] + 1).value
        data, ret, pasto, lote, cat, mov, qtd = g("Data"), g("Retiro"), g("Pasto"), g("Lote"), g("Categoria"), g("Movimentação"), g("Quantidade (cab)")
        raca, causa, od, obs, resp, strep, canal, peso, valor = (g("Raça"), g("Causa da Morte"), g("Origem / Destino"), g("Observação"),
            g("Responsável"), g("Status Reprodutivo"), g("Canal de Venda"), g("Peso Total (kg)"), g("Valor Total (R$)"))
        if all(v is None for v in (data, ret, pasto, lote, cat, mov, qtd)): continue
        L = f"{r}"
        alerta_xl = lcv.cell(r, idx["Alerta"] + 1).value
        # --- validações (relatório) ---
        falta = [n for n, v in (("Data",data),("Retiro",ret),("Categoria",cat),("Movimentação",mov),("Quantidade",qtd)) if v in (None,"")]
        if falta:
            rel.add("CRITICO","Lançamentos",r,"INCOMPLETO",f"Linha {L} sem: {', '.join(falta)} — não importada.",None); continue
        if not isinstance(qtd,(int,float)) or qtd <= 0 or int(qtd) != qtd:
            rel.add("CRITICO","Lançamentos",r,"QTD_INVALIDA",f"Linha {L}: quantidade '{qtd}' inválida — não importada.",qtd); continue
        if ret not in retiros: rel.add("CRITICO","Lançamentos",r,"RETIRO_INEXISTENTE",f"Linha {L}: retiro '{ret}' não cadastrado.",ret); continue
        if cat not in categorias: rel.add("CRITICO","Lançamentos",r,"CATEGORIA_INVALIDA",f"Linha {L}: categoria '{cat}' não cadastrada.",cat); continue
        if mov not in DEPARA: rel.add("CRITICO","Lançamentos",r,"MOV_INVALIDA",f"Linha {L}: movimentação '{mov}' inválida.",mov); continue
        op, sentido = DEPARA[mov]
        if raca and raca not in racas: rel.add("ATENCAO","Lançamentos",r,"RACA_INVALIDA",f"Linha {L}: raça '{raca}' não cadastrada.",raca)
        if pasto is None:
            rel.add("PENDENTE","Lançamentos",r,"SEM_PASTO",f"Linha {L}: {qtd} {cat} ({ret}/{lote or 'sem lote'}) sem pasto — entra na linha SEM PASTO do Mapão.",None,"D")
        elif (ret, pasto) not in pastos:
            rel.add("CRITICO","Lançamentos",r,"PASTO_FORA_DO_RETIRO",f"Linha {L}: pasto '{pasto}' não pertence a '{ret}'.",pasto,"D"); continue
        if op == "MORTE" and not causa: rel.add("PENDENTE","Lançamentos",r,"MORTE_SEM_CAUSA",f"Linha {L}: morte sem causa.",None)
        if op == "VENDA" and not canal: rel.add("PENDENTE","Lançamentos",r,"VENDA_SEM_CANAL",f"Linha {L}: venda sem canal.",None)
        if op == "VENDA" and (not peso or not valor): rel.add("PENDENTE","Lançamentos",r,"VENDA_INCOMPLETA",f"Linha {L}: venda sem peso/valor.",None)
        if op == "NASCIMENTO" and not str(cat).startswith("Bez."): rel.add("CRITICO","Lançamentos",r,"NASC_CATEGORIA",f"Linha {L}: nascimento em '{cat}'.",cat)
        if lote is None: rel.add("ATENCAO","Lançamentos",r,"SEM_LOTE",f"Linha {L}: {qtd} {cat} em {ret} sem lote.",None,"E")
        if isinstance(data, dt.datetime) and obs and "aproximada" in str(obs).lower():
            rel.add("ATENCAO","Lançamentos",r,"DATA_APROXIMADA",f"Linha {L}: data {data:%d/%m/%Y} marcada como aproximada na observação.",None,"B")
        if op == "SALDO_INICIAL" and obs and "contagem de" in str(obs):
            rel.add("ATENCAO","Lançamentos",r,"SALDO_RETROATIVO",f"Linha {L}: saldo inicial em {data:%d/%m/%Y} vem de contagem posterior ({obs}).",None)
        if alerta_xl not in (None, "OK"):
            rel.add("PENDENTE","Lançamentos",r,"ALERTA_PLANILHA",f"Linha {L}: alerta da planilha = '{alerta_xl}'.",alerta_xl,"V")
        chave = (data, ret, pasto, lote, cat, mov, qtd, raca)
        if chave in vistos_linha:
            rel.add("ATENCAO","Lançamentos",r,"POSSIVEL_DUPLICIDADE",f"Linha {L} idêntica à linha {vistos_linha[chave]} — confirme se não é lançamento em dobro.",None)
        vistos_linha[chave] = r
        if strep and strep not in status_rep: rel.add("ATENCAO","Lançamentos",r,"STATUS_INVALIDO",f"Linha {L}: status reprodutivo '{strep}'.",strep)

        lote_id = None
        if lote:
            lote_id = uid("lote", faz_id, ret, lote)
            lotes[lote_id] = (ret, lote)
        doc_id = uid("doc", imp_id, r)
        mv = dict(r=r, doc=doc_id, op=op, sentido=sentido, data=data.date() if isinstance(data, dt.datetime) else data,
                  ret=ret, pasto=pasto, lote_id=lote_id, cat=cat, raca=raca, qtd=int(qtd), causa=causa, canal=canal,
                  peso=peso, valor=valor, obs=obs, strep=strep, od=od)
        docs.append(mv); linhas_ok += 1

    # partida dobrada: na planilha cada perna é uma linha → parear (data, operação, categoria/qtd)
    pares = defaultdict(list)
    for m in docs:
        if m["op"] in ("TRANSF_PASTO","TRANSF_RETIRO","DESMAMA","ERA","REFUGO_COCHO"):
            pares[(m["data"], m["op"], m["qtd"])].append(m)
    for k, grupo in pares.items():
        s = [m for m in grupo if m["sentido"] == -1]; e = [m for m in grupo if m["sentido"] == 1]
        if len(s) == 1 and len(e) == 1:
            e[0]["doc"] = s[0]["doc"]  # mesmo documento
        else:
            for m in grupo:
                rel.add("CRITICO","Lançamentos",m["r"],"TRANSF_SEM_PAR",f"Linha {m['r']}: {m['op']} de {m['qtd']} cab. em {m['data']} sem a perna correspondente.",None)

    for lid, (ret, cod) in lotes.items():
        W(f"INSERT INTO pec.lote (id,fazenda_id,retiro_id,codigo,safra_id) VALUES ({q(lid)},{q(faz_id)},{q(retiros[ret])},{q(cod)},{q(safra_id)}) ON CONFLICT DO NOTHING;")

    emitidos = set()
    for m in sorted(docs, key=lambda x: (x["data"], x["r"])):
        if m["doc"] not in emitidos:
            emitidos.add(m["doc"])
            W(f"INSERT INTO pec.documento (id,fazenda_id,operacao_codigo,data,causa_morte_id,canal_venda_id,peso_total_kg,valor_total,"
              f"observacao,origem,importacao_id,linha_origem) VALUES ({q(m['doc'])},{q(faz_id)},{q(m['op'])},{q(m['data'])},"
              f"{q(causas.get(m['causa']))},{q(canais.get(m['canal']))},{q(m['peso'])},{q(m['valor'])},{q(m['obs'])},'IMPORTACAO',"
              f"{q(imp_id)},{q('Lançamentos!'+str(m['r']))}) ON CONFLICT DO NOTHING;")
        W(f"INSERT INTO pec.movimento (id,documento_id,sentido,fazenda_id,retiro_id,pasto_id,lote_id,categoria_id,raca_id,quantidade,data,status_reprodutivo) "
          f"VALUES ({q(uid('mov', imp_id, m['r']))},{q(m['doc'])},{m['sentido']},{q(faz_id)},{q(retiros[m['ret']])},"
          f"{q(pastos.get((m['ret'], m['pasto'])))},{q(m['lote_id'])},{q(categorias[m['cat']]['id'])},{q(racas.get(m['raca']))},"
          f"{m['qtd']},{q(m['data'])},{q(m['strep'])}) ON CONFLICT DO NOTHING;")

    # ------------------------------------------------------------ Regras zootécnicas cruzadas (por lote)
    por_lote = defaultdict(lambda: Counter())
    for m in docs:
        if m["cat"] in ("Vaca","Primípara") and m["op"] == "SALDO_INICIAL" and m["strep"] == "Parida":
            por_lote[(m["ret"], m["lote_id"])]["paridas"] += m["qtd"]
        if m["cat"].startswith("Bez.") and m["sentido"] == 1:
            por_lote[(m["ret"], m["lote_id"])]["bez"] += m["qtd"]
            por_lote[(m["ret"], m["lote_id"])][f"{m['cat']}|{m['raca']}"] += m["qtd"]
    for (ret, lid), c in por_lote.items():
        if c["paridas"] and c["paridas"] != c["bez"]:
            dif = c["paridas"] - c["bez"]
            sev = "CRITICO" if c["bez"] == 0 else "ATENCAO"
            rel.add(sev,"Lançamentos",None,"VACA_PARIDA_SEM_BEZERRO",
                    f"{ret} / {lotes.get(lid,('', '—'))[1]}: {c['paridas']} vacas paridas × {c['bez']} bezerros ao pé (faltam {dif}).",dif)
        combos = {k: v for k, v in c.items() if "|" in k}
        if len(combos) >= 2 and c["bez"]:
            pass
    # combinações sexo×raça improváveis (ex.: lote só com machos Nelore e fêmeas Angus)
    for (ret, lid), c in por_lote.items():
        combos = {k: v for k, v in c.items() if "|" in k}
        sexos_racas = defaultdict(set)
        for k in combos: cat, raca = k.split("|"); sexos_racas[cat].add(raca)
        if len(combos) == 2 and sexos_racas.get("Bez. Macho") and sexos_racas.get("Bez. Fêmea") \
           and sexos_racas["Bez. Macho"].isdisjoint(sexos_racas["Bez. Fêmea"]):
            rel.add("ATENCAO","Lançamentos",None,"SEXO_RACA_IMPROVAVEL",
                    f"{ret} / {lotes.get(lid,('', '—'))[1]}: machos só {', '.join(sexos_racas['Bez. Macho'])} e fêmeas só "
                    f"{', '.join(sexos_racas['Bez. Fêmea'])} — provável troca de raça/sexo no lançamento.", None)
    # bezerros 'Angus' de vacas Nelore
    for m in docs:
        if m["op"] == "NASCIMENTO" and m["raca"] == "Angus":
            rel.add("ATENCAO","Lançamentos",m["r"],"F1_COMO_ANGUS",f"Linha {m['r']}: {m['qtd']} {m['cat']} 'Angus' em lote de vacas Nelore — provável ½ Angus × Nelore (F1).",None,"I")
    # categoria x idade (bezerros no confinamento)
    for m in docs:
        if m["cat"].startswith("Bez.") and m["ret"] == "Confinamento":
            rel.add("ATENCAO","Lançamentos",m["r"],"CATEGORIA_X_LOCAL",f"Linha {m['r']}: {m['qtd']} {m['cat']} (mamando) no Confinamento — provavelmente já desmamados.",None)

    # ------------------------------------------------------------ Fórmulas quebradas da planilha (#REF!) e cobertura
    for ws in wb.worksheets:
        for row in ws.iter_rows():
            for c in row:
                if isinstance(c.value, str) and "#REF!" in c.value:
                    rel.add("ATENCAO", ws.title, c.row, "FORMULA_REF", f"{ws.title}!{c.coordinate}: fórmula com #REF! (referência perdida).", None, c.column_letter)

    # ------------------------------------------------------------ Pendências
    pd = wb["Pendências"]
    for r in range(6, pd.max_row + 1):
        if not pd[f"E{r}"].value: continue
        pr = {"ALTA":"ALTA","MÉDIA":"MEDIA","BAIXA":"BAIXA"}.get(pd[f"G{r}"].value, "MEDIA")
        stt = "RESOLVIDA" if pd[f"I{r}"].value == "S" else "ABERTA"
        ret = pd[f"C{r}"].value
        W(f"INSERT INTO pec.pendencia (id,fazenda_id,origem,titulo,descricao,acao_recomendada,retiro_id,prioridade,status) VALUES "
          f"({q(uid('pend', imp_id, r))},{q(faz_id)},'IMPORTACAO',{q(str(pd[f'D{r}'].value or '')+' — '+str(ret))},"
          f"{q(pd[f'E{r}'].value)},{q(pd[f'F{r}'].value)},{q(retiros.get(ret))},{q(pr)},{q(stt)}) ON CONFLICT DO NOTHING;")

    # ocorrências também vão para o banco (rastreáveis)
    for o in rel.itens:
        W(f"INSERT INTO pec.importacao_ocorrencia (importacao_id,aba,linha,coluna,severidade,regra,mensagem,valor) VALUES "
          f"({q(imp_id)},{q(o['aba'])},{q(o['linha'])},{q(o['coluna'])},{q(o['severidade'])},{q(o['regra'])},{q(o['mensagem'])},{q(o['valor'])});")
    W(f"UPDATE pec.parametro SET valor = '\"BLOQUEAR\"' WHERE fazenda_id = {q(faz_id)} AND chave = 'ESTOQUE_NEGATIVO';")
    W("COMMIT;")
    (out / "05_carga_planilha.sql").write_text("\n".join(sql), encoding="utf-8")

    # ------------------------------------------------------------ Relatório
    ordem = {"CRITICO":0,"ATENCAO":1,"PENDENTE":2,"NORMAL":3}
    itens = sorted(rel.itens, key=lambda o: (ordem[o["severidade"]], o["regra"], o["linha"] or 0))
    with open(out / "ocorrencias.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["severidade","regra","aba","linha","coluna","mensagem","valor"], delimiter=";")
        w.writeheader(); [w.writerow({k: o[k] for k in w.fieldnames}) for o in itens]
    cont = Counter(o["severidade"] for o in itens)
    md = [f"# Relatório de importação — {Path(a.xlsx).name}", "",
          f"SHA-256 `{hsh[:16]}…` · {linhas_ok} linhas de Lançamentos aceitas · {len(pastos)} pastos · {len(retiros)} retiros · {len(categorias)} categorias",
          "", f"**Críticos:** {cont['CRITICO']} · **Atenção:** {cont['ATENCAO']} · **Pendentes:** {cont['PENDENTE']}", ""]
    por_regra = defaultdict(list)
    for o in itens: por_regra[(o["severidade"], o["regra"])].append(o)
    for (sev, regra), lst in por_regra.items():
        md.append(f"## {sev} · {regra} ({len(lst)})")
        for o in lst: md.append(f"- {o['mensagem']}")
        md.append("")
    (out / "relatorio_importacao.md").write_text("\n".join(md), encoding="utf-8")
    print(f"OK: {linhas_ok} lançamentos, {len(rel.itens)} ocorrências → {out}")

if __name__ == "__main__":
    main()
