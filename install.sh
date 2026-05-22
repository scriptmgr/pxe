#!/usr/bin/env bash
# install.sh — Distro-agnostic iPXE/TFTP installer & menu builder
# Repo: github.com/scriptmgr/pxe
#
# Features
# - No DHCP. Provides TFTP + HTTP only. Works with any external DHCP (dnsmasq/ISC/Windows).
# - BIOS & UEFI iPXE chainloading: undionly.kpxe (BIOS), ipxe.efi/snponly.efi (UEFI)
# - Auto-detects latest stable release for: Debian, Ubuntu LTS, Fedora, AlmaLinux, Alpine, Arch
# - Downloads real vmlinuz/initrd for each distro — no stale hardcoded versions
# - Menu layout: Linux, Windows, BSD, Tools, iPXE, Local boot — organized and version-labelled
# - Auto-build ISO submenus from /mnt/ISOs (memdisk BIOS boot)
# - wimboot for Windows PE/Installer
# - memdisk (Syslinux) for ISO & IMG tools (BIOS-only)
# - Systemd units for TFTP and HTTP (nginx preferred, python http.server fallback)
#
# WARNING: This script configures network services (TFTP+HTTP). Run as root.
set -Eeuo pipefail

# ─── Identity ─────────────────────────────────────────────────────────────────
SCRIPT_NAME="install.sh"
SCRIPT_VERSION="2.0.0"

# ─── Paths ────────────────────────────────────────────────────────────────────
PREFIX_DIR="/srv/tftp"
HTTP_ROOT="/srv/www/ipxe"
STATE_DIR="/var/lib/ipxe-installer"
MGR_DIR="${PREFIX_DIR}/mgr/pxe"
IPXE_DIR="${PREFIX_DIR}/ipxe"
SYS_DIR="${PREFIX_DIR}/syslinux"
EFI_DIR="${PREFIX_DIR}/efi"
MENU_DIR="${HTTP_ROOT}/menus"
ISO_SCAN_DIR="/mnt/ISOs"   # legacy / custom mount point (always checked)
ISO_HTTP_DIR="${HTTP_ROOT}/isos"  # served root — contains per-source subdirs

# ─── Network ──────────────────────────────────────────────────────────────────
HOST_IP=""
HTTP_PORT="8080"
TFTP_SERVICE_NAME="tftpd-ipxe"
HTTP_SERVICE_NAME="ipxe-httpd"

# ─── Upstream URLs ────────────────────────────────────────────────────────────
IPXE_BIN_URL_BASE="https://boot.ipxe.org"
WIMBOOT_URL="https://ipxe.org/wimboot"
MEMTEST_URL="https://www.memtest.org/download/5.31b/memtest86+-5.31b.bin.gz"

# ─── Distro version state (populated by __detect_versions) ──────────────────────
DEBIAN_CODENAME=""
DEBIAN_VERSION=""
UBUNTU_VERSION=""
UBUNTU_CODENAME=""
UBUNTU_FULL_VERSION=""
FEDORA_VERSION=""
ALMALINUX_VERSION=""

# ─── Logging ──────────────────────────────────────────────────────────────────
__log_info()  { printf '[INFO]  %s\n'  "$*";      }
__log_warn()  { printf '[WARN]  %s\n'  "$*" >&2;  }
__log_ok()    { printf '[OK]    %s\n'  "$*";      }
__log_fatal() { printf '[FATAL] %s\n'  "$*" >&2; exit 1; }
__log_sep()   { printf '\n── %s %s\n\n' "$1" "$(printf '%.0s─' {1..50})"; }

# ─── Package manager detection ────────────────────────────────────────────────
pm=""
__detect_pm() {
  if   \command -v apt-get >/dev/null 2>&1; then pm=apt-get
  elif \command -v dnf     >/dev/null 2>&1; then pm=dnf
  elif \command -v yum     >/dev/null 2>&1; then pm=yum
  elif \command -v zypper  >/dev/null 2>&1; then pm=zypper
  elif \command -v pacman  >/dev/null 2>&1; then pm=pacman
  elif \command -v apk     >/dev/null 2>&1; then pm=apk
  else __log_fatal "Unsupported distro: no known package manager found."
  fi
}

__install_pkgs() {
  __log_info "Installing required packages via ${pm}"
  local pkgs=(curl wget tar gzip xz unzip coreutils findutils sed gawk grep psmisc)
  local tftp_pkgs=() http_pkgs=()

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      tftp_pkgs=(tftpd-hpa syslinux-common pxelinux syslinux)
      http_pkgs=(nginx python3)
      \apt-get update -y
      \apt-get install -y "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
    dnf)
      tftp_pkgs=(tftp-server syslinux)
      http_pkgs=(nginx python3)
      \dnf -y install "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
    yum)
      tftp_pkgs=(tftp-server syslinux)
      http_pkgs=(nginx python3)
      \yum -y install "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
    zypper)
      tftp_pkgs=(tftpd syslinux)
      http_pkgs=(nginx python3)
      \zypper --non-interactive install "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
    pacman)
      tftp_pkgs=(tftp-hpa syslinux)
      http_pkgs=(nginx python)
      \pacman --noconfirm -Sy "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
    apk)
      tftp_pkgs=(tftp-hpa syslinux)
      http_pkgs=(nginx python3)
      \apk add --no-cache "${pkgs[@]}" "${tftp_pkgs[@]}" "${http_pkgs[@]}"
      ;;
  esac
}

# ─── Directory setup ──────────────────────────────────────────────────────────
__ensure_dirs() {
  \install -d -m 0755 \
    "$PREFIX_DIR" "$HTTP_ROOT" "$STATE_DIR" "$MGR_DIR" \
    "$IPXE_DIR"   "$SYS_DIR"   "$EFI_DIR"  "$MENU_DIR"
}

__auto_detect_host_ip() {
  [[ -n "${HOST_IP}" ]] && return
  if \command -v ip >/dev/null 2>&1; then
    HOST_IP=$(\ip -4 route get 1.1.1.1 2>/dev/null | \awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}' || true)
  fi
  [[ -z "${HOST_IP}" ]] && HOST_IP=$(\hostname -I 2>/dev/null | \awk '{print $1}' || true)
  [[ -z "${HOST_IP}" ]] && HOST_IP=$(\hostname -i 2>/dev/null | \awk '{print $1}' || true)
  if [[ -z "${HOST_IP}" ]]; then
    __log_warn "Could not auto-detect host IP. You may need to edit menus later."
    HOST_IP="127.0.0.1"
  fi
  __log_info "Host IP: ${HOST_IP}"
}

# ─── HTTP fetch helpers ───────────────────────────────────────────────────────
# __fetch <url> <dest>
__fetch() {
  local url="$1" dest="$2"
  \mkdir -p "$(dirname -- "$dest")"
  if \command -v curl >/dev/null 2>&1; then
    \curl -fsSL --max-time 120 "$url" -o "$dest"
  else
    \wget -qO "$dest" "$url"
  fi
}

# __fetch_or_warn <label> <url> <dest>
__fetch_or_warn() {
  local label="$1" url="$2" dest="$3"
  if __fetch "$url" "$dest"; then
    __log_ok "${label} downloaded"
    return 0
  else
    __log_warn "${label}: download failed (${url})"
    return 1
  fi
}

