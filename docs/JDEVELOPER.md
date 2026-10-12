# JDeveloper: instalar, ligar ao OSB do Docker e publicar

Guia sequencial para ter o **JDeveloper 12.2.1.4** (com o tooling de Service Bus) a desenvolver e
a publicar no OSB que corre em Docker. É opcional: a consola web (`docs/TUTORIAL.md`) chega para
os exercícios. Usa o IDE se quiseres projetos em ficheiros, versionáveis e editáveis offline.

Cada passo diz **como confirmar** que correu bem. Os passos 1 a 5 foram executados e confirmados;
o passo 6 em diante (criar e publicar projetos no IDE) está descrito a partir da estrutura do
produto e **ainda não foi validado ecrã a ecrã** — onde isso importa, está assinalado.

## Visão geral

```
Windows                                         Docker (WSL2)
┌────────────────────────────┐                  ┌──────────────────────────┐
│ JDeveloper 12.2.1.4        │  7001 (Admin) →  │ osbas  (Admin Server)    │
│  + extensões OSB e SOA     │                  │ osbms  (osb_server1)     │
│  (SOA Quick Start)         │  9001 (testes) → │   └ Proxy Services :9001 │
└────────────────────────────┘                  │ soadb  (schemas RCU)     │
                                                └──────────────────────────┘
```

- O IDE **publica** no Admin Server (`localhost:7001`).
- As Proxy Services **respondem** no managed server (`localhost:9001`).
- O domínio chama-se **`infra_domain`**.

## Pré-requisitos

| Preciso de | Como confirmar |
|---|---|
| Ambiente Docker a correr e *healthy* (`docs/RUNNING.md`) | `docker ps` mostra `osbas`, `osbms` e `soadb` como *healthy* |
| Consola acessível | http://localhost:7001/console abre |
| JDK 8 de 64 bits | `java -version` diz `1.8.0_...` e `64-Bit Server VM` |
| Os dois zips `V983385-01` | existem `fmw_12.2.1.4.0_soa_quickstart.jar` e `fmw_12.2.1.4.0_soa_quickstart2.jar` |
| ~6 GB livres em `C:` | |
| Sessão **PowerShell como Administrador** | só para o passo 3 |

> Pacote certo: **SOA Quick Start** (`V983385-01`, 2 zips). O JDeveloper simples (`V983382-01`)
> **não** tem tooling de Service Bus e não serve. Mapa dos pacotes em `docs/LOGIN-ORACLE.md`.

## 1. Remover um JDeveloper anterior (só se existir)

Instalar por cima de outro produto no mesmo Oracle Home mistura componentes. Se já havia um:

1. Fecha o JDeveloper e qualquer instalador. `Get-Process java,javaw -ErrorAction SilentlyContinue`
   não deve devolver nada.
2. Como Administrador, desinstala pelo Oracle:
   ```powershell
   & "C:\Oracle\Middleware\Oracle_Home\oui\bin\deinstall.cmd"
   ```
3. Apaga o que sobrar:
   ```powershell
   Remove-Item -Recurse -Force "C:\Oracle\Middleware\Oracle_Home"
   Remove-Item -Recurse -Force "$env:APPDATA\JDeveloper"
   ```
   `%APPDATA%\JDeveloper` só tem preferências e caches. Se tiveres ligações a servidores que
   queiras guardar, copia primeiro o `connections.xml` de lá.

Como confirmar: `Test-Path C:\Oracle\Middleware\Oracle_Home` devolve `False` e
`HKLM:\SOFTWARE\Oracle\KEY_OracleHome1` já não existe.

## 2. Juntar os dois jars numa pasta

O instalador lê o segundo jar a meio, por isso têm de estar na **mesma pasta**, com um caminho
sem espaços:

```powershell
$src = "<pasta do repo>\quickstart_zip"
New-Item -ItemType Directory -Force C:\Oracle\qs_install | Out-Null
Copy-Item "$src\V983385-01_1of2\fmw_12.2.1.4.0_soa_quickstart.jar"  C:\Oracle\qs_install\
Copy-Item "$src\V983385-01_2of2\fmw_12.2.1.4.0_soa_quickstart2.jar" C:\Oracle\qs_install\
```

