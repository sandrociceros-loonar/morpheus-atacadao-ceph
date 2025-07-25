# Procedimento: Adição ou Atualização de Certificado SSL/TLS no Morpheus Data

Este passo a passo garante que qualquer técnico possa adicionar ou atualizar o certificado SSL/TLS da instância Morpheus utilizando corretamente os arquivos fornecidos.

## 1. Pré-requisitos

- **Permissões administrativas** no appliance Morpheus (acesso root).
- Os seguintes arquivos:
  - `private.key` — chave privada.
  - `star_cec_dev_br.crt` — certificado principal do servidor.
  - `My_CA_Bundle.crt` — cadeia de certificados intermediários (CA bundle).

## 2. Backup dos Arquivos Atuais

Antes de qualquer alteração, faça backup dos arquivos de SSL/TLS existentes:

```bash
sudo mkdir -p /etc/morpheus/ssl/backup_$(date +%Y%m%d_%H%M%S)
sudo cp /etc/morpheus/ssl/* /etc/morpheus/ssl/backup_$(date +%Y%m%d_%H%M%S)/
```

## 3. Upload e Preparo dos Novos Certificados

- Copie os arquivos fornecidos (`private.key`, `star_cec_dev_br.crt`, `My_CA_Bundle.crt`) para `/etc/morpheus/ssl/`.

- Recomenda-se criar um arquivo de certificado completo concatenando o arquivo principal com o bundle de CA:

```bash
cat star_cec_dev_br.crt My_CA_Bundle.crt > morpheus_cec_dev_br_fullchain.crt
```

## 4. Ajuste de Permissões

Garanta que **apenas o root** pode ler a chave privada:

```bash
sudo chown root:root /etc/morpheus/ssl/private.key
sudo chmod 600 /etc/morpheus/ssl/private.key
```

Assegure permissões adequadas para os certificados:

```bash
sudo chown root:root /etc/morpheus/ssl/morpheus_cec_dev_br_fullchain.crt
sudo chmod 644 /etc/morpheus/ssl/morpheus_cec_dev_br_fullchain.crt
```

## 5. Atualização da Configuração do Morpheus

Edite o arquivo de configuração `/etc/morpheus/morpheus.rb` para apontar corretamente para os arquivos:

```ruby
nginx['ssl_certificate'] = '/etc/morpheus/ssl/morpheus_cec_dev_br_fullchain.crt'
nginx['ssl_server_key'] = '/etc/morpheus/ssl/private.key'
```

Salve e feche o arquivo.

## 6. Reconfiguração e Reinicialização dos Serviços

Execute os comandos abaixo para aplicar a nova configuração e reiniciar o NGINX:

```bash
sudo morpheus-ctl reconfigure
sudo morpheus-ctl restart nginx
```

## 7. Validação

1. **Acesse o Morpheus por HTTPS:**  
   Vá até `https://morpheus.cec.dev.br` pelo navegador.
2. **Verifique o certificado:**  
   Certifique-se de que o certificado exibido é o novo, está válido e não gera advertências no navegador.
3. Se possível, valide também com ferramentas como:

   ```bash
   openssl s_client -connect morpheus.cec.dev.br:443 -showcerts
   ```

## 8. Resolução de Problemas

- Se houver erro após reiniciar o serviço, revise o caminho dos arquivos no `/etc/morpheus/morpheus.rb` e verifique permissões.
- Consulte logs do Morpheus/NGINX em `/var/log/morpheus/nginx/` para detalhes de falhas.
- Confirme que o arquivo `.crt` contém, em ordem, o certificado do servidor seguido pelo CA bundle.

**Pronto! Após seguir esses passos, seu Morpheus estará com o novo certificado SSL/TLS ativo.**
