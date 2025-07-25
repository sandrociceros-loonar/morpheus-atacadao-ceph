#!/bin/bash

# Solicitar URL base do Morpheus ao usuário
read -p "Digite a URL base do Morpheus (ex: https://seu-morpheus.seu-dominio.com): " baseUrl

# Perguntar ao usuário se quer ignorar erros SSL/TLS
read -p "Deseja ignorar erros de certificado SSL/TLS? (S/N): " ignoreSslInput
ignoreSsl=$(echo "$ignoreSslInput" | tr '[:lower:]' '[:upper:]')

if [ "$ignoreSsl" == "S" ]; then
    echo "Ignorando erros de certificado SSL/TLS..."
    export CURL_INSECURE="--insecure"
else
    echo "Validação de certificado SSL/TLS será respeitada."
    export CURL_INSECURE=""
fi

# Prompt para usuário
read -p "Digite o usuário: " username

# Prompt para senha (senha oculta)
echo -n "Digite a senha: "
read -s password
echo

# Autenticação
response=$(curl -s $CURL_INSECURE -X POST "$baseUrl/api/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$username&password=$password&grant_type=password&scope=write")

token=$(echo "$response" | jq -r '.access_token')

if [ "$token" == "null" ] || [ -z "$token" ]; then
    echo "Erro na autenticação. Verifique as credenciais."
    exit 1
fi

echo "Token obtido com sucesso."

# Obter clouds
cloudsResponse=$(curl -s $CURL_INSECURE -X GET "$baseUrl/api/clouds" \
    -H "Authorization: BEARER $token")

if [ -z "$cloudsResponse" ]; then
    echo "Erro ao consultar clouds."
    exit 1
fi

# Exibir resultado formatado como JSON
echo "$cloudsResponse" | jq .
