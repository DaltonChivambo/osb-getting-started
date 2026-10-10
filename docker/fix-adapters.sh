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

# Segundo fix (README, secao 4.1): o host do identity store vem como %HOST%, que o
# servidor resolve para o IP do container e envolve em [] como se fosse IPv6
# ("Malformed IPv6 address ... ldap://[172.19.0.3]:7001"). O resultado e o loop do
# errorPage.jspx na Service Bus Console. Trocar por localhost resolve, e e idempotente.
# So tem efeito a partir do PROXIMO arranque do servidor -- o start-osb.sh trata disso.
if grep -q '%HOST%' "$ADAPTERS"; then
  cp -f "$ADAPTERS" "$ADAPTERS.hostbak"
  sed -i 's|<host percentage="100" port="-1" readonly="false">%HOST%</host>|<host percentage="100" port="-1" readonly="false">localhost</host>|' "$ADAPTERS"
  if grep -q '%HOST%' "$ADAPTERS"; then
    echo "ERRO: ficou %HOST% no adapters.os_xml (o padrao do sed nao bateu). A repor o backup." >&2
    cp -f "$ADAPTERS.hostbak" "$ADAPTERS"
    exit 1
  fi
  echo "FIX-HOST: %HOST% substituido por localhost no adapters.os_xml (backup: adapters.os_xml.hostbak)."
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
