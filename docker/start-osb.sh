#!/usr/bin/env bash
#
# Sobe o ambiente OSB completo (soadb -> osbas -> osbms), aplicando o fix do
# adapters.os_xml nos dois momentos em que e preciso e esperando por cada servidor
# antes de passar ao seguinte.
#
# Assume que o dominio JA foi criado pelo menos uma vez (ver ../README.md para o
# setup inicial). Na primeira vez de todas, o osbas corre o RCU e demora 20-40 min --
# este script espera na mesma, mas convem acompanhar o log em paralelo.
#
# Mostra um cronometro (HH:MM:SS) com o tempo da fase atual e o total do script, e
# no fim um resumo com a duracao de cada fase.
#
# Uso:
#   ./start-osb.sh
#
# Corre em Git Bash ou WSL2 (nao em PowerShell/CMD).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=/dev/null
. ./setenv.sh > /dev/null 2>&1

if [ -z "${DC_DDIR_OSB:-}" ]; then
  echo "ERRO: nao consegui carregar o setenv.sh (DC_DDIR_OSB vazio)." >&2
  exit 1
fi

DOMAIN_DIR="$DC_DDIR_OSB/domains/infra_domain"
AS_LOG_HOST="$DOMAIN_DIR/logs/as.log"
MS_LOG_HOST="$DOMAIN_DIR/logs/osb_server1/ms.log"
AS_LOG="/u01/oracle/user_projects/domains/infra_domain/logs/as.log"
MS_LOG="/u01/oracle/user_projects/domains/infra_domain/logs/osb_server1/ms.log"