# ─── Version detection ────────────────────────────────────────────────────────
__detect_debian() {
  __log_info "Detecting latest Debian stable release"
  local rel
  rel=$(\curl -fsSL --max-time 15 "https://deb.debian.org/debian/dists/stable/Release" 2>/dev/null || true)
  DEBIAN_CODENAME=$(\printf '%s\n' "$rel" | \awk -F': ' '/^Codename:/{print $2; exit}')
  DEBIAN_VERSION=$(\printf '%s\n' "$rel" | \awk -F': ' '/^Version:/{print $2; exit}')
  if [[ -n "$DEBIAN_CODENAME" ]]; then
    __log_ok "Debian ${DEBIAN_CODENAME} (${DEBIAN_VERSION})"
  else
    __log_warn "Debian: version detection failed — will try with 'stable' symlink"
    DEBIAN_CODENAME="stable"
  fi
}

__detect_ubuntu() {
  __log_info "Detecting latest Ubuntu LTS release"
  local meta
  meta=$(\curl -fsSL --max-time 15 "https://changelogs.ubuntu.com/meta-release-lts" 2>/dev/null || true)
  [[ -z "$meta" ]] && { __log_warn "Ubuntu: version detection failed"; return; }

  UBUNTU_VERSION=$(\printf '%s\n' "$meta" | \awk '
    /^Version:/ { ver=$2 }
    /^Supported: 1/ { if (ver) latest=ver }
    END { print latest }
  ')

  # First word of "Name: Jammy Jellyfish" -> "jammy"
  UBUNTU_CODENAME=$(\printf '%s\n' "$meta" | \awk -v ver="$UBUNTU_VERSION" '
    /^Version:/ && $2==ver { found=1 }
    found && /^Name:/ { print tolower($2); found=0; exit }
  ')

  if [[ -n "$UBUNTU_VERSION" ]]; then
    __log_ok "Ubuntu ${UBUNTU_CODENAME} ${UBUNTU_VERSION} LTS"
  else
    __log_warn "Ubuntu: version detection failed"
  fi
}

__detect_fedora() {
  __log_info "Detecting latest Fedora stable release"
  FEDORA_VERSION=$(\curl -fsSL --max-time 15 \
    "https://dl.fedoraproject.org/pub/fedora/linux/releases/" 2>/dev/null | \
    \grep -oE 'href="[0-9]+/"' | \grep -oE '[0-9]+' | \sort -n | \tail -1 || true)
  if [[ -n "$FEDORA_VERSION" ]]; then
    __log_ok "Fedora ${FEDORA_VERSION}"
  else
    __log_warn "Fedora: version detection failed"
  fi
}

__detect_almalinux() {
  __log_info "Detecting latest AlmaLinux stable release"
  ALMALINUX_VERSION=$(\curl -fsSL --max-time 15 \
    "https://repo.almalinux.org/almalinux/" 2>/dev/null | \
    \grep -oE 'href="[0-9]+\.[0-9]+/"' | \grep -oE '[0-9]+\.[0-9]+' | \sort -V | \tail -1 || true)
  if [[ -n "$ALMALINUX_VERSION" ]]; then
    __log_ok "AlmaLinux ${ALMALINUX_VERSION}"
  else
    __log_warn "AlmaLinux: version detection failed"
  fi
}

__detect_versions() {
  __log_sep "Version Detection"
  __detect_debian
  __detect_ubuntu
  __detect_fedora
  __detect_almalinux
}

# ─── iPXE & Syslinux assets ───────────────────────────────────────────────────
__fetch_ipxe_bins() {
  __log_sep "iPXE Chainloaders"
  __log_info "Fetching iPXE binaries from ${IPXE_BIN_URL_BASE}"
  ( cd "$IPXE_DIR" && {
      __fetch_or_warn "undionly.kpxe (BIOS)"  "${IPXE_BIN_URL_BASE}/undionly.kpxe" undionly.kpxe || true
      __fetch_or_warn "ipxe.efi (UEFI)"       "${IPXE_BIN_URL_BASE}/ipxe.efi"      ipxe.efi      || true
      __fetch_or_warn "snponly.efi (UEFI SNP)" "${IPXE_BIN_URL_BASE}/snponly.efi"   snponly.efi   || true
      __fetch_or_warn "snp.efi (UEFI)"        "${IPXE_BIN_URL_BASE}/snp.efi"       snp.efi       || true
    })
}

__fetch_wimboot() {
  __log_info "Fetching wimboot (Windows PE loader)"
  __fetch_or_warn "wimboot" "$WIMBOOT_URL" "$IPXE_DIR/wimboot" || true
}

__link_syslinux_assets() {
  __log_sep "Syslinux Assets"
  local paths=(
    /usr/lib/syslinux /usr/share/syslinux
    /usr/lib/PXELINUX /usr/lib/syslinux/modules/bios
  )
  local found=0
  for p in "${paths[@]}"; do
    [[ -f "${p}/memdisk" || -f "${p}/bios/memdisk" ]] && { found=1; break; }
  done
  if (( found )); then
    for f in memdisk pxelinux.0 lpxelinux.0 ldlinux.c32 libutil.c32 libcom32.c32 menu.c32 vesamenu.c32; do
      local src=""
      for p in "${paths[@]}"; do
        [[ -f "${p}/${f}" ]]          && { src="${p}/${f}";          break; }
        [[ -f "${p}/bios/${f}" ]]     && { src="${p}/bios/${f}";     break; }
        [[ -f "${p}/modules/bios/${f}" ]] && { src="${p}/modules/bios/${f}"; break; }
      done
      [[ -n "$src" ]] && \install -m 0644 "$src" "$SYS_DIR/$f" && __log_ok "Syslinux: ${f}"
    done
  else
    __log_warn "Syslinux binaries not found; memdisk/pxelinux unavailable (ISO boot limited)"
  fi
}

# ─── Netboot payload downloads ────────────────────────────────────────────────
__fetch_debian_netboot() {
  __log_sep "Debian Netboot"
  local destdir="${HTTP_ROOT}/linux/debian"
  \install -d -m 0755 "$destdir"
  local codename="${DEBIAN_CODENAME:-stable}"
  local base="https://deb.debian.org/debian/dists/${codename}/main/installer-amd64/current/images/netboot/debian-installer/amd64"

  __log_info "Downloading Debian ${codename} vmlinuz + initrd.gz"
  __fetch_or_warn "Debian vmlinuz"   "${base}/linux"     "$destdir/vmlinuz"  || return
  __fetch_or_warn "Debian initrd.gz" "${base}/initrd.gz" "$destdir/initrd.gz" || return
  \printf '%s\n' "${codename}" >"$destdir/version.txt"
  __log_ok "Debian netboot ready → ${destdir}"
}

__fetch_ubuntu_netboot() {
  __log_sep "Ubuntu Netboot"
  local destdir="${HTTP_ROOT}/linux/ubuntu"
  \install -d -m 0755 "$destdir"

  if [[ -z "$UBUNTU_VERSION" ]]; then
    __log_warn "Ubuntu: version unknown — skipping download"
    return
  fi

  __log_info "Discovering Ubuntu ${UBUNTU_VERSION} netboot tarball"
  local tarball
  # Find the latest point release tarball on the releases page
  tarball=$(\curl -fsSL --max-time 15 "https://releases.ubuntu.com/${UBUNTU_VERSION}/" 2>/dev/null | \
    \grep -oE "ubuntu-${UBUNTU_VERSION}[.0-9]*-netboot-amd64[.]tar[.]gz" | \
    \sort -V | \tail -1 || true)
  [[ -z "$tarball" ]] && tarball="ubuntu-${UBUNTU_VERSION}-netboot-amd64.tar.gz"

  UBUNTU_FULL_VERSION="${tarball#ubuntu-}"
  UBUNTU_FULL_VERSION="${UBUNTU_FULL_VERSION%-netboot-amd64.tar.gz}"

  local url="https://releases.ubuntu.com/${UBUNTU_VERSION}/${tarball}"
  local tmptar tmpdir
  tmptar=$(\mktemp "${TMPDIR:-/tmp}/ubuntu-XXXXXX.tar.gz")
  tmpdir=$(\mktemp -d "${TMPDIR:-/tmp}/ubuntu-XXXXXX")

  local ok=0
  __log_info "Downloading ${tarball}"
  if __fetch "$url" "$tmptar" 2>/dev/null; then
    if \tar -xzf "$tmptar" -C "$tmpdir" 2>/dev/null; then
      local kfile initrd_file
      kfile=$(find "$tmpdir" \( -name 'linux' -o -name 'vmlinuz' \) 2>/dev/null | head -1 || true)
      initrd_file=$(find "$tmpdir" \( -name 'initrd' -o -name 'initrd.gz' \) 2>/dev/null | head -1 || true)

      if [[ -n "$kfile" ]]; then
        \install -m 0644 "$kfile" "$destdir/vmlinuz"
        __log_ok "Ubuntu vmlinuz installed"
        ok=1
      else
        __log_warn "Ubuntu: kernel not found in tarball"
      fi
      if [[ -n "$initrd_file" ]]; then
        \install -m 0644 "$initrd_file" "$destdir/initrd"
        __log_ok "Ubuntu initrd installed"
      else
        __log_warn "Ubuntu: initrd not found in tarball"
        ok=0
      fi
    else
      __log_warn "Ubuntu: tarball extraction failed"
    fi
  else
    __log_warn "Ubuntu: download failed (${url})"
  fi

  \rm -rf "$tmpdir" "$tmptar"
  if (( ok )); then
    \printf '%s\n' "${UBUNTU_FULL_VERSION:-${UBUNTU_VERSION}}" >"$destdir/version.txt"
    __log_ok "Ubuntu netboot ready → ${destdir}"
  else
    __log_warn "Ubuntu netboot unavailable — manual setup required"
  fi
}

__fetch_fedora_netboot() {
  __log_sep "Fedora Netboot"
  local destdir="${HTTP_ROOT}/linux/fedora"
  \install -d -m 0755 "$destdir"

  if [[ -z "$FEDORA_VERSION" ]]; then
    __log_warn "Fedora: version unknown — skipping download"
    return
  fi

  __log_info "Downloading Fedora ${FEDORA_VERSION} vmlinuz + initrd.img"
  local base="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Server/x86_64/os/images/pxeboot"
  __fetch_or_warn "Fedora vmlinuz"    "${base}/vmlinuz"    "$destdir/vmlinuz"    || return
  __fetch_or_warn "Fedora initrd.img" "${base}/initrd.img" "$destdir/initrd.img" || return
  \printf '%s\n' "$FEDORA_VERSION" >"$destdir/version.txt"
  __log_ok "Fedora netboot ready → ${destdir}"
}

__fetch_almalinux_netboot() {
  __log_sep "AlmaLinux Netboot"
  local destdir="${HTTP_ROOT}/linux/almalinux"
  \install -d -m 0755 "$destdir"

  if [[ -z "$ALMALINUX_VERSION" ]]; then
    __log_warn "AlmaLinux: version unknown — skipping download"
    return
  fi

  __log_info "Downloading AlmaLinux ${ALMALINUX_VERSION} vmlinuz + initrd.img"
  local base="https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION}/BaseOS/x86_64/os/images/pxeboot"
  __fetch_or_warn "AlmaLinux vmlinuz"    "${base}/vmlinuz"    "$destdir/vmlinuz"    || return
  __fetch_or_warn "AlmaLinux initrd.img" "${base}/initrd.img" "$destdir/initrd.img" || return
  \printf '%s\n' "$ALMALINUX_VERSION" >"$destdir/version.txt"
  __log_ok "AlmaLinux netboot ready → ${destdir}"
}

__fetch_alpine_netboot() {
  __log_sep "Alpine Linux Netboot"
  local destdir="${HTTP_ROOT}/linux/alpine"
  \install -d -m 0755 "$destdir"

  __log_info "Downloading Alpine Linux latest-stable netboot files"
  local base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/netboot"
  __fetch_or_warn "Alpine vmlinuz-lts"   "${base}/vmlinuz-lts"   "$destdir/vmlinuz-lts"   || return
  __fetch_or_warn "Alpine initramfs-lts" "${base}/initramfs-lts" "$destdir/initramfs-lts" || return
  __fetch_or_warn "Alpine modloop-lts"   "${base}/modloop-lts"   "$destdir/modloop-lts"   || return
  \printf 'latest-stable\n' >"$destdir/version.txt"
  __log_ok "Alpine netboot ready → ${destdir}"
}

__fetch_arch_netboot() {
  __log_sep "Arch Linux Netboot"
  local destdir="${HTTP_ROOT}/linux/arch"
  \install -d -m 0755 "$destdir"

  __log_info "Downloading Arch Linux latest netboot files"
  local base="https://geo.mirror.pkgbuild.com/iso/latest/arch/boot/x86_64"
  __fetch_or_warn "Arch vmlinuz-linux"       "${base}/vmlinuz-linux"        "$destdir/vmlinuz-linux"       || return
  __fetch_or_warn "Arch initramfs-linux.img" "${base}/initramfs-linux.img"  "$destdir/initramfs-linux.img" || return
  \printf 'rolling\n' >"$destdir/version.txt"
  __log_ok "Arch netboot ready → ${destdir}"
}

__fetch_all_linux_netboot() {
  __fetch_debian_netboot
  __fetch_ubuntu_netboot
  __fetch_fedora_netboot
  __fetch_almalinux_netboot
  __fetch_alpine_netboot
  __fetch_arch_netboot
}

# ─── HTTP content tree ────────────────────────────────────────────────────────
__seed_http_tree() {
  __log_sep "HTTP Content Tree"
  \install -d -m 0755 \
    "${HTTP_ROOT}/linux" \
    "${HTTP_ROOT}/windows/winpe" \
    "${HTTP_ROOT}/bsd/freebsd" \
    "${HTTP_ROOT}/tools" \
    "${HTTP_ROOT}/isos"
  \cat >"${HTTP_ROOT}/README.txt" <<'EOREADME'
ScriptMgr iPXE HTTP Root
========================
linux/        — kernel+initrd for each distribution
windows/winpe — WinPE files (bootmgr, BCD, boot.sdi, boot.wim)
bsd/          — BSD payloads
tools/        — diagnostic utilities (memtest86+, etc.)
isos/         — symlink to /mnt/ISOs for BIOS memdisk ISO boot
menus/        — generated iPXE menu scripts
EOREADME
  __log_ok "HTTP content tree seeded at ${HTTP_ROOT}"
}

__place_sample_tools() {
  \install -d -m 0755 "${HTTP_ROOT}/tools"
  __log_info "Fetching memtest86+ (optional)"
  __fetch_or_warn "memtest86+" "$MEMTEST_URL" "${HTTP_ROOT}/tools/memtest86+.bin.gz" || true
}

# __detect_iso_dirs — echo "label:path" for every ISO source directory found
__detect_iso_dirs() {
  # Custom / manual mount (original default)
  [[ -d "$ISO_SCAN_DIR" ]] && printf '%s\n' "custom:${ISO_SCAN_DIR}"

  # ── Proxmox VE ─────────────────────────────────────────────────────────────
  # Local storage pool
  [[ -d "/var/lib/vz/template/iso" ]] && printf '%s\n' "proxmox:/var/lib/vz/template/iso"
  # Shared/external storage pools mounted under /mnt/pve/<pool>/template/iso
  for _pve_pool in /mnt/pve/*/template/iso; do
    [[ -d "$_pve_pool" ]] && printf '%s\n' "pve-$(basename "$(dirname "$(dirname "$_pve_pool")")")":"$_pve_pool"
  done

  # ── libvirt / QEMU-KVM ─────────────────────────────────────────────────────
  [[ -d "/var/lib/libvirt/images" ]] && printf '%s\n' "libvirt:/var/lib/libvirt/images"
  [[ -d "/var/lib/libvirt/boot"   ]] && printf '%s\n' "libvirt-boot:/var/lib/libvirt/boot"

  # ── XCP-ng / XenServer ─────────────────────────────────────────────────────
  [[ -d "/var/opt/xen/ISO_Store" ]] && printf '%s\n' "xcpng:/var/opt/xen/ISO_Store"
  # ISO SRs mounted at /run/sr-mount/<uuid>/ — only include if they contain ISOs
  for _sr in /run/sr-mount/*/; do
    [[ -d "$_sr" ]] || continue
    find "$_sr" -maxdepth 2 -name '*.iso' -quit 2>/dev/null && \
      printf '%s\n' "xen-sr-${_sr##/run/sr-mount/}":"$_sr"
  done
}

# __expose_isos_via_http — create per-source symlinks under $ISO_HTTP_DIR
__expose_isos_via_http() {
  __log_sep "ISO Source Detection"

  # If old flat symlink exists from a previous version, remove it
  if [[ -L "${HTTP_ROOT}/isos" ]]; then
    \rm -f "${HTTP_ROOT}/isos"
  fi
  \install -d -m 0755 "$ISO_HTTP_DIR"

  local found=0
  local label path link
  while IFS=: read -r label path; do
    [[ -d "$path" ]] || continue
    link="${ISO_HTTP_DIR}/${label}"
    if [[ -L "$link" && "$(readlink "$link")" == "$path" ]]; then
      __log_ok "ISO source [${label}] already linked: ${path}"
    else
      \rm -rf "$link" 2>/dev/null || true
      \ln -s "$path" "$link"
      __log_ok "ISO source [${label}]: ${path}"
    fi
    found=$(( found + 1 ))
  done < <(__detect_iso_dirs)

  if (( found == 0 )); then
    __log_warn "No ISO source directories found. Place ISOs under ${ISO_SCAN_DIR} or a supported hypervisor path."
  else
    __log_info "Total ISO sources linked: ${found}"
  fi
}

# ─── iPXE menu generation ─────────────────────────────────────────────────────
# Label helpers — build aligned version tags for menu display
# __label <left-text> <width> <tag>
__label() {
  local text="$1" width="$2" tag="$3"
  local pad=$(( width - ${#text} ))
  (( pad < 1 )) && pad=1
  printf '%s%*s%s' "$text" "$pad" "" "$tag"
}

__build_ipxe_menus() {
  __log_sep "iPXE Menu Generation"

  # Version labels (padded to align the tag column)
  local deb_tag="" ubu_tag="" fed_tag="" alma_tag=""
  [[ -n "$DEBIAN_CODENAME" ]] && deb_tag="[ ${DEBIAN_CODENAME} / stable ]" || deb_tag="[ stable ]"
  [[ -n "$UBUNTU_VERSION"  ]] && ubu_tag="[ ${UBUNTU_CODENAME} ${UBUNTU_VERSION} / LTS ]" || ubu_tag="[ LTS ]"
  [[ -n "$FEDORA_VERSION"  ]] && fed_tag="[ ${FEDORA_VERSION} / latest ]" || fed_tag="[ latest ]"
  [[ -n "$ALMALINUX_VERSION" ]] && alma_tag="[ ${ALMALINUX_VERSION} / stable ]" || alma_tag="[ stable ]"

  # Anaconda repo URLs (for Fedora/AlmaLinux network install)
  local fedora_repo="" alma_repo=""
  [[ -n "$FEDORA_VERSION"    ]] && fedora_repo="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Server/x86_64/os/"
  [[ -n "$ALMALINUX_VERSION" ]] && alma_repo="https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION}/BaseOS/x86_64/os/"

  # ── Main Menu ────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/boot.ipxe" <<EOF
#!ipxe
###############################################################################
#                                                                             #
#                    ScriptMgr :: Network Boot Environment                   #
#                                                                             #
###############################################################################

set base-url    http://${HOST_IP}:${HTTP_PORT}
set menu-timeout   80000
set submenu-timeout 80000
set menu-default   localboot

:main_menu
menu  ScriptMgr Network Boot  ::  ${HOST_IP}:${HTTP_PORT}
item --gap --
item --gap --    +-----------[ Linux Distributions ]-----------------------------------+
item --key d debian      Debian GNU/Linux           ${deb_tag}
item --key u ubuntu      Ubuntu Linux               ${ubu_tag}
item --key f fedora      Fedora Linux               ${fed_tag}
item --key a almalinux   AlmaLinux OS               ${alma_tag}
item --key p alpine      Alpine Linux               [ latest-stable ]
item --key r arch        Arch Linux                 [ rolling ]
item --gap --    +-----------[ Windows ]-----------------------------------------------+
item --key w windows     Windows PE / Installer     (wimboot)
item --gap --    +-----------[ BSD ]---------------------------------------------------+
item --key b bsd         BSD Systems Menu
item --gap --    +-----------[ Tools & Diagnostics ]-----------------------------------+
item --key t tools       Diagnostics & Utilities    (memtest86+, etc.)
item --key x ipxe        iPXE Shell & Scripts
item --gap --    +-----------[ System ]------------------------------------------------+
item --key l localboot   Boot from Local Disk       (Default)
item --key 6 reboot      Reboot System
item --key 7 shutdown    Power Off
item --gap --
item --gap --    Timeout: 80s  |  Press a highlighted key to jump directly
item --gap --
choose --default localboot --timeout \${menu-timeout} selected || goto cancel
goto \${selected}

# ── Linux section ─────────────────────────────────────────────────────────────
:debian
chain \${base-url}/menus/linux-debian.ipxe || goto failed

:ubuntu
chain \${base-url}/menus/linux-ubuntu.ipxe || goto failed

:fedora
chain \${base-url}/menus/linux-fedora.ipxe || goto failed

:almalinux
chain \${base-url}/menus/linux-almalinux.ipxe || goto failed

:alpine
chain \${base-url}/menus/linux-alpine.ipxe || goto failed

:arch
chain \${base-url}/menus/linux-arch.ipxe || goto failed

# ── Other sections ────────────────────────────────────────────────────────────
:windows
chain \${base-url}/menus/windows.ipxe || goto failed

:bsd
chain \${base-url}/menus/bsd.ipxe || goto failed

:tools
chain \${base-url}/menus/tools.ipxe || goto failed

:ipxe
chain \${base-url}/menus/ipxe.ipxe || goto failed

# ── System actions ────────────────────────────────────────────────────────────
:reboot
reboot

:shutdown
poweroff

:cancel
clear menu-timeout
prompt Press any key to return to the menu...
goto main_menu

:failed
echo
echo  !! Boot failed. Check that files are present on the server. !!
echo
sleep 3
goto main_menu

$(cat <<'LOCALBOOT'
:localboot
  echo Booting from first local disk...
  sanboot --no-describe --drive 0x80 || exit 0
  boot || exit 0
LOCALBOOT
)
EOF

  # ── Debian ────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-debian.ipxe" <<EOF
#!ipxe
###############################################################################
#  Debian GNU/Linux  ${deb_tag}
###############################################################################
#  Files:  \${base-url}/linux/debian/vmlinuz
#          \${base-url}/linux/debian/initrd.gz
#
#  The Debian Installer (d-i) will guide you through the installation.
#  Network: DHCP auto-configured.  Mirror: debian.org (internet required).
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}

:debian_menu
menu  Debian GNU/Linux  ${deb_tag}
item --gap --
item --gap --    +---------[ Installation Options ]-------------------------------------+
item install     Standard Installation          (guided, choose mirror interactively)
item auto        Automated Installation         (auto=true priority=critical)
item rescue      Rescue Mode                   (repair an existing install)
item --gap --    +---------[ Keyboard & Language ]-[  Defaults: en_US / us kbd  ]------+
item expert      Expert Mode                   (full control, advanced users)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default install --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:install
kernel \${base-url}/linux/debian/vmlinuz
initrd \${base-url}/linux/debian/initrd.gz
imgargs vmlinuz vga=788
boot || goto debian_menu

:auto
kernel \${base-url}/linux/debian/vmlinuz
initrd \${base-url}/linux/debian/initrd.gz
imgargs vmlinuz auto=true priority=critical vga=788
boot || goto debian_menu

:rescue
kernel \${base-url}/linux/debian/vmlinuz
initrd \${base-url}/linux/debian/initrd.gz
imgargs vmlinuz rescue/enable=true vga=788
boot || goto debian_menu

:expert
kernel \${base-url}/linux/debian/vmlinuz
initrd \${base-url}/linux/debian/initrd.gz
imgargs vmlinuz priority=low vga=788
boot || goto debian_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Ubuntu ────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-ubuntu.ipxe" <<EOF
#!ipxe
###############################################################################
#  Ubuntu Linux  ${ubu_tag}
###############################################################################
#  Files:  \${base-url}/linux/ubuntu/vmlinuz
#          \${base-url}/linux/ubuntu/initrd
#
#  Ubuntu 22.04+ uses a casper/subiquity installer.
#  The installer will boot and can fetch packages from the internet.
#  For fully unattended installs, add:
#    autoinstall ds=nocloud-net;s=http://<server>/ubuntu-autoinstall/
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}

:ubuntu_menu
menu  Ubuntu Linux  ${ubu_tag}
item --gap --
item --gap --    +---------[ Installation Options ]-------------------------------------+
item install     Server Installer              (guided interactive install)
item auto        Automated Install             (requires autoinstall config)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default install --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:install
kernel \${base-url}/linux/ubuntu/vmlinuz
initrd \${base-url}/linux/ubuntu/initrd
imgargs vmlinuz ip=dhcp quiet splash
boot || goto ubuntu_menu

:auto
kernel \${base-url}/linux/ubuntu/vmlinuz
initrd \${base-url}/linux/ubuntu/initrd
imgargs vmlinuz ip=dhcp autoinstall ds=nocloud-net;s=http://${HOST_IP}:${HTTP_PORT}/ubuntu-autoinstall/
boot || goto ubuntu_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Fedora ────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-fedora.ipxe" <<EOF
#!ipxe
###############################################################################
#  Fedora Linux  ${fed_tag}
###############################################################################
#  Files:  \${base-url}/linux/fedora/vmlinuz
#          \${base-url}/linux/fedora/initrd.img
#
#  The Anaconda installer fetches packages from the official Fedora mirror.
#  Network: DHCP auto-configured.  Internet access required.
#  Kickstart: add inst.ks=http://<server>/ks/fedora.ks for unattended.
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}
set fedora-repo ${fedora_repo:-https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION:-41}/Server/x86_64/os/}

:fedora_menu
menu  Fedora Linux  ${fed_tag}
item --gap --
item --gap --    +---------[ Installation Options ]-------------------------------------+
item install     Standard Installation         (Anaconda, guided)
item ks          Kickstart Install             (inst.ks= — edit URL before use)
item text        Text Mode Install             (low-bandwidth / no GPU)
item rescue      Rescue Mode                  (repair an existing install)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default install --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:install
kernel \${base-url}/linux/fedora/vmlinuz
initrd \${base-url}/linux/fedora/initrd.img
imgargs vmlinuz inst.repo=\${fedora-repo} ip=dhcp rd.live.check=0 inst.lang=en_US inst.keymap=us
boot || goto fedora_menu

:ks
kernel \${base-url}/linux/fedora/vmlinuz
initrd \${base-url}/linux/fedora/initrd.img
imgargs vmlinuz inst.repo=\${fedora-repo} inst.ks=http://${HOST_IP}:${HTTP_PORT}/ks/fedora.ks ip=dhcp inst.lang=en_US inst.keymap=us
boot || goto fedora_menu

:text
kernel \${base-url}/linux/fedora/vmlinuz
initrd \${base-url}/linux/fedora/initrd.img
imgargs vmlinuz inst.repo=\${fedora-repo} ip=dhcp inst.text inst.lang=en_US inst.keymap=us
boot || goto fedora_menu

:rescue
kernel \${base-url}/linux/fedora/vmlinuz
initrd \${base-url}/linux/fedora/initrd.img
imgargs vmlinuz inst.rescue ip=dhcp
boot || goto fedora_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── AlmaLinux ─────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-almalinux.ipxe" <<EOF
#!ipxe
###############################################################################
#  AlmaLinux OS  ${alma_tag}
###############################################################################
#  Files:  \${base-url}/linux/almalinux/vmlinuz
#          \${base-url}/linux/almalinux/initrd.img
#
#  RHEL-compatible. Anaconda installer fetches packages from almalinux.org.
#  Network: DHCP auto-configured.  Internet access required.
#  Kickstart: add inst.ks=http://<server>/ks/almalinux.ks for unattended.
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}
set alma-repo ${alma_repo:-https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION:-9}/BaseOS/x86_64/os/}

