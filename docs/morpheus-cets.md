# Instrução: Arquivos necessários para nonfigurar SSL/TLS no Morpheus Data

## 1. Chave Privada (.key)

- **Arquivo:** `your_fqdn_name.key`
- **Descrição:** Esta é a chave privada gerada durante o processo de criação do CSR (Certificate Signing Request). Deve ser mantida em segredo e nunca compartilhada publicamente.
- **Local de armazenamento:**  
  `/etc/morpheus/ssl/your_fqdn_name.key`  
  (de preferência, somente com permissão de leitura para usuário root)

## 2. Certificado Principal (.crt ou .pem)

- **Arquivo:** `your_fqdn_name.crt` ou `your_fqdn_name.pem`
- **Descrição:** É o certificado digital principal emitido pela autoridade certificadora após validação do seu CSR.
- **Local de armazenamento:**  
  `/etc/morpheus/ssl/your_fqdn_name.crt`  
  (ou .pem, conforme fornecido)

## 3. Cadeia Completa de Certificados (Chain/Bundle)

- **Arquivo:** Opções possíveis:
  - Inclua a cadeia completa (incluindo certificados intermediários e root) dentro do arquivo de certificado principal (`.crt`)
  - Ou, se fornecido separadamente, obtenha também o arquivo:  
    `ca_bundle.crt` ou `full_chain.pem`
- **Descrição:** É fundamental que todo o caminho de confiança esteja disponível para clientes, incluindo certificados intermediários e de raiz. Esses certificados podem ser unidos em um único arquivo `.crt` ou referenciados separadamente.
- **Local de armazenamento:**  
  Caso use o arquivo bundle, coloque-o em `/etc/morpheus/ssl/` ou insira o conteúdo no arquivo `.crt` principal.

## 4. Certificados confiáveis adicionais (opcional)

- Para integração com provedores, serviços externos ou agentes que exigem confiança adicional, pode ser necessário importar certificados complementares no diretório:
  - `/etc/morpheus/ssl/trusted_certs/`  
  (arquivos `.pem` ou `.crt` da cadeia confiável para importação interna do Java Keystore, conforme documentação)

## 5. Arquivo de Configuração

- **Arquivo:** `/etc/morpheus/morpheus.rb`
- Após copiar os arquivos, edite este arquivo adicionando ou atualizando:

  ```ruby
  nginx['ssl_certificate'] = '/etc/morpheus/ssl/your_fqdn_name.crt'
  nginx['ssl_server_key'] = '/etc/morpheus/ssl/your_fqdn_name.key'
  ```

- Reinicie a configuração:

  ```shell
  sudo morpheus-ctl reconfigure
  sudo morpheus-ctl restart nginx
  ```

## Resumo em Tabela

| Arquivo                       | Descrição                                           | Local Padrão                                    |
|-------------------------------|----------------------------------------------------|-------------------------------------------------|
| your_fqdn_name.key            | Chave privada SSL                                  | /etc/morpheus/ssl/                              |
| your_fqdn_name.crt (ou .pem)  | Certificado principal emitido pela CA              | /etc/morpheus/ssl/                              |
| ca_bundle.crt / full_chain.pem| Cadeia completa de certificação (intermediários)   | /etc/morpheus/ssl/ (ou embutido no .crt/.pem)   |
| trusted_certs/*               | Certificados adicionais confiáveis (opcional)      | /etc/morpheus/ssl/trusted_certs/                |
| morpheus.rb                   | Configuração do caminho dos arquivos SSL/TLS       | /etc/morpheus/                                  |

> **Nota:** Certifique-se de que os arquivos de chave e certificado estejam com permissões restritas e pertencentes ao usuário root, e que o certificado possua toda a cadeia de confiança embutida se possível [1] [2] [3].

## Recomendações

- Sempre solicite o certificado em formato PEM ou CRT, incluindo toda a cadeia de intermediários.
- Não utilize certificados e chaves de ambientes de teste em produção.
- Após qualquer alteração, rode `sudo morpheus-ctl reconfigure` e reinicie o NGINX conforme documentação.

Esses são os arquivos padrão e procedimentos requeridos para garantir uma configuração segura de SSL/TLS no Morpheus Data.

[1] [https://docs.morpheusdata.com/en/7.0.4/getting_started/additional/additional_configuration.html]

[2] [https://docs.morpheusdata.com/en/6.2.4/getting_started/additional/morpheusSslCerts.html

[3] [https://docs.morpheusdata.com/en/latest/getting_started/additional/ssl-import.html?highlight=certificate

[4] [https://morpheus.my.site.com/support/s/article/How-to-enable-SSL

[5] [https://docs.morpheusdata.com/en/7.0.6/administration/settings/settings.html

[6] [https://morpheusdata.com/wp-content/uploads/content/Morpheus-Reference-Architecture-5.X-v3.1-2023-January.pdf

[7] [https://docs.morpheusdata.com/en/8.0.4/getting_started/installation/overview.html

[8] [https://morpheus.my.site.com/support/s/article/How-to-configure-TLS-for-RabbitMQ

[9] [https://docs.morpheusdata.com/en/8.0.2/troubleshooting/SSL_cert_regen.html

[10] [https://docs.morpheusdata.com/en/6.0.4/getting_started/installation/overview.html

[11] [https://support.hpe.com/hpesc/public/docDisplay?docId=sd00006453en_us&page=GUID-32D8CBBE-0375-48BC-8038-E6618F94BE83.html

[12] [https://docs.morpheusdata.com/en/6.1.1/getting_started/additional/additional_configuration.html

[13] [https://docs.morpheusdata.com/en/6.1.0/getting_started/additional/ha_load_balancer.html

[14] [https://docs.morpheusdata.com/en/6.0.7/getting_started/additional/ssl-import.html

[15] [https://support.morpheusdata.com/s/article/implement-a-third-party-ssl-certificate?language=en_US

[16] [https://support.morpheusdata.com/s/article/How-to-configure-TLS-for-RabbitMQ

[17] [https://discuss.morpheusdata.com/t/distributed-worker-is-not-being-able-to-configure-correctly/1645

[18] [https://morpheus.my.site.com/support/s/article/SSL-intercepts-and-Morpheus

[19] [https://support.morpheusdata.com/s/article/SSL-intercepts-and-Morpheus

[20] [https://support.hpe.com/hpesc/public/docDisplay?docId=sd00006453en_us&docLocale=en_US]
