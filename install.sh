#!/usr/bin/env bash
# install.sh — Distro-agnostic iPXE/TFTP installer & menu builder
# Repo intent: github.com/scriptmgr (you can drop this file in that repo)
#
# Features
# - No DHCP. Provides TFTP + HTTP only. Works with any external DHCP (dnsmasq/ISC/Windows).
# - BIOS & UEFI iPXE chainloading: undionly.kpxe (BIOS), ipxe.efi/snponly.efi (UEFI)
# - Menu layout: Linux, Windows, BSD, Tools, iPXE, Local boot (default = HD)
# - Auto-build submenus from /mnt/ISOs (subdirs become submenus; BIOS ISO boot via memdisk)
# - wimboot for Windows PE/Installer boot
# - memdisk (Syslinux) for ISO & floppy/IMG tools (BIOS-only)
# - Supports hosting for Debian/AlmaLinux/Alpine/Arch netboot images
# - Creates systemd units for TFTP and a tiny HTTP server (nginx if available, else python http.server)
# - Rootless-friendly file layout where possible; service install requires root
#
# WARNING: This script configures network services (TFTP+HTTP). Run as root.
set -Eeuo pipefail

SCRIPT_NAME="install.sh"
PREFIX_DIR="/srv/tftp"              # TFTP root (commonly /srv/tftp or /var/lib/tftpboot)
HTTP_ROOT="/srv/www/ipxe"          # HTTP root for iPXE payloads
STATE_DIR="/var/lib/ipxe-installer" # State/cache downloads
MGR_DIR="${PREFIX_DIR}/mgr/pxe"     # Requested path
IPXE_DIR="${PREFIX_DIR}/ipxe"
SYS_DIR="${PREFIX_DIR}/syslinux"
EFI_DIR="${PREFIX_DIR}/efi"
MENU_DIR="${HTTP_ROOT}/menus"
ISO_SCAN_DIR="/mnt/ISOs"
HOST_IP=""                          # try to auto-detect later
HTTP_PORT="8080"                    # non-privileged default (nginx will use 80 if installed)
TFTP_SERVICE_NAME="tftpd-ipxe"
HTTP_SERVICE_NAME="ipxe-httpd"

# Versions/URLs
IPXE_BIN_URL_BASE="https://boot.ipxe.org"
WIMBOOT_URL="https://ipxe.org/wimboot"           # redirects to latest
SYSLINUX_PKGS=(syslinux syslinux-common)
MEMTEST_URL="https://www.memtest.org/download/5.31b/memtest86+-5.31b.bin.gz" # example tool

# Detect package manager
pm=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then pm=apt-get
  elif command -v dnf >/dev/null 2>&1; then pm=dnf
  elif command -v yum >/dev/null 2>&1; then pm=yum
  elif command -v zypper >/dev/null 2>&1; then pm=zypper
  elif command -v pacman >/dev/null 2>&1; then pm=pacman
  elif command -v apk >/dev/null 2>&1; then pm=apk
  else
    echo "[FATAL] Unsupported distro: no known package manager found." >&2
    exit 1
  fi
}

install_pkgs() {
  echo "[INFO] Installing required packages using $pm"
  local pkgs=(curl wget tar gzip xz unzip coreutils findutils sed awk grep gawk psmisc)
  local tftp_pkgs=()
  local http_pkgs=()

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      tftp_pkgs=(tftpd-hpa syslinux-common pxelinux syslinux) # pxelinux.0 & modules
      http_pkgs=(nginx python3)
      apt-get update -y
      apt-get install -y ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
    dnf)
      tftp_pkgs=(tftp-server syslinux)
      http_pkgs=(nginx python3)
      dnf -y install ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
    yum)
      tftp_pkgs=(tftp-server syslinux)
      http_pkgs=(nginx python3)
      yum -y install ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
    zypper)
      tftp_pkgs=(tftpd syslinux)
      http_pkgs=(nginx python3)
      zypper --non-interactive install ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
    pacman)
      tftp_pkgs=(tftp-hpa syslinux)
      http_pkgs=(nginx python)
      pacman --noconfirm -Sy ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
    apk)
      tftp_pkgs=(tftp-hpa syslinux)
      http_pkgs=(nginx python3)
      apk add --no-cache ${pkgs[*]} ${tftp_pkgs[*]} ${http_pkgs[*]}
      ;;
  esac
}

ensure_dirs() {
  install -d -m 0755 "$PREFIX_DIR" "$HTTP_ROOT" "$STATE_DIR" "$MGR_DIR" "$IPXE_DIR" "$SYS_DIR" "$EFI_DIR" "$MENU_DIR"
}

