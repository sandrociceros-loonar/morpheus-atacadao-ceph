#!/usr/bin/bash

# 1. Verificar versão atual do kernel
uname -r

# 2. Instalar kernel genérico com todos os módulos
sudo apt update
sudo apt install linux-generic linux-modules-extra-$(uname -r)

# 3. Se não funcionar, instalar kernel HWE (Hardware Enablement)
sudo apt install --install-recommends linux-generic-hwe-22.04

# 4. Reiniciar o sistema
sudo reboot

# 5. Após reiniciar, verificar se DLM está disponível
sudo modprobe dlm
lsmod | grep dlm
