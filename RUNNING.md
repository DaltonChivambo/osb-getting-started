# Como correr o ambiente OSB (dia-a-dia)

Este guia assume que já fizeste a configuração inicial (build da imagem `oracle/soasuite`,
`docker-images` clonado, domínio já criado pelo menos uma vez — ver `README.md` para isso).
Aqui é só o essencial para ligar/desligar o ambiente numa sessão normal de trabalho.

## 0. Pré-requisitos

Docker Desktop tem de estar a correr. Se não estiver:

```bash
"/c/Users/<o teu user>/AppData/Local/Programs/DockerDesktop/Docker Desktop.exe" &
```

Espera até `docker info` funcionar sem erro antes de continuares.

**Importante — usa Git Bash, não PowerShell/CMD.** Todos os comandos abaixo (`source
./setenv.sh` incluído) são bash/POSIX. Em PowerShell, `source` não existe e o script nem chega
a correr — as variáveis `DC_*` ficam todas por definir, o `docker-compose` recebe valores em
branco, e vais ver avisos tipo `The "DC_ORCL_HOST" variable is not set` seguidos de erros como
`invalid spec: :/opt/oracle/oradata: empty section between colons`. Se vires esses avisos, é
sinal de que estás na shell errada.

Duas formas de resolver:

- **Abrir uma janela Git Bash a sério** — menu Iniciar → escreve "Git Bash" → Enter. O prompt
  passa a ser do estilo `user@host MINGW64 ~/caminho$`, não `PS C:\...>`. É preciso ser mesmo
  essa janela nova — correr `bash.exe` dentro do PowerShell sem mais nada normalmente só entra
  num sub-shell interativo, o que confunde fácil.