# O log da arranque anterior fica em .prev, para post-mortem. Sem isto, uma linha
# "RUNNING mode" ou "FAILED" antiga faz a espera dar um falso positivo imediato.
rotate_log() {
  local f="$1" c="${2:-}"
  # Se o container ja esta a correr, o processo continua a escrever no ficheiro aberto: um mv
  # deixava-o a escrever em .prev e o as.log nunca mais aparecia (a espera ficava presa).
  if [ -n "$c" ] && [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  if [ -f "$f" ] && [ -s "$f" ]; then
    mv -f "$f" "$f.prev" 2>/dev/null || true
  fi
}

# SECONDS e o contador do proprio bash (segundos desde o inicio do script).
SECONDS=0

# Formata um numero de segundos como HH:MM:SS.
fmt_time() {
  local s="$1"
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

# Cronometro: tempo da fase atual + total do script. Num terminal reescreve sempre a
# mesma linha; fora de um terminal (saida redirecionada) imprime uma linha por tick.
tick() {
  local label="$1" phase_start="$2"
  local phase=$((SECONDS - phase_start))
  if [ -t 1 ]; then
    printf '\r  [%s] %s a correr: %s  |  total: %s   ' \
      "$(date +%H:%M:%S)" "$label" "$(fmt_time "$phase")" "$(fmt_time "$SECONDS")"
  else
    printf '  [%s] %s a correr: %s | total: %s\n' \
      "$(date +%H:%M:%S)" "$label" "$(fmt_time "$phase")" "$(fmt_time "$SECONDS")"
  fi
}

# Espera $3 segundos, mas atualiza o cronometro todos os segundos (as verificacoes
# ao log so acontecem de $3 em $3 s; sem isto a linha parecia parada). Fora de um
# terminal imprime so uma linha por pausa, para nao encher o ficheiro.
pause_with_timer() {
  local label="$1" phase_start="$2" seconds="$3" i
  for ((i = 0; i < seconds; i++)); do
    if [ -t 1 ] || [ "$i" -eq 0 ]; then
      tick "$label" "$phase_start"
    fi
    sleep 1
  done
}

# Duracao de cada fase, para o resumo final.
T_DB=""; T_AS=""; T_AS2=""; T_MS=""

# A base de dados tem healthcheck a serio na imagem -- e mais fiavel que fazer grep
# ao docker logs, que mantem as linhas do arranque anterior.
wait_for_db() {
  local waited=0 interval=10 timeout_s=1500 status
  local phase_start=$SECONDS
  echo "INFO: a aguardar que a soadb fique pronta (1a vez, com BD nova: ~10 min; depois ~1-3 min)..."
  while [ "$waited" -lt "$timeout_s" ]; do
    status=$(docker inspect -f '{{.State.Health.Status}}' soadb 2>/dev/null || echo "unknown")
    # So "healthy" nao chega: com uma BD nova o healthcheck passa a healthy ao fim de ~1 min,
    # muito antes de o PDB estar criado e registado no listener (ORA-12514 / RCU a falhar).
    # A imagem database/enterprise escreve "Done ! The database is ready for use ." quando
    # termina (a frase "DATABASE IS READY TO USE!" e de outra imagem, nao aparece aqui).
    # Nao usar "docker logs | grep -q": com pipefail, o grep -q sai ao primeiro match,
    # o docker logs apanha SIGPIPE e o pipeline falha mesmo com a frase presente.
    if [ "$status" = "healthy" ] && [ "$(docker logs soadb 2>&1 | grep -ci "database is ready for use")" -gt 0 ]; then
      T_DB=$((SECONDS - phase_start))
      [ -t 1 ] && echo ""
      echo "OK: soadb healthy ($(fmt_time "$T_DB"))."
      return 0
    fi
    pause_with_timer "soadb" "$phase_start" "$interval"
    waited=$((waited + interval))
  done
  [ -t 1 ] && echo ""
  echo "ERRO: timeout a espera da soadb apos $(fmt_time "$timeout_s")." >&2
  return 1
}

wait_for_server() {
  local container="$1" log="$2" label="$3" timeout_s="$4" result_var="$5"
  local waited=0 interval=15
  local phase_start=$SECONDS
  echo "INFO: a aguardar que o $label chegue a RUNNING (tipicamente ~10 min; 20-40 min na 1a vez)..."
  while [ "$waited" -lt "$timeout_s" ]; do
    if MSYS_NO_PATHCONV=1 docker exec "$container" grep -q "RUNNING mode" "$log" 2>/dev/null; then
      printf -v "$result_var" '%s' "$((SECONDS - phase_start))"
      [ -t 1 ] && echo ""
      echo "OK: $label em RUNNING mode ($(fmt_time "$((SECONDS - phase_start))"))."
      return 0
    fi
    if MSYS_NO_PATHCONV=1 docker exec "$container" grep -q "state changed to FAILED" "$log" 2>/dev/null; then
      [ -t 1 ] && echo ""
      echo "ERRO: o $label falhou a arrancar ao fim de $(fmt_time "$((SECONDS - phase_start))"). Ultimas linhas do log:" >&2
      MSYS_NO_PATHCONV=1 docker exec "$container" tail -n 25 "$log" 2>&1 >&2
      return 1
    fi
    # O container pode ter terminado (ex.: o RCU falhou e o wrapper saiu com codigo 0).
    # Sem isto o script ficava a espera ate ao timeout de um log que nunca vai mudar.
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
      local code
      code=$(docker inspect -f '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "?")
      [ -t 1 ] && echo ""
      echo "ERRO: o container $container parou (exit code $code) ao fim de $(fmt_time "$((SECONDS - phase_start))"). Ultimas linhas do docker logs:" >&2
      docker logs --tail 25 "$container" 2>&1 >&2
      return 1
    fi
    pause_with_timer "$label" "$phase_start" "$interval"
    waited=$((waited + interval))
  done
  [ -t 1 ] && echo ""
  echo "ERRO: timeout a espera do $label apos $(fmt_time "$timeout_s")." >&2
  echo "      O container pode estar Up com o processo Java ja morto - ve o log:" >&2
  echo "      MSYS_NO_PATHCONV=1 docker exec $container tail -n 40 $log" >&2
  return 1
}

echo "=== 1/3  Base de dados (soadb) ==="
docker-compose up -d soadb || exit 1
wait_for_db || exit 1

echo ""
echo "=== 2/3  Admin Server (osbas) ==="

# Parar sempre o osbms e o osbas antes de arrancar: o adapters.os_xml so e lido no arranque do
# servidor, e o fix-adapters.sh tem de correr ANTES de o osbas arrancar. Se o osbas ja estava a
# correr (ex.: arrancado a mao), ficava com o identity store %HOST% em memoria e a consola
# entrava em loop no errorPage.jspx, mesmo com o ficheiro ja corrigido.
for c in osbms osbas; do
  if [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = "true" ]; then
    echo "INFO: a parar o $c antes de arrancar (para o fix ser lido no arranque)..."
    docker stop "$c" > /dev/null || exit 1
  fi
done
./fix-adapters.sh || exit 1
rotate_log "$AS_LOG_HOST" osbas
docker-compose up -d osbas || exit 1
wait_for_server osbas "$AS_LOG" "Admin Server" 2700 T_AS || exit 1

# Numa 1a subida o osbas acabou de criar o adapters.os_xml com %HOST% (identity store
# partido: loop do errorPage.jspx na consola). O fix so tem efeito no proximo arranque,
# por isso reinicia-se o osbas uma vez. Nas subidas seguintes isto nao acontece.
FIXOUT=$(./fix-adapters.sh) || exit 1
echo "$FIXOUT"
if grep -q '^FIX-HOST' <<< "$FIXOUT"; then
  echo ""
  echo "INFO: 1a subida - o identity store usava %HOST%. A reiniciar o osbas com o fix aplicado..."
  docker stop osbas > /dev/null || exit 1
  ./fix-adapters.sh || exit 1          # o osbas acrescentou o bloco dele: reduz a 1
  rotate_log "$AS_LOG_HOST" osbas
  docker-compose up -d osbas || exit 1
  wait_for_server osbas "$AS_LOG" "Admin Server (reinicio)" 2700 T_AS2 || exit 1
fi

echo ""
echo "=== 3/3  Managed Server (osbms) ==="
# Obrigatorio: o osbas acabou de acrescentar o bloco dele ao adapters.os_xml.
# Sem este segundo fix, o osbms apanha o ficheiro com 2 blocos e morre.
./fix-adapters.sh || exit 1
rotate_log "$MS_LOG_HOST" osbms
docker-compose up -d osbms || exit 1
wait_for_server osbms "$MS_LOG" "Managed Server" 2700 T_MS || exit 1

echo ""
echo "=== Ambiente pronto ==="
echo "  WebLogic Admin Console : http://localhost:7001/console"
echo "  Service Bus Console    : http://localhost:7001/servicebus"
echo "  Proxy Services         : http://localhost:9001 (HTTP) / :9002 (HTTPS)"
echo "  Utilizador             : weblogic / \$DC_ADMIN_PWD (ver setenv.sh)"
echo ""
echo "Tempos (HH:MM:SS):"
echo "  soadb  (base de dados) : $(fmt_time "$T_DB")"
echo "  osbas  (Admin Server)  : $(fmt_time "$T_AS")"
[ -n "$T_AS2" ] && echo "  osbas  (reinicio c/ fix): $(fmt_time "$T_AS2")"
echo "  osbms  (Managed Server): $(fmt_time "$T_MS")"
echo "  TOTAL                  : $(fmt_time "$SECONDS")"
echo ""
echo "Nota: 'docker ps' pode mostrar (health: starting) mais uns minutos - o"
echo "healthcheck demora a apanhar o estado novo. Os servidores estao a correr."