Como confirmar: `Get-ChildItem C:\Oracle\qs_install` lista dois ficheiros (≈1,9 GB e ≈1,2 GB).

## 3. Correr o instalador

Num PowerShell **como Administrador**, com o JDK 8 pelo caminho completo (não o Java 17/21):

```powershell
& "C:\Program Files\Java\jdk1.8.0_202\bin\java.exe" -jar "C:\Oracle\qs_install\fmw_12.2.1.4.0_soa_quickstart.jar"
```

No assistente:

| Ecrã | O que fazer |
|---|---|
| Welcome | *Next* |
| Auto Updates | *Skip Auto Updates* → *Next* |
| Installation Location | **Oracle Home** = `C:\Oracle\Middleware\Oracle_Home` → *Next* |
| Prerequisite Checks | esperar que passe → *Next* |
| Installation Summary | conferir o caminho → *Install* |
| Installation Progress | esperar (alguns minutos) |
| Installation Complete | *Finish* |

Se falhar:

| Sintoma | Causa | Resolução |
|---|---|---|
| `Unable to access or modify the system registry` | Sem permissões de administrador | PowerShell como Administrador |
| Instalador não arranca / JVM não suportada | JDK de 32 bits ou versão errada | Caminho completo do JDK 8 de 64 bits |
| Erro a ler o segundo jar | Os jars estão em pastas diferentes | Passo 2 |

## 4. Confirmar a instalação

```powershell
$h = "C:\Oracle\Middleware\Oracle_Home"
Test-Path "$h\jdeveloper\jdev\bin\jdev64.exe"   # True
Test-Path "$h\osb"                               # True
Test-Path "$h\soa"                               # True
Get-ChildItem "$h\osb\plugins\jdeveloper\extensions" | Select Name   # oracle.sb.tooling.ide.*
```

**Não precisas de instalar extensões à mão.** O Quick Start já traz as de Service Bus
(`osb\plugins\jdeveloper\extensions`, jars `oracle.sb.tooling.ide.*`), as de SOA
(`soa\plugins\jdeveloper\extensions`) e o suporte WebLogic. O `jdev.conf` regista
`<produto>\plugins\jdeveloper` como extensões dinâmicas e o IDE carrega-as no arranque.
Evita o *Help → Check for Updates* para "instalar o OSB": não é preciso e pode trazer versões
incompatíveis.

## 5. Primeiro arranque e ligação ao servidor

### 5.1 Abrir o IDE

Executa `C:\Oracle\Middleware\Oracle_Home\jdeveloper\jdev\bin\jdev64.exe`. Na primeira vez:

- **Select Role** → *Default Role* (ou *Studio Developer*).
- Se perguntar para importar preferências de outra versão → **No**.

Como confirmar a categoria de Service Bus: *File → New → From Gallery* deve mostrar **Service Bus**
(com *Service Bus Application* e *Service Bus Project*).
Se não aparecer, o IDE não carregou as extensões do passo 4 (ver Resolução de problemas).

### 5.2 Criar a ligação ao Admin Server

*Window → Application Servers* → ícone `+` (**New Application Server Connection**):

| Campo | Valor |
|---|---|
| Connection Type | WebLogic 12.x |
| Connection Name | `osb-docker` |
| Username | `weblogic` |
| Password | `DC_ADMIN_PWD` de `docker/setenv.sh` (por defeito a do `README.md`) |
| Weblogic Hostname | `localhost` |
| Port | `7001` |
| SSL | desligado |
| **WLS Domain** | **`infra_domain`** |

O campo **WLS Domain** vem preenchido com `base_domain`. É o valor por defeito do WebLogic e **não
é o nosso domínio**.

### 5.3 Testar a ligação

No último passo do assistente, **Test Connection** deve dar **12 of 12 tests successful**:

```
Testing HTTP Authentication ... success
Testing JSR-160 Runtime ... success
Testing JSR-160 DomainRuntime ... success
Testing JSR-88 ... success
Testing JSR-88-LOCAL ... success
Testing Server MBeans Model ... success
Testing App Controller ... success
Testing JSR-88-DEP-MGR ... success
Testing JSR-88-DEP-MGR-LOCAL ... success
Testing JNDI ... success
Testing JSR-160 Edit ... success
Testing HTTP ... success
```

