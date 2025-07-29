#!/bin/bash

# Solicita ao usuário a quantidade de VMs
read -p "Informe a quantidade de VMs a serem criadas: " QTD_VMS

# Obtém o total de RAM disponível em GiB
TOTAL_RAM_GIB=$(free -g | awk '/^Mem:/ {print $2}')

# Calcula 10% da RAM total
RESERVA=$(echo "$TOTAL_RAM_GIB * 0.10" | bc)

# Se a reserva calculada for menor que 4GB, define reserva mínima 4GB
RESERVA_MINIMA=4
RESERVA_OK=$(echo "$RESERVA < $RESERVA_MINIMA" | bc)
if [ "$RESERVA_OK" -eq 1 ]; then
  RESERVA=$RESERVA_MINIMA
fi

# RAM disponível para as VMs
RAM_VMS=$(echo "$TOTAL_RAM_GIB - $RESERVA" | bc)

# RAM por VM (em GiB)
RAM_POR_VM=$(echo "scale=2; $RAM_VMS / $QTD_VMS" | bc)

echo ""
echo "Total de RAM física disponível: $TOTAL_RAM_GIB GiB"
echo "Reserva para sistema/hypervisor: $RESERVA GiB"
echo "RAM disponível para VMs: $RAM_VMS GiB"
echo "RAM por VM (se $QTD_VMS VMs): $RAM_POR_VM GiB"
