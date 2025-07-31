Baseado no script `configure-enterprise-resources.sh` que criamos na conversa anterior, vou gerar a página markdown no mesmo padrão das anteriores:

# 🏢 Setup Enterprise Options - Configure Enterprise Resources

## 📋 Visão Geral

O script `configure-enterprise-resources.sh` configura recursos enterprise DLM/lvmlockd em cluster Pacemaker existente, transformando uma configuração básica em um ambiente de alta disponibilidade adequado para produção.

## 🎯 Propósito

Este script é executado **após** o `install-lun-prerequisites.sh` quando o cluster está funcionando mas **sem recursos enterprise configurados**. Ele adiciona:

- **DLM (Distributed Lock Manager)** em modo clone
- **lvmlockd (LVM Lock Daemon)** em modo clone  
- **Dependências e constraints** adequadas
- **Volume Group** em modo cluster DLM
- **Validação completa** da configuração

## 🔧 Pré-requisitos

### ✅ Requisitos Obrigatórios

- **Cluster Pacemaker/Corosync** ativo e funcionando
- **Ambos os nós** online (`fc-test1` e `fc-test2`)
- **Volume Group** `vg_cluster` criado e acessível
- **Conectividade de rede** entre nós funcionando
- **Execução no nó primário** (fc-test1)

### 📦 Dependências de Software

- `pacemaker` (já instalado via install-lun-prerequisites.sh)
- `corosync` (já instalado via install-lun-prerequisites.sh)
- `dlm-controld` (já instalado via install-lun-prerequisites.sh)
- `lvm2-lockd` (já instalado via install-lun-prerequisites.sh)
- `pcs` (já instalado via install-lun-prerequisites.sh)

## 📂 Estrutura de Arquivos

```
morpheus-atacadao-ceph/gfs2/
├── configure-enterprise-resources.sh  ← Script principal
├── install-lun-prerequisites.sh       ← Pré-requisito
├── configure-lun-multipath.sh         ← Próximo passo
└── docs/
    └── setup-enterprise-options.md    ← Esta documentação
```

## 🚀 Execução

### 1. Preparação

```bash
# Verificar cluster antes da execução
sudo pcs status

# Verificar Volume Group
sudo vgs vg_cluster

# Tornar script executável
chmod +x configure-enterprise-resources.sh
```

### 2. Execução Principal

```bash
# Executar APENAS no nó primário (fc-test1)
sudo ./configure-enterprise-resources.sh
```

### 3. Verificação Pós-Execução

```bash
# Verificar recursos configurados
sudo pcs status resources

# Verificar Volume Group em modo cluster
sudo vgs vg_cluster

# Verificar DLM
sudo dlm_tool status
```

## ⚙️ Configurações Implementadas

### 🔒 Recurso DLM (Distributed Lock Manager)

```bash
# Configuração aplicada pelo script
pcs resource create dlm systemd:dlm \
    op start timeout=90s \
    op stop timeout=100s \
    op monitor interval=60s timeout=60s on-fail=fence \
    clone interleave=true ordered=true
```

**Benefícios:**
- **Coordenação de locks** entre nós
- **Health monitoring** a cada 60 segundos
- **Restart automático** em caso de falhas
- **Disponibilidade** em ambos os nós

### 💾 Recurso lvmlockd (LVM Lock Daemon)

```bash
# Configuração aplicada pelo script
pcs resource create lvmlockd systemd:lvmlockd \
    op start timeout=90s \
    op stop timeout=100s \
    op monitor interval=60s timeout=60s on-fail=fence \
    clone interleave=true ordered=true
```

**Benefícios:**
- **LVM cluster-aware** adequado
- **Locks distribuídos** para Volume Groups
- **Failover automático** entre nós
- **Coordenação** com DLM

### 🔗 Dependências e Constraints

```bash
# Ordem de inicialização
pcs constraint order start dlm-clone then lvmlockd-clone

# Colocation (mesmo nó)
pcs constraint colocation add lvmlockd-clone with dlm-clone
```

**Benefícios:**
- **Inicialização ordenada** - DLM antes de lvmlockd
- **Recursos coordenados** - lvmlockd segue DLM
- **Estabilidade** do cluster

### 🗄️ Volume Group Cluster

```bash
# Conversão para modo cluster DLM
vgchange --locktype dlm vg_cluster
vgchange --lockstart vg_cluster
```