Se falhar:

| Sintoma | Causa | Resolução |
|---|---|---|
| `Server MBeans Model ... failed` com `Domain name mismatch. Remote domain is 'infra_domain', not 'base_domain'` (e *App Controller* `skipped`) | **WLS Domain** ficou `base_domain` | Editar a ligação (*Properties*) e pôr `infra_domain`; repetir o teste. Foi o erro que apareceu na primeira tentativa |
| `HTTP Authentication ... failed` | Password errada | Conferir `DC_ADMIN_PWD` em `docker/setenv.sh` |
| Tudo falha / *connection refused* | `osbas` ainda a arrancar ou parado | `docker ps`; esperar o *healthy*; abrir http://localhost:7001/console |

## 6. Criar a aplicação e os componentes

> **Estado:** este fluxo foi **validado nesta máquina** (JDeveloper 12.2.1.4 + OSB 12.2.1.4 na
> imagem Docker): `curl http://localhost:9001/echotest` devolveu **HTTP 200** com o JSON do
> backend. Os nomes dos menus são os que apareceram no IDE.

A ordem é **Application → Project → serviços**. Uma aplicação do JDeveloper é só o contentor; os
serviços vivem dentro de um projeto Service Bus.

### 6.1 Aplicação e projeto

1. *File → New → From Gallery → Service Bus → **Service Bus Application***. Nome sugerido:
   `OsbTutorial`.
2. Com a aplicação selecionada: *File → New → From Gallery → Service Bus → **Service Bus
   Project***. Nome sugerido: `TESTE_OSB`.

### 6.2 O que o wizard do IDE **não** faz

O wizard de *Business Service* desta versão só oferece **REST** (sem WADL). Um serviço assim
chega ao backend e falha com `OSB-380000 ... Invalid HTTP method: null`, porque o OSB não sabe
que método usar (é a mesma armadilha do `docs/TUTORIAL.md`).

A solução tem duas partes que **se fazem à mão**, em XML, dentro do projeto:

1. um ficheiro **WADL** no formato que o OSB gera (secção 6.3);
2. uma linha no `.bix` do Business Service que o liga a esse WADL (secção 6.4).

### 6.3 O WADL

O modelo está em `test/httpbin.wadl`. Copia-o para a **pasta do projeto** (a mesma do `.bix` e do
`.proxy`) e faz botão direito no projeto → **Refresh**. É este:

```xml
<ns:application xmlns:ns="http://wadl.dev.java.net/2009/02" xmlns:rest="http://www.oracle.com/soa/rest">
    <ns:doc title="HttpBinBS">HttpBinBS</ns:doc>
    <ns:resources>
        <ns:resource path="/get">
            <ns:method name="GET" rest:name="Method0">
                <ns:request/>
                <ns:response><ns:representation mediaType="application/xml"/></ns:response>
                <ns:response><ns:representation mediaType="application/xml"/></ns:response>
            </ns:method>
        </ns:resource>
    </ns:resources>
</ns:application>
```

Regras (todas confirmadas: o validador do OSB recusa o WADL sem elas):

- **Sem `base` em `<resources>`.** O host vem do endpoint do Business Service.
- **`rest:name`** no `<method>` com o namespace `http://www.oracle.com/soa/rest`. Dá o nome da
  operação, que escolhes depois no Route. Tem de ser **único** dentro do WADL.
- **`<request/>`** obrigatório (`Methods without 'request' element are not supported`).
- **Duas `<response>`**, sem `status`, como o OSB gera.
- `path` com `/` inicial e **só o caminho** do backend (`/get`).

> Este modelo cobre **GETs simples, sem parâmetros**. Para parâmetros de query, POST/PUT ou
> corpos, não está testado: cria o serviço uma vez na consola (*Typed REST from wizard (with
> WADL)*), exporta o `sbconfig.jar` e copia o WADL gerado (ver 9.2).

### 6.4 Serviços (por esta ordem)

Botão direito no projeto → *New → From Gallery → **Service Bus Tier → Services***.

