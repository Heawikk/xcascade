# xcascade

Port-forwarding cascades (DNAT) for Linux. Clients connect to your VPS, and the VPS transparently relays the traffic to a target (e.g. foreign) server. Works for UDP (WireGuard, AmneziaWG), TCP (VLESS, XRay, Reality, MTProto) and any other port.

A single bash script built on **nftables**. No dependencies except root access.

```
client ──► your VPS (xcascade) ──► target server
```

## Quick install

Ubuntu 20.04+ / Debian 11+ (requires bash ≥ 4.4; nftables is installed automatically). Run as root (or prefix with `sudo`).

**wget**

```bash
wget -O xcascade.sh https://raw.githubusercontent.com/Heawikk/xcascade/main/xcascade.sh && sudo bash xcascade.sh install
```

**curl**

```bash
curl -fsSL -o xcascade.sh https://raw.githubusercontent.com/Heawikk/xcascade/main/xcascade.sh && sudo bash xcascade.sh install
```

Download the script to a file and run it from there (piping it into `bash` is not supported). After installation the `xcascade` command is available system-wide:

```bash
sudo xcascade
```

On the first interactive run (`install` or the menu) xcascade asks for the interface language — **English** or **Русский** — and remembers your choice. You can change it any time, see [Language](#language).

What `install` does: installs nftables if missing, copies the script to `/usr/local/bin/xcascade`, enables `net.ipv4.ip_forward` (via `/etc/sysctl.d/99-xcascade.conf`), and creates and enables the `xcascade.service` systemd unit so the rules are restored on boot.

## Usage

```bash
sudo xcascade                                      # interactive menu
sudo xcascade add udp 51820 203.0.113.10           # WireGuard / AmneziaWG
sudo xcascade add tcp 443 203.0.113.10:8443 vless  # different target port, rule named "vless"
sudo xcascade add both 20000-20100 203.0.113.10    # port range, ports are preserved
sudo xcascade list
sudo xcascade del vless                            # by name or by number from `list`
sudo xcascade stats                                # packets and traffic per rule
sudo xcascade check                                # target reachability
sudo xcascade doctor                               # diagnostics
sudo xcascade lang ru                              # switch the interface language (ru | en)
```

Then, in your client app (AmneziaWG, v2rayNG, Telegram…), replace the target server's address with **the address of this VPS** and, if the ports differ, use the incoming port.

### Commands

| Command | Description |
|---|---|
| `add <tcp\|udp\|both> <port\|range> <ip[:port]> [name]` | Add a rule. Options: `--force`, `--dry-run`, `--no-ufw`, `--name` |
| `list` | List rules |
| `del <name\|number>` | Delete a rule |
| `stats` | Packet and traffic counters per rule |
| `check [name]` | Ping and TCP port check of the target |
| `doctor` | Diagnostics: forwarding, nft table, autostart, UFW, Docker |
| `apply` | Recreate the rules from the config (repairs a flushed firewall) |
| `backup`, `restore [file]` | Backups of the rule list |
| `bbr` | Enable BBR (optional, see below) |
| `lang [ru\|en]` | Show / change the interface language |
| `install [--bbr] [--lang ru\|en]`, `uninstall [--purge] [--yes]` | Install / remove |
| `help`, `version` | Help / version |

## Language

The interface is available in English and Russian.

- On the first interactive run, `xcascade install` (or the menu) shows a language prompt. In a non-interactive run (scripts, CI) no prompt is shown and English is used.
- Change it later with `sudo xcascade lang ru` / `sudo xcascade lang en`, or via the **Language / Язык** item in the menu (`l`). Without an argument, `xcascade lang` opens the same prompt.
- Skip the prompt on install: `sudo bash xcascade.sh install --lang ru`.
- Override for a single run: `XCASCADE_LANG=ru xcascade list`.
- The choice is stored in `/etc/xcascade/lang`.
- The final "Installed" message after `install` is always printed in English.

## How it works

- All rules live in a **dedicated nft table** `ip xcascade`. Other firewall rules (UFW, Docker, fail2ban, your own) are never read or modified. Removing xcascade means deleting a single table.
- The source of truth is `/etc/xcascade/rules.conf`; the nft ruleset is generated from it.
- Changes are applied **atomically**: the ruleset is validated first (`nft -c`), then loaded as one transaction, and only then saved to disk. If nft rejects the configuration, nothing changes.
- A backup of the rule list is made before every change (the last 20 are kept in `/etc/xcascade/backups/`).
- `MASQUERADE` is applied only to forwarded (DNAT'ed) traffic towards the specific target, not to all outgoing traffic of the server.
- Before adding a rule, xcascade validates input (IPs, ports, names), detects conflicts with existing rules, and refuses ports used by **SSH** (so you don't lock yourself out) or warns about other local services. Override with `--force`.
- If **UFW** is active, narrow `ufw route allow` rules are added for the targets only. UFW's global forward policy is left untouched.

## Limitations

- IPv4 only.
- Port ranges are forwarded with ports preserved (incoming = outgoing).
- The server masquerades the client address: the target sees the cascade's IP, not the client's.
- `stats` counts client → target traffic and resets whenever the rules change.
- Existing connections keep working after a rule is deleted until they end (conntrack).
- If iptables has a `FORWARD DROP` policy (typical for Docker) and UFW is not used, you have to allow forwarding to the targets in your own firewall. `xcascade doctor` warns about this.
- `systemctl reload nftables` with the stock `/etc/nftables.conf` (`flush ruleset`) also wipes the xcascade table. Fix it with `xcascade apply`; a `restart` of the nftables service restarts xcascade automatically.

## About BBR

BBR only speeds up TCP sessions that terminate **on the server itself** (SSH, downloads on the VPS). Forwarded traffic passes through the server between the client and the target, so it does not get faster from BBR on the cascade. That is why BBR is optional here: enable it with `xcascade bbr` or `xcascade install --bbr`.

## Uninstall

```bash
sudo xcascade uninstall            # removes the table, unit, sysctl files and the command; keeps the config
sudo xcascade uninstall --purge    # same, plus the /etc/xcascade directory
```

Only xcascade's own objects are touched. The running `net.ipv4.ip_forward` value is not changed (other services may need it).

## Files

| Path | Purpose |
|---|---|
| `/etc/xcascade/rules.conf` | Rule list: `name protocol in ip out` |
| `/etc/xcascade/xcascade.nft` | Generated nft ruleset (used on boot) |
| `/etc/xcascade/lang` | Interface language (`en` or `ru`) |
| `/etc/xcascade/backups/` | Backups of the rule list |
| `/etc/systemd/system/xcascade.service` | Autostart unit |
| `/etc/sysctl.d/99-xcascade.conf` | Enables IP forwarding |
