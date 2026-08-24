# OSB Getting Started

Guia prático para aprender **Oracle Service Bus (OSB)**: como montar um ambiente local via
Docker e como funciona o ciclo básico **Proxy Service → Pipeline → Business Service**.

Pensado para quem está a começar com OSB e quer um ponto de partida reproduzível, sem precisar
de uma instalação on-prem completa.

## Estrutura do repositório

```
.
├── README.md                              — este guia (setup inicial, do zero)
├── RUNNING.md                             — arrancar/parar o ambiente numa sessão normal
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

- Docker Desktop instalado e a correr (o backend WSL2 é o recomendado pela própria Docker
  Desktop, mas não é preciso correr os comandos dentro de uma distro WSL2 — ver nota abaixo).
- Corre os comandos abaixo numa shell bash (**Git Bash** no Windows serve perfeitamente,
  ou uma distro WSL2 se preferires) — os scripts (`setenv.sh`) e os caminhos usados são
  estilo Linux/POSIX. O Docker Desktop trata a tradução dos bind mounts (`$HOME/osb-docker/...`)
  para o filesystem do Windows automaticamente quando corres a partir do Git Bash.
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

**Notas sobre o arranque:**

- O `docker logs -f` do `osbas`/`osbms` só mostra o *wrapper* do container script. O log real
  do WebLogic (RCU, criação do domínio, boot do servidor) fica dentro do container, em
  `/u01/oracle/user_projects/domains/infra_domain/logs/as.log` (Admin Server) ou
  `.../logs/osb_server1/ms.log` (Managed Server). Para acompanhar o progresso real:

  ```bash
  docker exec osbas tail -f /u01/oracle/user_projects/domains/infra_domain/logs/as.log
  docker exec osbms tail -f /u01/oracle/user_projects/domains/infra_domain/logs/osb_server1/ms.log
  ```

- `docker ps` pode mostrar os containers como `(unhealthy)` ou `(health: starting)` durante
  vários minutos depois de o log já dizer `The server started in RUNNING mode.` — o healthcheck
  demora um pouco a apanhar o estado novo. Não é sinal de erro por si só; confia na mensagem
  `RUNNING mode` no log.
- Se o `osbms` ficar preso indefinidamente em "Waiting for the Managed Server to accept
  requests..." sem nunca avançar nem o container morrer, o mais provável é o processo Java ter
  morrido logo a seguir a arrancar (por exemplo, por falta de `boot.properties`) e o script
  wrapper ficou à espera de uma linha no log que nunca vai aparecer. Confirma sempre no
  `ms.log` (comando acima) — se vires `Enter username to boot WebLogic server` seguido de
  `shutdown hook`, falta a variável `ADMIN_PASSWORD` no serviço `osbms` do
  `docker-compose.yml`.

### 4.1 Fix obrigatório, uma vez só: identity store embutido

Na primeira vez que o domínio é criado, o login na Service Bus Console (e em qualquer página
ADF autenticada) falha com um redirect para `errorPage.jspx`. A causa é um bug de
incompatibilidade entre o JDK 8 incluído na imagem e código antigo do FMW: o identity store
embutido (`libOVD`) tenta ligar-se via `ldap://[<ip-do-container>]:7001` — colocar um endereço
IPv4 entre `[]`, como se fosse IPv6, faz o parser de URI mais recente rejeitar com
`Malformed IPv6 address`. Corrige-se trocando o host dinâmico por `localhost` (correto aqui,
porque é um identity store self-referencing, não precisa de ser alcançável de fora):

```bash
MSYS_NO_PATHCONV=1 docker exec osbas sed -i \
  's|<host percentage="100" port="-1" readonly="false">%HOST%</host>|<host percentage="100" port="-1" readonly="false">localhost</host>|' \
  /u01/oracle/user_projects/domains/infra_domain/config/fmwconfig/ovd/default/adapters.os_xml
docker restart osbas
```

Isto vive na configuração do domínio (bind mount), por isso só precisas de fazer isto **uma
vez** — sobrevive a `docker-compose down`/`up` normais. Ver `RUNNING.md` para mais detalhe.

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