| Ordem | Componente | Nome | Configuração |
|---|---|---|---|
| 1 | Business Service | `HttpBinBS` | Definition **REST**; Transport `http`; Endpoint URI no formato `http://host:80/caminho` (o wizard recusa URIs sem porta e sem `https`) |
| 2 | Proxy Service | `EchoTestPS` | Definition **REST**; Transport `http`; Endpoint URI `/echotest` |
| 3 | Pipeline | `EchoTestPSPipeline` | criado **automaticamente** pelo wizard da Proxy (`<Proxy>Pipeline`) |
| 4 | Route | `RouteNode1`, no pipeline | nó **Route** com a ação **Routing** para `HttpBinBS` |

Depois de gravar o Business Service, **abre o `HttpBinBS.bix`** (ficheiro de texto) e faz duas
alterações:

```xml
<!-- 1. Ligar o WADL: acrescenta o <con:wadl> dentro do <con1:binding> -->
<con1:binding type="native REST" xsi:type="con:NativeRestBindingType" xmlns:con="http://www.bea.com/wli/sb/services/bindings/config" xmlns:con1="http://xmlns.oracle.com/servicebus/business/config">
    <con:wadl ref="TESTE_OSB/httpbin"/>      <!-- <projeto>/<nome do .wadl sem extensão> -->
</con1:binding>

<!-- 2. O endpoint passa a ser só a base (o caminho vem do WADL) -->
<env:value>https://httpbin.org</env:value>
```

Recarrega o ficheiro no IDE (*Reload*). Em `Service Type` o editor passa a mostrar **REST
Service** e **WADL URL**; o *Problems* tem de ficar vazio.

### 6.5 O Route

1. Abre o `EchoTestPSPipeline` (duplo clique). Se o desenho não tiver a paleta,
   *View → **Components***.
2. Arrasta o **Route** da paleta para a linha do fluxo; fica `RouteNode1`.
3. Clica no `RouteNode1` → *Add → Communication → **Routing***.
4. **Service:** `HttpBinBS`. **Operation:** escolhe `Method0` (a lista só se enche depois de o
   WADL estar ligado e válido). **Save All**.

A ação *Routing* só existe num nó **Route**, não num Stage normal.

Como confirmar: o separador *Problems* está vazio e o `.pipeline` tem
`<con1:operation>Method0</con1:operation>` dentro da ação `route`.

## 7. Publicar no servidor

1. Botão direito no **projeto** (`TESTE_OSB`, não na aplicação, para não publicar outros projetos
   da mesma aplicação) → **Deploy** → entrada de **Service Bus** (por exemplo *to Service Bus*).
2. Escolhe a ligação **`osb-docker`**.
3. Marca **Overwrite** (substitui a configuração anterior com o mesmo nome) e conclui.

Aparece um aviso **"Project and Server Configuration Mismatch"** (projeto em modo *Classic*,
servidor em *Reference Configuration*). É só um aviso: clica **OK** e segue.

