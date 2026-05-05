#!/bin/bash
# setup-vbox.sh — разворачивает OpenWRT 23.05.6 в VirtualBox для тестирования splitvpn.
# Запускается на macOS/Linux хосте, где установлен VirtualBox + VBoxManage.
#
# Что создаёт:
#   - VM "openwrt-gw" с двумя NIC: nic1=intnet 'splitlan' (LAN), nic2=NAT (WAN)
#   - LAN: 192.168.1.1 (дефолт OpenWRT)
#   - WAN: DHCP от VirtualBox NAT (10.0.x.x)
#
# После запуска зайти в LAN-сеть с тест-клиента (vbox VM в той же intnet).

set -euo pipefail

VM_NAME="${VM_NAME:-openwrt-gw}"
OWRT_VERSION="${OWRT_VERSION:-23.05.6}"
WORKDIR="${WORKDIR:-$HOME/splitvpn-vbox}"
INTNET="${INTNET:-splitlan}"

IMG_URL="https://downloads.openwrt.org/releases/${OWRT_VERSION}/targets/x86/64/openwrt-${OWRT_VERSION}-x86-64-generic-ext4-combined.img.gz"
IMG_GZ="$WORKDIR/openwrt-${OWRT_VERSION}.img.gz"
IMG_RAW="$WORKDIR/openwrt-${OWRT_VERSION}.img"
VDI="$WORKDIR/${VM_NAME}.vdi"

log() { echo "[setup-vbox] $*"; }
err() { echo "[setup-vbox] ERROR: $*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || err "не найдена утилита: $1"; }

require VBoxManage
require gunzip

# curl на macOS всегда есть, wget — нет; используем что найдём
if command -v curl >/dev/null 2>&1; then
	DOWNLOADER="curl -L -o"
elif command -v wget >/dev/null 2>&1; then
	DOWNLOADER="wget -O"
else
	err "нужен curl или wget"
fi

mkdir -p "$WORKDIR"

# 1. Скачать образ
if [ ! -f "$IMG_RAW" ]; then
	if [ ! -f "$IMG_GZ" ]; then
		log "Скачиваю $IMG_URL"
		$DOWNLOADER "$IMG_GZ" "$IMG_URL"
	fi
	log "Распаковываю $IMG_GZ"
	gunzip -k "$IMG_GZ"
fi

# 2. Конвертировать в VDI
if [ ! -f "$VDI" ]; then
	log "Конвертирую в VDI: $VDI"
	VBoxManage convertfromraw --format VDI "$IMG_RAW" "$VDI"
	log "Расширяю до 256 MB"
	VBoxManage modifymedium disk "$VDI" --resize 256
fi

# 3. Удалить старую VM, если есть
if VBoxManage list vms | grep -q "\"$VM_NAME\""; then
	log "Удаляю старую VM $VM_NAME"
	VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
	sleep 1
	VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
fi

# 4. Создать VM
log "Создаю VM $VM_NAME"
VBoxManage createvm --name "$VM_NAME" --ostype Linux26_64 --register
VBoxManage modifyvm "$VM_NAME" --memory 256 --cpus 1 --boot1 disk

# Storage
VBoxManage storagectl "$VM_NAME" --name "SATA" --add sata --controller IntelAhci
VBoxManage storageattach "$VM_NAME" --storagectl "SATA" --port 0 \
	--type hdd --medium "$VDI"

# Network: nic1 = LAN (intnet), nic2 = WAN (NAT)
# OpenWRT x86-64-generic по дефолту: eth0=lan, eth1=wan
VBoxManage modifyvm "$VM_NAME" --nic1 intnet --intnet1 "$INTNET" --nictype1 virtio
VBoxManage modifyvm "$VM_NAME" --nic2 nat --nictype2 virtio

# Console serial для headless
VBoxManage modifyvm "$VM_NAME" --uart1 0x3F8 4 --uartmode1 file "$WORKDIR/${VM_NAME}.console.log"

log "Готово. Запуск:"
echo "    VBoxManage startvm $VM_NAME --type gui      # с окном"
echo "    VBoxManage startvm $VM_NAME --type headless # без окна (логи в $WORKDIR/${VM_NAME}.console.log)"
echo
log "После старта (~30s) открой LAN VM в той же intnet '$INTNET' и:"
echo "    ssh root@192.168.1.1   # пароль не задан, root-only при первом входе"
echo
log "Установка splitvpn:"
echo "    wget -O- https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/openwrt/install.sh | sh"
