#!/bin/sh
# install.sh — установщик splitvpn-gateway-openwrt.
# Запуск:  wget -O- https://github.com/russakilya-web/splitvpn-gateway/raw/master/openwrt/install.sh | sh
# Или:     scp install.sh root@192.168.1.1:/tmp/ && ssh root@192.168.1.1 sh /tmp/install.sh

set -e

REPO_RAW="https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/openwrt"
AWG_RELEASES="https://github.com/Slava-Shchipunov/awg-openwrt/releases"
# Тег в awg-openwrt совпадает с версией OpenWRT (v23.05.6, v23.05.5 и т.д.)
# Реальное значение определяется в install_amneziawg() по DISTRIB_RELEASE.

log()  { echo "[install] $*"; }
err()  { echo "[install] ERROR: $*" >&2; exit 1; }

require() {
	command -v "$1" >/dev/null 2>&1 || err "не найдена утилита: $1"
}

check_openwrt() {
	[ -f /etc/openwrt_release ] || err "это не OpenWRT"
	. /etc/openwrt_release
	log "OpenWRT $DISTRIB_RELEASE / $DISTRIB_TARGET"
	# 23.05.x целевой; 22.03 и 24.10 тоже возможны
	case "$DISTRIB_RELEASE" in
		23.05.*) ;;
		22.03.*) log "WARN: 22.03 не тестировался, но fw4 уже дефолт — пробуем" ;;
		24.10.*) err "24.10 использует apk, нужен другой релиз awg-openwrt — см. https://github.com/Slava-Shchipunov/awg-openwrt/releases" ;;
		25.*)    err "25.x ещё не поддерживается этим установщиком" ;;
		*)       log "WARN: непротестированная версия $DISTRIB_RELEASE — продолжаем" ;;
	esac
}

# Определить target/subtarget для имени .ipk
detect_target() {
	. /etc/openwrt_release
	# DISTRIB_TARGET=x86/64 → target=x86, subtarget=64
	target="${DISTRIB_TARGET%/*}"
	subtarget="${DISTRIB_TARGET#*/}"
	# DISTRIB_ARCH=x86_64
	arch="${DISTRIB_ARCH:-x86_64}"
	echo "${target}_${subtarget}_${arch}"
}

install_packages() {
	log "Обновляю opkg..."
	opkg update >/dev/null 2>&1 || err "opkg update провалился — проверь интернет на роутере"

	log "Ставлю системные пакеты (dnsmasq-full, kmod-nft-nat, ip-full, kmod-tun)..."
	# dnsmasq-full нужен для nftset поддержки (обычный dnsmasq не умеет)
	# kmod-nft-nat для nat-правил, ip-full для policy routing с tables
	# Удаляем стандартный dnsmasq и ставим dnsmasq-full
	if opkg list-installed | grep -q '^dnsmasq '; then
		opkg remove dnsmasq >/dev/null 2>&1 || true
	fi
	opkg install dnsmasq-full ip-full kmod-nft-nat 2>&1 | grep -vE '^(Configuring|Installing) ' || true

	# AmneziaWG: kmod + tools из релиза awg-openwrt
	if ! opkg list-installed | grep -q '^kmod-amneziawg'; then
		install_amneziawg
	else
		log "kmod-amneziawg уже установлен — пропускаю"
	fi
}

install_amneziawg() {
	. /etc/openwrt_release
	# Тег awg-openwrt = v + версия OpenWRT (например, v23.05.6)
	awg_tag="v${DISTRIB_RELEASE}"
	pkg_target="$(detect_target)"
	log "Скачиваю kmod-amneziawg + amneziawg-tools для ${pkg_target} (тег ${awg_tag})..."

	# Прямые URL по шаблону: <release>/download/<tag>/<pkg>_<tag>_<target>.ipk
	cd /tmp
	for pkg in kmod-amneziawg amneziawg-tools; do
		fname="${pkg}_${awg_tag}_${pkg_target}.ipk"
		url="${AWG_RELEASES}/download/${awg_tag}/${fname}"
		log "  → ${fname}"
		rm -f "$fname"
		# wget-ssl или uclient-fetch — оба умеют redirect; --max-redirect для подстраховки
		if ! wget -q "$url" -O "$fname" 2>/dev/null; then
			rm -f "$fname"
			err "Не удалось скачать ${url}. Возможно, тег/архитектура не существуют — проверь ${AWG_RELEASES}"
		fi
		# Проверка что скачался реальный .ipk, а не HTML-страница 404
		if [ ! -s "$fname" ] || head -c 4 "$fname" | grep -q '<'; then
			rm -f "$fname"
			err "Файл ${fname} пустой или HTML (вероятно 404). Проверь ${AWG_RELEASES}/${awg_tag}"
		fi
	done

	log "Устанавливаю .ipk..."
	opkg install /tmp/kmod-amneziawg*.ipk /tmp/amneziawg-tools*.ipk \
		|| err "opkg install провалился — см. вывод выше"
}