:alma_menu
menu  AlmaLinux OS  ${alma_tag}
item --gap --
item --gap --    +---------[ Installation Options ]-------------------------------------+
item install     Standard Installation         (Anaconda, guided)
item ks          Kickstart Install             (inst.ks= — edit URL before use)
item text        Text Mode Install             (low-bandwidth / no GPU)
item rescue      Rescue Mode                  (repair an existing install)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default install --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:install
kernel \${base-url}/linux/almalinux/vmlinuz
initrd \${base-url}/linux/almalinux/initrd.img
imgargs vmlinuz inst.repo=\${alma-repo} ip=dhcp rd.live.check=0 inst.lang=en_US inst.keymap=us
boot || goto alma_menu

:ks
kernel \${base-url}/linux/almalinux/vmlinuz
initrd \${base-url}/linux/almalinux/initrd.img
imgargs vmlinuz inst.repo=\${alma-repo} inst.ks=http://${HOST_IP}:${HTTP_PORT}/ks/almalinux.ks ip=dhcp inst.lang=en_US inst.keymap=us
boot || goto alma_menu

:text
kernel \${base-url}/linux/almalinux/vmlinuz
initrd \${base-url}/linux/almalinux/initrd.img
imgargs vmlinuz inst.repo=\${alma-repo} ip=dhcp inst.text inst.lang=en_US inst.keymap=us
boot || goto alma_menu

