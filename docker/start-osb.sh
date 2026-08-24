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
  local f="$1"
  if [ -f "$f" ] && [ -s "$f" ]; then
    mv -f "$f" "$f.prev" 2>/dev/null || true
  fi
}

# A base de dados tem healthcheck a serio na imagem -- e mais fiavel que fazer grep
# ao docker logs, que mantem as linhas do arranque anterior.
wait_for_db() {
  local waited=0 interval=10 timeout_s=900 status
  echo "INFO: a aguardar que a soadb fique healthy..."
  while [ "$waited" -lt "$timeout_s" ]; do
    status=$(docker inspect -f '{{.State.Health.Status}}' soadb 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ]; then
      echo ""
      echo "OK: soadb healthy (${waited}s)."
      return 0
    fi
    sleep "$interval"; waited=$((waited + interval)); printf '.'
  done
  echo ""
  echo "ERRO: timeout a espera da soadb apos ${timeout_s}s." >&2
  return 1
}

wait_for_server() {
  local container="$1" log="$2" label="$3" timeout_s="$4"
  local waited=0 interval=15
  echo "INFO: a aguardar que o $label chegue a RUNNING (tipicamente ~10 min)..."
  while [ "$waited" -lt "$timeout_s" ]; do
    if MSYS_NO_PATHCONV=1 docker exec "$container" grep -q "RUNNING mode" "$log" 2>/dev/null; then
      echo ""
      echo "OK: $label em RUNNING mode (${waited}s)."
      return 0
    fi
    if MSYS_NO_PATHCONV=1 docker exec "$container" grep -q "state changed to FAILED" "$log" 2>/dev/null; then
      echo ""
      echo "ERRO: o $label falhou a arrancar. Ultimas linhas do log:" >&2
      MSYS_NO_PATHCONV=1 docker exec "$container" tail -n 25 "$log" 2>&1 >&2
      return 1
    fi
    sleep "$interval"; waited=$((waited + interval)); printf '.'
  done
  echo ""
  echo "ERRO: timeout a espera do $label apos ${timeout_s}s." >&2
  echo "      O container pode estar Up com o processo Java ja morto - ve o log:" >&2
  echo "      MSYS_NO_PATHCONV=1 docker exec $container tail -n 40 $log" >&2
  return 1
}

echo "=== 1/3  Base de dados (soadb) ==="
docker-compose up -d soadb || exit 1
wait_for_db || exit 1

echo ""
echo "=== 2/3  Admin Server (osbas) ==="
./fix-adapters.sh || exit 1
rotate_log "$AS_LOG_HOST"
docker-compose up -d osbas || exit 1
wait_for_server osbas "$AS_LOG" "Admin Server" 2700 || exit 1

echo ""
echo "=== 3/3  Managed Server (osbms) ==="
# Obrigatorio: o osbas acabou de acrescentar o bloco dele ao adapters.os_xml.
# Sem este segundo fix, o osbms apanha o ficheiro com 2 blocos e morre.
./fix-adapters.sh || exit 1
rotate_log "$MS_LOG_HOST"
docker-compose up -d osbms || exit 1
wait_for_server osbms "$MS_LOG" "Managed Server" 2700 || exit 1

echo ""
echo "=== Ambiente pronto ==="
echo "  WebLogic Admin Console : http://localhost:7001/console"
echo "  Service Bus Console    : http://localhost:7001/servicebus"
echo "  Proxy Services         : http://localhost:9001 (HTTP) / :9002 (HTTPS)"
echo "  Utilizador             : weblogic / \$DC_ADMIN_PWD (ver setenv.sh)"
echo ""
echo "Nota: 'docker ps' pode mostrar (health: starting) mais uns minutos - o"
echo "healthcheck demora a apanhar o estado novo. Os servidores estao a correr."
