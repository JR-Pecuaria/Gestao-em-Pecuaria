-- =====================================================================
-- SISTEMA DE GESTÃO PECUÁRIA — ENTREGA 1
-- 01_schema.sql — Estrutura de dados (PostgreSQL 15+ / Supabase)
--
-- Princípios:
--   1. Livro central de movimentações: o estoque NUNCA é gravado, é sempre
--      calculado (saldo = Σ entradas − Σ saídas).
--   2. Uma única fonte de verdade por assunto; dashboards só leem views.
--   3. Nada é apagado: lançamentos são estornados; tudo é auditado.
--   4. Chaves UUID geradas no dispositivo (permite lançar offline).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS extensions;      -- no Supabase já existe
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS pec;
SET search_path = pec, public, extensions;

-- ---------------------------------------------------------------------
-- 0. Domínios e tipos
-- ---------------------------------------------------------------------
CREATE TYPE pec.sexo_t           AS ENUM ('M','F');
CREATE TYPE pec.status_cad_t     AS ENUM ('ATIVO','INATIVO');
CREATE TYPE pec.status_lanc_t    AS ENUM ('ATIVO','ESTORNADO','ESTORNO');
CREATE TYPE pec.origem_reg_t     AS ENUM ('APP','WEB','IMPORTACAO','SISTEMA','API');
CREATE TYPE pec.status_periodo_t AS ENUM ('ABERTO','EM_FECHAMENTO','FECHADO');
CREATE TYPE pec.prioridade_t     AS ENUM ('ALTA','MEDIA','BAIXA');
CREATE TYPE pec.status_pend_t    AS ENUM ('ABERTA','EM_ANDAMENTO','RESOLVIDA','CANCELADA');
CREATE TYPE pec.nivel_alerta_t   AS ENUM ('CRITICO','ATENCAO','PENDENTE','NORMAL');
CREATE TYPE pec.fase_cat_t       AS ENUM ('BEZERRO','RECRIA','MATRIZ','ENGORDA','REPRODUTOR','DESCARTE','LEITEIRA');

-- ---------------------------------------------------------------------
-- 1. Organização, usuários e permissões (RBAC)
-- ---------------------------------------------------------------------
CREATE TABLE pec.organizacao (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome          text NOT NULL,
  documento     text,                       -- CPF/CNPJ do produtor
  criado_em     timestamptz NOT NULL DEFAULT now()
);

-- Em Supabase, id = auth.users.id
CREATE TABLE pec.usuario (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id uuid NOT NULL REFERENCES pec.organizacao,
  nome          text NOT NULL,
  email         text UNIQUE,
  status        pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  criado_em     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pec.papel (               -- Administrador, Gerente, Escritório, Encarregado, Vaqueiro, Diretoria
  codigo        text PRIMARY KEY,
  nome          text NOT NULL,
  descricao     text
);

CREATE TABLE pec.permissao (           -- ex.: MOV_LANCAR, MOV_ESTORNAR, PERIODO_FECHAR, CAD_EDITAR...
  codigo        text PRIMARY KEY,
  descricao     text NOT NULL
);

CREATE TABLE pec.papel_permissao (
  papel_codigo     text REFERENCES pec.papel ON DELETE CASCADE,
  permissao_codigo text REFERENCES pec.permissao ON DELETE CASCADE,
  PRIMARY KEY (papel_codigo, permissao_codigo)
);

-- ---------------------------------------------------------------------
-- 2. Estrutura física: Fazenda → Retiro → Pasto
-- ---------------------------------------------------------------------
CREATE TABLE pec.fazenda (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id uuid NOT NULL REFERENCES pec.organizacao,
  nome           text NOT NULL,
  municipio      text,
  uf             char(2),
  area_total_ha  numeric(12,2) CHECK (area_total_ha >= 0),
  responsavel    text,
  inscricao_estadual text,
  status         pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  criado_em      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organizacao_id, nome)
);

-- Escopo de acesso: usuário × fazenda (opcionalmente × retiro) × papel
CREATE TABLE pec.usuario_acesso (
  usuario_id    uuid REFERENCES pec.usuario ON DELETE CASCADE,
  fazenda_id    uuid REFERENCES pec.fazenda ON DELETE CASCADE,
  papel_codigo  text NOT NULL REFERENCES pec.papel,
  retiro_ids    uuid[],                      -- NULL = todos os retiros da fazenda
  PRIMARY KEY (usuario_id, fazenda_id)
);