install_files() {
	log "Скачиваю конфиги и скрипты splitvpn..."
	for path in \
		etc/config/vpn-split \
		etc/init.d/amneziawg \
		etc/init.d/vpn-split \
		etc/uci-defaults/99-vpn-split \
		usr/sbin/vpn-split-enforce \
		usr/sbin/splitvpn
	do
		dest="/$path"
		mkdir -p "$(dirname "$dest")"
		log "  → $dest"
		wget -q "${REPO_RAW}/files/${path}" -O "$dest" \
			|| err "не удалось скачать ${path}"
	done

	chmod 755 \
		/etc/init.d/amneziawg \
		/etc/init.d/vpn-split \
		/etc/uci-defaults/99-vpn-split \
		/usr/sbin/vpn-split-enforce \
		/usr/sbin/splitvpn
}

setup_awg_config() {
	mkdir -p /etc/amnezia/amneziawg
	if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
		log "Конфиг /etc/amnezia/amneziawg/awg0.conf уже есть — пропускаю"
		return 0
	fi

	if [ ! -t 0 ] && [ -e /dev/tty ]; then
		exec < /dev/tty
	fi

	echo
	echo "=== AmneziaWG-конфиг ==="
	echo "Где взять awg0.conf?"
	echo "  1) Указать путь к .conf на роутере (например, /tmp/awg0.conf — заранее scp'нутый)"
	echo "  2) Вставить содержимое .conf вручную (paste, потом Ctrl-D)"
	echo "  3) Пропустить (поставлю позже руками в /etc/amnezia/amneziawg/awg0.conf)"
	printf "Выбор [1]: "
	read choice
	choice="${choice:-1}"

	case "$choice" in
		1)
			printf "  Путь к .conf: "
			read path
			[ -f "$path" ] || err "файл не найден: $path"
			install -m 600 "$path" /etc/amnezia/amneziawg/awg0.conf
			;;
		2)
			echo "Вставляй содержимое (Ctrl-D в конце):"
			cat > /etc/amnezia/amneziawg/awg0.conf
			chmod 600 /etc/amnezia/amneziawg/awg0.conf
			[ -s /etc/amnezia/amneziawg/awg0.conf ] || err "пустой ввод"
			;;
		3)
			log "Пропускаю — потом положи .conf в /etc/amnezia/amneziawg/awg0.conf и запусти: /etc/init.d/amneziawg start"
			return 0
			;;
		*)  err "неверный выбор" ;;
	esac

	# Минимальная валидация
	grep -q '^\[Interface\]' /etc/amnezia/amneziawg/awg0.conf || err "в конфиге нет [Interface]"
	grep -q '^\[Peer\]'      /etc/amnezia/amneziawg/awg0.conf || err "в конфиге нет [Peer]"
	log "Конфиг сохранён: /etc/amnezia/amneziawg/awg0.conf"
}

bootstrap() {
	# uci-defaults уже на месте, но при установке через wget OpenWRT не запустит его автоматически.
	# Если файл всё ещё там — выполняем вручную.
	if [ -x /etc/uci-defaults/99-vpn-split ]; then
		log "Запускаю uci-defaults..."
		sh /etc/uci-defaults/99-vpn-split && rm -f /etc/uci-defaults/99-vpn-split
	fi

	log "Стартую сервисы..."
	/etc/init.d/amneziawg start 2>/dev/null || log "WARN: amneziawg не стартовал (нет конфига?)"
	sleep 2
	/etc/init.d/vpn-split   start 2>/dev/null || log "WARN: vpn-split не стартовал"
}

ensure_wget_ssl() {
	# Проверяем что wget умеет https. Базовый busybox/uclient-fetch на свежем
	# образе OpenWRT 23.05 х86_64 не умеет — выдаёт invalid option на простых
	# флагах. Ставим wget-ssl сразу, чтобы дальше всё работало стабильно.
	if wget --version 2>&1 | grep -qi 'gnu wget\|wget'; then
		return 0
	fi
	if opkg list-installed 2>/dev/null | grep -q '^wget-ssl '; then
		return 0
	fi
	log "Ставлю wget-ssl (нужен для https-скачивания .ipk)..."
	opkg update >/dev/null 2>&1 || err "opkg update провалился — проверь интернет"
	opkg install wget-ssl >/dev/null 2>&1 || err "не удалось поставить wget-ssl"
}

main() {
	[ "$(id -u)" -eq 0 ] || err "запусти от root"
	require opkg
	check_openwrt
	ensure_wget_ssl
	require wget
	install_packages
	install_files
	setup_awg_config
	bootstrap

	echo
	log "=== Установка завершена ==="
	log "Управление: splitvpn status | splitvpn domain add <host>"
	log "Логи:       logread -e vpn-split"
	log "AmneziaWG:  awg show"
}

main "$@"