:rescue
kernel \${base-url}/linux/almalinux/vmlinuz
initrd \${base-url}/linux/almalinux/initrd.img
imgargs vmlinuz inst.rescue ip=dhcp
boot || goto alma_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Alpine ────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-alpine.ipxe" <<EOF
#!ipxe
###############################################################################
#  Alpine Linux  [ latest-stable ]
###############################################################################
#  Files:  \${base-url}/linux/alpine/vmlinuz-lts
#          \${base-url}/linux/alpine/initramfs-lts
#          \${base-url}/linux/alpine/modloop-lts
#
#  Minimal, security-oriented Linux.  Fast netboot — files are small.
#  After boot: run 'setup-alpine' to install.
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}

:alpine_menu
menu  Alpine Linux  [ latest-stable ]
item --gap --
item --gap --    +---------[ Boot Modes ]-----------------------------------------------+
item standard    Standard Boot                 (setup-alpine to install)
item diskless    Diskless Mode                 (run from RAM, no disk needed)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default standard --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:standard
kernel \${base-url}/linux/alpine/vmlinuz-lts
initrd \${base-url}/linux/alpine/initramfs-lts
imgargs vmlinuz-lts modloop=\${base-url}/linux/alpine/modloop-lts alpine_repo=http://dl-cdn.alpinelinux.org/alpine/latest-stable/main ip=dhcp quiet
boot || goto alpine_menu