CREATE TABLE pec.retiro (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id    uuid NOT NULL REFERENCES pec.fazenda,
  nome          text NOT NULL,
  sigla         text,                        -- AgF, Pon, Ser, Pla, Que, Pot...
  area_informada_ha numeric(12,2) CHECK (area_informada_ha >= 0),  -- p/ retiros sem mapa (Confinamento, ILP)
  tipo          text NOT NULL DEFAULT 'PASTO' CHECK (tipo IN ('PASTO','CONFINAMENTO','ILP','SEMICONFINAMENTO')),
  status        pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  ordem         int,
  UNIQUE (fazenda_id, nome),
  UNIQUE (id, fazenda_id)                    -- alvo de FK composta
);

CREATE TABLE pec.pasto (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id    uuid NOT NULL,
  retiro_id     uuid NOT NULL,
  codigo        text NOT NULL,               -- código do mapa: AgF-10, Pon-6A...
  nome          text,
  area_ha       numeric(10,2) NOT NULL DEFAULT 0 CHECK (area_ha >= 0),
  tipo          text,                        -- capim/forrageira, piquete, curral, cocho...
  forrageira    text,
  lotacao_min_ua_ha numeric(6,2),            -- NULL = usa o parâmetro da fazenda
  lotacao_max_ua_ha numeric(6,2),
  generico      boolean NOT NULL DEFAULT false,  -- "Conf-Geral": pasto genérico de retiro sem mapa
  geom          jsonb,                       -- GeoJSON do polígono (futuro mapa)
  status        pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  observacao    text,
  FOREIGN KEY (retiro_id, fazenda_id) REFERENCES pec.retiro (id, fazenda_id),
  UNIQUE (fazenda_id, codigo),
  UNIQUE (id, retiro_id)                     -- garante "pasto pertence ao retiro" nas FKs
);

-- ---------------------------------------------------------------------
-- 3. Cadastros mestres (todos extensíveis sem alterar código)
-- ---------------------------------------------------------------------
CREATE TABLE pec.categoria (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,             -- Vaca, Primípara, Bez. Macho...
  sexo            pec.sexo_t NOT NULL,
  fase            pec.fase_cat_t NOT NULL,
  idade_min_meses int,
  idade_max_meses int,
  permite_nascimento boolean NOT NULL DEFAULT false,  -- só bezerros
  eh_matriz       boolean NOT NULL DEFAULT false,     -- Vaca, Primípara, Novilha Matriz
  grupo_dashboard text,                      -- Matrizes, Bezerros ao pé, Recria, Bois, Descarte, Touros
  coluna_mapao    text,                      -- rótulo da coluna no Mapão
  ordem           int NOT NULL,
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  UNIQUE (organizacao_id, nome)
);

-- Parâmetros da categoria COM VIGÊNCIA: mudar o fator de UA não reescreve o passado
CREATE TABLE pec.categoria_parametro (
  categoria_id    uuid REFERENCES pec.categoria ON DELETE CASCADE,
  vigente_desde   date NOT NULL,
  fator_ua        numeric(5,3) NOT NULL CHECK (fator_ua >= 0),
  peso_ref_kg     numeric(7,2),
  meta_mortalidade numeric(6,4) CHECK (meta_mortalidade BETWEEN 0 AND 1),
  PRIMARY KEY (categoria_id, vigente_desde)
);

-- Mudanças de categoria permitidas (Transferência de Era / Desmama)
CREATE TABLE pec.categoria_transicao (
  de_categoria_id   uuid REFERENCES pec.categoria,
  para_categoria_id uuid REFERENCES pec.categoria,
  operacao_codigo   text NOT NULL,           -- ERA ou DESMAMA
  gatilho           text,                    -- '13 meses', '1º parto', 'entrada em reprodução'...
  PRIMARY KEY (de_categoria_id, para_categoria_id, operacao_codigo)
);

CREATE TABLE pec.raca (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,             -- Nelore, Angus, Cruzado, ½ Angus x Nelore (F1)...
  composicao      jsonb,                     -- {"Nelore":0.5,"Angus":0.5}
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  UNIQUE (organizacao_id, nome)
);

CREATE TABLE pec.causa_morte (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,
  grupo           text,                      -- Acidente, Predação, Doença, Manejo, Indeterminada
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  UNIQUE (organizacao_id, nome)
);

