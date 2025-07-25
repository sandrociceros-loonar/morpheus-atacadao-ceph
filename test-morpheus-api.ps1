# morpheus-api-test.ps1

# Solicitar URL base do Morpheus ao usuário
$baseUrl = Read-Host "Digite a URL base do Morpheus (ex: https://seu-morpheus.seu-dominio.com)"

# Perguntar ao usuário se quer ignorar erros SSL/TLS
$ignoreSslInput = Read-Host "Deseja ignorar erros de certificado SSL/TLS? (S/N)"
$ignoreSsl = ($ignoreSslInput.Trim().ToUpper() -eq "S")

if ($ignoreSsl) {
    Write-Host "Ignorando erros de certificado SSL/TLS..."
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
} else {
    Write-Host "Validação de certificado SSL/TLS será respeitada."
}

# Prompt para usuário
$username = Read-Host "Digite o usuário"

# Prompt para senha (senha oculta)
$password = Read-Host "Digite a senha" -AsSecureString
$Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr)

# Autenticação
$body = @{
    username = $username
    password = $plainPassword
    grant_type = "password"
    scope = "write"
}

try {
    $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/oauth/token" -Body $body -ContentType "application/x-www-form-urlencoded"
} catch {
    Write-Error "Erro na autenticação: $_"
    exit 1
}

$token = $response.access_token

if (-not $token) {
    Write-Error "Falha ao obter token de acesso. Verifique as credenciais."
    exit 1
}

Write-Host "Token obtido com sucesso."

# Obter clouds
$headers = @{ Authorization = "BEARER $token" }

try {
    $cloudsResponse = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/clouds" -Headers $headers
} catch {
    Write-Error "Erro ao consultar clouds: $_"
    exit 1
}

# Exibir resultado formatado como JSON
$cloudsResponse | ConvertTo-Json -Depth 5