auto_detect_host_ip() {
  if [[ -n "${HOST_IP}" ]]; then return; fi
  # Prefer default route interface
  if command -v ip >/dev/null 2>&1; then
    HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
  fi
  if [[ -z "${HOST_IP}" ]]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "${HOST_IP}" ]]; then
    HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "${HOST_IP}" ]]; then
    echo "[WARN] Could not auto-detect host IP. You may need to edit menus later." >&2
    HOST_IP="127.0.0.1"
  fi
  echo "[INFO] Using host IP: ${HOST_IP}"
}

fetch() { # fetch <url> <dest>
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

fetch_ipxe_bins() {
  echo "[INFO] Fetching iPXE chainloaders"
  ( cd "$IPXE_DIR" && {
      fetch "${IPXE_BIN_URL_BASE}/undionly.kpxe" undionly.kpxe || true
      fetch "${IPXE_BIN_URL_BASE}/ipxe.efi" ipxe.efi || true
      fetch "${IPXE_BIN_URL_BASE}/snponly.efi" snponly.efi || true
      fetch "${IPXE_BIN_URL_BASE}/snp.efi" snp.efi || true
    })
}

fetch_wimboot() {
  echo "[INFO] Fetching wimboot"
  fetch "$WIMBOOT_URL" "$IPXE_DIR/wimboot"
}

link_syslinux_assets() {
  echo "[INFO] Linking Syslinux assets (memdisk, pxelinux, modules)"
  # Try to find where distros installed them
  local paths=(
    /usr/lib/syslinux /usr/share/syslinux /usr/lib/PXELINUX /usr/lib/syslinux/modules/bios
  )
  local found=0
  for p in "${paths[@]}"; do
    if [[ -f "$p/memdisk" ]] || [[ -f "$p/bios/memdisk" ]]; then
      found=1
      break
    fi
  done
  if (( found )); then
    # Create copies to SYS_DIR for TFTP serving
    for f in memdisk pxelinux.0 lpxelinux.0 ldlinux.c32 libutil.c32 libcom32.c32 menu.c32 vesamenu.c32; do
      local src=""
      for p in "${paths[@]}"; do
        if [[ -f "$p/$f" ]]; then src="$p/$f"; break; fi
        if [[ -f "$p/bios/$f" ]]; then src="$p/bios/$f"; break; fi
        if [[ -f "$p/modules/bios/$f" ]]; then src="$p/modules/bios/$f"; break; fi
      done
      if [[ -n "$src" ]]; then
        install -m 0644 "$src" "$SYS_DIR/$f"
      fi
    done
  else
    echo "[WARN] Could not locate Syslinux binaries; memdisk/pxelinux may be unavailable." >&2
  fi
}

seed_http_tree() {
  echo "[INFO] Seeding HTTP content tree"
  install -d -m 0755 "$HTTP_ROOT/{linux,windows,bsd,tools,ipxe}"
  install -d -m 0755 "$HTTP_ROOT/windows/winpe"
  # sample placeholder
  cat >"$HTTP_ROOT/README.txt" <<'EOF'
Place your kernel/initrd, WinPE files, and tools under this tree. The iPXE menus are generated under menus/.
EOF
}

make_ipxe_entry_localboot() {
  cat <<'EOF'
:localboot
  echo Booting from first hard disk...
  sanboot --no-describe --drive 0x80 || exit 0
  boot || exit 0
EOF
}

# Generate iPXE main menu and submenus
build_ipxe_menus() {
  echo "[INFO] Building iPXE menus in $MENU_DIR"
  local main="$MENU_DIR/boot.ipxe"
  local linux_menu="$MENU_DIR/linux.ipxe"
  local win_menu="$MENU_DIR/windows.ipxe"
  local bsd_menu="$MENU_DIR/bsd.ipxe"
  local tools_menu="$MENU_DIR/tools.ipxe"
  local raw_menu="$MENU_DIR/ipxe.ipxe"

  # Main menu
  cat >"$main" <<EOF
#!ipxe
set menu-timeout 80000
set submenu-timeout 80000
set menu-default localboot

:main
menu ScriptMgr iPXE Boot Menu (${HOST_IP})
item --gap -- -------------------- Linux --------------------
item linux     Linux distributions
item windows   Windows (wimboot/WinPE/Installers)
item bsd       BSD
item tools     Tools (memdisk, memtest, utilities)
item ipxe      iPXE scripts/examples
item --gap -- ------------------ System ---------------------
item localboot Boot from local disk (default)
item reboot    Reboot
item shutdown  Power off
choose --default localboot --timeout \${menu-timeout} selected || goto cancel
goto \${selected}

:linux
chain http://${HOST_IP}:${HTTP_PORT}/menus/linux.ipxe || goto failed

:windows
chain http://${HOST_IP}:${HTTP_PORT}/menus/windows.ipxe || goto failed

:bsd
chain http://${HOST_IP}:${HTTP_PORT}/menus/bsd.ipxe || goto failed

:tools
chain http://${HOST_IP}:${HTTP_PORT}/menus/tools.ipxe || goto failed

:ipxe
chain http://${HOST_IP}:${HTTP_PORT}/menus/ipxe.ipxe || goto failed

:reboot
reboot

:shutdown
poweroff

:cancel
clear menu-timeout
clear submenu-timeout
prompt

:failed
echo Boot failed, returning to menu...
sleep 2
goto main

$(make_ipxe_entry_localboot)
EOF

  # Linux submenu with common distros (HTTP paths expected)
  cat >"$linux_menu" <<EOF
#!ipxe
:linux_menu
menu Linux Distributions
item debian    Debian Netboot
item alma      AlmaLinux Netboot
item alpine    Alpine Linux Netboot
item arch      Arch Linux Netboot
item isos      ISO Submenus (from ${ISO_SCAN_DIR})
item back      Back
choose selected || goto back
goto \${selected}

:debian
kernel http://${HOST_IP}:${HTTP_PORT}/linux/debian/vmlinuz
initrd http://${HOST_IP}:${HTTP_PORT}/linux/debian/initrd.gz
imgargs vmlinuz ip=dhcp url=http://${HOST_IP}:${HTTP_PORT}/linux/debian/preseed.cfg auto=true priority=critical
boot || goto linux_menu

:alma
kernel http://${HOST_IP}:${HTTP_PORT}/linux/alma/vmlinuz
initrd http://${HOST_IP}:${HTTP_PORT}/linux/alma/initrd.img
imgargs vmlinuz inst.stage2=http://${HOST_IP}:${HTTP_PORT}/linux/alma/ inst.ks=http://${HOST_IP}:${HTTP_PORT}/linux/alma/ks.cfg ip=dhcp
boot || goto linux_menu

:alpine
kernel http://${HOST_IP}:${HTTP_PORT}/linux/alpine/vmlinuz-lts
initrd http://${HOST_IP}:${HTTP_PORT}/linux/alpine/initramfs-lts
imgargs vmlinuz-lts modloop=http://${HOST_IP}:${HTTP_PORT}/linux/alpine/modloop-lts alpine_repo=http://${HOST_IP}:${HTTP_PORT}/linux/alpine/repo ip=dhcp
boot || goto linux_menu

:arch
kernel http://${HOST_IP}:${HTTP_PORT}/linux/arch/vmlinuz-linux
initrd http://${HOST_IP}:${HTTP_PORT}/linux/arch/initramfs-linux.img
imgargs vmlinuz-linux archiso_http_srv=http://${HOST_IP}:${HTTP_PORT}/linux/arch ip=dhcp
boot || goto linux_menu

:isos
chain http://${HOST_IP}:${HTTP_PORT}/menus/iso-auto.ipxe || goto linux_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # Windows submenu (wimboot)
  cat >"$win_menu" <<EOF
#!ipxe
:win_menu
menu Windows Boot via wimboot
item winpe     WinPE (place files under /windows/winpe)
item back      Back
choose selected || goto back
goto \${selected}

:winpe
set wimpath http://${HOST_IP}:${HTTP_PORT}/windows/winpe
kernel ${IPXE_DIR_URL:-tftp://${HOST_IP}/ipxe}/wimboot
initrd \${wimpath}/bootmgr         bootmgr
initrd \${wimpath}/BCD             BCD
initrd \${wimpath}/boot.sdi        boot.sdi
initrd \${wimpath}/boot.wim        boot.wim
boot || goto win_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # BSD submenu (placeholders)
  cat >"$bsd_menu" <<EOF
#!ipxe
:bsd_menu
menu BSD
item freebsd   FreeBSD Installer
item back      Back
choose selected || goto back
goto \${selected}

:freebsd
kernel http://${HOST_IP}:${HTTP_PORT}/bsd/freebsd/boot/kernel/kernel
initrd http://${HOST_IP}:${HTTP_PORT}/bsd/freebsd/boot/mfsroot.gz mfsroot.gz
imgargs kernel -S115200
boot || goto bsd_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # Tools submenu (memdisk, memtest, etc.)
  cat >"$tools_menu" <<EOF
#!ipxe
:tools_menu
menu Tools
item memtest86 Memtest86+
item hdboot    Boot from local disk
item back      Back
choose selected || goto back
goto \${selected}

:memtest86
kernel ${SYS_DIR_URL:-tftp://${HOST_IP}/syslinux}/memdisk
initrd http://${HOST_IP}:${HTTP_PORT}/tools/memtest86+.bin.gz
imgargs memdisk iso raw
boot || goto tools_menu

:hdboot
goto localboot

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # Raw iPXE (for advanced users)
  cat >"$raw_menu" <<'EOF'
#!ipxe
:ipxe_menu
menu iPXE Snippets
item shell   iPXE shell
item back    Back
choose selected || goto back

:shell
shell

:back
chain ${base-url}/menus/boot.ipxe
EOF

  # Auto ISO submenu (BIOS via memdisk)
  build_iso_auto_menu
}

build_iso_auto_menu() {
  local iso_menu="$MENU_DIR/iso-auto.ipxe"
  echo "[INFO] Scanning ISOs under ${ISO_SCAN_DIR} for auto menu"
  cat >"$iso_menu" <<EOF
#!ipxe
:iso_auto
menu ISO Auto-Discovery (BIOS only via memdisk)
item back Back
EOF

  local count=0
  if [[ -d "$ISO_SCAN_DIR" ]]; then
    while IFS= read -r -d '' iso; do
      local rel="${iso#${ISO_SCAN_DIR}/}"
      local key="iso$((++count))"
      echo "item ${key} ${rel}" >>"$iso_menu"
    done < <(find "$ISO_SCAN_DIR" -type f -iname '*.iso' -print0 | sort -z)
  fi

  cat >>"$iso_menu" <<'EOF'
choose selected || goto back
set selected
iseq ${selected} back && goto back || goto ${selected}
EOF

  count=0
  if [[ -d "$ISO_SCAN_DIR" ]]; then
    while IFS= read -r -d '' iso; do
      count=$((count+1))
      local key="iso${count}"
      local rel="${iso#${ISO_SCAN_DIR}/}"
      local urlpath="${rel// /%20}"
      cat >>"$iso_menu" <<EOF
:${key}
# BIOS-only ISO boot through memdisk (UEFI not supported)
kernel ${SYS_DIR_URL:-tftp://${HOST_IP}/syslinux}/memdisk
initrd http://${HOST_IP}:${HTTP_PORT}/isos/${urlpath}
imgargs memdisk iso raw
boot || goto iso_auto
EOF
    done < <(find "$ISO_SCAN_DIR" -type f -iname '*.iso' -print0 | sort -z)
  fi

  cat >>"$iso_menu" <<EOF
:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/linux.ipxe
EOF
}

# Setup TFTP via systemd socket-activated tftp-hpa where available
setup_tftp() {
  echo "[INFO] Configuring TFTP service (tftpd-hpa or in.tftpd via systemd)"
  local unit_dir="/etc/systemd/system"
  install -d "$unit_dir"

  cat >"$unit_dir/${TFTP_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TFTP server for iPXE (no DHCP)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/in.tftpd -s ${PREFIX_DIR} -4 --secure --create --permissive
Restart=on-failure
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  systemctl enable --now "${TFTP_SERVICE_NAME}.service" || true
}

# Setup HTTP: prefer nginx on :80; fallback to python http.server :8080
setup_http() {
  if command -v nginx >/dev/null 2>&1; then
    echo "[INFO] Configuring nginx to serve ${HTTP_ROOT} on :80"
    local conf="/etc/nginx/conf.d/ipxe.conf"
    cat >"$conf" <<EOF
server {
    listen 80 default_server;
    server_name _;
    root ${HTTP_ROOT};
    autoindex on;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    systemctl enable --now nginx || true
    HTTP_PORT="80"
  else
    echo "[INFO] Using Python http.server on :${HTTP_PORT}"
    local unit_dir="/etc/systemd/system"
    cat >"$unit_dir/${HTTP_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Minimal HTTP server for iPXE payloads
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${HTTP_ROOT}
ExecStart=/usr/bin/python3 -m http.server ${HTTP_PORT}
Restart=on-failure
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable --now "${HTTP_SERVICE_NAME}.service" || true
  fi
}

symlink_convenience() {
  # TFTP paths expected
  ln -sf "$IPXE_DIR" "$PREFIX_DIR/ipxe"
  ln -sf "$SYS_DIR" "$PREFIX_DIR/syslinux"
  # pxelinux legacy (optional)
  if [[ -f "$SYS_DIR/pxelinux.0" ]]; then
    ln -sf "$SYS_DIR/pxelinux.0" "$PREFIX_DIR/pxelinux.0"
  fi
}

copy_menu_to_tftp() {
  # Provide a default iPXE entry point over TFTP as /ipxe/boot.ipxe
  install -d -m 0755 "$IPXE_DIR"
  cp -f "$MENU_DIR/boot.ipxe" "$IPXE_DIR/boot.ipxe"
}

place_sample_linux_payloads() {
  # Create lightweight placeholders to guide users
  install -d -m 0755 "$HTTP_ROOT/linux/debian" "$HTTP_ROOT/linux/alma" "$HTTP_ROOT/linux/alpine" "$HTTP_ROOT/linux/arch"
  touch "$HTTP_ROOT/linux/debian/{vmlinuz,initrd.gz,preseed.cfg}" || true
  touch "$HTTP_ROOT/linux/alma/{vmlinuz,initrd.img,ks.cfg}" || true
  touch "$HTTP_ROOT/linux/alpine/{vmlinuz-lts,initramfs-lts,modloop-lts}" || true
  touch "$HTTP_ROOT/linux/arch/{vmlinuz-linux,initramfs-linux.img}" || true
}

place_sample_tools() {
  install -d -m 0755 "$HTTP_ROOT/tools"
  # Attempt to fetch memtest (optional)
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    echo "[INFO] Fetching memtest86+ (optional)"
    fetch "$MEMTEST_URL" "$HTTP_ROOT/tools/memtest86+.bin.gz" || true
  fi
}

print_dhcp_hints() {
  cat <<EOF

============================================================
PXE/IPXE SERVER READY (NO DHCP CONFIGURED)
============================================================
Point your existing DHCP to this server:
  next-server ${HOST_IP};
  filename "ipxe/undionly.kpxe";     # for BIOS clients
  # UEFI x86_64:
  filename "ipxe/ipxe.efi";          # or snponly.efi depending on NIC firmware

iPXE HTTP entrypoints:
  http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe

TFTP root: ${PREFIX_DIR}
HTTP root: ${HTTP_ROOT}

Auto-ISO menu: will include any *.iso found under ${ISO_SCAN_DIR}
  Served under: http://${HOST_IP}:${HTTP_PORT}/isos/...
  NOTE: ISO boot via memdisk works for BIOS clients only.

Windows (wimboot): Place WinPE/Installer files here:
  ${HTTP_ROOT}/windows/winpe/{bootmgr,BCD,boot.sdi,boot.wim}

Services:
  TFTP:   systemctl status ${TFTP_SERVICE_NAME}
  HTTP:   nginx (if installed) OR systemctl status ${HTTP_SERVICE_NAME}

Files of interest:
  TFTP iPXE loaders: ${IPXE_DIR}/undionly.kpxe, ${IPXE_DIR}/ipxe.efi, ${IPXE_DIR}/snponly.efi
  Syslinux/memdisk:  ${SYS_DIR}/memdisk, ${SYS_DIR}/pxelinux.0 (optional)
  Menus:             ${MENU_DIR}/boot.ipxe (main) and submenus
============================================================
EOF
}

expose_isos_via_http() {
  # Bind /mnt/ISOs into HTTP as /isos using a symlink (must be within docroot)
  if [[ -d "$ISO_SCAN_DIR" ]]; then
    install -d -m 0755 "$HTTP_ROOT/isos"
    if [[ ! -L "$HTTP_ROOT/isos" ]]; then
      rm -rf "$HTTP_ROOT/isos" || true
      ln -s "$ISO_SCAN_DIR" "$HTTP_ROOT/isos"
    fi
  fi
}

main() {
  [[ $EUID -eq 0 ]] || { echo "[FATAL] Please run as root." >&2; exit 1; }

  detect_pm
  install_pkgs
  ensure_dirs
  auto_detect_host_ip
  fetch_ipxe_bins
  fetch_wimboot
  link_syslinux_assets
  seed_http_tree
  place_sample_linux_payloads
  place_sample_tools
  expose_isos_via_http
  build_ipxe_menus
  copy_menu_to_tftp
  setup_tftp
  setup_http
  symlink_convenience
  print_dhcp_hints
}

main "$@"