CREATE TABLE pec.canal_venda (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,             -- Leilão, Frigorífico, Venda Direta
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  UNIQUE (organizacao_id, nome)
);

CREATE TABLE pec.parceiro (                  -- compradores, fornecedores, frigoríficos, leiloeiras
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,
  documento       text,
  tipo            text[] NOT NULL DEFAULT '{}',  -- {COMPRADOR,FORNECEDOR}
  municipio       text, uf char(2),
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO'
);

CREATE TABLE pec.colaborador (               -- vaqueiros, encarregados, técnicos (podem não ser usuários)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,
  funcao          text,
  usuario_id      uuid REFERENCES pec.usuario,
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO'
);

-- Tipo de OPERAÇÃO (o evento de negócio). O sentido (+/−) fica em cada perna.
-- "Entrada - Compra" da planilha = operação COMPRA, perna +1.
-- "Saída/Entrada - Transferência de Pasto" = operação TRANSF_PASTO, duas pernas.
CREATE TABLE pec.tipo_operacao (
  codigo            text PRIMARY KEY,        -- SALDO_INICIAL, NASCIMENTO, COMPRA, VENDA, MORTE, TRANSF_PASTO...
  nome              text NOT NULL,
  sentido_permitido smallint[] NOT NULL,     -- {1}, {-1} ou {1,-1}
  partida_dobrada   boolean NOT NULL DEFAULT false,  -- exige perna de saída + perna de entrada
  muda_categoria    boolean NOT NULL DEFAULT false,  -- ERA, DESMAMA
  muda_local        boolean NOT NULL DEFAULT false,  -- TRANSF_PASTO, TRANSF_RETIRO, TRANSF_FAZENDA
  afeta_rebanho     boolean NOT NULL,        -- entra/sai da FAZENDA (false = movimento interno)
  grupo_mapao       char(1),                 -- N=nascimento, M=morte, V=venda, E=outras entradas, S=outras saídas
  exige_causa       boolean NOT NULL DEFAULT false,
  exige_canal       boolean NOT NULL DEFAULT false,
  exige_parceiro    boolean NOT NULL DEFAULT false,
  exige_peso        boolean NOT NULL DEFAULT false,
  exige_valor       boolean NOT NULL DEFAULT false,
  so_categoria_nascimento boolean NOT NULL DEFAULT false,
  rotulo_planilha_entrada text,              -- de/para da importação
  rotulo_planilha_saida   text,
  ativo             boolean NOT NULL DEFAULT true,
  ordem             int
);

-- ---------------------------------------------------------------------
-- 4. Tempo: safras e períodos (fechamento mensal)
-- ---------------------------------------------------------------------
CREATE TABLE pec.safra (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  nome            text NOT NULL,             -- 2026/2027
  inicio          date NOT NULL,
  fim             date NOT NULL,
  status          text NOT NULL DEFAULT 'ABERTA' CHECK (status IN ('PLANEJADA','ABERTA','ENCERRADA')),
  CHECK (fim > inicio),
  UNIQUE (fazenda_id, nome)
);
-- Impede safras sobrepostas na mesma fazenda
ALTER TABLE pec.safra ADD CONSTRAINT safra_sem_sobreposicao
  EXCLUDE USING gist (fazenda_id WITH =, daterange(inicio, fim, '[]') WITH &&);

CREATE TABLE pec.safra_meta (                -- metas por safra (opcionalmente por retiro/categoria)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  safra_id        uuid NOT NULL REFERENCES pec.safra ON DELETE CASCADE,
  indicador_codigo text NOT NULL,            -- TX_PRENHEZ, TX_DESMAME, MORTALIDADE, PESO_DESMAMA...
  retiro_id       uuid REFERENCES pec.retiro,
  categoria_id    uuid REFERENCES pec.categoria,
  valor_meta      numeric NOT NULL
);

CREATE TABLE pec.periodo (                   -- 1 linha por fazenda × mês
  fazenda_id      uuid REFERENCES pec.fazenda,
  competencia     date NOT NULL CHECK (extract(day FROM competencia) = 1),
  status          pec.status_periodo_t NOT NULL DEFAULT 'ABERTO',
  fechado_por     uuid REFERENCES pec.usuario,
  fechado_em      timestamptz,
  reaberto_por    uuid REFERENCES pec.usuario,
  reaberto_em     timestamptz,
  motivo_reabertura text,
  snapshot        jsonb,                     -- fotografia do fechamento (saldo por retiro×pasto×categoria)
  PRIMARY KEY (fazenda_id, competencia)
);

