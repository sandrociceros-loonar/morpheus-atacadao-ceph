#!/bin/bash

echo "🚀 Setup iSCSI Mínimo"
echo ""

DEFAULT_TGT_IP="192.168.0.250"

echo "Opções:"
echo "1) Usar IP padrão: $DEFAULT_TGT_IP"
echo "2) Informar IP personalizado"
echo ""

echo -n "Escolha [1-2]: "
read choice

if [[ "$choice" == "2" ]]; then
    echo -n "Digite o IP: "
    read TARGET_IP
else
    TARGET_IP="$DEFAULT_TGT_IP"
fi

echo "Usando IP: $TARGET_IP"
echo ""

echo "🔍 Fazendo discovery..."
sudo iscsiadm -m discovery -t st -p "$TARGET_IP:3260"

echo ""
echo "✅ Discovery concluído!"
echo "Execute manualmente os próximos passos se necessário."
