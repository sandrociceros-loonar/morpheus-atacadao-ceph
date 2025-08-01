# 🔗 Setup iSCSI LUN - Configuração Automática de Storage

## 📋 Visão Geral

O script `setup-iscsi-lun.sh` configura automaticamente a conectividade iSCSI com discovery automático de targets, estabelecendo conexão com storage compartilhado via multipath para clusters GFS2.

## 🎯 Propósito

Este script automatiza completamente a configuração de conectividade iSCSI, incluindo:

- **Discovery automático** de targets iSCSI disponíveis
- **Configuração otimizada** do initiator iSCSI 
- **Estabelecimento de conexão** com target selecionado
- **Configuração de multipath** com alias personalizado
- **Validação completa** da configuração e testes de I/O

## 🔧 Pré-requisitos

### ✅ Requisitos de Sistema

- **Ubuntu 22.04 LTS** (ou distribuição compatível)
- **Conectividade de rede** com servidor iSCSI Target
- **Privilégios administrativos** (sudo)
- **Acesso TCP porta 3260** no servidor Target

### 📦 Dependências de Software

O script instala automaticamente os pacotes necessários:
- `open-iscsi` - Cliente iSCSI
- `multipath-tools` - Gerenciamento de caminhos múltiplos
- `lvm2` - Logical Volume Manager

### 🌐 Requisitos de Rede

- **Conectividade TCP** para servidor iSCSI na porta 3260
- **Resolução DNS** ou conectividade por IP direto
- **Largura de banda adequada** para storage compartilhado

## 📂 Estrutura de Arquivos

```
morpheus-atacadao-ceph/gfs2/
├── setup-iscsi-lun.sh                 ← Script principal (v2.0)
├── install-lun-prerequisites.sh       ← Próximo passo (cluster)
├── configure-lun-multipath.sh         ← Configuração GFS2
└── docs/
    └── setup-iscsi-lun.md            ← Esta documentação
```

## 🚀 Execução

### 1. Preparação

```bash
# Baixar e tornar executável
chmod +x setup-iscsi-lun.sh

# Verificar conectividade com servidor Target
ping 192.168.0.250  # ou IP do seu servidor iSCSI
```

### 2. Execução com Discovery Automático

```bash
# Usar IP padrão (192.168.0.250)
sudo ./setup-iscsi-lun.sh

# Ou especificar IP do servidor
sudo ./setup-iscsi-lun.sh 192.168.1.100
```

### 3. Processo Interativo

O script executará automaticamente:

1. **Verificação de pré-requisitos**
2. **Discovery de targets disponíveis**
3. **Seleção automática ou manual do target**
4. **Configuração do initiator iSCSI**
5. **Estabelecimento da conexão**
6. **Configuração do multipath**
7. **Validação e testes**

## ⚙️ Configurações Aplicadas

### 🔍 Discovery Automático

```bash
# Funcionalidade implementada:
- Descoberta automática de todos os targets no servidor
- Seleção inteligente (automática para 1 target)
- Interface interativa para múltiplos targets
- Validação de conectividade antes do discovery
```

### 🔧 Configuração do Initiator

```bash
# InitiatorName único gerado automaticamente:
iqn.2004-10.com.ubuntu:01:[random-hex]:[hostname]

# Exemplo gerado:
iqn.2004-10.com.ubuntu:01:a1b2c3d4e5f6:fc-test1
```

### ⚙️ Parâmetros iSCSI Otimizados

```bash
# Configurações aplicadas em /etc/iscsi/iscsid.conf:
node.startup = automatic
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.session.queue_depth = 32
node.session.auth.authmethod = None  # Para laboratório
```

### 🛣️ Configuração Multipath

```bash
# Alias padrão criado:
/dev/mapper/fc-lun-cluster

# Configurações otimizadas para cluster:
- path_grouping_policy: multibus
- failback: immediate
- no_path_retry: queue
- dev_loss_tmo: infinity
- fast_io_fail_tmo: 5
```

## 📊 Validações Realizadas

### ✅ Verificações Automáticas

1. **Pré-requisitos do Sistema**
   - Pacotes necessários instalados
   - Serviços iSCSI ativos
   - Conectividade de rede

2. **Discovery de Targets**
   - Conectividade com servidor iSCSI
   - Descoberta de targets disponíveis
   - Validação de IQNs

3. **Conexão iSCSI**
   - Estabelecimento da sessão
   - Detecção de dispositivos
   - Verificação de acesso

4. **Configuração Multipath**
   - Criação do alias personalizado
   - Validação do WWID
   - Testes de I/O básicos

### 🧪 Testes de Validação

```bash
# Testes executados automaticamente:
- Teste de conectividade TCP (ping)
- Teste de discovery iSCSI
- Teste de login no target
- Teste de leitura do dispositivo
- Teste de performance básica (opcional)
```

## 🔧 Opções Avançadas

### Argumentos do Script

```bash
# Ajuda e informações
./setup-iscsi-lun.sh --help
./setup-iscsi-lun.sh --version

# Especificar servidor Target
./setup-iscsi-lun.sh 192.168.1.100
./setup-iscsi-lun.sh 10.0.0.50
```

### Customização de Configurações

