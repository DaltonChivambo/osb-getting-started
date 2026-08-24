#!/usr/bin/env bash
#
# Reduz o adapters.os_xml do dominio a UM unico bloco <ldap>.
#
# Porque e preciso: cada servidor (osbas, osbms) acrescenta um bloco
# <ldap id="DefaultAuthenticator"> a este ficheiro quando arranca. Como os dois
# containers partilham o mesmo dominio (bind mount $DC_DDIR_OSB), escrevem ambos
# no mesmo ficheiro. Um servidor que encontre o ficheiro ja com 2 blocos morre com
# JPS-02592 / "duplicate keys" -- o container fica Up mas o processo Java suicida-se
# e a consola nunca responde.
#
# Depois de um arranque completo o ficheiro fica sempre com 2 blocos, por isso isto
# tem de correr ANTES de cada arranque de servidor. Ver docs/RUNNING.md,
# "Problemas comuns".
#
# Uso:
#   ./fix-adapters.sh          # com setenv.sh ja sourced, ou deixa-o tratar disso
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Se o setenv.sh ainda nao foi sourced nesta shell, trata disso (sem poluir o output).
if [ -z "${DC_DDIR_OSB:-}" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/setenv.sh" > /dev/null 2>&1
fi

if [ -z "${DC_DDIR_OSB:-}" ]; then
  echo "ERRO: DC_DDIR_OSB nao esta definido e nao consegui carregar o setenv.sh." >&2
  exit 1
fi

ADAPTERS="$DC_DDIR_OSB/domains/infra_domain/config/fmwconfig/ovd/default/adapters.os_xml"

if [ ! -f "$ADAPTERS" ]; then
  echo "INFO: adapters.os_xml ainda nao existe (dominio por criar) - nada a fazer."
  exit 0
fi

count=$(grep -c '<ldap[ >]' "$ADAPTERS" || true)
count=${count:-0}

if [ "$count" -le 1 ]; then
  echo "OK: adapters.os_xml tem $count bloco(s) <ldap> - nao precisa de fix."
  exit 0
fi

cp -f "$ADAPTERS" "$ADAPTERS.bak"

# Mantem tudo ate ao fim do primeiro bloco <ldap>...</ldap>, descarta os blocos
# seguintes (sao identicos), e volta a fechar com </adapters>.
awk '
  /<ldap[ >]/ { n++ }
  (n <= 1)    { print; next }
  /<\/adapters>/ { print }
' "$ADAPTERS.bak" > "$ADAPTERS"

new=$(grep -c '<ldap[ >]' "$ADAPTERS" || true)
new=${new:-0}

if [ "$new" -ne 1 ]; then
  echo "ERRO: o fix deixou $new blocos (esperado 1). A repor o backup." >&2
  cp -f "$ADAPTERS.bak" "$ADAPTERS"
  exit 1
fi

echo "FIX: adapters.os_xml tinha $count blocos <ldap>, ficou com 1 (backup: adapters.os_xml.bak)."