:diskless
kernel \${base-url}/linux/alpine/vmlinuz-lts
initrd \${base-url}/linux/alpine/initramfs-lts
imgargs vmlinuz-lts modloop=\${base-url}/linux/alpine/modloop-lts alpine_repo=http://dl-cdn.alpinelinux.org/alpine/latest-stable/main ip=dhcp diskless_mode=1 quiet
boot || goto alpine_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Arch ──────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/linux-arch.ipxe" <<EOF
#!ipxe
###############################################################################
#  Arch Linux  [ rolling ]
###############################################################################
#  Files:  \${base-url}/linux/arch/vmlinuz-linux
#          \${base-url}/linux/arch/initramfs-linux.img
#
#  Rolling release — always the latest.  After boot: follow the Arch Wiki
#  Installation Guide.  Requires internet access.
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}

:arch_menu
menu  Arch Linux  [ rolling ]
item --gap --
item --gap --    +---------[ Boot Modes ]-----------------------------------------------+
item install     Standard Boot                 (archinstall / manual install)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default install --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:install
kernel \${base-url}/linux/arch/vmlinuz-linux
initrd \${base-url}/linux/arch/initramfs-linux.img
imgargs vmlinuz-linux archiso_http_srv=\${base-url}/linux/arch ip=dhcp quiet
boot || goto arch_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Windows ───────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/windows.ipxe" <<EOF
#!ipxe
###############################################################################
#  Windows  ::  wimboot (BIOS & UEFI)
###############################################################################
#  Required files under ${HTTP_ROOT}/windows/winpe/:
#    bootmgr   BCD   boot.sdi   boot.wim
#
#  Download WinPE from the Windows ADK.
#  For a full Windows installer, extract the ISO and copy files here.
###############################################################################