- **Ficar no PowerShell mas invocar o Git Bash só para o comando** — mais à prova de erro,
  porque não depende de "estares na janela certa". Usa `bash.exe -lc "..."` com o comando
  completo lá dentro:

  ```powershell
  & "C:\Program Files\Git\bin\bash.exe" -lc "cd '/d/caminho/para/o/repo/docker' && source ./setenv.sh && docker-compose up -d soadb"
  ```

  (ajusta o caminho ao teu clone; usa `/d/...` em vez de `D:\...`, com `/` em vez de `\`).

## 1. Subir o ambiente

Corre a partir da pasta `docker/` deste repositório (os container names — `soadb`, `osbas`,
`osbms` — já resolvem-se por DNS interno do Docker Compose, não precisas de mexer em hosts):

```bash
cd docker
source ./setenv.sh

# 1) Base de dados — espera por "DATABASE IS READY TO USE!"
docker-compose up -d soadb
docker logs -f soadb

# 2) Admin Server — como o domínio já existe, salta RCU/criação e arranca direto
docker-compose up -d osbas
docker logs -f osbas

# 3) Managed Server — expõe as Proxy Services em :9001/:9002
docker-compose up -d osbms
docker logs -f osbms
```

Numa máquina onde o domínio já foi criado, isto demora poucos minutos (arranque normal do
WebLogic), não os 20-40 min da primeira vez.

## 2. Acompanhar o progresso real

O `docker logs` dos containers `osbas`/`osbms` só mostra o *wrapper* do script. O boot real do
WebLogic fica dentro do container:

```bash
# Admin Server
docker exec osbas tail -f /u01/oracle/user_projects/domains/infra_domain/logs/as.log

# Managed Server
docker exec osbms tail -f /u01/oracle/user_projects/domains/infra_domain/logs/osb_server1/ms.log
```

Procura pela linha `The server started in RUNNING mode.` — é o sinal definitivo de que arrancou.

`docker ps` pode mostrar `(unhealthy)` ou `(health: starting)` durante um bocado mesmo depois de
aparecer `RUNNING mode` no log — o healthcheck demora um pouco a apanhar o estado novo. Não é
erro por si só.

## 3. Verificar que está tudo bem

```bash
docker ps --filter name=soadb --filter name=osbas --filter name=osbms
```

Os três devem aparecer `Up ... (healthy)`.

Confirmação definitiva (mais fiável que o healthcheck do Docker): entra no
**WebLogic Admin Console** → *Environment → Servers* e confirma que `AdminServer` e
`osb_server1` aparecem `RUNNING` / `OK`. (`osb_server2` aparece sempre `SHUTDOWN` — é normal,
este `docker-compose.yml` só cria container para `osb_server1`.)

## 4. Acessos

| O quê | URL | Credenciais |
|---|---|---|
| WebLogic Admin Console | http://localhost:7001/console | `weblogic` / o que definiste em `DC_ADMIN_PWD` (setenv.sh) |
| Service Bus Console | http://localhost:7001/servicebus | idem |
| Proxy Services (runtime) | http://localhost:9001/... (HTTP) e :9002 (HTTPS) | — |

## 5. Testar uma Proxy Service

Depois de criares uma Proxy Service na Service Bus Console (ver passo 6 do `README.md`):

```bash
cd test
./test-proxy.sh /caminho/da/tua/proxy
```

ou importa `test/osb-test.postman_collection.json` no Postman.

## 6. Parar

```bash
cd docker
docker-compose down          # para os containers, mantém os dados (domínio + BD)
```

Não uses `docker-compose down -v` nem apagues `$DC_USERHOME` a não ser que queiras mesmo
recomeçar do zero — isso obriga a correr o RCU e a criação do domínio outra vez (20-40 min).

Um `docker-compose down` normal (sem `-v`) é seguro — os dados reais da BD Oracle vivem no
volume nomeado `osb_soadb_orcl` (declarado neste `docker-compose.yml`), que sobrevive à
remoção dos containers. **Isto só é verdade se a tua cópia do `docker-compose.yml` já tiver
essa entrada `volumes: soadb_orcl:`** — sem ela, o Docker cria um volume anónimo novo (vazio)
de cada vez que o `soadb` é recriado, e perdes as schemas RCU em silêncio (ver primeiro item
de "Problemas comuns" abaixo).

## Problemas comuns

- **`osbas` falha a arrancar com `ORA-01017: invalid username/password` no `as.log`**, mesmo
  tendo a certeza de que a password em `setenv.sh` está certa: isto não é um problema de
  password — é a schema RCU (`OSB01_OPSS`, etc.) que deixou de existir na base de dados. A
  imagem `database/enterprise` guarda os datafiles reais em `/ORCL`, um volume *anónimo*
  declarado dentro da própria imagem. Se o teu `docker-compose.yml` não tiver a entrada
  `soadb_orcl:/ORCL` (e a secção `volumes: soadb_orcl:` no fim do ficheiro), um
  `docker-compose down` + `up` recria esse volume vazio sem avisar, e a base "esquece-se" de
  tudo o que o RCU criou — mesmo continuando a arrancar normalmente e a ficar `healthy`, porque
  do ponto de vista dela é só uma base nova. Este `docker-compose.yml` já vem com o volume
  nomeado para evitar isto; se acontecer mesmo assim, confirma que a tua cópia está actualizada
  (`git pull`).
- **`/servicebus` redireciona para `errorPage.jspx`** (normalmente ao tentar fazer login, não
  necessariamente ao carregar a página inicial): confirma no `as.log` (ver secção 2) se há
  `java.net.URISyntaxException: Malformed IPv6 address at index 8: ldap://[172.20.0.x]:7001`.
  É um bug de incompatibilidade entre o JDK 8 mais recente incluído na imagem e código antigo
  do FMW (`libOVD`/`ArisID`) que envolve endereços IPv4 em `[]` como se fossem IPv6 ao construir
  URLs LDAP para o identity store embutido. `EXTRA_JAVA_PROPERTIES=-Djava.net.preferIPv4Stack=true`
  (já definido em `osbas`/`osbms`) **não chega sozinho** — só evita alguns casos, mas o login em
  si continua a falhar. O fix real é editar a config do OVD para deixar de usar o IP dinâmico do
  container:

  ```bash
  MSYS_NO_PATHCONV=1 docker exec osbas sed -i \
    's|<host percentage="100" port="-1" readonly="false">%HOST%</host>|<host percentage="100" port="-1" readonly="false">localhost</host>|' \
    /u01/oracle/user_projects/domains/infra_domain/config/fmwconfig/ovd/default/adapters.os_xml
  docker restart osbas
  ```

  Isto troca o macro `%HOST%` (que se resolve para o IP dinâmico do container, ex:
  `172.20.0.3` — daí o "endereço IPv6 malformado") por `localhost`, que é correto neste caso: é
  o identity store embutido do próprio WebLogic, self-referencing, não precisa de ser
  alcançável a partir de outros containers. Como isto vive no domínio (bind mount), só precisas
  de fazer isto **uma vez** — sobrevive a `docker-compose down`/`up` normais. Confirmado por
  login real (POST a `j_security_check`), não só por a página inicial carregar.
- **`osbms` preso em "Waiting for the Managed Server to accept requests..."**: confirma no
  `ms.log` se há `Enter username to boot WebLogic server` seguido de `shutdown hook` — significa
  que falta `ADMIN_PASSWORD` no serviço `osbms`.
- **`osbms` sempre `(unhealthy)` mesmo com `RUNNING mode` no log**: o healthcheck da imagem
  verifica a porta errada se faltar `MANAGED_SERVER_CONTAINER=true` e `MANAGEDSERVER_PORT=9001`
  no ambiente do serviço.
