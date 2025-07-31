# install-tgt-iscsi-target.md

## Descrição do Script

O script `install-tgt-iscsi-target.sh` é um utilitário automatizado para instalar, configurar e disponibilizar um servidor iSCSI Target utilizando o pacote `tgt` no ambiente Ubuntu ou Proxmox.

### Funcionalidades principais:

- Instala e configura o serviço `tgt` para fornecer armazenamento iSCSI.
- Cria um target iSCSI com nome configurável.
- Cria uma LUN baseada em um arquivo de imagem com tamanho configurável.
- Configura autenticação CHAP para segurança, se desejado.
- Permite definir quais endereços IP ou initiators podem acessar o target.
- Configura o serviço para iniciar automaticamente.
- Aplica configurações básicas de firewall caso o UFW esteja ativo.

## Como executar

1. Salve o script em um arquivo chamado `install-tgt-iscsi-target.sh`.
2. Dê permissão de execução:

   ```bash
   chmod +x install-tgt-iscsi-target.sh
   ```

3. Execute o script como root ou usando sudo:

   ```bash
   sudo ./install-tgt-iscsi-target.sh
   ```

4. Durante a execução, o script solicitará:

   - Nome do iSCSI Target (ex.: `iqn.2024-01.com.empresa:target01`).
   - Tamanho da LUN em GB.
   - Diretório onde será armazenado o arquivo de LUN.
   - Endereços IP dos initiators autorizados.
   - Se deseja configurar autenticação CHAP, com usuário e senha.

## Resultados esperados

- O script instalará os pacotes necessários do `tgt`.
- Será criado um arquivo com o tamanho especificado representando a LUN.
- Uma configuração do iSCSI target será criada em `/etc/tgt/conf.d/`.
- O serviço `tgt` será habilitado e iniciado, disponibilizando o target para acesso.
- O firewall será configurado para permitir conexões na porta TCP 3260, caso o UFW esteja ativo.

Ao final, será exibido um resumo da configuração, instruções para conectar initiators e comandos para gerenciamento.

## Dicas de troubleshooting

- Certifique-se de que a porta 3260 TCP está aberta e acessível na rede.

- Verifique se os initiators estão configurados corretamente com o IQN e endereço IP autorizados.

- Se o target não aparecer no initiator, utilize o comando de descoberta:

  ```bash
  iscsiadm -m discovery -t st -p :3260
  ```

- Para problemas de autenticação, confirme que as credenciais CHAP configuradas no servidor e no initiator coincidem.

- Use o comando `tgt-admin --show` para verificar a configuração atual do target.

- Se a LUN não estiver acessível, confira a configuração do arquivo imagem e se ele tem permissões corretas.

- Em caso de problemas no serviço, verifique os logs usando:

  ```bash
  journalctl -u tgt
  ```

- Se executar o script em um container, certifique-se que as capacidades de bloco e rede estejam corretamente configuradas para suportar iSCSI.

Este documento fornece todas as informações essenciais para entender, executar e solucionar possíveis problemas relacionados ao script `install-tgt-iscsi-target.sh` para criação e gerenciamento de um servidor iSCSI target.