set base-url    http://${HOST_IP}:${HTTP_PORT}
set wimboot-url tftp://${HOST_IP}/ipxe/wimboot
set winpe-path  \${base-url}/windows/winpe

:windows_menu
menu  Windows  ::  wimboot Network Boot
item --gap --
item --gap --    +---------[ Windows PE / Installer ]-----------------------------------+
item winpe       Windows PE                    (WinPE environment — ADK)
item --gap --    +---------[ Notes ]----------------------------------------------------+
item --gap --    Place bootmgr, BCD, boot.sdi, boot.wim under:
item --gap --    ${HTTP_ROOT}/windows/winpe/
item --gap --
item back        Back to Main Menu
item --gap --
choose --default winpe --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:winpe
kernel \${wimboot-url}
initrd \${winpe-path}/bootmgr    bootmgr
initrd \${winpe-path}/BCD        BCD
initrd \${winpe-path}/boot.sdi   boot.sdi
initrd \${winpe-path}/boot.wim   boot.wim
boot || goto windows_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── BSD ───────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/bsd.ipxe" <<EOF
#!ipxe
###############################################################################
#  BSD Systems
###############################################################################
#  Populate ${HTTP_ROOT}/bsd/<name>/ with the appropriate boot files.
#  FreeBSD example: kernel + mfsroot.gz from the installer ISO.
###############################################################################

set base-url http://${HOST_IP}:${HTTP_PORT}

:bsd_menu
menu  BSD Systems
item --gap --
item --gap --    +---------[ BSD Distributions ]----------------------------------------+
item freebsd     FreeBSD Installer             (kernel + mfsroot netboot)
item --gap --    +---------[ Notes ]----------------------------------------------------+
item --gap --    Place BSD netboot files under:
item --gap --    ${HTTP_ROOT}/bsd/<distro>/
item --gap --
item back        Back to Main Menu
item --gap --
choose --default freebsd --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:freebsd
kernel \${base-url}/bsd/freebsd/boot/kernel/kernel
initrd \${base-url}/bsd/freebsd/boot/mfsroot.gz mfsroot.gz
imgargs kernel -S115200
boot || goto bsd_menu

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── Tools ─────────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/tools.ipxe" <<EOF
#!ipxe
###############################################################################
#  Tools & Diagnostics
###############################################################################

set base-url  http://${HOST_IP}:${HTTP_PORT}
set sys-tftp  tftp://${HOST_IP}/syslinux

:tools_menu
menu  Tools & Diagnostics
item --gap --
item --gap --    +---------[ Memory & Hardware ]----------------------------------------+
item memtest     Memtest86+                    (BIOS, via memdisk — RAM test)
item --gap --    +---------[ Boot Options ]-[ UEFI ISO boot requires kernel+initrd ]----+
item isos        ISO Auto-Discovery Menu       (BIOS-only, memdisk)
item --gap --    +---------[ System ]---------------------------------------------------+
item localboot   Boot from Local Disk
item reboot      Reboot System
item --gap --
item back        Back to Main Menu
item --gap --
choose --default localboot --timeout \${submenu-timeout} selected || goto back
goto \${selected}