**Benefícios:**
- **Acesso coordenado** entre nós
- **Prevenção de corrupção** de dados
- **Compatibilidade** com GFS2

## 📊 Validações Realizadas

### ✅ Verificações Automáticas

1. **Status do Cluster**
   - Cluster ativo e acessível
   - Ambos os nós online
   - Execução no nó correto

2. **Recursos Enterprise**
   - DLM ativo em ambos os nós
   - lvmlockd ativo em ambos os nós
   - Constraints configuradas

3. **Volume Group**
   - Modo cluster DLM ativo
   - Locks funcionando
   - Acesso em ambos os nós

4. **Coordenação DLM**
   - Lockspaces ativos
   - Comunicação entre nós
   - Status geral saudável

## 🔧 Opções Avançadas

### Argumentos do Script

```bash
# Ajuda e informações
./configure-enterprise-resources.sh --help
./configure-enterprise-resources.sh --version

# Troubleshooting
./configure-enterprise-resources.sh --troubleshoot
```

### Comandos de Diagnóstico

```bash
# Status completo do cluster
sudo pcs status --full

# Status específico dos recursos
sudo pcs status resources

# Logs do cluster
sudo journalctl -u corosync -n 20
sudo journalctl -u pacemaker -n 20

# Status DLM detalhado
sudo dlm_tool status
sudo dlm_tool ls
```

## 🚨 Troubleshooting

### Problemas Comuns

#### 1. **Recurso não inicia**
```bash
# Verificar logs detalhados
sudo pcs status --full

# Limpar falhas
sudo pcs resource cleanup dlm-clone
sudo pcs resource cleanup lvmlockd-clone
```

#### 2. **DLM não conecta entre nós**
```bash
# Verificar conectividade
ping fc-test2

# Verificar portas do cluster
telnet fc-test2 5405
```

#### 3. **Volume Group sem locks**
```bash
# Reiniciar locks manualmente
sudo vgchange --lockstop vg_cluster
sudo vgchange --lockstart vg_cluster
```

#### 4. **Timeout durante configuração**
```bash
# Aguardar mais tempo
sleep 60

# Verificar dependências
sudo pcs constraint show
```

### Reset Completo (Último Recurso)

```bash
# Parar recursos
sudo pcs resource disable dlm-clone lvmlockd-clone

# Limpar configurações
sudo pcs resource cleanup

# Remover recursos
sudo pcs resource delete dlm-clone lvmlockd-clone --force

# Reexecutar script
sudo ./configure-enterprise-resources.sh
```

## 📈 Benefícios Enterprise

### 🏢 Alta Disponibilidade

- **Failover automático** de recursos entre nós
- **Monitoramento contínuo** com health checks
- **Recovery automático** em caso de falhas
- **Balanceamento** de carga entre nós

### 🔒 Segurança e Integridade

- **Locks distribuídos** previnem corrupção
- **Coordenação adequada** de acesso concorrente
- **Isolamento** de nós com falha
- **Consistência** de dados garantida

### 📊 Monitoramento

- **Health checks** a cada 60 segundos
- **Logs centralizados** via Pacemaker
- **Status detalhado** dos recursos
- **Alertas automáticos** para falhas

### 🔄 Operações

- **Gestão centralizada** via PCS
- **Comandos padronizados** para administração
- **Backup automático** de configurações
- **Upgrade path** para versões futuras

## 🎯 Próximos Passos

### Após Execução Bem-Sucedida

1. **Verificar configuração:**
   ```bash
   sudo pcs status
   sudo vgs vg_cluster
   ```

2. **Formatar GFS2:**
   ```bash
   sudo ./configure-lun-multipath.sh
   ```

3. **Configurar segundo nó:**
   ```bash
   sudo ./configure-second-node.sh
   ```

4. **Validar ambiente:**
   ```bash
   sudo ./test-lun-gfs2.sh
   ```

## 📚 Referências

- [Red Hat High Availability Add-On](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_and_managing_high_availability_clusters/)
- [Pacemaker Documentation](https://clusterlabs.org/pacemaker/doc/)
- [DLM Documentation](https://docs.kernel.org/filesystems/dlm.html)
- [GFS2 Cluster Configuration](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_gfs2_file_systems/)

**📝 Nota:** Este script transforma um cluster básico em uma configuração enterprise de produção, adequada para ambientes críticos que requerem alta disponibilidade e coordenação de locks distribuídos.