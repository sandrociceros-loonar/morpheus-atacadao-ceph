#!/bin/bash

# Função para arredondar para cima
ceil() {
  awk -v n="$1" 'BEGIN{print (n == int(n)) ? n : int(n)+1}'
}

# Quantas VMs L1 deseja criar?
read -p "Quantas VMs L1 deseja criar? " NUM_VMS

# Coleta de informações do host
TOTAL_CORES=$(lscpu | awk '/^Core\\(s\\) per socket:/ { print $4 }')
SOCKETS=$(lscpu | awk '/^Socket\\(s\\):/ { print $2 }')
TOTAL_PHYSICAL_CORES=$((TOTAL_CORES * SOCKETS))

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GIB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_KB/1024/1024}")

# Reserva recomendada: 10% para sistema/hypervisor
CORE_RESERVA=$((TOTAL_PHYSICAL_CORES / 10))
[ $CORE_RESERVA -lt 1 ] && CORE_RESERVA=1

MEM_RESERVA=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_GIB*0.10}")

CORES_PARA_VMS=$((TOTAL_PHYSICAL_CORES - CORE_RESERVA))
MEM_PARA_VMS=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_GIB - $MEM_RESERVA}")

CORES_POR_VM=$(awk "BEGIN {printf \"%.2f\", $CORES_PARA_VMS/$NUM_VMS}")
CORES_POR_VM_INT=$(ceil $CORES_POR_VM)

MEM_POR_VM=$(awk "BEGIN {printf \"%.2f\", $MEM_PARA_VMS/$NUM_VMS}")

CORES_POR_SOCKET_POR_VM=$(awk "BEGIN {printf \"%.2f\", $CORES_POR_VM_INT/$SOCKETS}")
CORES_POR_SOCKET_POR_VM_INT=$(ceil $CORES_POR_SOCKET_POR_VM)

# Resultado
echo ""
echo "Host detectado:"
echo "Total de núcleos físicos: $TOTAL_PHYSICAL_CORES"
echo "Total de sockets:         $SOCKETS"
echo "Total de memória (GiB):   $TOTAL_MEM_GIB"
echo "Reservado p/ SO/hypervisor: Núcleos $CORE_RESERVA, Memória $MEM_RESERVA GiB"
echo ""
echo "Recursos sugeridos por VM para $NUM_VMS VMs L1:"
echo "CPU - Core Count:         $CORES_POR_VM_INT"
echo "CPU - Cores per Socket:   $CORES_POR_SOCKET_POR_VM_INT"
echo "Memória (GiB):            $MEM_POR_VM"