:memtest
kernel \${sys-tftp}/memdisk
initrd \${base-url}/tools/memtest86+.bin.gz
imgargs memdisk iso raw
boot || goto tools_menu

:isos
chain \${base-url}/menus/iso-auto.ipxe || goto tools_menu

:localboot
sanboot --no-describe --drive 0x80 || exit 0

:reboot
reboot

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
EOF

  # ── iPXE Shell ────────────────────────────────────────────────────────────────
  \cat >"${MENU_DIR}/ipxe.ipxe" <<'EOF'
#!ipxe
###############################################################################
#  iPXE Shell & Scripts
###############################################################################

:ipxe_menu
menu  iPXE Advanced
item --gap --
item --gap --    +---------[ iPXE Tools ]-----------------------------------------------+
item shell       Interactive iPXE Shell        (type iPXE commands manually)
item sanboot     SAN Boot (iSCSI / AoE)        (enter target URI at prompt)
item --gap --
item back        Back to Main Menu
item --gap --
choose --default shell --timeout ${submenu-timeout} selected || goto back
goto ${selected}

:shell
shell

:sanboot
echo Enter iSCSI target URI (e.g. iscsi:192.168.1.10::::iqn.2024-01.com.example:target):
read san-uri
sanboot ${san-uri} || goto ipxe_menu

:back
chain ${base-url}/menus/boot.ipxe
EOF

  __log_ok "All iPXE menus generated in ${MENU_DIR}"
  __build_iso_auto_menu
}

__build_iso_auto_menu() {
  local iso_menu="${MENU_DIR}/iso-auto.ipxe"
  __log_info "Building ISO auto-discovery menu from ${ISO_HTTP_DIR}"

  # Collect all ISO entries: array of "key|label_source|display_name|url_path"
  local -a iso_entries=()
  local total=0 src_label src_link iso rel urlpath key display

  for src_link in "${ISO_HTTP_DIR}"/*/; do
    [[ -d "$src_link" ]] || continue
    src_label="$(basename "$src_link")"
    while IFS= read -r -d '' iso; do
      rel="${iso#${src_link}}"
      urlpath="${src_label}/${rel// /%20}"
      key="iso$(( ++total ))"
      display="[${src_label}]  ${rel}"
      iso_entries+=("${key}|${src_label}|${display}|${urlpath}|${iso}")
    done < <(find "$src_link" -type f -iname '*.iso' -print0 2>/dev/null | \sort -z)
  done

  # ── Write menu header ───────────────────────────────────────────────────────
  \cat >"$iso_menu" <<EOF
#!ipxe
###############################################################################
#  ISO Auto-Discovery  (BIOS only — memdisk)
#  Sources: ${ISO_HTTP_DIR}/*/
#  ${total} ISO(s) discovered across all hypervisor/custom directories
###############################################################################

set sys-tftp  tftp://${HOST_IP}/syslinux
set base-url  http://${HOST_IP}:${HTTP_PORT}

:iso_auto
menu  ISO Boot  [ BIOS / memdisk only ]  ${total} image(s) found
item --gap --
EOF

  # ── Write menu items grouped by source ──────────────────────────────────────
  local last_src="" entry k s d u f
  if (( total == 0 )); then
    printf 'item --gap -- (no ISO files found — place ISOs under %s or a hypervisor path)\n' \
      "$ISO_SCAN_DIR" >>"$iso_menu"
  else
    for entry in "${iso_entries[@]}"; do
      IFS='|' read -r k s d u f <<< "$entry"
      if [[ "$s" != "$last_src" ]]; then
        # Section header per source
        printf 'item --gap --\n' >>"$iso_menu"
        case "$s" in
          proxmox*)    printf 'item --gap --    +-[ Proxmox VE: %s ]-\n' "$s" >>"$iso_menu" ;;
          pve-*)       printf 'item --gap --    +-[ Proxmox Pool: %s ]-\n' "${s#pve-}" >>"$iso_menu" ;;
          libvirt*)    printf 'item --gap --    +-[ libvirt / QEMU-KVM: %s ]-\n' "$s" >>"$iso_menu" ;;
          xcpng*)      printf 'item --gap --    +-[ XCP-ng / XenServer ]-\n' >>"$iso_menu" ;;
          xen-sr-*)    printf 'item --gap --    +-[ XCP-ng SR: %s ]-\n' "${s#xen-sr-}" >>"$iso_menu" ;;
          custom*)     printf 'item --gap --    +-[ Custom / Manual: %s ]-\n' "$ISO_SCAN_DIR" >>"$iso_menu" ;;
          *)           printf 'item --gap --    +-[ %s ]-\n' "$s" >>"$iso_menu" ;;
        esac
        last_src="$s"
      fi
      printf 'item %-14s %s\n' "$k" "$d" >>"$iso_menu"
    done
  fi

  # ── Footer ──────────────────────────────────────────────────────────────────
  \cat >>"$iso_menu" <<'ISOEOF'
item --gap --
item back     Back to Tools Menu
item --gap --
choose --default back --timeout ${submenu-timeout} selected || goto back
iseq ${selected} back && goto back || goto ${selected}
ISOEOF

  # ── Boot stanzas ────────────────────────────────────────────────────────────
  local entry k s d u f
  for entry in "${iso_entries[@]}"; do
    IFS='|' read -r k s d u f <<< "$entry"
    \cat >>"$iso_menu" <<EOF

:${k}
# BIOS-only ISO boot via memdisk (UEFI not supported for raw ISO)
# Source: ${f}
kernel tftp://${HOST_IP}/syslinux/memdisk
initrd http://${HOST_IP}:${HTTP_PORT}/isos/${u}
imgargs memdisk iso raw
boot || goto iso_auto
EOF
  done

  \cat >>"$iso_menu" <<EOF

:back
chain http://${HOST_IP}:${HTTP_PORT}/menus/tools.ipxe
EOF

  __log_ok "ISO auto-menu generated — ${total} ISO(s) across $(ls -1 "${ISO_HTTP_DIR}" 2>/dev/null | wc -l) source(s)"
}

# ─── Service setup ────────────────────────────────────────────────────────────
__setup_tftp() {
  __log_sep "TFTP Service"
  local unit_dir="/etc/systemd/system"
  \install -d "$unit_dir"

  \cat >"${unit_dir}/${TFTP_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TFTP server for iPXE (ScriptMgr PXE)
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

  \systemctl daemon-reload || true
  \systemctl enable --now "${TFTP_SERVICE_NAME}.service" || true
  __log_ok "TFTP service configured: ${TFTP_SERVICE_NAME}"
}

__setup_http() {
  __log_sep "HTTP Service"
  if \command -v nginx >/dev/null 2>&1; then
    __log_info "Configuring nginx to serve ${HTTP_ROOT} on :80"
    \cat >"/etc/nginx/conf.d/ipxe.conf" <<EOF
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
    \systemctl enable --now nginx || true
    HTTP_PORT="80"
    __log_ok "nginx configured on :80"
  else
    __log_info "No nginx found — using Python http.server on :${HTTP_PORT}"
    local unit_dir="/etc/systemd/system"
    \cat >"${unit_dir}/${HTTP_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Minimal HTTP server for iPXE payloads (ScriptMgr PXE)
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
    \systemctl daemon-reload || true
    \systemctl enable --now "${HTTP_SERVICE_NAME}.service" || true
    __log_ok "Python http.server configured on :${HTTP_PORT}"
  fi
}