```bash
# Variáveis configuráveis no script:
DEFAULT_TGT_IP="192.168.0.250"      # IP padrão do servidor
ISCSI_PORT="3260"                   # Porta iSCSI padrão
MULTIPATH_ALIAS="fc-lun-cluster"    # Alias do dispositivo multipath
```

### Configuração Manual Pós-Execução

```bash
# Verificar dispositivos criados
ls -la /dev/mapper/fc-lun-cluster

# Status das sessões iSCSI
sudo iscsiadm -m session

# Status detalhado do multipath
sudo multipath -ll fc-lun-cluster

# Informações do dispositivo
lsblk /dev/mapper/fc-lun-cluster
```

## 🚨 Troubleshooting

### Problemas Comuns

#### 1. **Discovery falha - "No targets found"**
```bash
# Verificar conectividade
ping [IP_DO_SERVIDOR]
telnet [IP_DO_SERVIDOR] 3260

# Verificar firewall no servidor Target
# Verificar se serviço tgtd está ativo no servidor
```

#### 2. **Conexão iSCSI falha**
```bash
# Verificar configuração de ACL no Target
sudo tgtadm --mode target --op show

# Verificar InitiatorName
cat /etc/iscsi/initiatorname.iscsi

# Reiniciar serviços iSCSI
sudo systemctl restart open-iscsi iscsid
```

#### 3. **Dispositivo multipath não criado**
```bash
# Verificar dispositivos detectados
lsscsi | grep -E "(IET|LIO)"

# Forçar recriação do multipath
sudo multipath -F
sudo multipath -r

# Verificar configuração
sudo multipath -t
```

#### 4. **Performance baixa**
```bash
# Verificar parâmetros de queue depth
cat /sys/class/scsi_host/host*/can_queue

# Otimizar parâmetros de I/O
echo mq-deadline | sudo tee /sys/block/dm-*/queue/scheduler

# Verificar configurações de rede
sudo ethtool [interface_de_rede]
```

### Comandos de Diagnóstico

```bash
# Status completo das sessões iSCSI
sudo iscsiadm -m session -P3

# Informações detalhadas do multipath
sudo multipathd show config
sudo multipathd show maps

# Logs do sistema
sudo journalctl -u open-iscsi -n 20
sudo journalctl -u multipathd -n 20

# Teste de conectividade
sudo iscsiadm -m discovery -t st -p [IP_SERVIDOR]:3260
```

## 📈 Recursos da Versão 2.0

### 🆕 Novidades Implementadas

1. **Discovery Automático Inteligente**
   - Descoberta automática de todos os targets
   - Seleção inteligente para target único
   - Interface interativa para múltiplos targets

2. **Configuração Otimizada**
   - InitiatorName único por nó
   - Parâmetros otimizados para cluster
   - Timeouts adequados para ambiente GFS2

3. **Validação Abrangente**
   - Testes de conectividade em cada etapa
   - Verificação de dispositivos criados
   - Testes básicos de I/O

4. **User Experience Melhorada**
   - Output colorido e organizado
   - Mensagens informativas detalhadas
   - Relatório final completo

### ⚡ Melhorias de Performance

- **Queue depth otimizado** para storage compartilhado
- **Timeouts ajustados** para ambiente cluster
- **Configuração multipath** otimizada para HA
- **Parâmetros de retry** adequados

### 🔒 Security e Confiabilidade

- **InitiatorName único** por nó (evita conflitos)
- **Validação de WWID** para garantir dispositivo correto
- **Configuração de failover** adequada
- **Tratamento de erros** robusto

## 🎯 Próximos Passos

### Após Execução Bem-Sucedida

1. **Verificar configuração:**
   ```bash
   ls -la /dev/mapper/fc-lun-cluster
   sudo multipath -ll
   ```

2. **Executar no segundo nó:**
   ```bash
   # No fc-test2
   sudo ./setup-iscsi-lun.sh
   ```

3. **Configurar cluster:**
   ```bash
   sudo ./install-lun-prerequisites.sh
   ```

4. **Configurar GFS2:**
   ```bash
   sudo ./configure-lun-multipath.sh
   ```

### Integração com Scripts Subsequentes

O script cria automaticamente o dispositivo `/dev/mapper/fc-lun-cluster` que será usado pelos próximos scripts:

- **install-lun-prerequisites.sh** - Detectará automaticamente o device
- **configure-lun-multipath.sh** - Usará para formatação GFS2
- **test-lun-gfs2.sh** - Validará funcionamento completo

## 📚 Referências

- [iSCSI Target Discovery (RFC 3720)](https://tools.ietf.org/html/rfc3720)
- [Linux Multipath Configuration Guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/managing_storage_devices/configuring-device-mapper-multipath_managing-storage-devices)
- [Open-iSCSI Administration Guide](http://www.open-iscsi.com/docs/README)
- [GFS2 Storage Requirements](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_gfs2_file_systems/)

## 📝 Informações Técnicas

- **Autor:** sandro.cicero@loonar.cloud
- **Compatibilidade:** Ubuntu 22.04 LTS, Debian 11+
- **Suporte:** Ambiente de laboratório GFS2

**📝 Nota:** Este script foi desenvolvido para configuração automatizada de conectividade iSCSI em ambientes de cluster GFS2, com foco em simplicidade, robustez e experiência do usuário otimizada.