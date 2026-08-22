# OSB Getting Started

Guia prático para aprender **Oracle Service Bus (OSB)**: como montar um ambiente local via
Docker e como funciona o ciclo básico **Proxy Service → Pipeline → Business Service**.

Pensado para quem está a começar com OSB e quer um ponto de partida reproduzível, sem precisar
de uma instalação on-prem completa.

## Estrutura do repositório

```
.
├── README.md                              — este guia
├── docker/
│   ├── setenv.sh                          — variáveis de ambiente do domínio OSB
│   └── docker-compose.yml                 — domínio OSB-only (base de dados + Admin + Managed Server)
└── test/
    ├── test-proxy.sh                      — script curl para testar uma Proxy Service
    └── osb-test.postman_collection.json   — coleção Postman equivalente
```

## Guia passo a passo

Baseado em: https://github.com/oracle/docker-images/tree/main/OracleSOASuite

### 0. Pré-requisitos

- Docker Desktop, com o **WSL2 backend** ativo, e uma distro WSL2 (ex: Ubuntu) instalada.
- Corre todos os comandos abaixo **dentro da shell WSL2** (não no PowerShell/CMD), porque os
  scripts e caminhos são Linux.
- ~16 GB RAM livres e ~40 GB de disco.
- Uma conta Oracle (gratuita) para aceitar as licenças.

### 1. Download dos binários (manual, na Oracle)

#### 1.1. Instaladores do SOA Suite / OSB

Em https://edelivery.oracle.com, procura "Oracle SOA Suite" e baixa para a versão **12.2.1.4.0**:

- `fmw_12.2.1.4.0_soa.jar`
- `fmw_12.2.1.4.0_osb.jar`
- `fmw_12.2.1.4.0_b2bhealthcare.jar`

#### 1.2. Imagem base (Oracle Fusion Middleware Infrastructure)

1. Vai a https://container-registry.oracle.com e faz login com a tua conta Oracle.
2. Navega até **Middleware → fmw-infrastructure** e seleciona a tag **`12.2.1.4`** (JDK 8 +
   Oracle Linux 7 — compatível com os `.jar` acima).
3. Aceita a **License Agreement** dessa imagem (obrigatório antes do pull funcionar).
4. Gera um **Auth Token** — desde 30/06/2025 a Oracle já não aceita a password normal da conta
   no `docker login`:
   - Clica no ícone da conta (canto superior direito) → **Auth Token**.
   - Gera um novo token e copia o valor (só é mostrado uma vez).
5. Faz login do Docker usando o Auth Token como password:

   ```bash
   docker login container-registry.oracle.com
   # Username: <o teu email da conta Oracle>
   # Password: <cola aqui o Auth Token, não a password da conta>
   ```

6. Faz o pull da imagem base:

   ```bash
   docker pull container-registry.oracle.com/middleware/fmw-infrastructure:12.2.1.4
   ```

   ```bash
   docker images | grep fmw-infrastructure   # confirma que ficou local
   ```

### 2. Clonar o repositório oficial e construir a imagem

```bash
git clone https://github.com/oracle/docker-images.git
cd docker-images/OracleSOASuite/dockerfiles

# coloca os 3 .jar baixados dentro de 12.2.1.4/
cp /caminho/para/*.jar 12.2.1.4/

sh buildDockerImage.sh -v 12.2.1.4
```

Isto cria a imagem `oracle/soasuite:12.2.1.4` — ainda sem domínio configurado.

### 3. Copiar os ficheiros deste repositório

Copia `docker/setenv.sh` e `docker/docker-compose.yml` (desta pasta `osb`) para dentro da tua
checkout do `docker-images`, por exemplo para `docker-images/OracleSOASuite/osb-domain/`.

Edita `setenv.sh`:
- Confirma `DC_REGISTRY_SOA="localhost"` (assume que a imagem ficou local após o build).
- **Muda as passwords** (`DC_ORCL_SYSPWD`, `DC_ADMIN_PWD`, `DC_RCU_SCHPWD`) — regra Oracle:
  mín. 8 caracteres, pelo menos 1 maiúscula e 1 número.

### 4. Subir o ambiente

```bash
cd docker-images/OracleSOASuite/osb-domain
source setenv.sh

# 1) Base de dados — espera até aparecer "DATABASE IS READY TO USE!" no log
docker-compose up -d soadb
docker logs -f soadb

# 2) Admin Server — primeira vez corre o RCU e cria o domínio OSB (demora 20-40 min)
docker-compose up -d osbas
docker logs -f osbas

# 3) Managed Server — expõe as Proxy Services
docker-compose up -d osbms
docker logs -f osbms
```

### 5. Aceder às consolas

- **WebLogic Admin Console**: http://localhost:7001/console (user: `weblogic`, password: a que definiste em `DC_ADMIN_PWD`)
- **Service Bus Console**: http://localhost:7001/servicebus

### 6. Fazer o pequeno teste

Na Service Bus Console:

1. Cria um **Business Service** REST apontando para, por exemplo, `https://httpbin.org/get`.
2. Cria uma **Proxy Service** REST (ex: path `/echo/test`) com uma rota simples para essa
   Business Service.
3. Ativa (*Activate*) as mudanças na sessão.

Depois testa com um dos scripts em `test/`:

```bash
cd test
./test-proxy.sh /echo/test
```

Ou importa `test/osb-test.postman_collection.json` no Postman.

Uma resposta HTTP 200 vinda do `httpbin.org` através do OSB confirma o ciclo completo:
**cliente → Proxy Service → pipeline → Business Service → resposta**.

### Parar / limpar

```bash
docker-compose down          # para os containers, mantém os dados (volumes em $DC_USERHOME)
docker-compose down -v       # para e apaga volumes nomeados (dados ficam em bind mounts, não são apagados)
rm -rf $DC_USERHOME          # apaga mesmo tudo (domínio + dados da BD)
```