__symlink_convenience() {
  \ln -sf "$IPXE_DIR" "${PREFIX_DIR}/ipxe"     2>/dev/null || true
  \ln -sf "$SYS_DIR"  "${PREFIX_DIR}/syslinux" 2>/dev/null || true
  [[ -f "${SYS_DIR}/pxelinux.0" ]] && \ln -sf "${SYS_DIR}/pxelinux.0" "${PREFIX_DIR}/pxelinux.0" 2>/dev/null || true
}

__copy_menu_to_tftp() {
  \install -d -m 0755 "$IPXE_DIR"
  \cp -f "${MENU_DIR}/boot.ipxe" "${IPXE_DIR}/boot.ipxe"
  __log_ok "boot.ipxe copied to TFTP root: ${IPXE_DIR}/boot.ipxe"
}

# ─── Final summary ────────────────────────────────────────────────────────────
__print_dhcp_hints() {
  # Re-read version files in case detection was skipped
  [[ -z "$DEBIAN_CODENAME"    && -f "${HTTP_ROOT}/linux/debian/version.txt"    ]] && DEBIAN_CODENAME=$(< "${HTTP_ROOT}/linux/debian/version.txt")
  [[ -z "$UBUNTU_FULL_VERSION" && -f "${HTTP_ROOT}/linux/ubuntu/version.txt"   ]] && UBUNTU_FULL_VERSION=$(< "${HTTP_ROOT}/linux/ubuntu/version.txt")
  [[ -z "$FEDORA_VERSION"     && -f "${HTTP_ROOT}/linux/fedora/version.txt"    ]] && FEDORA_VERSION=$(< "${HTTP_ROOT}/linux/fedora/version.txt")
  [[ -z "$ALMALINUX_VERSION"  && -f "${HTTP_ROOT}/linux/almalinux/version.txt" ]] && ALMALINUX_VERSION=$(< "${HTTP_ROOT}/linux/almalinux/version.txt")

  \cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║          ScriptMgr iPXE Boot Server — READY                 ║
╚══════════════════════════════════════════════════════════════╝

  Server IP   : ${HOST_IP}
  TFTP root   : ${PREFIX_DIR}
  HTTP root   : ${HTTP_ROOT}
  HTTP port   : ${HTTP_PORT}

┌─ Distro Versions ─────────────────────────────────────────────
│  Debian    : ${DEBIAN_CODENAME:-unknown}
│  Ubuntu    : ${UBUNTU_FULL_VERSION:-${UBUNTU_VERSION:-unknown}}  (${UBUNTU_CODENAME:-})
│  Fedora    : ${FEDORA_VERSION:-unknown}
│  AlmaLinux : ${ALMALINUX_VERSION:-unknown}
│  Alpine    : latest-stable
│  Arch      : rolling
└───────────────────────────────────────────────────────────────

┌─ DHCP Configuration ──────────────────────────────────────────
│  Configure your existing DHCP server to point here:
│
│  [dnsmasq]
│    dhcp-option=66,${HOST_IP}
│    dhcp-boot=ipxe/undionly.kpxe           # BIOS
│    # UEFI x86_64:
│    # dhcp-match=set:efi-x86_64,option:client-arch,7
│    # dhcp-boot=tag:efi-x86_64,ipxe/ipxe.efi
│
│  [ISC DHCPd]
│    next-server ${HOST_IP};
│    filename "ipxe/undionly.kpxe";         # BIOS
│    # if option arch = 00:07 {
│    #   filename "ipxe/ipxe.efi";          # UEFI x86_64
│    # }
│
│  [Windows DHCP]
│    Option 066 = ${HOST_IP}
│    Option 067 = ipxe/undionly.kpxe        # BIOS
│             or = ipxe/ipxe.efi            # UEFI
└───────────────────────────────────────────────────────────────

┌─ iPXE Entry Points ───────────────────────────────────────────
│  Main menu (TFTP) : ${PREFIX_DIR}/ipxe/boot.ipxe
│  Main menu (HTTP) : http://${HOST_IP}:${HTTP_PORT}/menus/boot.ipxe
└───────────────────────────────────────────────────────────────

┌─ Service Management ──────────────────────────────────────────
│  TFTP : systemctl status ${TFTP_SERVICE_NAME}
│  HTTP : systemctl status nginx   (or ${HTTP_SERVICE_NAME})
│  Logs : journalctl -u ${TFTP_SERVICE_NAME}
└───────────────────────────────────────────────────────────────

┌─ ISO Sources (auto-detected) ─────────────────────────────────
EOF

  # List every linked ISO source
  local iso_found=0
  local lbl
  for lbl in "${ISO_HTTP_DIR}"/*/; do
    [[ -d "$lbl" ]] || continue
    local src_name iso_count
    src_name="$(basename "$lbl")"
    iso_count=$(find "$lbl" -type f -iname '*.iso' 2>/dev/null | wc -l)
    printf '│  %-14s → %s  (%s ISO(s))\n' "$src_name" "$(readlink "$lbl")" "$iso_count"
    iso_found=$(( iso_found + 1 ))
  done

  if (( iso_found == 0 )); then
    printf '│  (none detected — place ISOs under %s\n' "$ISO_SCAN_DIR"
    printf '│   or a supported hypervisor path and re-run)\n'
  fi

  \cat <<EOF
│
│  Re-run this script any time to refresh iso-auto.ipxe after
│  adding or removing ISO files.
└───────────────────────────────────────────────────────────────

┌─ Adding Content ──────────────────────────────────────────────
│  ISOs      : Supported auto-detected paths:
│               /mnt/ISOs                         (custom)
│               /var/lib/vz/template/iso          (Proxmox local)
│               /mnt/pve/<pool>/template/iso      (Proxmox shared)
│               /var/lib/libvirt/images           (libvirt/KVM)
│               /var/opt/xen/ISO_Store            (XCP-ng)
│               /run/sr-mount/<uuid>/             (XCP-ng ISO SR)
│  Windows   : Copy bootmgr, BCD, boot.sdi, boot.wim to
│              ${HTTP_ROOT}/windows/winpe/
│  BSD       : Place kernel + mfsroot.gz under
│              ${HTTP_ROOT}/bsd/freebsd/boot/
│  Kickstart : Place .ks files under
│              ${HTTP_ROOT}/ks/
└───────────────────────────────────────────────────────────────

EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────
__main() {
  [[ $EUID -eq 0 ]] || __log_fatal "Please run as root."

  __log_sep "ScriptMgr PXE Installer v${SCRIPT_VERSION}"

  __detect_pm
  __install_pkgs
  __ensure_dirs
  __auto_detect_host_ip

  __detect_versions

  __fetch_ipxe_bins
  __fetch_wimboot
  __link_syslinux_assets

  __seed_http_tree
  __fetch_all_linux_netboot
  __place_sample_tools
  __expose_isos_via_http

  __build_ipxe_menus
  __copy_menu_to_tftp

  __setup_tftp
  __setup_http
  __symlink_convenience

  __print_dhcp_hints
}

__main "$@"