-- Parâmetros gerais por fazenda (chave/valor tipado)
CREATE TABLE pec.parametro (
  fazenda_id      uuid REFERENCES pec.fazenda ON DELETE CASCADE,
  chave           text NOT NULL,             -- LOTACAO_MAX, LOTACAO_MIN, ESTOQUE_NEGATIVO, DIV_INV_BAIXA...
  valor           jsonb NOT NULL,
  descricao       text,
  PRIMARY KEY (fazenda_id, chave)
);

-- ---------------------------------------------------------------------
-- 5. Lotes e animais
-- ---------------------------------------------------------------------
CREATE TABLE pec.lote (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  retiro_id       uuid REFERENCES pec.retiro, -- retiro "de referência" (a localização real vem do livro)
  codigo          text NOT NULL,             -- Lote 01, Lote 02...
  descricao       text,
  carimbo         text,                      -- Cr8, Cr 08/09 (marca da geração de bezerros)
  safra_id        uuid REFERENCES pec.safra,
  finalidade      text,                      -- CRIA, RECRIA, ENGORDA, REPRODUCAO, CONFINAMENTO
  status          pec.status_cad_t NOT NULL DEFAULT 'ATIVO',
  criado_em       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fazenda_id, retiro_id, codigo)
);

CREATE TABLE pec.animal (                    -- opcional: controle individual (brinco/RFID/SISBOV)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  brinco          text,
  rfid            text,
  sisbov          text,
  nome            text,
  sexo            pec.sexo_t NOT NULL,
  raca_id         uuid REFERENCES pec.raca,
  data_nascimento date,
  mae_id          uuid REFERENCES pec.animal,
  pai_id          uuid REFERENCES pec.animal,
  touro_semen     text,                      -- quando o pai é sêmen (IATF)
  peso_nascimento_kg numeric(6,2),
  status          text NOT NULL DEFAULT 'ATIVO' CHECK (status IN ('ATIVO','VENDIDO','MORTO','BAIXADO')),
  observacao      text,
  UNIQUE (fazenda_id, brinco),
  UNIQUE (rfid)
);

-- ---------------------------------------------------------------------
-- 6. LIVRO CENTRAL DE MOVIMENTAÇÕES
--    documento  = o fato de negócio (uma venda, uma transferência, um parto...)
--    movimento  = cada perna que altera o estoque (+ ou −)
-- ---------------------------------------------------------------------
CREATE TABLE pec.documento (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- gerado no app (idempotente no sync)
  numero          bigint GENERATED ALWAYS AS IDENTITY UNIQUE,   -- nº legível sequencial
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  operacao_codigo text NOT NULL REFERENCES pec.tipo_operacao,
  data            date NOT NULL,
  safra_id        uuid REFERENCES pec.safra,                    -- preenchido por trigger
  causa_morte_id  uuid REFERENCES pec.causa_morte,
  canal_venda_id  uuid REFERENCES pec.canal_venda,
  parceiro_id     uuid REFERENCES pec.parceiro,                 -- comprador / fornecedor
  peso_total_kg   numeric(12,2) CHECK (peso_total_kg >= 0),
  valor_total     numeric(14,2) CHECK (valor_total >= 0),
  nota_fiscal     text,
  gta             text,
  responsavel_id  uuid REFERENCES pec.colaborador,              -- quem fez no campo
  observacao      text,
  status          pec.status_lanc_t NOT NULL DEFAULT 'ATIVO',
  estorna_documento_id uuid REFERENCES pec.documento,           -- se este doc é um ESTORNO
  origem          pec.origem_reg_t NOT NULL DEFAULT 'WEB',
  dispositivo_id  text,                                          -- offline: aparelho que gerou
  criado_por      uuid REFERENCES pec.usuario,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  sincronizado_em timestamptz,
  importacao_id   uuid,                                          -- rastreio da carga da planilha
  linha_origem    text                                           -- ex.: "Lançamentos!7"
);

