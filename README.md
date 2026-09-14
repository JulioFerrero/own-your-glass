# own-your-glass

> Harden a rooted LG webOS TV — kill the microphones, stop the screen-capture leak, block the ad/telemetry endpoints, and debloat the services you never asked for.

![platform: webOS](https://img.shields.io/badge/platform-webOS-8B5CF6?style=flat-square)
![shell: POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-1F2937?style=flat-square)
![root: required](https://img.shields.io/badge/root-required-DC2626?style=flat-square)
![license: MIT](https://img.shields.io/badge/license-MIT-22C55E?style=flat-square)
![status: validated on hardware](https://img.shields.io/badge/status-validated%20on%20hardware-0EA5E9?style=flat-square)

The name is a reminder: this tool helps you *own* the glass on your wall,
not the vendor's data pipeline. It does not turn the TV into a fortress.
It is a best-effort mitigation of the specific leaks found by your own
security investigation on your own rooted webOS TV.

Written in POSIX `sh` so it runs on the BusyBox shell that ships on the device.

---

## What it actually does

- **Microphones**: all 6 ALSA capture endpoints neutralised; playback untouched.
- **Magic Remote mic + speech-to-text**: dead. The `voiceinput_hidraw` → `voiceinput` → `voiceconductor` pipeline is replaced with `/dev/null`; `/dev/hidraw0` stays alive so the rest of the remote still works.
- **Screen-capture leak** (`/tmp/capture.rgb`, readable by any app): closed. `/usr/bin/vtCaptureTestSuite` is bind-mounted over `/dev/null`; the capture file is `chattr`+`immutable`.
- **Ad / telemetry / ACR domains + ThinQ cloud + firmware-update servers**: blocked, dual-stack (IPv4 `0.0.0.0` **and** IPv6 `::1` per domain, because an IPv4-only sinkhole let AAAA lookups fall through to DNS).
- **LG consents**: force-declined and re-declined every boot (covers the system silently re-accepting them after a component update).
- **Ad / ACR / overlay / SDK-example apps**: hidden from the launcher via the vendor's own `blockedSystemAppList/<REGION>.json`.
- **Unused feature services**: stopped — including the DIAL casting-discovery server, which was consuming CPU continuously on an idle TV.
- **telnetd** (unauthenticated root on the LAN): disabled via `/var/luna/preferences/webosbrew_telnet_disabled`, which makes webOSbrew's `startup.sh` skip the `telnetd -l /bin/sh` launch.

---

## Rooting your TV

`oyg` requires root. Rootability of a webOS TV is **firmware-version-specific** — what works on one build may be patched on the next. This project does not ship exploit code; find one that matches your model + firmware on the community sites below.

- **Compatibility checker:** <https://cani.rootmy.tv> (model + firmware → supported chains).
- **Community guide:** <https://www.webosbrew.org/rooting/> — the official rooting walk-through.
- **RootMyTV:** <https://rootmy.tv> — the original `GetMeNow` exploit. Patched on many recent models.
- **DejaVuln autoroot:** <https://github.com/throwaway96/dejavuln-autoroot> — webOS 3.5+. Other common chains: `faultmanager`, `GetMeNow`.
- **Research / kernel work:** <https://openlgtv.github.io>.

**Before you start**, uninstall LG's **Developer Mode** app if it is present. It conflicts with the rooting chain, and its functionality is replaced by Homebrew Channel once you are rooted.

**After rooting**, Homebrew Channel is installed automatically. In Homebrew Channel → Settings, **enable the SSH server**. **Leave Telnet off** — `telnetd` ships as an unauthenticated root shell on the LAN, and the `policy` module below maintains the flag that keeps it off.

**First login**, from your computer:

```sh
ssh root@<tv-ip>                       # default password: alpine
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<tv-ip>
```

The key lands at `/home/root/.ssh/authorized_keys` on the TV. Once that file exists, Homebrew Channel stops provisioning the `alpine` default password on subsequent boots, so do this immediately.

**Never flash the kernel, rootfs, or TVService.** See <https://rootmy.tv/warning>. `oyg` never writes a system partition; it only changes file modes on writable paths, bind-mounts, `ip route` entries, and service state.

**Warnings:**

- Rooting affects your warranty. That is between you and LG.
- A **factory reset can lose root** and may make re-rooting impossible on that unit — re-check `cani.rootmy.tv` for your firmware before doing either.
- The webOSbrew update-blocker flag (touched by the `policy` module) protects your root by sinkholing LG's update servers. It also stops LG kernel security patches from arriving. Pick your trade-off.

---

## Quick start

```sh
scp -r . root@<tv-ip>:/tmp/oyg && ssh root@<tv-ip> 'sh /tmp/oyg/install.sh'
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg list'
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg harden --dry-run'   # then drop --dry-run
```

After install, no hardening is applied yet — pick your modules and re-run with `--dry-run` removed. See [Install (on the TV)](#install-on-the-tv) below for the full flag set, including the opt-in aggressive modes.

---

## Contents

- [What it actually does](#what-it-actually-does)
- [Rooting your TV](#rooting-your-tv)
- [Quick start](#quick-start)
- [Threat model](#threat-model)
- [Module table](#module-table)
- [How it works (the four techniques)](#how-it-works-the-four-techniques)
- [Install (on the TV)](#install-on-the-tv)
- [Watch what the TV talks to](#watch-what-the-tv-talks-to)
- [Send a notification to the TV](#send-a-notification-to-the-tv)
- [`oyg list`](#oyg-list)
- [Warn-on-risk / opt-in flags](#warn-on-risk--opt-in-flags)
- [What this CANNOT do on this device](#what-this-cannot-do-on-this-device)
- [Network module: four layers](#network-module-three-layers)
- [Debloat module: reclaim RAM and attack surface from unused feature services](#debloat-module-reclaim-ram-and-attack-surface-from-unused-feature-services)
- [Apps module: hide unwanted apps from the launcher](#apps-module-hide-unwanted-apps-from-the-launcher)
- [Capture-device neutralisation (the `mic` module)](#capture-device-neutralisation-the-mic-module)
- [Magic Remote microphone neutralisation (the `voice` module)](#magic-remote-microphone-neutralisation-the-voice-module)
- [Consent + update-blocker neutralisation (the `policy` module)](#consent--update-blocker-neutralisation-the-policy-module)
- [Router-level enforcement (the real fix for the resolver-bypass gap)](#router-level-enforcement-the-real-fix-for-the-resolver-bypass-gap)
- [Layout](#layout)
- [Boot persistence](#boot-persistence)
- [Attribution](#attribution)
- [License](#license)
- [Disclaimer](#disclaimer)

---

## Threat model

You own the device, it is rooted, but the vendor's data-collection
processes (ACR, content miner, object detection, ad overlay, telemetry
beacons, voice transcription, screen capture into app sandboxes,
RemoteOne remote-support gate, world-writable vendor service code paths)
keep running in the background and leak data to LG / cloud / AdTech.
This toolkit stops what it can, blocks what it can, and clearly documents
what it cannot.

It is **not** designed to defend against an attacker with root. Once
someone has root they can disable everything in this toolkit. The
defender-of-root is firmware integrity and boot-chain validation, which
this tool does not touch.

---

## Module table

| Module | Neutralises | Opt-in flag | Reversible? |
|---|---|---|---|
| `capture` | Screen-capture leak: `chattr`+`immutable` on `/tmp/capture.rgb`; `mount --bind /dev/null` on `/usr/bin/vtCaptureTestSuite` (read-only `/usr`) | none — safe by default | yes (`umount` + restore mode) |
| `mic` | All ALSA capture PCMs (`pcmC*D*c`): `chmod 000` + `mount --bind /dev/null`. Playback untouched. | none — safe by default | yes |
| `voice` | Magic Remote mic pipeline: `chmod 000` + bind-null on `voiceinput_hidraw`, `voiceinput`, `voiceconductor`. `/dev/hidraw0` deliberately untouched (carries every other remote button). | none — safe by default | yes |
| `logs` | Periodic clear of `/tmp/var/log/messages` and `/tmp/app.voice.log` (damage limitation). | none — safe by default | yes (stop the watcher) |
| `remoteone` | Verifies `/mnt/lg/cmn_data/remoteDebug/` is absent; optionally tightens `cmn_data`. | `OYG_AGGRESSIVE=1` for the chmod step | yes |
| `policy` | Touches `/var/luna/preferences/webosbrew_block_updates` (webOSbrew fallback hosts-bind) and `webosbrew_telnet_disabled` (suppresses telnetd — unauthenticated root on the LAN); force-declines LG consents in **all four** on-disk consent stores — `/var/luna/preferences/eula` (Job B) plus the three SDX/ACR-side stores at `/mnt/lg/{cmn_data,cache,user}/sdp/eula-service/eula.json` (Job C, A→D for every `S_DPA`/`S_SVC`/`S_VNG`/`S_MKT`/`S_ADG`/`S_TAG`); moves `marketingAllowedDate.json` aside so the 2-year "re-allow marketing" toast never fires (Job D). All re-applied every boot. | `OYG_TOS_IDS="S_VNG S_TAG"` allow-list form (default = decline ALL — applies to Job B only) | yes (`restore` from `$OYG_BACKUP/eula.orig` + `eula-{cmn,cache,user}.orig` + `marketingAllowedDate.json.orig`) |
| `apps` | Hides a curated list (48 IDs) from the launcher via the vendor's own `blockedSystemAppList/<REGION>.json`. Ad machinery, remote-support tile, SDK examples, demo apps. Skips IDs absent on the device. | none — safe by default | yes (restore the original file from backup) |
| `debloat` | Stops + bind-nulls unused feature services: `mycar`, `familycare`, `buddyconnector`, `alwaysready`, `ai-inference-manager`, `avahi-daemon`, `avahi-adaptor`, `ruleengine`; bind-nulls `/usr/bin/com.webos.app.voice`, `ss.gateway` (DIAL discovery), `iconnectivity`, `uploadd` (dynamic LS2 — bind defeats respawn), and other luna-launched binaries if present. **`sdx` is deliberately NOT bind-nulled** — neutralising it silently breaks the TV's Settings UI. See F42. | `OYG_DEBLOAT=1` (opt-in — the only default-safe module that isn't on by default) | yes |
| `network` | Four-layer mitigation: `/etc/hosts` bind-overlay (dual-stack IPv4+IPv6 sinkhole, always); blackhole public resolvers (always); per-IP blackhole (opt-in); on-device sinkhole resolver on `127.0.0.2:53` hooked in via a `/etc/resolv.conf` bind-mount (opt-in; the ConnMan route is rejected on this device — see scripts/dns.sh post-mortem). Always blocks LG firmware/update servers. | `OYG_NETWORK_BLOCK=1` (without it, layer 1 + layer 2 still applied); `OYG_NETWORK_STRICT=1`; `OYG_NETWORK_IPBLOCK=1`; `OYG_DNS_OVERRIDE=1`; `OYG_DNS_RESOLVER=1` | yes (`umount` + route delete + resolv.conf umount) |

Every module exposes:

- `mod_<name>_harden`   — apply, idempotent, reversible
- `mod_<name>_restore`  — undo
- `mod_<name>_status`   — print `OK|PARTIAL|FAIL|N/A <detail>`

`oyg verify` exits non-zero if any applied module is not in `OK` or `N/A`.

---

## How it works (the four techniques)

Everything in this toolkit is built from the same four low-level moves, because a rooted webOS TV gives you very few of them.

1. **`mount --bind /dev/null` over a device node or binary** (kills the *pipe*, not the driver).
   - Over an ALSA PCM like `/dev/snd/pcmC0D10c`: every `open()` returns `ENXIO` / "Inappropriate ioctl for device" — the kernel still owns the driver, the user-space consumer just cannot read from it.
   - Over a vendor binary like `/usr/bin/vtCaptureTestSuite` (which lives on a read-only `/usr`, so `chmod 000` fails): any `exec()` reads zeros and fails. Re-launchers hit the bind immediately on the next attempt.
2. **`mount --bind` a generated file over the read-only `/etc/hosts`** (LG already does this same trick for `/etc/shadow`).
   - The network module emits a hosts file from the blocklists at `/var/lib/own-your-glass/hosts` and bind-mounts it over `/etc/hosts`. Dual-stack: every blocked domain gets **both** `0.0.0.0 <d>` and `::1 <d>` — an IPv4-only sinkhole lets AAAA lookups fall through to DNS.
3. **`systemctl stop` + re-stop from an `/var/lib/webosbrew/init.d` hook**.
   - Because `/etc` is a read-only overlay on this device, `systemctl mask` is impossible (mask writes to `/etc/systemd`). So the model is: stop now, then stop again on every boot. The init.d hook reads two flat files (`services.stopped`, `services.kill`) and re-applies them after the network wait.
4. **`ip route add blackhole`** for hardcoded public resolvers (because netfilter does not exist on this SoC).
   - `iptables` is non-functional (`ip_tables` kernel module absent), `nft` is not present, `tc` returns `RTNETLINK answers: Operation not supported`. The network module's layer 2 blackholes `8.8.8.8 / 8.8.4.4 / 1.1.1.1 / 1.0.0.1 / 9.9.9.9 / 208.67.222.222 / 208.67.220.220` so daemons that bypass `/etc/hosts` by talking to a hardcoded resolver IP are still cut.

---

## Install (on the TV)

Pick whichever path is easier. **(A)** runs entirely on the TV; **(B)** lets you review the repo on your computer first.

**(A) One-liner — run ON the TV.** The TV's BusyBox + webOS userland ships `curl`, `wget`, `tar`, `gzip`, and `unzip`, and can reach GitHub over TLS. After rooting and installing your SSH key:

```sh
ssh root@<tv-ip>
curl -fsSL https://github.com/JulioFerrero/own-your-glass/archive/refs/heads/main.tar.gz \
  | tar xz -C /tmp \
  && sh /tmp/own-your-glass-main/install.sh
```

Tarballs from `archive/refs/heads/main.tar.gz` extract to `own-your-glass-main/` — use that exact path. If `curl` misbehaves, the same flow works with `wget`:

```sh
wget -qO- https://github.com/JulioFerrero/own-your-glass/archive/refs/heads/main.tar.gz \
  | tar xz -C /tmp \
  && sh /tmp/own-your-glass-main/install.sh
```

**(B) From your computer** — `git clone` then serve the tree to the TV any way you like (scp to `/tmp/own-your-glass` and run `install.sh` there works; the control-panel app does this for you from its bundled copy).

Either path installs to:

- `/var/lib/own-your-glass/`        — the toolkit root (state, backups, log, watchers)
- `/var/lib/webosbrew/init.d/oyg`   — boot hook (re-applies safe modules; `run-parts` ignores dotfiles, so no `.sh` suffix)

`install.sh` only copies files and drops the boot hook — **nothing is hardened until you run `oyg harden`** below.

After install, inspect what is available, dry-run, apply, then verify:

```sh
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg list'
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg harden --dry-run'   # review
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg harden'             # apply the safe set
ssh root@<tv-ip> '/var/lib/own-your-glass/oyg verify'
```

Pick your modules (the rest of the flag set is unchanged from before):

```sh
# Always safe, no flags:
/var/lib/own-your-glass/oyg harden

# Dry-run first:
/var/lib/own-your-glass/oyg harden --dry-run

# Risky — break ThinQ/Home if applied:
OYG_AGGRESSIVE=1 /var/lib/own-your-glass/oyg harden --only services
OYG_AGGRESSIVE=1 /var/lib/own-your-glass/oyg harden --only perms

# Risky — may break apps/updates:
OYG_NETWORK_BLOCK=1 /var/lib/own-your-glass/oyg harden --only network
# Even riskier — also blocks ThinQ / voice / AI / LG control plane:
# OYG_NETWORK_BLOCK=1 OYG_NETWORK_STRICT=1 /var/lib/own-your-glass/oyg harden --only network
# Also enable per-IP blackhole (layer 3, ages as CDNs rotate):
# OYG_NETWORK_BLOCK=1 OYG_NETWORK_IPBLOCK=1 /var/lib/own-your-glass/oyg harden --only network
# Also rewrite /var/lib/misc/resolv.conf with the default gateway as nameserver:
# OYG_NETWORK_BLOCK=1 OYG_DNS_OVERRIDE=1     /var/lib/own-your-glass/oyg harden --only network
# Recommended — also install the on-device sinkhole resolver and hook it
# in via a /etc/resolv.conf bind-mount (layer 4, closes the connman-bypass
# gap verified on this device — see F14g in docs/FINDINGS.md; the ConnMan
# route itself is rejected, see the post-mortem in scripts/dns.sh):
# OYG_NETWORK_BLOCK=1 OYG_DNS_RESOLVER=1 /var/lib/own-your-glass/oyg harden --only network

# Verify everything is applied:
/var/lib/own-your-glass/oyg verify
```

Restore everything to the original state:

```sh
sh uninstall.sh
```

(or `/var/lib/own-your-glass/oyg restore` if you want to keep the
tool installed but undo the hardening.)

---

## Watch what the TV talks to

`scripts/sniff.sh` is a small **on-device** packet sniffer for this TV.
It needs no `tcpdump` / `libpcap` / `dumpcap` — those aren't installed
on the device and netfilter is absent — so it uses Python's stdlib
`socket.AF_PACKET` + `ETH_P_ALL` instead. Runs as root; SSH into the TV
already gives you root.

```sh
ssh lgtv 'sh /var/lib/own-your-glass/sniff.sh --seconds 30'
ssh lgtv 'sh /var/lib/own-your-glass/sniff.sh --pcap /tmp/tv.pcap --seconds 60'
scp lgtv:/tmp/tv.pcap .   # then open in Wireshark
```

Two modes: **live text** (default) prints one line per interesting
event, flushed, so the operator on the other end of the SSH sees the
TV's connections stream in real time; **`--pcap FILE`** writes a
libpcap-format capture (magic `0xa1b2c3d4`, version 2.4, linktype 1 /
Ethernet) that opens cleanly in Wireshark.

Surfaced events: **DNS queries** (UDP/53, both directions), **TCP SYN
attempts**, and **sinkhole hits** (destination `0.0.0.0` or `::1` —
i.e. one of our `/etc/hosts` block entries winning against the
resolver). **TLS SNI** is extracted from `ClientHello` payloads so we
can name HTTPS destinations even though the traffic is encrypted — that
is the only place the destination hostname appears in cleartext for
TLS, which is the entire point of the SNI field and why HTTPS-everywhere
and the network module's blocklist work in the first place.

Defaults: TCP 22 (ssh) and 9998 (CDP) are auto-excluded so the
operator's own session doesn't drown the output; the interface is
auto-detected from `ip route show default` (likely `wlan0`). Override
with `-i IFACE`. Bound a capture with `--seconds N`.

Flags:

- `-i IFACE` — capture interface (default: auto-detect from default route)
- `-d, --seconds N` — stop after N seconds (default: unbounded, Ctrl-C)
- `--pcap FILE` — write a libpcap capture (open in Wireshark)
- `--exclude-port PORT` — repeatable; default-excludes TCP 22 + 9998
- `--dns`, `--sni`, `--tcp`, `--blocked`, `--all` — filter categories
  (default: DNS + SNI + SYN + sinkhole; `--all` adds the per-packet firehose)
- `-q, --quiet` — suppress the banner

**Why SNI matters.** TLS 1.2+ encrypts everything in the HTTPS record
*after* the `ClientHello`, but the `server_name` extension in the
`ClientHello` is sent in cleartext. It is the only field that names the
destination hostname before encryption kicks in. The MITM-in-the-middle
proxies at workplaces and LG's own update-telemetry path both rely on
this; we rely on it the other way to see where the TV is going without
having to decrypt anything.

---

## Send a notification to the TV

`scripts/notify.sh` posts a native webOS toast (the small banner the TV
itself uses for "Firmware update available", "Connected to Wi-Fi…", etc.)
so it renders over any screen and any app — unlike the CDP DOM overlay
that `Runtime.evaluate` gives you inside a web app's tab.

```sh
# From your computer (uses TV_HOST / the ssh alias; default TV_USER=root, TV_PORT=22):
TV_HOST=lgtv scripts/notify.sh -m "Now you own your glass!"
TV_HOST=lgtv scripts/notify.sh -m "auto-closes in 5s" -t 5
TV_HOST=lgtv scripts/notify.sh -m "tick" -r 3 -g 2   # 3 toasts, 2s apart
TV_HOST=lgtv scripts/notify.sh -C                    # close the last one

# From the TV itself (luna-send is in /usr/bin; no TV_HOST needed):
scripts/notify.sh -m "Done."
```

Mode autodetects: if `luna-send` is in `PATH` the script runs locally
on the TV; otherwise it drives `luna-send` over ssh. Mixing the two
(e.g. `TV_HOST` set while `luna-send` is on PATH) is an error.

**The `</dev/null` gotcha (load-bearing).** `luna-send` reads the bus
reply on a pipe fed from STDIN; if STDIN closes before the reply
arrives the call silently returns zero bytes and looks like a success.
Every call in `notify.sh` ends with `</dev/null` for that reason — do
not remove it. Verify with:

```sh
TV_HOST=lgtv scripts/notify.sh --selftest    # bus reachability tripwire
```

`--selftest` calls `getServiceAPIVersions` and reports FAIL (with the
reproduction matrix) if the bus returned zero bytes — that was the bug
that produced two false findings ("luna-send broken", "LS2 unreachable")
in the verification report. See `docs/VERIFICATION-REPORT.md` §0.1.

---

## `oyg list`

```
Module      What it does
-------     ------------------------------------------------
services    stop+kill contentminer, objectdetection, adoverlay, acr, remotediag (+ iot-client, pushclient if OYG_AGGRESSIVE=1)
capture     chattr+immutable / chmod+watcher on /tmp/capture.rgb; mount --bind /dev/null on vtCaptureTestSuite (vendor ro)
apps        hide a curated list of unwanted apps from the launcher via LG blockedSystemAppList/<REGION>.json (ad machinery, remote-support, SDK examples, demo apps); preserves existing entries; skips IDs absent on device
debloat     opt-in (OYG_DEBLOAT=1) — stop+kill mycar/familycare/buddyconnector/alwaysready/ai-inference-manager/avahi-{daemon,adaptor}/ruleengine + wowplay (Type=static, sticks); bind-neutralise /usr/bin/com.webos.app.voice + ss.gateway (DIAL discovery) + iconnectivity + uploadd (Type=dynamic LS2 service, bind defeats ls-hubd respawn) (+ other luna-launched binaries if present); re-applied on every boot. sdx is deliberately excluded — see F42.
mic         chmod 000 + mount --bind /dev/null over each ALSA capture PCM (pcmC*D*c); playback preserved
voice       chmod 000 + mount --bind /dev/null over voiceinput_hidraw / voiceinput / voiceconductor (Magic Remote mic); /dev/hidraw0 untouched
logs        periodic clear of /tmp/var/log/messages and /tmp/app.voice.log (damage limitation)
network     three-layer mitigation: /etc/hosts bind-overlay with dual-stack (IPv4 + IPv6 sinkhole) sinkhole (always); blackhole public resolvers (always); per-IP blackhole (opt-in OYG_NETWORK_IPBLOCK=1)
perms       chmod webOSbrew hbchannel + Google Home runtime paths (opt-in, OYG_AGGRESSIVE=1); re-applied on every boot when previously applied
remoteone   verify /mnt/lg/cmn_data/remoteDebug/ absent; optionally tighten cmn_data (aggressive)
policy      touch /var/luna/preferences/webosbrew_block_updates (webOSbrew fallback hosts-bind) and webosbrew_telnet_disabled (suppresses telnetd — unauthenticated root on the LAN); force-decline LG consents in /var/luna/preferences/eula (decline-all default; OYG_TOS_IDS="S_VNG S_TAG" allow-list supported)
```

Every action is idempotent and reversible. Every mutation is logged.

---

## Warn-on-risk / opt-in flags

The default `oyg harden` is conservative. The following flags unlock
risky behaviour. **Read the linked findings in `docs/FINDINGS.md` first.**

| Flag | Effect | What can break |
|------|--------|----------------|
| `OYG_AGGRESSIVE=1` (services) | also stops `iot-client` + `pushclient` (luna-launched AWS IoT MQTT + LG push channel; `systemctl stop` is a no-op for the actual process, so the module `kill`s it and re-kills on every boot) | ThinQ app, voice control, push notifications; may be re-spawned on demand by `ls-hubd` (boot hook is best-effort, not permanent) |
| `OYG_DEBLOAT=1` (debloat) | stops `mycar`, `familycare`, `buddyconnector`, `alwaysready`, `ai-inference-manager`, `avahi-daemon`, `avahi-adaptor`, `com.webos.service.ruleengine`, `wowplay` and `chmod 000` + `mount --bind /dev/null` over `/usr/bin/com.webos.app.voice` (the preloaded voice-app UI, ~51 MB), `ss.gateway` (the DIAL second-screen discovery server, was burning 6m09s+ of CPU and listening on TCP 8008), `iconnectivity` (LG phone-connectivity helper), `uploadd` (log-upload daemon; LS2 `Type=dynamic` — bind-over-binary is the only structural fix because `ls-hubd` respawns on the next `com.palm.uploadd` call), and the luna-launched binaries (`lg.thinqai.adapter`, `airessrvallocator`, `com.webos.service.iotproxy`, `sportsalert`) where present. **`sdx` is deliberately NOT touched** — it is LG's Service Delivery eXtension (`com.webos.service.sdx`), and bind-neutralising it silently breaks the TV's gear/Settings button. SDX's network endpoints are blocked instead by the `network` module — see F42. | family-care, buddy-connector, alwaysready, AI inference, avahi/mDNS, the webOS rule engine, the wowplay screen-mirroring receiver, the voice-app UI in the launcher, screen-share / DIAL cast discovery (Chromecast-style), LG phone-pairing / ThinQ app cast, LG's log-upload telemetry; `wowplay` stop is permanent (`Type=static`), the rest may be re-spawned on demand by `ls-hubd` except for `uploadd` which is structurally defeated by the bind |
| `OYG_AGGRESSIVE=1` (perms) | chmods webOSbrew hbchannel + Google Home runtime | webOSbrew updates, Google Home on TV |
| `OYG_AGGRESSIVE=1` (remoteone) | chmods `/mnt/lg/cmn_data` from 0777 to 0755 | vendor apps that rely on that directory being world-writable |
| `OYG_TOS_IDS="S_VNG S_TAG"` (policy) | allow-list for the consent-decline step: only the named `"id"` entries are force-declined; default is decline ALL | depends on which ids you include |
| `OYG_NETWORK_BLOCK=1` | applies layers 1 + 2 (bind-mount hosts file + blackhole public resolvers) | apps, EPG, SmartShare, firmware updates — anything resolving via libc |
| `OYG_NETWORK_STRICT=1` | includes the STRICT blocklist section | ThinQ app, voice control, push notifications, LG home-screen card delivery |
| `OYG_NETWORK_IPBLOCK=1` | also applies layer 3 (per-IP `ip route add blackhole`) | anything whose IPs happen to be near the listed hosts (CDNs change!) |
| `OYG_DNS_OVERRIDE=1` | backs up `/var/lib/misc/resolv.conf` and writes `nameserver <default-gw>` | any DNS consumer that does NOT honour `/etc/hosts` (e.g. `nslookup`, some webOS daemons) |
| `OYG_DNS_RESOLVER=1` (network, layer 4) | installs an on-device DNS sinkhole resolver (UDP + TCP, pure Python stdlib) and hooks it in via a **`/etc/resolv.conf` bind-mount**: the managed file lists the sink first and the real DHCP-learned upstream as fallback. The resolver is started and verified answering BEFORE the override goes in; an auto-revert timer (180 s) unmounts an unconfirmed apply. Substring/suffix-match covers subdomains in one rule. Watchdog re-asserts resolv.conf and reverts the override if the resolver dies and won't restart. The bind address comes from `$OYG_ROOT/dns.bind` (`127.0.0.2` by default; `127.0.0.1` under Variant C — see F44). | anything that resolves through `/etc/resolv.conf` (libc `getaddrinfo`, most daemons) and `nslookup`/BusyBox resolution. The ConnMan *settings* route is **rejected on this device**: editing connman's settings + nudging connmand (no `ExecReload` → SIGHUP) took the TV off the network for ~30 min, so this toolkit NEVER signals, reloads or restarts connmand (see the post-mortem in `scripts/dns.sh`). The launcher-patch route (`scripts/go-c.sh`, `-r --nodnsproxy`) is the supported way to close the loopback path. Worst-case rollback is `umount` — the TV falls back to ConnMan's own resolv.conf. |

---

## What this CANNOT do on this device

- **No firewall.** `iptables` is non-functional (`ip_tables` kernel
  module absent). We block specific IPs via `ip route add blackhole`,
  which is not the same as a firewall: return packets are dropped only
  because the route says "no". Outbound UDP from the box to the
  blackholed IP is silently discarded — there is no logging, no
  per-port rules, no state.
- **No `/etc` direct edit.** `/etc` is a read-only overlay. The
  network module gets around this for `/etc/hosts` only — by bind-
  mounting a file we generated at `/var/lib/own-your-glass/hosts`
  over `/etc/hosts` (verified to work on this device). Other files in
  `/etc` remain unmodifiable (see the next bullet on
  `systemctl mask`).
- **No `systemctl mask`.** Because `/etc` is a read-only overlay, mask
  is unimplementable here. Enforcement of "this service must never
  come back" is done by:
  1. `systemctl stop <unit>` immediately (works on this device,
     verified).
  2. `kill -TERM` the matching process (then `-KILL` after a short
     sleep if it survives) — REQUIRED for **luna-launched** services
     whose systemd unit is only a one-shot wrapper that exits 0
     (e.g. `iot-client`); `systemctl stop` does nothing to the
     actually-running process. Verified: `systemctl is-active iot-client`
     returned `inactive` while the `iot-client` process was still
     running (PID 4497); killing the PID worked and nothing respawned
     it within 25 s.
  3. Recording the **unit** in
     `/var/lib/own-your-glass/services.stopped` and the **process**
     in `/var/lib/own-your-glass/services.kill` (one per line, both
     idempotent).
  4. The boot hook (`/var/lib/webosbrew/init.d/oyg`) reads both files
     on every boot after the network wait: `systemctl stop` for
     every entry in `services.stopped`, then `kill -TERM` (then
     `-KILL` if needed) for every entry in `services.kill`. The hook
     is tolerant of a missing file and of a process that isn't
     running.
  State for `services` is therefore reported as
  `unit stopped + process killed, boot-enforced`, never as `masked`.

  ### Two service classes

  Not every background service on this device is actually controlled
  by systemd. The module distinguishes two classes:

  | Class | How it runs | What stops it | Examples on this device |
  |-------|-------------|---------------|--------------------------|
  | **systemd-managed** | Long-running process supervised by its systemd unit; `systemctl stop` actually kills the process. | `systemctl stop <unit>` | `contentminer`, `objectdetection`, `adoverlay`, `acr`, `remotediag`, `com.webos.service.pushclient.service` |
  | **luna-launched (LS2)** | Spawned on demand by `ls-hubd` (the LS2 hub daemon, PID 350). The systemd unit is only a one-shot launcher script that exits 0 immediately, so the unit is always `inactive (dead)`; the real process is invisible to `systemctl`. **This makes `is-active` actively misleading** — it reports `inactive` while the process is happily running. | `kill -TERM` (then `-KILL`) the process | `iot-client` (LS2 service `com.webos.service.iotclient`) |

  Each entry in the module's list is therefore a 3-tuple
  `<id> | <unit> | <process>`. The `services.stopped` file holds
  unit names; the `services.kill` file holds process names. Both
  are re-applied by the boot hook. This is a **best-effort**
  control: `ls-hubd` may respawn a luna-launched process if
  something later requests the LS2 service, which is why the
  boot hook re-kills them on every boot.

  Stopping the aggressive set (`OYG_AGGRESSIVE=1`) disables the LG
  cloud control plane and **breaks ThinQ features** (ThinQ app,
  voice control, push notifications).
- **No `/etc` direct edit (but `/etc/resolv.conf` is a symlink, and
  bind-mounts work).** `/etc` is a read-only overlay. `/etc/resolv.conf`
  is a symlink to the writable `/var/lib/misc/resolv.conf`, but ConnMan
  regenerates that file, so a plain edit is clobbered. Layer 2 can install
  a naive override there behind `OYG_DNS_OVERRIDE=1` (default-gateway as
  nameserver); layer 4 instead **bind-mounts a managed file over
  `/etc/resolv.conf`** (the same technique as `/etc/hosts`), which the
  watchdog re-asserts and `umount` reverts.
- **No DoH / DoT blocking.** Without netfilter we cannot intercept
  TLS/443 (DoH) or TLS/853 (DoT). Layer 2 blackholes the
  hardcoded public DNS resolvers (8.8.8.8, 1.1.1.1, 9.9.9.9, etc.)
  but a daemon that resolves `dns.google` over 443 will still talk to
  Google — there is no way to stop that on this kernel.
- **No `/usr` writes, but `mount --bind /dev/null` works.** Vendor
  binaries like `/usr/bin/vtCaptureTestSuite` live on a read-only
  partition, so `chmod 000` fails. The `capture` module's strategy
  ladder is therefore:
  1. `mount --bind /dev/null <path>` (verified on this device —
     even though `/usr` is read-only, mount-bind works and replaces
     the binary with the null device for execution purposes).
  2. Fall back to `chmod 000` only if bind fails AND the path is
     writable.
  3. Otherwise report `FAIL` with the reason.
  `restore` records the original state and `umount`s exactly the
  paths it bound.
- **No firmware or kernel changes.** This tool does not reflash,
  downgrade, or modify boot chain. It cannot defeat a root-level
  attacker — anyone with root can undo every change here in seconds.
- **No prevention of voice transcription.** The microphone transcription
  to `/tmp/var/log/messages` and `/tmp/app.voice.log` happens before
  we can intervene on the ALSA path alone — but the Magic Remote's
  microphone does NOT use an ALSA device. It arrives as a Bluetooth
  HID raw stream on `/dev/hidraw0` (HID_NAME=`LGE MR25GA`), consumed
  by the `voiceinput_hidraw` → `voiceinput` → `voiceconductor`
  pipeline. The `voice` module kills that pipeline (see "Magic
  Remote microphone neutralisation" below), so on the Magic Remote the
  mic captures no audio and produces no transcripts. The `mic` module
  alone covers any other capture path (built-in mic arrays, USB mics
  on the ALSA bus); the `logs` module clears the plaintext log files
  every `${OYG_LOG_INTERVAL:-60}s` as damage limitation. We do NOT
  touch `/dev/hidraw*` — it carries the mic button press on the same
  HID channel as every other remote button, and breaking it would
  break the remote.
- **No protection against the user logging in.** If you (or a child,
  or a guest) presses the mic button or uses voice search, the mic
  captures. Neutralising the capture nodes makes the captured audio
  unreadable to user-space consumers; it does not stop the hardware
  from receiving audio.

---

## Network module: four layers

The network module is a four-layer mitigation. Each layer catches a
different class of leak.

| Layer | What it does | What it catches | What it does NOT catch |
|-------|--------------|-----------------|------------------------|
| 1. `/etc/hosts` overlay | Generates a hosts file from the blocklists and bind-mounts it over `/etc/hosts` (which is on a read-only overlay on this device). For every blocked domain we emit **both** `0.0.0.0 <d>` and `::1 <d>` — an IPv4-only sinkhole lets AAAA lookups fall through to DNS, so the dual-stack sinkhole is required. | Anything resolving via libc `getent`. The TV's first-party daemons and JavaScript libraries use this path. | Anything that talks DNS directly and IGNORES `/etc/hosts` (verified: `nslookup` and BusyBox's own resolver bypass it). |
| 2. Resolver bypass mitigation | `ip route add blackhole` for the hardcoded public resolvers (8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1, 9.9.9.9, 208.67.222.222, 208.67.220.220). Optional: backup + rewrite `/var/lib/misc/resolv.conf` to point at the default gateway (opt-in `OYG_DNS_OVERRIDE=1`). | webOS daemons that bypass `/etc/hosts` by talking to a hardcoded resolver IP directly. | DoH (TCP/443 to `dns.google` etc.) and DoT (TCP/853). No netfilter, no interception possible. |
| 3. Per-domain IP blackhole | Resolve each blocklist domain via `getent` (with `nslookup` fallback), then `ip route add blackhole` the resulting A records. | Daemons that resolve at startup and cache the IP. Useful when both layer 1 (libc bypass) and layer 2 (hardcoded resolver) miss. | Anything that re-resolves each time (CDNs rotate IPs) — this layer ages badly. |
| 4. On-device sinkhole resolver via `/etc/resolv.conf` *(opt-in `OYG_DNS_RESOLVER=1`)* | Pure-Python stdlib DNS resolver (UDP + TCP) — suffix-matches the blocklist, returns `0.0.0.0` / `::` / NXDOMAIN for matches, forwards everything else to the real upstream (txn-id preserved). Hooked in by **bind-mounting a managed `/etc/resolv.conf`** over the real one (sink first, DHCP-learned upstream as fallback). Resolver started + verified BEFORE the override; auto-revert timer (180 s) on apply. **No connmand signal/reload ever** (the ConnMan settings route took the TV offline once — see scripts/dns.sh post-mortem); the loopback path is closed instead by launching connmand with `--nodnsproxy` (Variant C, F44), after which the sink owns `127.0.0.1:53`. | Everything that resolves through `/etc/resolv.conf`: webOS daemons using libc `getaddrinfo`, and `nslookup`/BusyBox resolution. This closes the gap documented as F14g in `docs/FINDINGS.md`: libc tools honour `/etc/hosts`, but `nslookup` and the DNS path IGNORE it. | DoH (TCP/443) and DoT (TCP/853) that talk to a hardcoded resolver IP (rare on this TV; latent exposure). Without Variant C: daemons that hard-wire ConnMan's proxy on `127.0.0.1:53` instead of reading resolv.conf. |

### Effectiveness, honestly

- **Layer 1** is verified effective for libc-resolving daemons on this
  device. We have *verified* that `nslookup` bypasses it (it reads its
  own resolver config, not `/etc/hosts`), so anything using BusyBox's
  `nslookup`-style resolution is unaffected. The hosts file is emitted
  dual-stack (`0.0.0.0` **and** `::1` for every domain) — an IPv4-only
  sinkhole leaves AAAA lookups free to fall through to DNS, which on
  this device made `criteo.com` resolve to `2620:12a:8000::4` and
  `doubleclick.net` to `2a00:1450:4003:80b::200e` even though both were
  in the blocklist; the IPv6 mirror closes that gap. See F14f in
  `docs/FINDINGS.md`.
- **Layer 2** blocks the public DNS IPs that some webOS daemons
  hardcode. It cannot block DNS-over-HTTPS (TCP/443) or DNS-over-TLS
  (TCP/853) because we have no netfilter.
- **Layer 3** is a *fallback* and ages badly. CDNs rotate IPs; an entry
  that blocks the right IP today may not in a week.
- **Layer 4** (opt-in `OYG_DNS_RESOLVER=1`) is **the load-bearing layer on
  this device**. Why: this TV's libc-resolving daemons honour `/etc/hosts`
  (so layer 1 works for them), but connmand's DNS proxy on `127.0.0.1:53`
  reads `/etc/hosts` and ignores it; verified live:
    - `getent hosts ngfts.nextlgsdp.com` → `::1` (layer 1 sinkhole, OK)
    - `nslookup ngfts.nextlgsdp.com 127.0.0.1` → `23.211.135.15` (real IP — layer 1 bypassed)
  And even `/etc/hosts` can't express subdomains — one `nextlgsdp.com` entry
  does NOT cover `es.nextlgsdp.com`. Layer 4's suffix-match covers all
  subdomains in one rule. Live evidence (pre-layer-4): `es.nextlgsdp.com`,
  `ES.ibsstat.nextlgsdp.com`, `eic.cdpbeacon*.lgtvcommon.com`,
  `eic.lgchhomeapp.lgtvcommon.com`, `eic.cdplauncher/cdpsvc.lgtvcommon.com`,
  `eic.ads.lgtvcommon.com`, `eic-ngfts.lge.com`, `cf-kic/EIC.lggalleryplus.com`,
  `static.doubleclick.net`, `www.googletagmanager.com` all resolved to real
  IPs through connmand after layer 1 was active. After layer 4, the same
  `nslookup` calls return `0.0.0.0` / NXDOMAIN while `www.youtube.com` and
  `github.com` keep answering normally. **How it hooks in (resolv.conf;
  the ConnMan route is REJECTED on this device).** Editing ConnMan's
  service settings and nudging connmand once took this TV off the network
  for ~30 min (`systemctl reload connman` has no `ExecReload`, so systemd
  fell back to `SIGHUP`, which on this LG build tears the Wi-Fi down). So
  `scripts/dns.sh` contains no ConnMan interaction at all: a guard
  (`oyg_guard_connman_route`) fails loudly if `kill -HUP` /
  `systemctl reload connman` ever reappears. It instead bind-mounts a
  managed `/etc/resolv.conf` over the real one — `127.0.0.2` first, the
  DHCP-learned upstream as fallback — starting and verifying the resolver
  BEFORE the override, with an auto-revert timer (180 s) on every apply.
  The bind address is not hardcoded: `dns.sh` reads `$OYG_ROOT/dns.bind`,
  which starts as `127.0.0.2` and becomes `127.0.0.1` once Variant C is
  applied (connmand started with `--nodnsproxy` so the sink can own the
  loopback port every consumer uses). **Watchdog.** `scripts/watch-dns.sh`
  polls every 15 s; it re-asserts the
  override (ConnMan regenerates resolv.conf), restarts a dead resolver
  (3 tries), and if it will not come back, reverts the override (umount)
  so the TV drops onto ConnMan's own resolv.conf — never left without DNS
  (the fallback nameserver carries lookups in the meantime). **Undoing C.**
  `dns.sh stop` (and therefore `oyg restore` / `uninstall.sh`) detects the
  C state and runs `scripts/rollback-c.sh` first — stock launcher back,
  connmand restarted with its proxy. **Audit trail.**
  `$OYG_ROOT/dns-audit.log` records every blocked lookup (timestamp, client,
  name, qtype) — that is what proves layer 4 is doing real work.

### How to confirm layer 4 is doing its job (one-shot)

After `OYG_NETWORK_BLOCK=1 OYG_DNS_RESOLVER=1 oyg harden --only network`,
on the TV:

```sh
nslookup eic-ngfts.lge.com             # was 23.223.82.90 — now 0.0.0.0
nslookup es.nextlgsdp.com              # was resolving — now blocked
nslookup www.youtube.com               # must still resolve to a real IP
nslookup github.com                    # must still resolve to a real IP
getent hosts www.youtube.com           # real IP (layer 1 keeps working)
tail -f /var/lib/own-your-glass/dns-audit.log
# each blocked lookup prints: timestamp  BLOCK  name  <answer>  qtype=N from=127.0.0.1 proto=udp
```

See **F14g** in `docs/FINDINGS.md` for the full proof and rationale.

### Source attribution

The blocklist at `etc/blocklist-upstream-safe.txt` is a vendored snapshot
of [furkan-bayrak/lg-tv-blocklist](https://github.com/furkan-bayrak/lg-tv-blocklist),
retrieved 2026-09-14. The upstream list is licensed **CC BY 4.0**;
attribution to the upstream author is preserved in the file's header.
Refresh with `scripts/refresh-blocklist.sh` (off-device, never on the TV).

### Upstream note (worth filing)

The upstream repo's `dns-egress` hook is iptables-based. That hook does
**not work on this device** because `ip_tables` is not loaded into the
kernel. Worth reporting upstream; the safe fix from our side is the
bind-mount approach used by layer 1.

---

## Debloat module: reclaim RAM and attack surface from unused feature services

Opt-in via `OYG_DEBLOAT=1`. With the flag set, `oyg harden --only debloat`
stops the following **Tier A + Tier B** targets and persists a
boot-time re-apply record so they stay down across reboots:

| Target | Type | What it costs |
|--------|------|---------------|
| `com.webos.service.mycar.service` | systemd unit + matching process | car-related app; no car, no use |
| `com.webos.service.familycare.service` | systemd unit only (`familycare` runs under `iotjs`, so `pidof familycare` does not match; rely on `systemctl stop`) | family-care UI; nobody uses it on this TV |
| `com.webos.service.buddyconnector.service` | systemd unit + matching process | buddy-list sync; unused |
| `alwaysready.service` | systemd unit + matching process | "always-ready" wake-word listener; mic pipeline is already dead (`voice` module) so this can never fire |
| `ai-inference-manager.service` | systemd unit + matching process | on-device AI; consents are declined (`policy` module) so its consumers can't talk to the cloud anyway |
| `avahi-daemon.service` + `avahi-adaptor.service` | systemd units + matching processes | mDNS / Bonjour; unused on this TV |
| `com.webos.service.ruleengine.service` | systemd unit + matching process | ThinQ edge-rules engine; its cloud backend is already blocked by the `network` module |
| `/usr/bin/com.webos.app.voice` | luna-launched preloaded app, **~51 MB**, NOT a systemd unit | the voice-app UI in the launcher; the mic pipeline it would feed is already neutralised by the `voice` module, so launching it serves no purpose. Neutralised with `chmod 000` + `mount --bind /dev/null` (the proven technique that works on the read-only `/usr`). |
| `/usr/sbin/lg.thinqai.adapter`, `/usr/sbin/airessrvallocator`, `/usr/sbin/com.webos.service.iotproxy`, `/usr/sbin/sportsalert` | luna-launched binaries (no systemd unit) | ThinQ / AI / IoT / sports-notification consumers; backend cloud is already blocked by `network`, so disabling the front-ends is safe. Verified at runtime: skipped gracefully if absent. |
| `/usr/palm/services/com.webos.service.dial/discovery-server.js` (process name `ss.gateway`) | luna-launched Node script, NOT a systemd unit | DIAL second-screen / casting discovery server (TCP 8008). argv[0] is set to `ss.gateway` so `pidof ss.gateway` matches. Was burning CPU continuously (**6m09s of accumulated CPU and climbing at the time of observation**). Neutralised with `chmod 000` + `mount --bind /dev/null` and killed by process name. **Kills Chromecast / DIAL "cast to TV" discovery** — the launcher home screen still works. |
| `/usr/sbin/iconnectivity` | luna-launched binary (no systemd unit) | LG phone-connectivity helper (TV Companion / mobile pairing). Neutralised the same way. **Kills the "pair your phone" code path** — casting from the ThinQ app also relies on it. |
| `/usr/sbin/sdx` | luna-launched binary (no systemd unit) | **DELIBERATELY NOT NEUTRALISED** — see F42. LG's Service Delivery eXtension (`com.webos.service.sdx`) downloads the EULA, the ACR config, the smartConfig, performs device authentication, and stamps an encrypted `X-Device-ID` on every service request. Its `server_addr_version.conf` declares 14 endpoints — the `network` module's blocklist covers all of them, so the binary's telemetry is cut without touching the binary itself. Bind-neutralising it silently breaks the TV's gear/Settings button (the launch path goes through `com.webos.app.quicksettings`, which never finishes initialising — `grep QUICKSETTINGS_EDITMODE /tmp/var/log/messages` is the reusable pass/fail signal). **Reproduce with a full reboot, not a live `oyg restore`** — the boot hook re-binds, so live A/B tests contradict each other. |

The binary spec format supports an optional kill-name override
(`<path>|<proc>`) for cases where the process basename differs from the
file basename (e.g. `node` running `discovery-server.js` with
`argv[0]=ss.gateway`). Bind target is always the file path; the
override only affects the kill step.

**Measured on this device (Tier A + Tier B applied):**

- `MemAvailable`: **471 MB → 868 MB** (+397 MB reclaimed, ~84% gain)
- `MemFree`: **128 MB → 196 MB** (+68 MB reclaimed)
- `ss.gateway` accumulated CPU: **6m09s and climbing** at the time of
  observation — was the largest non-system CPU consumer on the device.
  After applying the module it is gone and does not respawn.

Expected RAM reclaim: roughly the working-set of all eight units plus
~51 MB for the preloaded voice-app binary, plus whatever the three
Tier B luna-launched binaries were holding (the `ss.gateway` CPU burn
alone indicates that DIAL discovery was not idle). The full
Tier A + Tier B run moves the device from `MemAvailable ~471 MB` to
`MemAvailable ~868 MB`, which is a meaningful chunk.

**Fully reversible.** `oyg restore --only debloat` `systemctl start`s
the units that were previously active, `umount`s every binary it
bind-mounted, restores the original mode on each one, and clears the
boot-enforce lists. No restart of killed processes — luna-launched /
preloaded processes respawn on demand if the system asks for them.

**What this module NEVER touches.** It is deliberately narrow. The
following stay exactly as the vendor ships them, because they ARE the
TV:

`surface-manager`, `WebAppMgr`, `flutter-client` (home UI),
`com.webos.app.inputcommon`, `legacy-broadcast-dvb` (tuner), audio
services, `connman`, `bootd`, `db8-*`, `lginput2`, `memchute`,
`crashd`, `configd`, `micomservice`, `fancontroller`, `faultmanager`,
`tvpower`, `lowlevelstorage`, `ls-hubd`, `luna-*`. The home launcher
keeps rendering; the remote keeps working; the TV keeps waking on HDMI
and turning off on schedule.

Why the same enforcement model as `services`: `/etc` is a read-only
overlay on this device, so `systemctl mask` is impossible. The model is
therefore "stop now + stop again on every boot". The debloat module
records each stopped unit in `/var/lib/own-your-glass/debloat.units.stopped`
and each killed process in `/var/lib/own-your-glass/debloat.procs.kill`,
and the boot hook re-applies both on every boot when state contains
`debloat.applied=1`. Like the `services` module, this is best-effort
control — `ls-hubd` may respawn a luna-launched process if something
later requests the LS2 service.

---

## Apps module: hide unwanted apps from the launcher

The `apps` module uses LG's own `blockedSystemAppList` mechanism — the
same one the vendor ships in the application manager — to **hide** a
curated list of unwanted apps from the launcher. It does not delete,
uninstall, or modify the apps themselves; the binaries stay on disk
and can be re-shown at any time by removing their IDs from the
blocked list.

### The supported mechanism (verified on the device)

```
/var/preferences/com.webos.applicationManager/blockedSystemAppList/<REGION>.json
{"blocked_system_applist":["com.webos.app.buddy","com.webos.app.gamehome", ...]}
```

`/var/preferences` is writable on this device. The file is named after the
device's region (e.g. `ESP.json` in Spain). The module discovers
the file dynamically — it globs `blockedSystemAppList/*.json` and
prefers the existing one — so it does not hardcode the region.

Apps whose IDs appear in this array are hidden from the launcher but
remain installed; the app manager re-reads the file at every launcher
render, so the effect is immediate and survives the app manager's own
housekeeping.

### Curated list (groups)

The module ships with 48 IDs grouped into four blocks:

- **Ad / ACR / commercial-overlay apps** — `acrcomponent`, `acrhdmi1..4`,
  `acroverlay`, `adoverlay[ex]`, `adhdmi1..4`, `fooddelivery[ex|hdmi1..4]`,
  `overlaycontainer[ex|hdmi1..4]`, `overlaymembership`, `videoads`,
  `cmp-client`, `newandhot`. The full LG ad machinery stack.
- **Vendor remote-support app** — `com.webos.app.remoteservice` (the
  RemoteOne front-end; the gate itself is verified by the `remoteone`
  module, this just hides the launcher tile).
- **SDK example apps shipped in production** — `enyoapp.epg`,
  `groupowner`, `nav`, the eight `qmlapp.*` examples, `systemui`.
- **Demo / test / developer-only apps** — `store-demo`, `sync-demo`,
  `factorywin`, `svcdiagnostics`, `quickrecovery`, `renewupdate`.

### Portability: skip-if-absent

Not every curated ID exists on every webOS TV build. Before adding an
ID to the live file, the module checks `/usr/palm/applications/<id>`
and `/media/system/apps/<id>` (the two canonical installation
locations) and skips any that aren't present, listing them in a
warning. Status reports `N/M curated present` so you can spot drift
across firmware updates.

### Reversibility

- `oyg restore --only apps` puts the original file back from
  `$OYG_BACKUP/blockedSystemAppList.<REGION>.json` (backed up once,
  never overwritten).
- If no original existed at harden time (the device's first boot
  after install), the sentinel backup tells restore to delete the
  live file instead.

### Boot persistence

The app manager may rewrite `blockedSystemAppList/<REGION>.json` on
its own (a related component update can do this). The `apps` module
is therefore in the boot hook alongside `capture`/`mic`/`voice`/
`logs`/`remoteone`/`policy` — the init.d hook re-runs
`oyg harden --only apps` on every boot so the curated list stays
merged in.

### What this module does NOT do

- It hides local apps from the launcher. It does not delete them.
- It does not remove **store-delivered promotional tiles** such as
  "Rakuten TV" or "LG Streaming Week". Those are not local apps —
  they are pulled from the content store / recommendation feed by the
  content manager. The only effective countermeasure for that class
  is the **network blocklist** (`network` module), which sinkholes the
  content-store / recommendation endpoints via the `/etc/hosts`
  bind-mount and the resolver blackholes. Hiding a local `com.webos.app.*`
  ID will not touch those tiles.

---

## Capture-device neutralisation (the `mic` module)

The `mic` module cuts the microphone capture path at the device-node
level instead of trying to mute mixer controls. On this device the
ALSA mixer control for capture gain (`numid=628`, "Adc Open") is
driver-owned — `amixer` returns "Operation not permitted" on close.
That is a dead end: the user cannot mute the gain via the mixer
interface. So the module:

1. Enumerates ALSA capture PCM nodes dynamically (walks `/dev/snd/pcmC*`
   and selects names ending in `c`; cross-checks `/proc/asound/pcm`
   for lines containing `capture`). A hardcoded fallback list of the
   known nodes on this device is used only when neither source
   produces output, so the module still covers an offline dev box.
2. For each capture node: `chmod 000 <node>` then
   `mount --bind /dev/null <node>`. The bind makes every `open()` on
   that PCM return ENXIO / "Inappropriate ioctl for device".
3. Records per-node state (original mode, bound flag) so `restore`
   can `umount` exactly what it mounted and restore the original mode.

Playback nodes (`pcmC0D0p` … `pcmC0D7p`) are **never** touched —
verified on device with `paplay -d pcm_output <file>` after the
mitigation, playback still works (rc=0).

Evidence on the device:

```
BEFORE: arecord -D hw:0,10 ... | wc -c   ->  64000 bytes
APPLY : chmod 000 /dev/snd/pcmC0D10c
        mount --bind /dev/null /dev/snd/pcmC0D10c
AFTER : arecord -D hw:0,10 ...
        -> "arecord: main:831: audio open error: Inappropriate ioctl for device"
        -> 0 bytes
PLAYBACK: paplay -d pcm_output <file>    -> rc=0
```

Status is verified actively: when `arecord` is available, the module
opens the device and requires 0 bytes (or non-zero exit) for `OK`.
If a capture succeeds, status reports `FAIL` with the byte count.
If `arecord` is missing, status falls back to the bind-mount state
and prints a warning that the active check was skipped.

The capture nodes on this device are:

```
/dev/snd/pcmC0D10c  /dev/snd/pcmC0D11c  /dev/snd/pcmC0D12c
/dev/snd/pcmC0D13c  /dev/snd/pcmC0D14c  /dev/snd/pcmC1D0c
```

This module is in the boot hook (`/var/lib/webosbrew/init.d/oyg`)
because `mount --bind` does not survive a reboot. The hook re-applies
it on every boot.

**Caveats** — this neutralisation is real but not absolute:

- It stops the ALSA capture path. It does **not** stop a kernel-level
  actor that reads the PCM nodes directly, since the kernel bypasses
  the bind. (On this device, the kernel does not provide such a path,
  so this is a theoretical limit, not an observed one.)
- `mount --bind` does not survive a reboot. Re-application is required
  after each boot — the boot hook does this. If the boot hook is
  removed or fails to run, the mitigation is lost. Status will report
  `FAIL` for every node.
- The original amixer approach was removed: it produced misleading
  `PARTIAL` output and could not mute the driver-owned gain control
  (`numid=628` `Adc Open` is driver-owned; `amixer` returns "Operation
  not permitted"). See F8 in `docs/FINDINGS.md`.

---

## Magic Remote microphone neutralisation (the `voice` module)

The LG Magic Remote's microphone is **not** an ALSA device. It is a
Bluetooth HID raw stream that arrives on `/dev/hidraw0`
(HID_NAME=`LGE MR25GA`). The pipeline that turns those bytes into
text + logs is three vendor binaries:

```
/dev/hidraw0 (HID_NAME=LGE MR25GA, mic audio)
  --> voiceinput_hidraw   (HID consumer)
  --> voiceinput          (decoder/normaliser)
  --> voiceconductor      (writes app.voice.log + NL_* events)
```

The `mic` module neutralises every ALSA capture PCM. That is correct
and necessary for any other mic on the bus (built-in arrays, USB mics),
but it does **not** touch this path — there is no ALSA device involved.
The mic button is just a HID key event (`KEY_VOICE`) on the same
`/dev/hidraw0` channel as every other Magic Remote button.

The `voice` module therefore neutralises the three consumer
**binaries** instead of the HID device:

1. For each of `/usr/sbin/voiceinput_hidraw`, `/usr/sbin/voiceinput`,
   `/usr/sbin/voiceconductor`: record the original mode, then
   `chmod 000 <binary>`, then `mount --bind /dev/null <binary>`.
   Any `exec()` of the binary now reads zeros and fails; any
   re-launcher (e.g. a respawning ls-hubd) hits the bind immediately.
2. After the binds, walk the basename of each binary, look up its
   PIDs via `pidof` (with `pgrep -x` fallback), send `TERM`, sleep,
   then `KILL` any survivors. Verified on device: all three
   processes are gone after this step.

`/dev/hidraw0` is **deliberately untouched**. The mic button press
rides the same HID channel as pointer, scrollwheel, and every other
remote button; bind-mounting `/dev/null` over `/dev/hidraw0` would
break the remote. Verified on device with the magic remote in hand:
input devices `LGE RCU`, `LGE M-RCU - Builtin [0..2]`, `LGE Simple
Premium` remain functional after the `voice` module is applied, and
the mic button continues to register as a button click — it just no
longer triggers any capture or transcription.

This module is in the boot hook (`/var/lib/webosbrew/init.d/oyg`)
because `mount --bind` does not survive a reboot. The hook re-applies
it on every boot.

**Controlled test evidence** (log watcher paused, both
`/tmp/var/log/messages` and `/tmp/app.voice.log` wiped to 0 bytes,
user pressed the mic button twice on the Magic Remote):

- `app.voice.log` stayed at 0 bytes.
- `/tmp/var/log/messages` recorded only one event:
  `lginput2 NL_BUTTON_CLICK {"remote_type":"LGE MR25GA","button_type":"KEY_VOICE"}`
- ZERO `user_utterance` lines.
- ZERO voice `NL_*` events.
- ZERO respawns of any of the three consumers within 10 s of the press.
- Audio playback (`paplay -d pcm_output <file>`) unaffected (rc=0).

This confirms the button is registered but no capture and no
transcription occur.

**Caveats** — same shape as `mic`:

- The mitigation stops the three consumer binaries. If the vendor
  extracts a new binary with a different name in a future update,
  the new name is NOT covered. Re-running `oyg list` and checking
  which binaries exist on the device is a one-line check after each
  firmware update; add any new names to `VOICE_TARGETS` in
  `modules/voice.sh`.
- `mount --bind` does not survive a reboot. The boot hook re-applies
  on every boot. If the boot hook is removed or fails to run, status
  will report `FAIL` for every binary.
- Status verifies each binary is a mount point AND that the
  corresponding process is gone. `OK` requires both.

---

## Consent + update-blocker neutralisation (the `policy` module)

The `policy` module does three jobs, all applied at every boot
because the on-device state changes on its own without any user
action.

### Job A — webOSbrew update-blocker flag

`/var/luna/preferences/webosbrew_block_updates` is a one-line flag
file. webOSbrew's own `/var/lib/webosbrew/startup.sh` checks for it
at line ~62 and, if present, bind-mounts a copy of `/etc/hosts` over
the real file with the four LG update servers appended:

```
127.0.0.1 snu.lge.com su-dev.lge.com su.lge.com su-ssl.lge.com
::1     snu.lge.com su-dev.lge.com su.lge.com su-ssl.lge.com
```

That bind runs **before** `run-parts /var/lib/webosbrew/init.d`
(line ~136), so our own `/etc/hosts` bind-mount (applied from our
init.d hook in the `network` module) stacks on top and wins. This
file is therefore a **fallback** for our own hosts-file mitigation,
not a replacement — but it covers us if our hook ever fails to run,
because webOSbrew's own mechanism will still silently sinkhole the
four update servers. Our blocklist already contains those four
domains, so on this device both layers hold the line.

### Job A2 — suppress `telnetd`

`/var/luna/preferences/webosbrew_telnet_disabled` is a second
one-line flag file. webOSbrew's own `/var/lib/webosbrew/startup.sh`
checks for it and, when **present**, skips the line that launches
`telnetd -l /bin/sh`. Without that line the telnet daemon never
starts. That is the desired state — `telnetd -l /bin/sh` is an
**unauthenticated root shell on the LAN**: no password prompt, no
banner, no log; anyone on the same network who can reach the TV gets
a root shell as soon as the daemon is up. SSH is how the operator
manages the TV, so we deliberately do not touch
`webosbrew_sshd_enabled`.

### Job B — force-decline LG consents at the source

`/var/luna/preferences/eula` is a ~5 KB JSON file of 25 `_id`
entries, each shaped like:

```json
{"updated":false,"fileName":"S_SVC_20141117001.html",
 "version":"20141117001","_id":"8275",
 "fileLocation":"/usr/palm/license/","id":"S_SVC",
 "accepted":false}
```

On this device **six are `"accepted":true`**: `S_DPA`, `S_SVC`,
`S_VNG`, `S_ADG`, `S_TAG`, `S_MKT`. They can be — and here were —
re-accepted without any user action: the state flips back when a
related component updates, when an account is re-bound, or after a
factory-reset cycle that preserves the preference file. The module
must therefore re-enforce them on every boot, which is why it is in
the boot hook alongside `capture`, `mic`, `voice`, `logs`, and
`remoteone`.

`S_VNG` is the **Viewing Information Gathering** consent — i.e. the
ACR consent — so leaving it accepted means the vendor has legal
cover to run ACR. Force-declining `S_VNG` removes that cover. It
does **not** uninstall the ACR engine: that is the `services`
module's job (`acr` + `contentminer` + `objectdetection`), and
`mic` + `voice` are what actually stop audio reaching it. The
`network` module's `/etc/hosts` bind stops the ACR endpoints from
reaching the cloud. Force-declining `S_VNG` is a consent-layer
defence that complements the engine-layer and network-layer
defences — none of them alone is sufficient.

The `policy` module:

1. Backs the file up **once** to `$OYG_BACKUP/eula.orig` and never
   overwrites it (a later flip cannot quietly corrupt the audit
   trail). `restore` puts this copy back.
2. Rewrites every `"accepted":true` to `"accepted":false` using
   `sed`. There is no `python` on the device. The pattern is
   unambiguous in this file (no nested booleans). We write to a
   temp file then `mv` — never edit in place. A JSON sanity check
   (first non-whitespace byte = `{`, last = `}`) guards against a
   pathological sed that would otherwise leave a malformed file.
   If the sanity check fails, the module restores from backup and
   exits non-zero; the on-disk file is then bit-for-bit the
   original.
3. Records `before`, `after`, and `flipped` counts in the state
   file so `status` can report what was changed on the last run.
4. Default behaviour: **decline ALL** `accepted:true` entries. This
   is the stronger posture.
5. Allow-list form: `OYG_TOS_IDS="S_VNG S_TAG"` declines only the
   named `"id"` values. Implementation is per-id sed:
   `s/"id":"S_VNG","accepted":true/"id":"S_VNG","accepted":false/`
   — safe because `"id"` immediately precedes `"accepted"` in every
   entry on this device.

**WARNINGS** — declining some of these consents gates real
features. `S_SVC`, `S_DPA`, `S_MKT` are LG service / smart-home /
market consents; declining them will disable LG account features
and may affect first-party apps. This is intentional: the owner has
root, has investigated, and prefers "no LG cloud" over "all LG
features". Decline at your own risk.

**Boot hook** — the `policy` module is in the boot hook
(`/var/lib/webosbrew/init.d/oyg`) because the consent state must
be re-enforced on every boot. `restore` removes the two flag
files and restores `$OYG_BACKUP/eula.orig` over the live file.

**Effectiveness** — `OK` when the two webOSbrew flag files both
exist AND the EULA file has zero `"accepted":true` (default mode),
or when the named allow-list entries are all `false` (allow-list
mode). A non-zero `accepted:true` count after a successful harden
means the system flipped an entry back between harden and status;
re-running the module closes the gap, which is exactly why the boot
hook does so on every boot.

---

## Router-level enforcement (the real fix for the resolver-bypass gap)

**The TV cannot filter ports.** Verified on webOS 10.3.1 / kernel 5.4.268:

| Mechanism | Result |
|---|---|
| `iptables` | fails — `ip_tables` kernel module is not shipped |
| `nft` | not present |
| `tc` | `RTNETLINK answers: Operation not supported` — no traffic-control subsystem |

So ports **443 (DoH)** and **853 (DoT)** cannot be blocked on the device itself.
The sinkholes in `etc/blocklist-oyg.txt` (dual-stack, applied to `/etc/hosts`)
only stop clients that resolve a provider **by name**; a client using a
**hardcoded DoH IP** bypasses them entirely. Note that no DoH/DoT is currently
configured anywhere on this TV, so the exposure is latent until something opts in.

Close it at the router (requires admin on the gateway):

1. **Reserve a DHCP lease** for the TV so its address is stable.
2. **Add outbound rules for the TV's IP/MAC:**
   - `DROP tcp/udp 853` — kills DoT outright, low risk.
   - `DROP tcp/udp 53 except to <your resolver>` — optional, strongest.
   - `DROP tcp/udp 443` to the **known DoH IPs** (resolve `dns.google`,
     `cloudflare-dns.com`, `dns.quad9.net`, `doh.opendns.com`,
     `dns.adguard.com`, `dns.nextdns.io` first).
3. **Set the DHCP-advertised DNS** to a resolver you control (Pi-hole /
   AdGuard Home on the LAN), so the TV's plain DNS is filtered and DoT/DoH
   have nothing to escape to.

**Trade-off / rollout order:** blocking `443` to DoH IPs can break unrelated
services that share those addresses (Cloudflare-fronted sites). Start with
**853 only**, confirm nothing breaks, then add DoH IPs one at a time.

### What remains unfixable on-device

- Port-level filtering of any kind (above).
- A hardcoded DoH endpoint, if something ever ships one.
- A root-level actor, or a firmware update, which bypasses every control here.

---

## Layout

```
own-your-glass/
├── oyg                       main CLI (POSIX sh)
├── install.sh                install onto device
├── uninstall.sh              restore + remove
├── lib/common.sh             logging, run, backup, state, require_root, dry-run
├── modules/                  one .sh per module
│   ├── services.sh
│   ├── capture.sh
│   ├── debloat.sh
│   ├── apps.sh
│   ├── mic.sh
│   ├── voice.sh
│   ├── logs.sh
│   ├── network.sh
│   ├── perms.sh
│   ├── remoteone.sh
│   └── policy.sh
├── etc/
│   ├── blocklist-oyg.txt           operator-curated SAFE/STRICT sections
│   └── blocklist-upstream-safe.txt CC BY 4.0 snapshot of upstream SAFE list
├── scripts/refresh-blocklist.sh    re-fetch upstream (off-device only)
├── scripts/notify.sh              send a native webOS toast to the TV (on-device or via ssh)
├── scripts/sniff.sh               on-device packet sniffer (AF_PACKET + ETH_P_ALL, no libpcap)
├── scripts/sniff.py               the sniffer itself (stdlib only); --pcap FILE exports a Wireshark-readable capture
├── scripts/dnssink.py             on-device DNS sinkhole resolver (stdlib only) — UDP + TCP on 127.0.0.2:53, suffix-matches /var/lib/own-your-glass/hosts
├── scripts/dns.sh                 operator entry point: start|apply|ensure|confirm|revert|stop|status|log|test — hooks the resolver in via a /etc/resolv.conf bind-mount (never touches ConnMan; auto-revert timer on apply)
├── scripts/watch-dns.sh           watchdog: re-asserts the resolv.conf override, restarts the resolver on death, reverts the override if it cannot come back
└── docs/FINDINGS.md           finding → countermeasure → effectiveness table
```

---

## Boot persistence

`install.sh` drops a single executable at
`/var/lib/webosbrew/init.d/oyg`. **The filename must not contain a
dot** — the directory is executed at boot by `run-parts`, which
ignores dotfiles. The hook re-invokes hardening on every boot, but
defers gracefully if the network is not yet up.

At boot the hook:

1. Waits up to 30s for a default route. If none appears, network-
   dependent modules are skipped and a warning is logged.
2. Re-applies `capture`, `mic`, `voice`, `logs`, `remoteone`,
   `apps`, `policy` (safe modules). The `capture` re-apply also re-establishes
   the bind-mount on `/usr/bin/vtCaptureTestSuite`, since
   `mount --bind` does not survive a reboot — and re-tightens
   `/tmp/capture.rgb` via the watcher. The `voice` re-apply
   re-establishes the bind-mounts over the Magic Remote mic
   pipeline binaries (`voiceinput_hidraw`, `voiceinput`,
   `voiceconductor`); `/dev/hidraw0` is deliberately untouched
   because the mic button rides the same HID channel as every other
   remote button (see `mic` and `voice` module sections below).
   The `apps` re-apply re-merges the curated blocked-app IDs into
   `blockedSystemAppList/<REGION>.json` because the application
   manager may rewrite that file on its own (see the `apps` module
   section below). The `policy` re-apply re-touches the webOSbrew
   update-blocker AND telnet-disable flags and re-declines the LG
   consent entries in `/var/luna/preferences/eula` (the system
   silently re-accepts them on component updates; see `policy`
   module section below).
3. Reads `/var/lib/own-your-glass/services.stopped` (one unit per
   line) and `systemctl stop`s each entry, then reads
   `/var/lib/own-your-glass/services.kill` (one process name per
   line) and `kill -TERM`s (then `-KILL` if needed) each matching
   PID. This is the `services` module's enforcement:
   `systemctl mask` is impossible on this device (read-only `/etc`),
   so the model is "stop unit + kill process, and repeat on every
   boot". The hook is tolerant of a missing file, of services that
   are already inactive, and of processes that aren't running. Each
   action is logged to `boot.log`.
4. If `$OYG_ROOT/state` shows `network.applied=1`, re-applies the
   network module (which re-applies layer 1 — the `/etc/hosts` bind
   mount — and layer 2 — the resolver blackholes). Layer 3 is
   re-applied only if the state also shows `network.ipblock=1`. Layer 4   (the on-device sinkhole resolver, hooked in via a
   `/etc/resolv.conf` bind-mount) is re-applied only if state has
   `network.dns_resolver=1`; the boot hook exports `OYG_DNS_RESOLVER=1`
   so layer 4's harden path takes effect. `dns.sh start` brings the
   resolver up and VERIFIES it before mounting the override, so boot-time
   lookups never fail (until then resolv.conf is ConnMan's own). The hosts
   file's mtime is watched by the running resolver, so an
   `oyg harden --only network` after editing blocklists picks them up
   without a restart. All opt-in flags are re-derived from the state file
   so the boot environment doesn't need to know about them. **If Variant C
   is active** (`dns.bind` = `127.0.0.1` and `connman.sh.patched` exists),
   the hook first re-applies the patched connman launcher (the bind-mount
   dies at reboot) and restarts connmand so the proxy stays off — at boot
   this is safe, nothing is using the network yet — then waits up to 90 s
   for Wi-Fi before layer 4 starts.
5. If `$OYG_ROOT/state` shows `perms.applied=1`, re-applies the
   `perms` module (chmods webOSbrew hbchannel + Google Home runtime
   paths). The opt-in flag (`OYG_AGGRESSIVE=1`) is re-exported from
   state so the boot environment does not need it. The block runs
   regardless of network availability — `perms` is purely local. The
   operator opts in once via `OYG_AGGRESSIVE=1 oyg harden --only
   perms` after install; `install.sh` does not run that command for
   them. Re-applying on every boot is required because webOSbrew
   updates may re-extract those paths in mode 0777 between boots,
   restoring the local privilege-escalation path that `perms` exists
   to close.

---

## Attribution

This toolkit builds on the work of others. Specific credit:

- **Blocklist** — `etc/blocklist-upstream-safe.txt` is a vendored snapshot of
  [furkan-bayrak/lg-tv-blocklist](https://github.com/furkan-bayrak/lg-tv-blocklist),
  retrieved 2026-09-14. The upstream list is licensed **CC BY 4.0**;
  attribution to the upstream author is preserved in the file's header.
  Refresh with `scripts/refresh-blocklist.sh` (always off-device).
- **Rooting** — webOSbrew / rootmy.tv provide the homebrew channel used
  to gain the root access this toolkit assumes you already have.

---

## License

This project — code, configuration, and prose — is released under the
**MIT License**. See the [`LICENSE`](./LICENSE) file at the repository root.

The vendored blocklist *data* in `etc/blocklist-upstream-safe.txt` is a
snapshot of upstream work and **remains under its original CC BY 4.0
license**; attribution to the upstream author is preserved in the
file's header and must be carried with any redistribution of the
blocklist contents.

---

## Disclaimer

- **Never flash the kernel or rootfs.** See the upstream rootmy.tv
  warning — flashing system partitions can permanently brick the
  device. This tool does not flash anything and never writes a system
  partition; it only bind-mounts over user-writable paths (or vendor
  paths that `mount --bind` can legally target) and stops processes.
- **Everything is reversible.** `oyg restore` (or `uninstall.sh`) puts
  the device back to the pre-install state.
- **For hardware you own.** Root access and OS-level hardening are
  legitimate on a device you own, but may void your warranty and may
  violate terms of service in your jurisdiction. Run at your own risk.
- **Not a root-level defence.** Anyone with root on the device can
  undo every change here in seconds. The defender-of-root is firmware
  integrity and boot-chain validation, which this tool does not touch.
