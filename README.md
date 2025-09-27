# iPXE/TFTP All‑in‑One Installer

**Script:** `install.sh`
**Repo:** [https://github.com/scriptmgr](https://github.com/scriptmgr)
**Purpose:** Stand up a DHCP‑agnostic PXE/iPXE boot server with TFTP + HTTP, BIOS/UEFI chainloaders, iPXE menus, Windows PE via wimboot, Syslinux/memdisk tooling, and auto‑generated ISO submenus from `/mnt/ISOs`.

> **No DHCP included.** Keep your existing DHCP (dnsmasq/ISC/Windows, etc). This script only provides **TFTP + HTTP** and menu automation.

---

## Features

* **Distro‑agnostic**: Works on Debian/Ubuntu, RHEL/Alma, openSUSE, Arch, Alpine.
* **No DHCP**: Prints DHCP hints for external servers (dnsmasq/ISC/Windows).
* **BIOS & UEFI**: Serves `undionly.kpxe` (BIOS), `ipxe.efi`/`snponly.efi` (UEFI).
* **HTTP + TFTP**: Prefers nginx on :80; falls back to Python `http.server` on :8080. TFTP served from `/srv/tftp`.
* **Menu layout**: **Linux**, **Windows**, **BSD**, **Tools**, **iPXE**, **Local Boot** (default = HD).
* **Windows PE / Installer**: via **wimboot** (auto‑fetched).
* **Syslinux/memdisk**: For BIOS ISO/IMG tools and utilities.
* **Auto ISO menus**: Scans `/mnt/ISOs` (subdirs → submenus) and wires a BIOS‑only memdisk launcher.
* **Netboot seeds**: Placeholders for Debian, AlmaLinux, Alpine, Arch.
* **Systemd services**: `tftpd-ipxe.service` and either `nginx` or fallback `ipxe-httpd.service`.
* **Idempotent**: Safe to re‑run; creates required directories and links.

---

## What gets installed

* **TFTP root**: `/srv/tftp`

  * `/srv/tftp/ipxe/{undionly.kpxe, ipxe.efi, snponly.efi, wimboot, boot.ipxe}`
  * `/srv/tftp/syslinux/{memdisk, pxelinux.0, *.c32}` (when available)
  * `/srv/tftp/mgr/pxe` (requested path, for your own assets)
* **HTTP root**: `/srv/www/ipxe`

  * `menus/` → generated iPXE menus (`boot.ipxe`, `linux.ipxe`, `windows.ipxe`, `bsd.ipxe`, `tools.ipxe`, `ipxe.ipxe`, `iso-auto.ipxe`)
  * `linux/{debian,alma,alpine,arch}/` → put netboot kernels/initrds here
  * `windows/winpe/{bootmgr,BCD,boot.sdi,boot.wim}`
  * `tools/` → utilities (e.g., `memtest86+.bin.gz` if downloaded)
  * `isos/` → symlink to `/mnt/ISOs` when present

---

## Quick start

```bash
# As root
bash install.sh
```

After it completes, set your DHCP to point to this server:

* **Next‑server** (a.k.a. TFTP server): `NEXT-SERVER <SERVER_IP>`
* **Filename**:

  * BIOS: `ipxe/undionly.kpxe`
  * UEFI x86_64: `ipxe/ipxe.efi` (or `ipxe/snponly.efi`)

Optional **HTTP chain** (if your environment supports iPXE over HTTP):

```
http://<SERVER_IP>/menus/boot.ipxe
```

> The installer auto‑detects a host IP for menus. You can safely edit the menu files in `/srv/www/ipxe/menus/` if you need to change host/IP/port.

---

## Prerequisites

* Root access, systemd environment (services are created as units).
* Network ports available:

  * **TFTP** UDP/69
  * **HTTP** TCP/80 (nginx) or TCP/8080 (Python fallback)
* Outbound Internet access during install (to fetch iPXE binaries and wimboot). If offline, pre‑stage those files and re‑run.

### Package managers detected

`apt-get`, `dnf`, `yum`, `zypper`, `pacman`, `apk`

The script installs base tooling, TFTP server, Syslinux (for memdisk), and nginx (if available) or Python 3 for fallback.

---

## DHCP configuration examples (external)

> Again, DHCP is **external**. Configure your existing server to point to this PXE host.

### dnsmasq

```ini
# Common settings
log-dhcp
# Set TFTP server
dhcp-option=66,<SERVER_IP>
# BIOS
dhcp-boot=ipxe/undionly.kpxe
# UEFI x86_64 example
#dhcp-match=set:efi-x86_64,option:client-arch,7
#dhcp-boot=tag:efi-x86_64,ipxe/ipxe.efi
# Or use snponly.efi for UEFI
```

### ISC DHCPd

```conf
next-server <SERVER_IP>;
# BIOS
filename "ipxe/undionly.kpxe";
# For UEFI (x86_64 = 00:07)
# if option arch = 00:07 {
#   filename "ipxe/ipxe.efi";
# } else {
#   filename "ipxe/undionly.kpxe";
# }
```

### Windows DHCP

* Scope Options:

  * **066 Boot Server Host Name** = `<SERVER_IP>`
  * **067 Bootfile Name** = `ipxe/ipxe.efi` (UEFI) or `ipxe/undionly.kpxe` (BIOS)

> If you have mixed BIOS/UEFI clients, use vendor class policies or IP helper rules to differentiate.

---

## Menu layout & behavior

Top‑level: **Linux · Windows · BSD · Tools · iPXE · Local Boot**

* **Linux**: Debian, AlmaLinux, Alpine, Arch + **ISO Submenus** (auto‑discovered from `/mnt/ISOs`).
* **Windows**: WinPE/Installer via **wimboot** (place files under `windows/winpe/`).
* **BSD**: Example FreeBSD entry (customize to your tree).
* **Tools**: Memtest86+ and local‑disk boot option.
* **iPXE**: Shell and custom snippets.
* **Local Boot**: Default; attempts `sanboot 0x80` (first disk).

> **Note:** Memdisk ISO boot is **BIOS‑only**. For UEFI, prefer kernel+initrd netboot workflows or WinPE.

---

## Adding Linux distributions

Below are minimal patterns. Replace with actual versions/filenames from your distro’s netboot artifacts.

### Debian/Ubuntu

* Place files:

  * `linux/debian/vmlinuz`
  * `linux/debian/initrd.gz`
  * Optional: `linux/debian/preseed.cfg`
* The menu uses:

```ipxe
kernel http://<SERVER_IP>/linux/debian/vmlinuz
initrd http://<SERVER_IP>/linux/debian/initrd.gz
imgargs vmlinuz ip=dhcp url=http://<SERVER_IP>/linux/debian/preseed.cfg auto=true priority=critical
boot
```

### AlmaLinux (RHEL family)

* Place files:

  * `linux/alma/vmlinuz`
  * `linux/alma/initrd.img`
  * Optional Kickstart: `linux/alma/ks.cfg`
* Menu snippet:

```ipxe
kernel http://<SERVER_IP>/linux/alma/vmlinuz
initrd http://<SERVER_IP>/linux/alma/initrd.img
imgargs vmlinuz inst.stage2=http://<SERVER_IP>/linux/alma/ inst.ks=http://<SERVER_IP>/linux/alma/ks.cfg ip=dhcp
boot
```

### Alpine Linux

* Place files:

  * `linux/alpine/vmlinuz-lts`
  * `linux/alpine/initramfs-lts`
  * `linux/alpine/modloop-lts`
* Menu snippet:

```ipxe
kernel http://<SERVER_IP>/linux/alpine/vmlinuz-lts
initrd http://<SERVER_IP>/linux/alpine/initramfs-lts
imgargs vmlinuz-lts modloop=http://<SERVER_IP>/linux/alpine/modloop-lts alpine_repo=http://<SERVER_IP>/linux/alpine/repo ip=dhcp
boot
```

### Arch Linux

* Place files:

  * `linux/arch/vmlinuz-linux`
  * `linux/arch/initramfs-linux.img`
* Menu snippet:

```ipxe
kernel http://<SERVER_IP>/linux/arch/vmlinuz-linux
initrd http://<SERVER_IP>/linux/arch/initramfs-linux.img
imgargs vmlinuz-linux archiso_http_srv=http://<SERVER_IP>/linux/arch ip=dhcp
boot
```

> **Tip:** You can host full mirrors or netboot roots under the HTTP tree if you prefer offline installs.

---

## Windows via wimboot

* Place these in `windows/winpe/`:

  * `bootmgr`
  * `BCD`
  * `boot.sdi`
  * `boot.wim` (WinPE or installer WIM)
* The menu loads `wimboot` and those resources, then boots into WinPE/Installer.

> The script downloads **wimboot** into `/srv/tftp/ipxe/wimboot` automatically.

---

## Auto‑ISO submenu (BIOS only)

* Put ISO files under **`/mnt/ISOs`**.
* Subdirectories become **submenus**. The installer symlinks this tree into `http://<SERVER_IP>/isos/`.
* iPXE entries use **Syslinux `memdisk`** to boot ISO images on BIOS clients.

> UEFI + ISO via memdisk is generally not supported. Use UEFI‑native netboot or WinPE instead.

---

## Services & management

* **TFTP**: `systemctl status tftpd-ipxe`
* **HTTP (nginx)**: `systemctl status nginx` (listens on :80)
* **HTTP (fallback)**: `systemctl status ipxe-httpd` (Python `http.server` on :8080)

Logs: use `journalctl -u <service>`.

---

## Firewall

Open these ports to your provisioning/VLAN:

* UDP/69 (TFTP)
* TCP/80 (HTTP if nginx) or TCP/8080 (fallback HTTP)

**firewalld**

```bash
firewall-cmd --add-service=tftp --permanent
firewall-cmd --add-service=http --permanent
firewall-cmd --reload
```

**ufw**

```bash
ufw allow 69/udp
ufw allow 80/tcp
# or if using Python fallback
ufw allow 8080/tcp
```

---

## File tree (key paths)

```
/srv/tftp/
  ├─ ipxe/
  │   ├─ undionly.kpxe
  │   ├─ ipxe.efi
  │   ├─ snponly.efi
  │   ├─ wimboot
  │   └─ boot.ipxe  # copy of main menu for TFTP access
  ├─ syslinux/
  │   ├─ memdisk
  │   ├─ pxelinux.0 (if available)
  │   └─ *.c32 modules
  └─ mgr/pxe/        # reserved path for your custom assets

/srv/www/ipxe/
  ├─ menus/
  │   ├─ boot.ipxe (main)
  │   ├─ linux.ipxe
  │   ├─ windows.ipxe
  │   ├─ bsd.ipxe
  │   ├─ tools.ipxe
  │   ├─ ipxe.ipxe
  │   └─ iso-auto.ipxe
  ├─ linux/{debian,alma,alpine,arch}/...
  ├─ windows/winpe/{bootmgr,BCD,boot.sdi,boot.wim}
  ├─ tools/
  └─ isos/ -> /mnt/ISOs (symlink)
```

---

## Customization

* **Host/IP/port**: Detected at install; edit URLs in `/srv/www/ipxe/menus/*.ipxe` as needed.
* **Menu entries**: Add/remove sections in `menus/*.ipxe`. iPXE syntax is simple—use `menu`, `item`, `choose`, `kernel`, `initrd`, `imgargs`, `boot`, `chain`.
* **Alternative chainloaders**: Swap `ipxe.efi` with `snponly.efi` if vendor SNP driver works better.
* **Local mirrors**: Host full repositories under `/srv/www/ipxe/linux/<distro>/` and point menu args accordingly.

---

## Troubleshooting

* **PXE times out / no file**: Check DHCP `next-server` and `filename` values; verify TFTP port 69/UDP is open.
* **UEFI clients fail to boot ISO**: Expected—use kernel+initrd netboot or WinPE.
* **403/404 over HTTP**: Confirm nginx is active (`systemctl status nginx`) or Python fallback service, and that files exist under `/srv/www/ipxe`.
* **iPXE says “No such file”**: URLs are case‑sensitive; verify exact paths and filenames.
* **Windows PE stuck early**: Ensure `bootmgr`, `BCD`, `boot.sdi`, `boot.wim` are present and correct for your architecture.
* **Syslinux assets missing**: On some distros, Syslinux modules live under different paths. Re‑run the installer; it will try multiple locations.

---

## Security considerations

* Limit exposure to provisioning networks/VLANs only.
* If using nginx, consider `autoindex off;` and explicit locations.
* Keep WinPE/WIM images and installers on restricted segments.
* Regularly update iPXE and distro netboot images.

---

## Uninstall / cleanup

```bash
systemctl disable --now tftpd-ipxe || true
systemctl disable --now ipxe-httpd || true
systemctl disable --now nginx || true
rm -f /etc/systemd/system/tftpd-ipxe.service /etc/systemd/system/ipxe-httpd.service
systemctl daemon-reload
# Remove content trees (optional)
rm -rf /srv/tftp /srv/www/ipxe /var/lib/ipxe-installer
```

---

## Contributing

Issues and PRs welcome at [https://github.com/scriptmgr](https://github.com/scriptmgr). Keep changes POSIX‑friendly and distro‑agnostic.

---

## License

MIT — © ScriptMgr