CREATE TABLE pec.movimento (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id    uuid NOT NULL REFERENCES pec.documento ON DELETE RESTRICT,
  sentido         smallint NOT NULL CHECK (sentido IN (1,-1)),  -- +1 entrada, −1 saída
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  retiro_id       uuid NOT NULL,
  pasto_id        uuid,                                         -- NULL só aceito em IMPORTACAO (vira pendência)
  lote_id         uuid REFERENCES pec.lote,
  categoria_id    uuid NOT NULL REFERENCES pec.categoria,
  raca_id         uuid REFERENCES pec.raca,
  animal_id       uuid REFERENCES pec.animal,                   -- preenchido quando o controle é individual
  quantidade      integer NOT NULL CHECK (quantidade > 0),
  peso_kg         numeric(12,2) CHECK (peso_kg >= 0),           -- peso da perna (ex.: bezerros desmamados)
  data            date NOT NULL,                                -- copiada do documento (índice)
  estorno         boolean NOT NULL DEFAULT false,               -- perna de estorno (anula a original)
  qtd_liquida     integer GENERATED ALWAYS AS (CASE WHEN estorno THEN -quantidade ELSE quantidade END) STORED,
  efeito          integer GENERATED ALWAYS AS (sentido * CASE WHEN estorno THEN -quantidade ELSE quantidade END) STORED,
  status_reprodutivo text,                                      -- legado da planilha (Parida/Prenhe/Vazia...)
  FOREIGN KEY (retiro_id, fazenda_id) REFERENCES pec.retiro (id, fazenda_id),
  FOREIGN KEY (pasto_id, retiro_id)   REFERENCES pec.pasto (id, retiro_id),   -- pasto pertence ao retiro
  CHECK (animal_id IS NULL OR quantidade = 1)
);

CREATE INDEX movimento_saldo_ix   ON pec.movimento (fazenda_id, retiro_id, pasto_id, categoria_id, data);
CREATE INDEX movimento_doc_ix     ON pec.movimento (documento_id);
CREATE INDEX movimento_lote_ix    ON pec.movimento (lote_id, data);
CREATE INDEX movimento_animal_ix  ON pec.movimento (animal_id) WHERE animal_id IS NOT NULL;
CREATE INDEX documento_data_ix    ON pec.documento (fazenda_id, data, operacao_codigo);
CREATE INDEX documento_safra_ix   ON pec.documento (safra_id, operacao_codigo);

-- ---------------------------------------------------------------------
-- 7. Pesagens e desmama (detalhe zootécnico ligado ao livro)
-- ---------------------------------------------------------------------
CREATE TABLE pec.pesagem (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  data            date NOT NULL,
  documento_id    uuid REFERENCES pec.documento,   -- quando a pesagem é parte de uma desmama/venda
  animal_id       uuid REFERENCES pec.animal,
  lote_id         uuid REFERENCES pec.lote,
  categoria_id    uuid REFERENCES pec.categoria,
  quantidade      integer NOT NULL DEFAULT 1 CHECK (quantidade > 0),  -- pesagem de lote: n cab
  peso_total_kg   numeric(12,2) NOT NULL CHECK (peso_total_kg > 0),
  ecc             numeric(3,1),                     -- escore de condição corporal
  origem          text DEFAULT 'MANUAL'             -- MANUAL, BALANCA, IMPORTACAO
);

CREATE TABLE pec.desmama_registro (          -- 1 linha por bezerro (individual) ou por lote/sexo (agregado)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id    uuid NOT NULL REFERENCES pec.documento,   -- o documento DESMAMA do livro
  bezerro_id      uuid REFERENCES pec.animal,
  mae_id          uuid REFERENCES pec.animal,
  sexo            pec.sexo_t NOT NULL,
  quantidade      integer NOT NULL DEFAULT 1 CHECK (quantidade > 0),
  data_nascimento_media date,                       -- individual: data exata; agregado: média
  data_desmama    date NOT NULL,
  peso_total_kg   numeric(12,2) NOT NULL CHECK (peso_total_kg > 0),
  peso_nascimento_kg numeric(6,2),                  -- NULL = parâmetro por sexo
  lote_id         uuid REFERENCES pec.lote,
  retiro_id       uuid REFERENCES pec.retiro
);

-- ---------------------------------------------------------------------
-- 8. Reprodução (por LOTE compilado, com espaço p/ individual)
-- ---------------------------------------------------------------------
CREATE TABLE pec.estacao_monta (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  safra_id        uuid NOT NULL REFERENCES pec.safra,
  nome            text NOT NULL,             -- "Estação 26/27"
  inicio          date NOT NULL,
  fim             date NOT NULL,
  UNIQUE (fazenda_id, nome)
);

