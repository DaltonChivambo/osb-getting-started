# Contas, logins e licenças Oracle — o que fazer antes de tudo

Quase tudo o que bloqueia quem começa este ambiente do zero não é o OSB em si: é **não ter
feito os logins e aceite as licenças** que a Oracle exige antes de deixar descarregar uma imagem
ou um instalador. Este documento junta isso num único sítio.

Se o `./start-osb.sh` falhou logo no início com `failed to resolve reference
"localhost/oracle/database:12.2.0.1-ee"`, é este o documento que precisas — vai direto à
secção [Erros comuns](#erros-comuns).

## 1. As três coisas diferentes (e porque se confundem)

| # | O quê | Onde | Para quê | Credencial |
|---|---|---|---|---|
| 1 | **Conta Oracle** (gratuita) | *Sign In* / *Create Account* em qualquer dos sites abaixo | Base de tudo o resto | email + password da conta |
| 2 | **Download manual dos instaladores** (`.jar`, JDeveloper) | https://edelivery.oracle.com | Os 3 jars do SOA/OSB/B2B e o JDeveloper | login no browser com a conta (1) |
| 3 | **Imagens Docker** (BD e `fmw-infrastructure`) | https://container-registry.oracle.com | `docker pull` das imagens base | `docker login` com **Auth Token** (não a password) + **aceitar a licença de cada imagem** |

O ponto 3 é o que mais engana: a password normal da conta **não** serve no `docker login`
(desde 30/06/2025) — é preciso um Auth Token — e, mesmo com login feito, o `docker pull`
recusa se não aceitaste a licença **dessa imagem** no site.

## 2. Ordem a seguir (checklist)

- [ ] **A.** Ter uma conta Oracle e conseguir entrar em https://container-registry.oracle.com
- [ ] **B.** Gerar um **Auth Token** (secção 3.1) e guardá-lo — só é mostrado uma vez
- [ ] **C.** `docker login container-registry.oracle.com` com o token (secção 3.2)
- [ ] **D.** Aceitar a licença de **Database → enterprise** (tag `12.2.0.1`) e de **Middleware → fmw-infrastructure** (tag `12.2.1.4`) (secção 3.3)
- [ ] **E.** `docker pull` das duas imagens + `docker tag` da imagem da BD (secção 3.4)
- [ ] **F.** Descarregar os instaladores em https://edelivery.oracle.com (secção 4)
- [ ] **G.** Construir a imagem `oracle/soasuite:12.2.1.4` — `../README.md`, secção 2. Inclui: clone parcial do `oracle/docker-images`, copiar os 3 jars, **converter CRLF → LF**, `docker tag` da base para `oracle/fmw-infrastructure:12.2.1.4.0`, `buildDockerImage.sh` e `docker tag` final para `localhost/oracle/soasuite:12.2.1.4`
- [ ] **H.** Se existir um domínio antigo em `~/osb-docker/osbdomain` e a BD é nova: `mv ~/osb-docker/osbdomain ~/osb-docker/osbdomain.old`
- [ ] **I.** `./start-osb.sh` na pasta `docker/` (1.ª vez: 20-40 min, com cronómetro)

O resumo de todos os comandos, por ordem, está no `../README.md`, "Caminho rápido".

O `./start-osb.sh` e o `docs/RUNNING.md` **assumem que de A a G já está feito**. Eles só ligam e
desligam o ambiente; não descarregam nem constroem nada.

## 3. Container Registry (imagens Docker)

### 3.1 Gerar o Auth Token

1. Abre https://container-registry.oracle.com e clica em **Sign In** (canto superior direito),
   com a tua conta Oracle.
2. Depois do login, clica no **teu nome / ícone de conta** (canto superior direito).
3. Escolhe **Auth Token** e gera um novo (**Generate Secret Key**). Dá-lhe um nome qualquer.
4. **Copia o valor logo.** Só é mostrado uma vez; se o perderes, geras outro.

> Trata o token como uma password: não o coloques no repo, no `setenv.sh` nem em screenshots.

### 3.2 Login do Docker

Em **Git Bash** (ou o terminal onde corres `docker`):

```bash
docker login container-registry.oracle.com
# Username: o email da tua conta Oracle
# Password: cola o Auth Token (NÃO a password da conta)
```

No Git Bash a password **não aparece** enquanto colas — é normal. Carrega Enter e deves ver
`Login Succeeded`.

### 3.3 Aceitar a licença de cada imagem

Ainda no site do Container Registry, com a sessão iniciada, para **cada** imagem:

| Navegação no site | Tag |
|---|---|
| **Database → enterprise** | `12.2.0.1` |
| **Middleware → fmw-infrastructure** | `12.2.1.4` |

Abre a página da imagem e aceita a **License Agreement**. Sem isto o `docker pull` falha mesmo
com o login certo. A licença é por imagem: aceitar uma não cobre a outra.

### 3.4 Pull e tag

```bash
# Imagem base do SOA/OSB (usada pelo buildDockerImage.sh)
docker pull container-registry.oracle.com/middleware/fmw-infrastructure:12.2.1.4

# Base de dados
docker pull container-registry.oracle.com/database/enterprise:12.2.0.1

# O docker-compose.yml espera a imagem da BD com este nome local (DC_REGISTRY_DB="localhost").
# É uma tag extra: não apaga a original.
docker tag container-registry.oracle.com/database/enterprise:12.2.0.1 localhost/oracle/database:12.2.0.1-ee
```

> **Uma linha só, de propósito.** Estes comandos `docker` funcionam tanto em Git Bash como em
> PowerShell, mas o `\` de continuação de linha **só existe em bash**: em PowerShell o `docker
> tag` falha com `"\\" is not a valid repository/tag` ou `requires 2 arguments`. Por isso o
> comando está todo na mesma linha. (Em PowerShell a continuação é o backtick `` ` ``.)