Como confirmar: o *Deployment Log* termina com sucesso, e na Service Bus Console
(http://localhost:7001/servicebus) o projeto aparece em *Projects*.

## 8. Testar

As Proxy Services respondem no managed server, **porta 9001** (não 7001). Em **Git Bash**:

```bash
cd test
./test-proxy.sh /echotest
```

Uma resposta HTTP 200 com JSON do `httpbin.org` confirma o ciclo completo:
**cliente → `EchoTestPS` → `EchoTestPS_Pipeline` → Route → `HttpBinBS` → httpbin.org**.
Detalhe de cada salto em `docs/FLUXO.md`.

## 9. Levar um projeto para outro computador

Há dois caminhos, conforme a origem do projeto. Em ambos, o JDeveloper do outro computador tem de
ser a **mesma versão (12.2.1.4)**, instalado com o **SOA Quick Start** (passo 3), senão não há
*Service Bus* no IDE.

### 9.1 O projeto nasceu no JDeveloper (recomendado)

Leva a **pasta da aplicação** (a que contém o `.jws`, o `.jpr` e as pastas dos projetos), de
preferência através de **Git** (`git clone` no outro computador). Depois, **File → Open** e
escolhe o `.jws`.

Isto preserva tudo: estrutura, dependências entre projetos e configuração.

### 9.2 O projeto só existe no servidor

1. **Exportar:** na Service Bus Console (`http://localhost:7001/servicebus`) → **Project
   Explorer** → seleciona o projeto → **Export**. O browser descarrega um `sbconfig.jar`.
2. Copia o `sbconfig.jar` para o outro computador.
3. **Importar no IDE:** **File → Import → Service Bus Resources** → **Configuration Jar** →
   escolhe o `sbconfig.jar` e a aplicação/projeto de destino.

Como confirmar: o projeto aparece no *Applications* com Proxy, Pipeline e Business Service, e o
separador *Problems* está vazio.

### 9.3 Cuidados

- **Dependências:** se o projeto usa outro projeto OSB (por exemplo um `Common` com WSDLs/XSDs),
  exporta-o no **mesmo** JAR, senão a importação fica com referências por resolver.
- **Valores de ambiente** (URLs dos endpoints, JNDI, JCA) podem não servir no destino. Ajusta-os
  depois de importar.
- **Passwords:** as *service accounts* não saem em claro no JAR. Têm de ser recriadas no destino.
- **Uma fonte de verdade:** depois de importar, passa a versionar o projeto no Git e a publicar a
  partir do IDE (ver regras abaixo).

## Regras para não te complicares

- **Uma fonte de verdade de cada vez.** Publicar a partir do IDE com *Overwrite* substitui o que
  estiver no servidor; alterações feitas na consola web e não exportadas perdem-se. Escolhe: ou
  desenhas no IDE, ou na consola.
- **Consola web:** `http://localhost:7001/servicebus` (Service Bus) e `/console` (WebLogic). Não
  uses o botão de Ajuda (`?`) da consola (ver `README.md`).
- **Portas:** `7001` publicar/administrar, `9001` chamar as proxies.
- **O Java do Windows só serve para instalar e correr o IDE.** O OSB corre no JDK 8 de dentro da
  imagem Docker.

## Resolução de problemas

| Sintoma | Causa provável | Resolução |
|---|---|---|
| Não aparece *Service Bus* em *New → From Gallery* | JDeveloper simples instalado em vez do Quick Start, ou extensões não carregadas | Confirmar o passo 4; se faltar `osb\`, reinstalar com `V983385-01` |
| Ligação falha por `base_domain` | **WLS Domain** errado | Passo 5.3 |
| Publicação falha com *connection refused* | Contentor parado | `docker ps`; `./start-osb.sh` |
| Publica mas a proxy responde 404 | Chamaste a porta 7001 em vez da 9001, ou o Base URI é outro | Usar `localhost:9001/<base uri>` |
| `OSB-380000 ... Invalid HTTP method: null` | Business Service REST **sem WADL** (o wizard do IDE não o liga) | Secção 6.3 e 6.4: WADL no projeto + `<con:wadl ref=...>` no `.bix` + *Operation* no Route |
| `OSB-380000` **sem mensagem** (corpo só `{ "errorCode" : "OSB-380000" }`) | Backend em baixo (503) ou WADL fora do formato do OSB | `curl` direto ao backend; se der 200, comparar o WADL com o modelo 6.3 |
| *The WADL used by the service is not supported: ... missing required Oracle extensions* | Faltam `rest:name` ou `<request/>` no WADL | Secção 6.3 |
| Campo **Operation** do Routing sem opções | WADL inválido ou não ligado ao `.bix` | Secção 6.3/6.4; *Problems* tem de estar vazio |
| `OSB-398075` | Proxy tipada a invocar Business tipada de forma diferente | Meter um **Pipeline** no meio |
| Test Connection: `JSR-160 Runtime ... failed`, resto `skipped`, e a consola nega a password certa | Conta `weblogic` **bloqueada** (5 tentativas inválidas, `BEA-090078`, 30 min) | Esperar 30 min ou reiniciar o `osbas`; corrigir a password guardada na ligação do IDE antes de voltar a testar |
| Wizard recusa o Endpoint URI (`https://...` ou sem porta) | O wizard exige `http://host:porta/caminho` | Usar `http://host:80/caminho` e corrigir no `.bix` (6.4) |