CREATE TABLE pec.lote_reprodutivo (          -- fêmeas expostas: um grupo homogêneo de manejo
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  estacao_id      uuid NOT NULL REFERENCES pec.estacao_monta,
  lote_id         uuid REFERENCES pec.lote,
  retiro_id       uuid NOT NULL REFERENCES pec.retiro,
  categoria_id    uuid NOT NULL REFERENCES pec.categoria,  -- Vaca, Primípara, Novilha Matriz
  qtd_expostas    integer NOT NULL CHECK (qtd_expostas > 0),
  ecc_medio       numeric(3,1),
  carimbo_bezerro text,                      -- Cr8 — geração que vai nascer
  observacao      text
);

CREATE TABLE pec.protocolo_iatf (            -- cadastro do protocolo (hormônios/dias)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacao_id  uuid NOT NULL REFERENCES pec.organizacao,
  nome            text NOT NULL,
  dias            jsonb NOT NULL DEFAULT '{"D0":0,"D8":8,"D10":10}',
  descricao       text
);

CREATE TABLE pec.iatf_rodada (               -- 1ª, 2ª, 3ª IATF de um lote reprodutivo
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lote_reprodutivo_id uuid NOT NULL REFERENCES pec.lote_reprodutivo ON DELETE CASCADE,
  rodada          smallint NOT NULL CHECK (rodada BETWEEN 1 AND 5),
  tipo            text NOT NULL DEFAULT 'IATF' CHECK (tipo IN ('IATF','RESSINCRONIZACAO','REPASSE_TOURO','MONTA_NATURAL')),
  protocolo_id    uuid REFERENCES pec.protocolo_iatf,
  data_d0         date,
  data_d8         date,
  data_iatf       date,
  qtd_inseminadas integer CHECK (qtd_inseminadas >= 0),
  touro_semen     text,                      -- nome/código do touro ou partida de sêmen
  raca_touro_id   uuid REFERENCES pec.raca,
  tecnico_id      uuid REFERENCES pec.colaborador,
  data_dg         date,
  qtd_prenhes     integer CHECK (qtd_prenhes >= 0),
  qtd_vazias      integer CHECK (qtd_vazias >= 0),
  qtd_perdas      integer DEFAULT 0,          -- mortes/descartes entre IATF e DG
  semen_lote_ext  text,                      -- vínculo com o controle de estoque de sêmen
  UNIQUE (lote_reprodutivo_id, rodada),
  CHECK (qtd_prenhes IS NULL OR qtd_inseminadas IS NULL OR qtd_prenhes <= qtd_inseminadas)
);

CREATE TABLE pec.diagnostico_final (         -- DG de fim de estação por lote reprodutivo
  lote_reprodutivo_id uuid PRIMARY KEY REFERENCES pec.lote_reprodutivo ON DELETE CASCADE,
  data_dg         date NOT NULL,
  qtd_prenhes     integer NOT NULL CHECK (qtd_prenhes >= 0),
  qtd_vazias      integer NOT NULL CHECK (qtd_vazias >= 0),
  qtd_descarte    integer NOT NULL DEFAULT 0,
  tecnico_id      uuid REFERENCES pec.colaborador
);

CREATE TABLE pec.parto (                     -- parto individual ou agregado; o bezerro entra no livro via NASCIMENTO
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id    uuid REFERENCES pec.documento,     -- documento NASCIMENTO correspondente
  lote_reprodutivo_id uuid REFERENCES pec.lote_reprodutivo,
  matriz_id       uuid REFERENCES pec.animal,
  bezerro_id      uuid REFERENCES pec.animal,
  data            date NOT NULL,
  qtd_partos      integer NOT NULL DEFAULT 1 CHECK (qtd_partos > 0),
  qtd_machos      integer NOT NULL DEFAULT 0,
  qtd_femeas      integer NOT NULL DEFAULT 0,
  qtd_natimortos  integer NOT NULL DEFAULT 0,
  dificuldade     smallint CHECK (dificuldade BETWEEN 1 AND 5),  -- escala de facilidade de parto
  observacao      text
);

