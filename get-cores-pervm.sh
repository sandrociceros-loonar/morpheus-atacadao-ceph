#!/bin/bash

TOTAL_CORES=$(nproc --all)

if [[ -z "$TOTAL_CORES" || "$TOTAL_CORES" -lt 1 ]]; then
  echo "Não foi possível detectar a quantidade total de núcleos físicos do host."
  exit 1
fi

read -p "Informe a quantidade de VMs a criar: " QTD_VMS

if [[ -z "$QTD_VMS" || "$QTD_VMS" -lt 1 ]]; then
  echo "Quantidade inválida de VMs."
  exit 2
fi

RESERVA_INICIAL=$(( TOTAL_CORES / 10 ))
if [[ "$RESERVA_INICIAL" -lt 1 ]]; then
  RESERVA_INICIAL=1
fi

NUCLEOS_PARA_VMS=$(( TOTAL_CORES - RESERVA_INICIAL ))

if (( NUCLEOS_PARA_VMS < 1 )); then
  echo "Número insuficiente de núcleos para alocar às VMs após reserva do sistema."
  exit 3
fi

NUCLEOS_POR_VM_FLOAT=$(echo "scale=2; $NUCLEOS_PARA_VMS / $QTD_VMS" | bc -l)
NUCLEOS_POR_VM_INT=$(printf "%.0f" "$NUCLEOS_POR_VM_FLOAT")
NUCLEOS_USADOS_VM=$(( NUCLEOS_POR_VM_INT * QTD_VMS ))
RESERVA_FINAL=$(( TOTAL_CORES - NUCLEOS_USADOS_VM ))
if [[ "$RESERVA_FINAL" -lt 1 ]]; then
  RESERVA_FINAL=1
fi

echo ""
echo "Total de núcleos físicos detectados: $TOTAL_CORES"
echo "Reserva inicial para guest OS e hypervisor (10% ou 1 mínimo): $RESERVA_INICIAL"
echo "Núcleos restantes para uso das VMs (flutuante): $NUCLEOS_PARA_VMS"
echo "Núcleos por VM (arredondado): $NUCLEOS_POR_VM_INT"
echo "Núcleos usados pelas VMs: $NUCLEOS_USADOS_VM"
echo "Reserva final para guest OS e hypervisor (ajustada com arredondamento): $RESERVA_FINAL"