### 3.5 Confirmar

```bash
docker images | grep -E "oracle/database|fmw-infrastructure|oracle/soasuite"
```

Em PowerShell não há `grep`; o equivalente é:

```powershell
docker images | Select-String "oracle/database|fmw-infrastructure|oracle/soasuite"
```

Antes de arrancar o ambiente deves ver **estas três**:

| Repositório | Tag | De onde vem |
|---|---|---|
| `localhost/oracle/database` | `12.2.0.1-ee` | o `docker tag` acima |
| `container-registry.oracle.com/middleware/fmw-infrastructure` | `12.2.1.4` | `docker pull` |
| `oracle/soasuite` | `12.2.1.4` | `buildDockerImage.sh` (README, secção 2) |
| `localhost/oracle/soasuite` | `12.2.1.4` | `docker tag oracle/soasuite:12.2.1.4 localhost/oracle/soasuite:12.2.1.4` — é este o nome que o compose pede |

Se faltar alguma, o `./start-osb.sh` não consegue subir. Antes do build da `soasuite` é
preciso ainda uma tag para a base: `docker tag container-registry.oracle.com/middleware/fmw-infrastructure:12.2.1.4 oracle/fmw-infrastructure:12.2.1.4.0`
(o `Dockerfile` do build faz `FROM oracle/fmw-infrastructure:12.2.1.4.0`). Comandos completos no
`README.md`, secção 2.

## 4. Instaladores (edelivery.oracle.com)

Este é um login de **browser**, independente do Docker. Faz Sign In em
https://edelivery.oracle.com com a mesma conta, procura o produto, escolhe a versão
**12.2.1.4.0** e a plataforma, aceita os termos e descarrega.

O que cada pacote contém (nomes `V9833xx-01.zip` que o eDelivery dá aos downloads):

| Zip | Conteúdo | Para quê |
|---|---|---|
| `V983383-01.zip` | `fmw_12.2.1.4.0_soa.jar` | Instalador do SOA Suite (obrigatório mesmo num domínio só-OSB) |
| `V983387-01.zip` | `fmw_12.2.1.4.0_osb.jar` | Instalador do Oracle Service Bus |
| `V983384-01.zip` | `fmw_12.2.1.4.0_b2bhealthcare.jar` | B2B/Healthcare — não usado nos exercícios, mas o `buildDockerImage.sh` espera-o |
| `V983385-01_1of2.zip` + `V983385-01_2of2.zip` | `fmw_12.2.1.4.0_soa_quickstart.jar` + `fmw_12.2.1.4.0_soa_quickstart2.jar` | **SOA Quick Start for Developers** 12.2.1.4.0 — JDeveloper com o tooling de SOA e OSB; opcional, só para desenvolver no IDE |
| `V983382-01.zip` | `jdev_suite_122140.jar` + `jdev_suite_1221402.jar` | JDeveloper Studio simples — **não serve para OSB** (sem tooling de projetos Service Bus); usa o Quick Start acima |

Descompacta cada zip para a sua pasta. Os 3 `.jar` `fmw_...` são os que vão para
`docker-images/OracleSOASuite/dockerfiles/12.2.1.4/` (README, secção 2).

### Problemas no download

- **`Request for this download has expired`** — o link que a Oracle gera é temporário (poucos
  minutos). Volta à página, recarrega (F5) e clica no ficheiro outra vez, deixando o download
  começar logo. Não guardes o link para usar mais tarde nem o passes a outro gestor de downloads.
  Se persistir, tenta numa janela anónima, ou usa o eDelivery em vez da página pública do
  JDeveloper.
- **A página pública do JDeveloper dá 404** — a Oracle mudou-a de sítio mais do que uma vez. O
  caminho fiável é o eDelivery (pesquisar *Oracle JDeveloper*, versão 12.2.1.4.0, Windows x64).

### Instalar o JDeveloper (opcional)

Não é preciso para correr o OSB em Docker (a consola web chega para os exercícios). Só para quem
quer o IDE. O instalador é o **SOA Quick Start** (`V983385-01`), que traz o JDeveloper já com o
tooling de SOA e OSB; o JDeveloper simples (`V983382-01`) não serve.

Descompacta os dois zips e copia os dois `.jar` para a **mesma pasta**, sem espaços no caminho:

```powershell
$src = "<pasta>\quickstart_zip"
New-Item -ItemType Directory -Force C:\Oracle\qs_install | Out-Null
Copy-Item "$src\V983385-01_1of2\fmw_12.2.1.4.0_soa_quickstart.jar"  C:\Oracle\qs_install\
Copy-Item "$src\V983385-01_2of2\fmw_12.2.1.4.0_soa_quickstart2.jar" C:\Oracle\qs_install\
```

Numa janela **PowerShell como Administrador**:

```powershell
& "C:\Program Files\Java\jdk1.8.0_202\bin\java.exe" -jar "C:\Oracle\qs_install\fmw_12.2.1.4.0_soa_quickstart.jar"
```

No assistente: *Skip Auto Updates* → *Oracle Home* = `C:\Oracle\Middleware\Oracle_Home` →
*Install* → *Finish*. O JDeveloper fica em
`C:\Oracle\Middleware\Oracle_Home\jdeveloper\jdev\bin\jdev64.exe`. No primeiro arranque escolhe
*Default Role* e responde *No* à importação de preferências.

- Tem de ser um **JDK 8 de 64 bits** (`java -version` deve dizer `64-Bit Server VM`; uma pasta
  em `Program Files (x86)` é 32 bits e o instalador não corre). O Java 17/21 não serve.
- Corre como **Administrador**, senão falha com `Unable to access or modify the system registry`.
- Os dois `.jar` têm de estar na **mesma pasta**; o segundo é lido a meio da instalação.
- Se já havia um JDeveloper no mesmo Oracle Home, **desinstala-o primeiro**
  (`<Oracle Home>\oui\bin\deinstall.cmd` como Administrador, depois apaga a pasta e
  `%APPDATA%\JDeveloper`). Instalar por cima mistura produtos.
- Para confirmar o tooling OSB: *File → New → From Gallery* deve mostrar *Service Bus*. A
  instalação correta tem as pastas `osb\` e `soa\` dentro do Oracle Home.
- Para ligar ao Docker: *Window → Application Servers*, WebLogic 12.x, `localhost:7001`, utilizador
  `weblogic`, e **WLS Domain = `infra_domain`** (o valor por defeito `base_domain` falha com
  `Domain name mismatch`).

Guia completo, da instalação à publicação de um projeto: **`JDEVELOPER.md`**.

## Erros comuns

| Sintoma | Causa | Resolução |
|---|---|---|
| `./start-osb.sh` → `failed to resolve reference "localhost/oracle/database:12.2.0.1-ee" ... dial tcp [::1]:80: i/o timeout` | A imagem da BD não existe localmente; o Docker tenta descarregá-la de um registo chamado `localhost` e dá timeout. | Faz o pull e o `docker tag` da secção 3.4; confirma com `docker images` (3.5). |
| Idem para `localhost/oracle/soasuite:12.2.1.4` (falha no passo 2/3 do `start-osb.sh`) | A imagem nunca foi construída, ou foi construída como `oracle/soasuite` e falta a tag `localhost/...`. | `README.md`, secção 2: `buildDockerImage.sh` + `docker tag oracle/soasuite:12.2.1.4 localhost/oracle/soasuite:12.2.1.4`. |
| `docker login` rejeita a password | Desde 30/06/2025 a password da conta já não é aceite. | Usa o **Auth Token** (3.1). |
| `docker pull` recusa mesmo depois do login | Licença da imagem por aceitar. | 3.3 — por imagem e com sessão iniciada no site. |
| `Request for this download has expired` | Link temporário. | Secção 4, "Problemas no download". |
| `buildDockerImage.sh` → `: FAILED open or readr` e `MD5 for required packages ... did not match` | Vários ficheiros do repositório `oracle/docker-images` estão **commitados com CRLF** (não depende da tua config do Git); o `md5sum` procura `fmw_...jar\r`. Não é problema dos jars. | Converter para LF dentro de `12.2.1.4/`, ver `README.md` secção 2. Atenção: `grep -rlI $'\r'` **não** os encontra no Git Bash (o grep do MSYS esconde o `\r`); usa `grep -lU`. |
| JDeveloper: `Unable to access or modify the system registry` | Falta de permissões de administrador. | PowerShell como Administrador. |
| JDeveloper: o instalador não arranca / JVM não suportada | JDK 32 bits ou versão errada. | JDK 8 de 64 bits (ver acima). |
| JDeveloper: não aparece *Service Bus* em *New → From Gallery* | Foi instalado o JDeveloper simples (`V983382-01`) em vez do Quick Start. | Instala o `V983385-01` (ver acima). |

## Segurança e higiene do repo

- O **Auth Token** é uma credencial: nunca no repo, no `setenv.sh` ou em issues.
- As passwords do `setenv.sh` (`DC_ORCL_SYSPWD`, `DC_ADMIN_PWD`, `DC_RCU_SCHPWD`) devem ser
  alteradas dos valores por defeito antes de qualquer uso partilhado.
- A pasta com os downloads (`zip/`, vários GB) **não deve ser commitada**. Se a deixares dentro
  do repo, acrescenta-a a um `.gitignore` ou guarda-a fora dele.
