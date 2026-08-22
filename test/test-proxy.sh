#!/bin/sh
#===============================================
# Teste rápido de uma Proxy Service REST no OSB.
#
# Usa isto DEPOIS de criares, na Service Bus Console
# (http://localhost:7001/servicebus), uma Proxy Service REST
# que faz route para uma Business Service (ex: https://httpbin.org/get).
#
# Uso:
#   ./test-proxy.sh /minha-proxy/echo
#===============================================

HOST="localhost"
PORT="9001"
PROXY_PATH="${1:-/echo/test}"

URL="http://${HOST}:${PORT}${PROXY_PATH}"

echo "A chamar: ${URL}"
echo "---"
curl -i -X GET "${URL}"
echo
echo "---"
echo "Se receberes uma resposta HTTP (200 ou similar), a Proxy Service"
echo "recebeu o pedido e encaminhou para a Business Service com sucesso."
