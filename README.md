# Omarchy NAS

An [Omarchy 4](https://omarchy.org) bar plugin for a small office file server.

It lives in the Quattro bar. Click **NAS**, pick how this box identifies people, then turn DHCP and DNS on only if you want this machine to hand those out too.

This is Omarchy 4 only (`omarchy-shell` / Quickshell). It will not load on Waybar-era Omarchy.

## What you can run

Pick one directory mode:

| Mode | This box is | Users |
| --- | --- | --- |
| **Host AD** | Samba Active Directory DC | Domain accounts on this box |
| **Join AD** | Domain member / file server | Accounts from an existing DC |
| **Local users** | Standalone Samba | Unix + Samba accounts stored here |

DHCP and DNS are separate switches. You can host files with neither, run DHCP without being the office DNS, or (on Host AD) keep Samba’s AD DNS while DHCP clients get a forwarder instead of this box.

Untagged LAN, tagged VLANs, and shares work in every mode. The DNS tab (manual A records) is for Host AD with DNS on. The Users tab is for Host AD and local users. Join AD does not invent users; they already live on the domain.

## Install

```sh
omarchy plugin add https://github.com/wcoy7/omarchy-nas.git --enable
omarchy bar put office.ad --section right
```

Or copy the folder (no symlinks):

```sh
mkdir -p ~/.config/omarchy/plugins/office.ad
cp -a . ~/.config/omarchy/plugins/office.ad/
omarchy plugin validate ~/.config/omarchy/plugins/office.ad
omarchy-shell shell rescanPlugins
omarchy plugin enable office.ad
omarchy bar put office.ad --section right
```

Click **NAS**. Escape closes the panel. Apply buttons prompt polkit. Opening the panel and filling fields does nothing until you apply.

First-time **Host AD** still needs a one-shot provision after the untagged IP is set:

```sh
sudo ~/.config/omarchy/plugins/office.ad/bin/omarchy-ad-dc-setup.sh
```

Edit realm, hostname, and addresses at the top of that script first. Join AD and local users do not use it.

## Mode notes

**Host AD.** `samba.service` only. Do not also start `smb`, `nmb`, or `winbind`; the DC already forks those. Windows clients join `OFFICE.LAN` (or whatever realm you set).

**Join AD.** Member server: `smb` + `winbind` + `wsdd`. Point DNS at the existing DC, then Join domain. You cannot join while this box is still a DC (`sam.ldb` present).

**Local users.** Standalone Samba. Add and delete accounts from the Users tab (`useradd` + `smbpasswd`). No realm.

## DHCP and DNS

- **DHCP on** starts Kea and serves the pools on the untagged LAN and each VLAN.
- **DHCP off** leaves the pools saved but stops Kea.
- **DNS on** (Host AD) uses Samba DNS and, when DHCP is on, hands out this box as nameserver. Reverse zones are created per subnet.
- **DNS off** does not stop the DC. AD SRV records still live in Samba. DHCP clients get the forwarder you set instead of this box.

## VLANs

The switch port must trunk the tags you add. Each tag gets a parent NIC (`eth0.10`), this box’s IP on that subnet, its own DHCP pool (if DHCP is on), and a reverse zone (if DNS is on). AD stays one realm. Hosts on VLAN 10 still resolve `office.lan`; they just use the DC address on that VLAN.

## Shares

Name, path, unix mode, optional `valid users`, read-only switch. Reloads `smb.conf` in place.

## Packages

The Packages tab lists what the current mode needs (Samba, Kea, wsdd, and so on). If something required is missing, opening the panel jumps there and offers **Install missing**. That uses `omarchy-pkg-add` when present, otherwise `pacman -S --needed`, via polkit.

## Privileges

Plugins run unsandboxed as your user inside `omarchy-shell`. The panel cannot sudo. Changes go through `pkexec bin/omarchy-adctl`. Status is unprivileged.

State: `/etc/omarchy-ad/state.json`.

## Layout

```
manifest.json      plugin id office.ad
BarWidget.qml      bar button
Panel.qml          Mode, Network, VLANs, DNS, Shares, Users
bin/omarchy-adctl  status + apply (pkexec)
bin/omarchy-ad-dc-setup.sh   Host AD first provision
```