-- ---------------------------------------------------------------------
-- 9. Inventário (Mapão) e conferência de campo
-- ---------------------------------------------------------------------
CREATE TABLE pec.inventario (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  retiro_id       uuid NOT NULL REFERENCES pec.retiro,
  competencia     date NOT NULL,             -- mês do Mapão
  data_posicao    date NOT NULL,             -- posição do sistema (último dia do mês)
  data_contagem   date,
  contado_por     uuid REFERENCES pec.colaborador,
  conferido_por   uuid REFERENCES pec.colaborador,
  status          text NOT NULL DEFAULT 'EMITIDO' CHECK (status IN ('EMITIDO','EM_CONTAGEM','CONTADO','AJUSTADO','CANCELADO')),
  UNIQUE (retiro_id, competencia)
);

CREATE TABLE pec.inventario_item (
  inventario_id   uuid REFERENCES pec.inventario ON DELETE CASCADE,
  pasto_id        uuid REFERENCES pec.pasto,   -- NULL = linha "SEM PASTO"
  categoria_id    uuid REFERENCES pec.categoria,
  qtd_sistema     integer NOT NULL,            -- fotografia no momento da emissão
  qtd_campo       integer CHECK (qtd_campo >= 0),
  diferenca       integer GENERATED ALWAYS AS (qtd_campo - qtd_sistema) STORED,
  observacao      text,
  documento_ajuste_id uuid REFERENCES pec.documento,  -- ajuste gerado a partir da divergência
  UNIQUE NULLS NOT DISTINCT (inventario_id, pasto_id, categoria_id)
);

-- ---------------------------------------------------------------------
-- 10. Pendências, alertas e auditoria
-- ---------------------------------------------------------------------
CREATE TABLE pec.pendencia (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  numero          bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  fazenda_id      uuid NOT NULL REFERENCES pec.fazenda,
  origem          text NOT NULL CHECK (origem IN ('MANUAL','INVENTARIO','ALERTA','IMPORTACAO','FECHAMENTO','REPRODUCAO')),
  referencia_tabela text,
  referencia_id   uuid,
  titulo          text NOT NULL,
  descricao       text,
  acao_recomendada text,
  retiro_id       uuid REFERENCES pec.retiro,
  pasto_id        uuid REFERENCES pec.pasto,
  lote_id         uuid REFERENCES pec.lote,
  prioridade      pec.prioridade_t NOT NULL DEFAULT 'MEDIA',
  responsavel_id  uuid REFERENCES pec.colaborador,
  prazo           date,
  status          pec.status_pend_t NOT NULL DEFAULT 'ABERTA',
  resolucao       text,
  resolvida_em    timestamptz,
  criado_por      uuid REFERENCES pec.usuario,
  criado_em       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pec.auditoria (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  momento         timestamptz NOT NULL DEFAULT now(),
  usuario_id      uuid,
  tabela          text NOT NULL,
  registro_id     text NOT NULL,
  acao            text NOT NULL CHECK (acao IN ('INSERT','UPDATE','DELETE','ESTORNO','FECHAMENTO','REABERTURA','IMPORTACAO')),
  valor_anterior  jsonb,
  valor_novo      jsonb,
  contexto        jsonb                     -- dispositivo, ip, motivo
);
CREATE INDEX auditoria_reg_ix ON pec.auditoria (tabela, registro_id);

-- Offline: fila de sincronização / conflitos
CREATE TABLE pec.sync_conflito (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispositivo_id  text NOT NULL,
  usuario_id      uuid REFERENCES pec.usuario,
  payload         jsonb NOT NULL,
  motivo          text NOT NULL,             -- PERIODO_FECHADO, ESTOQUE_NEGATIVO, DUPLICADO, CADASTRO_INATIVO...
  status          text NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE','RESOLVIDO','DESCARTADO')),
  criado_em       timestamptz NOT NULL DEFAULT now()
);

-- Importações (rastreabilidade da carga da planilha)
CREATE TABLE pec.importacao (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fazenda_id      uuid REFERENCES pec.fazenda,
  arquivo         text NOT NULL,
  hash_arquivo    text,
  executada_em    timestamptz NOT NULL DEFAULT now(),
  executada_por   uuid REFERENCES pec.usuario,
  resumo          jsonb
);
CREATE TABLE pec.importacao_ocorrencia (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  importacao_id   uuid NOT NULL REFERENCES pec.importacao ON DELETE CASCADE,
  aba             text, linha int, coluna text,
  severidade      pec.nivel_alerta_t NOT NULL,
  regra           text NOT NULL,
  mensagem        text NOT NULL,
  valor           text
);
