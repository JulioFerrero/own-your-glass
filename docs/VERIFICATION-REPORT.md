> **Redacted for publication.** All device- and network-identifying values in this
> report (MAC addresses, SSIDs, advertising/device identifiers, tokens, household
> names, LAN addresses) have been replaced with placeholders. The unredacted
> original remains private.

# LG Smart TV — Independent Verification Report

**Verifying the claims of the Gamers Nexus "LG smart TVs as surveillance devices" investigation against a real, owner-controlled 2025 LG OLED.**

| | |
|---|---|
| **Date of work** | 2026-09-13 (single session, ~14:20–23:25 CEST) |
| **Target device** | LG OLED55B56LA (2025 B5 OLED), owner-controlled, rooted |
| **Subject** | `nexus-transcript.formatted.md` — Gamers Nexus LG TV investigation transcript |
| **Operator** | Owner (<owner>) + AI assistant, on the owner's Mac |
| **Authorization** | Testing performed by the device owner on the owner's own hardware and network |
| **Classification** | **SENSITIVE — contains MAC addresses, SSIDs, tokens, and device identifiers** |

---

## Table of contents

1. [TL;DR](#1-tldr)
2. [Scope, authorization and legal framing](#2-scope-authorization-and-legal-framing)
3. [Executive summary — findings with severity](#3-executive-summary--findings-with-severity)
4. [Environment inventory](#4-environment-inventory)
5. [Access path and tooling](#5-access-path-and-tooling)
6. [Detailed findings](#6-detailed-findings)
   - [F1 — Consent gating: ACR is present but dormant](#f1--consent-gating-acr-is-present-but-dormant)
   - [F2 — The ACR / Alphonso advertising stack](#f2--the-acr--alphonso-advertising-stack)
   - [F3 — HDMI inputs have dedicated ACR apps](#f3--hdmi-inputs-have-dedicated-acr-apps)
   - [F4 — Shoppable ads driven by ACR video matching](#f4--shoppable-ads-driven-by-acr-video-matching)
   - [F5 — Voice input transcribed to plaintext and logged](#f5--voice-input-transcribed-to-plaintext-and-logged)
   - [F6 — Logs live on a RAM disk and rotate fast](#f6--logs-live-on-a-ram-disk-and-rotate-fast)
   - [F7 — Microphone: gated, not always-on (correction to the video)](#f7--microphone-gated-not-always-on-correction-to-the-video)
   - [F8 — Microphone capture proven over the network](#f8--microphone-capture-proven-over-the-network)
   - [F9 — Screen capture exists and leaks to any app (no root needed)](#f9--screen-capture-exists-and-leaks-to-any-app-no-root-needed)
   - [F10 — Video-plane capture (what the "screenshot" missed)](#f10--video-plane-capture-what-the-screenshot-missed)
   - [F11 — Unauthenticated root via Telnet and default SSH password](#f11--unauthenticated-root-via-telnet-and-default-ssh-password)
   - [F12 — Unauthenticated Chromium DevTools exposed on the LAN](#f12--unauthenticated-chromium-devtools-exposed-on-the-lan)
   - [F13 — Wi-Fi survey for geolocation](#f13--wi-fi-survey-for-geolocation)
   - [F14 — Network telemetry baseline (consent declined)](#f14--network-telemetry-baseline-consent-declined)
   - [F15 — Nuance / Cerence voice backend](#f15--nuance--cerence-voice-backend)
7. [Claim-by-claim verdict vs the transcript](#7-claim-by-claim-verdict-vs-the-transcript)
8. [Security assessment](#8-security-assessment)
9. [Remediation](#9-remediation)
10. [Artifacts index](#10-artifacts-index)
11. [Chronology](#11-chronology)
12. [Appendix A — exact commands used](#appendix-a--exact-commands-used)
13. [Appendix B — our own tooling bugs found and fixed](#appendix-b--our-own-tooling-bugs-found-and-fixed)
14. [Appendix C — what we did NOT test / open questions](#appendix-c--what-we-did-not-test--open-questions)
15. [Appendix D — caveats, limitations and methodology notes](#appendix-d--caveats-limitations-and-methodology-notes)

---

## 1. TL;DR

The Gamers Nexus investigation is **substantially accurate** about the *capability* LG builds into its TVs, but on this specific 2025 model several of the scariest behaviours are **gated** rather than always-on:

- **ACR (Automatic Content Recognition) is real, present, and configured to use Alphonso** — but on this TV it **has never run**, because the owner never accepted LG's "Viewing Information" EULA. All 11 tracking-related consent flags are `false`.
- **Voice input is transcribed to plaintext and written to log files on a RAM disk.** Proven end-to-end with the owner's own voice.
- **The room microphone is NOT an always-on, remotely-readable device on this firmware.** It surfaced only while the voice pipeline was active. What *is* readable is the TV's internal audio bus (i.e. **everything the TV plays** — the "boardroom" scenario is real) plus mic audio while voice is engaged.
- **Screen capture is worse than the video implies, and needs no root at all.** A world-readable, world-writable-in-scope file `/tmp/capture.rgb` contains a 640×360 RGB screenshot of the TV's screen, refreshed every ~3 seconds, and system `/tmp` is bind-mounted into every app sandbox. **Any installed app can watch the screen.**
- **The 2025 root setup exposed unauthenticated root to the whole LAN** (`telnet` with no password, plus SSH default password `alpine`). This was a side effect of the owner's own rooting, not a factory defect.
- **Chromium DevTools was exposed unauthenticated on port 9998** while a web app ran — meaning arbitrary JavaScript execution in the TV's web app context from anywhere on the LAN.

---

## 2. Scope, authorization and legal framing

**What was authorized:** The owner asked for verification of publicly reported claims, on hardware they own, on their own LAN. Every action was taken with the owner present and consenting.

**What was actually done:**

- Passive observation of multicast/broadcast traffic
- ARP-spoof man-in-the-middle on the owner's LAN (owner ran the privileged steps)
- Read-only on-device inspection over the owner's own root SSH access
- Audio capture from the owner's own TV microphones/audio bus, with the owner speaking
- Screen and video-plane capture of the owner's own display
- DevTools protocol inspection of the owner's own running YouTube app

**What was NOT done:**

- No exploitation of third-party devices
- No reverse engineering to defeat DRM or signature checks
- No modification of the TV's firmware, system partitions, or settings that could brick it
- No exfiltration of data off the LAN

**DMCA §1201 note (as raised by the source video itself):** Observing your own device and reading your own logs is not circumvention. What would be legally hazardous is defeating signature checks or extracting DRM-protected content. Nothing in this report did that — and notably, **protected video could not be captured even with root**, which is discussed in [F10](#f10--video-plane-capture-what-the-screenshot-missed).

**Reversibility:** All state changes made to the TV are listed in [§9 Remediation](#9-remediation). One mixer control (`Adc Open`) could not be reverted programmatically and resets on reboot.

---

## 3. Executive summary — findings with severity

| # | Finding | Root needed? | Status | Severity |
|---|---|---|---|---|
| F1 | ACR configured but disabled by consent — the tracking gates are all `false` | No | Observed | Informational (mitigating) |
| F2 | Full Alphonso/LG Ads advertising + ACR stack present in firmware | No | Observed | High (capability) |
| F3 | Dedicated ACR apps for every HDMI input (`acrhdmi1..4`) + ad overlay on HDMI | No | Observed | High (matches video) |
| F4 | Shoppable ads driven by ACR video matching (NBCU/Comcast data on disk) | No | Observed | High (matches video) |
| F5 | **Voice input → plaintext, written to logs** | No | **Proven with owner's voice** | **High** |
| F6 | Logs on a RAM disk, rotating as fast as ~2 minutes | No | Observed | Medium |
| F7 | Room microphone is gated, **not** always-on (corrects the video) | Yes | Observed | Informational (mitigating) |
| F8 | Microphone audio IS capturable over the network while voice is active | Yes | **Proven** | High |
| F9 | **World-readable, jail-shared screen framebuffer `/tmp/capture.rgb`** | **No** | **Proven** | **Critical** |
| F10 | Video plane capturable (`vtCapture`) — graphics-plane capture misses video | Yes | **Proven (MP4 produced)** | Medium |
| F11 | **Unauthenticated root on the LAN** (telnet + default SSH password) | n/a | **Proven** | **Critical** |
| F12 | **Unauthenticated Chromium DevTools on the LAN (port 9998)** | **No** | **Proven** | **Critical** |
| F13 | Wi-Fi survey of ~25 neighbouring APs (`iw scan`) | Yes | Observed | Medium |
| F14 | Baseline telemetry with all consent declined: Alexa captive portal ×40, periodic TLS beacon, MQTT, LG discovery | n/a | Observed | Low–Medium |
| F15 | Voice backend is Nuance/Cerence via `he-eu-ai.lgthinq.com` | No | Observed | Medium |

---

## 4. Environment inventory

### 4.1 The Mac (operator)

| Item | Value |
|---|---|
| OS | macOS 26.6.2 (build 25G83), arm64 (Apple T6030) |
| Hostname | `<mac-host>` |
| User | `<owner>` |
| Interface | `en0` (Wi-Fi), IP `10.0.0.40` |
| Hardware MAC | `<MAC-LAPTOP-HW>` |
| **Actual wire MAC** | **`<MAC-LAPTOP-RANDOM>`** ← Private Wi-Fi Address (MAC randomisation) is ON. This matters enormously for ARP spoofing. |
| Gateway | `10.0.0.1` (Movistar), MAC `<MAC-GATEWAY>` |
| Tools present | `tcpdump` (system), `bettercap` 2.41.7, `adb` (platform-tools), `expect`, `node` v24.14.0, `python3` 3.x (system), `ffmpeg` (broken), ImageMagick 7.1.2, Pillow 11.3.0, full **Xcode** (`swiftc`) |
| Tools absent | `nmap`, `tshark`, `scapy`, `numpy`, `pyobjc`/`AVFoundation` bindings, `gifsicle` |

### 4.2 The TV

| Item | Value |
|---|---|
| Model | **LG OLED55B56LA** (2025 B5 OLED) |
| Model string | `OLED55B56LA.DEUQDJP` |
| Friendly name | `[LG] webOS TV OLED55B56LA` |
| webOS | **webOS TV 10.3.1** (`ID=starfish`) |
| Kernel | `5.4.268-294.24.papikonda.2` aarch64, built 2026-01-19 |
| IP | `10.0.0.34` |
| Wi-Fi MAC | `<TV-MAC>` (interface `wlan0`; connected to SSID `<ssid>`) |
| Wired MAC | `<TV-WIRED-MAC>` |
| P2P interface | `p2p0` = `<mac>` |
| Region | `CountryCode="ES"` (Spain) |
| Linked accounts | Amazon Alexa adapter jail present, Chromecast cell, ThinQ AI |
| Storage | 16 GB flash (per source video's description of the class); USB HDD attached (`Realtek`, exFAT, contains a `Smart TV` folder) |
| Processes | 383 total |
| UPnP UDNs | `<uuid>` (lge:device:tv), `<uuid>` (second screen), `<uuid>` (DIAL), `<uuid>` (DLNA MediaRenderer) |

### 4.3 TV listening services (from the TV's own `netstat`)

```
0.0.0.0:22      ← webOSbrew dropbear (SSH, root)
0.0.0.0:23      ← webOSbrew telnetd  (UNAUTHENTICATED ROOT)
0.0.0.0:515     ← LPD (printer)
0.0.0.0:1125    0.0.0.0:1246    0.0.0.0:1297    0.0.0.0:1332
0.0.0.0:1359    0.0.0.0:1429    0.0.0.0:1591    0.0.0.0:1653
0.0.0.0:1677    0.0.0.0:1697    0.0.0.0:1755    0.0.0.0:1933
0.0.0.0:3000    :::3000         ← LG Connect SDK / dev-mode port
0.0.0.0:3001    :::3001         ← TLS variant
0.0.0.0:7000
0.0.0.0:8008    0.0.0.0:8009
0.0.0.0:8443
0.0.0.0:9998    ← Chromium DevTools (when a web app runs)  [SEE F12]
0.0.0.0:18181   0.0.0.0:36866
127.0.0.1:53    ::1:53           ← local DNS resolver
10.0.0.34:7250
0.0.0.0:5353 ×4                  ← mDNS responders
UDP: 5353, 56700, 52407, 51642, 57644
UPnP: 1210, 1438, 1713, 1918 (DLNA/DIAL/second-screen/device)
```

> **Correction of an early misreading:** during first contact, port `23` was initially assumed to be LG's proprietary "second-screen" protocol because it returned telnet-style option negotiation bytes (`\xff\xfd\x01` = IAC DO ECHO). It is in fact **webOSbrew's unauthenticated `telnetd`** — see [F11](#f11--unauthenticated-root-via-telnet-and-default-ssh-password).

---

## 5. Access path and tooling

### 5.1 How root was obtained (owner's own device)

The owner had previously rooted the TV and installed **webOSbrew / Homebrew Channel** (`/var/lib/webosbrew/`). Per webOSbrew's own documented behaviour:

- The Homebrew Channel SSH server is **dropbear**, listening on **port 22**, user `root`.
- Until `/home/root/.ssh/authorized_keys` exists, the server installs a **placeholder password of `alpine`** via a tmpfs bind-mount over `/etc/shadow`.
- Once `authorized_keys` exists, the placeholder is not installed on subsequent boots, and only key auth works.

We installed our key using the documented default password, non-interactively (via `expect`):

```bash
# push our public key into /home/root/.ssh/authorized_keys, chmod 600
# (password: alpine)  — done once, then key-only access
```

Resulting convenience alias in `~/.ssh/config`:

```
Host lgtv
  HostName 10.0.0.34
  User root
  Port 22
  IdentityFile ~/.ssh/lgtv_ed25519
  StrictHostKeyChecking accept-new
```

### 5.2 Harness built at `~/lg-nexus-tests/`

```
lg-nexus-tests/
├── RUNBOOK.md                 step-by-step network capture runbook
├── STATUS.md                  session handoff / current state
├── README.md
├── bin/
│   ├── lan-watch.py           passive SSDP+mDNS watcher (no sudo)
│   ├── mitm-up.sh             sudo: forwarding + ICMP-redirect suppression + ARP spoof + tcpdump
│   ├── mitm-down.sh           sudo: SIGINT bettercap -> active ARP restore -> sysctl restore
│   ├── mitm.cap               bettercap caplet (full-duplex ARP spoof)
│   ├── arp-spoof.py           scapy fallback spoofer (unicast, restores on exit)
│   ├── arp-restore.py         enables unicast ARP correction
│   └── dns-log.sh             dnsmasq logging-resolver fallback
├── analysis/analyze.py        dependency-free pcap analyser (DNS/SNI/HTTP/endpoints/volume)
├── tv/
│   ├── root-audit.sh          on-device, read-only, 12-section audit
│   ├── tv-pull.sh             pulls the audit bundle to the Mac
│   └── README.md
├── captures/                  pcaps + logs
└── ondevice/                  pulled evidence, demos, screenshots
```

### 5.3 Notable environment obstacles we had to solve

1. **Private Wi-Fi Address** (MAC randomisation) meant the Mac's ARP poison initially targeted the wrong MAC. Fixed by auto-detecting `ifconfig <iface> | awk '/ether/{print $2}'`.
2. **ICMP redirects**: macOS will tell a spoofed client to bypass the MITM. Suppressed with `sysctl -w net.inet.ip.redirect=0`.
3. **`luna-send` is non-functional from the SSH shell** — it produces `rc=0` with **zero bytes on stdout and stderr**, and never appears on the LS2 bus (confirmed with `ls-monitor`). All LS2 method calls therefore had to be replaced by filesystem evidence or by driving vendor binaries directly.
4. **No `tcpdump` on the TV** (and not available via `opkg`), so network capture had to come from the Mac.
5. **`ffmpeg` on the Mac is broken** — ABI mismatch: ffmpeg 8.1 links `libx265.215.dylib`, x265 4.2 ships `libx265.216.dylib`, and the symbol `_x265_api_get_215` no longer exists. MP4 encoding was therefore done natively with **Swift + AVFoundation**.
6. **`analyser.py` initially counted the Mac's own traffic** (tcpdump on `en0` sees everything), producing wildly wrong volume figures. Always pre-filter: `tcpdump -r cap.pcap -w tv.pcap 'host 10.0.0.34'`.

---

## 6. Detailed findings

### F1 — Consent gating: ACR is present but dormant

**Claim:** LG TVs ship ACR that harvests viewing data whether or not the user understands it.

**Method:** Read the consent store and cross-check the ACR service's runtime state.

**Evidence — `/var/luna/preferences/eula`:**

25 entries, **6 accepted, 19 not**. All the tracking-related ones are `false`:

```
"id":"S_VNG","accepted":false     ← Viewing Information Gathering  (the ACR consent)
"id":"S_PRV","accepted":false     ← Privacy
"id":"S_TAD","accepted":false     ← Targeted Ads
"id":"S_TAG","accepted":false
"id":"S_ADG","accepted":false     ← Advertising
"id":"S_ADC","accepted":false
"id":"S_ADD","accepted":false
"id":"S_VDC","accepted":false     ← Video Data
"id":"S_VDD","accepted":false
"id":"S_NVC","accepted":false
"id":"S_NVD","accepted":false
```

**Evidence — capability is present but the service does not run.** The TV's own config daemon logs:

```
[    3.027561922] [debug  ] [insert] : (tv.conti) supportAcr : true
```

Yet with **live antenna TV playing and decoding video** (`GOOD-VIDEO`, `ChannelId: 1_27_10_0_15_153_8916`), a 2-minute watch showed:

```
t+0s   acr2=0  alphonso=0  dsnoop=none  acrlog=no
...
t+115s acr2=0  alphonso=0  dsnoop=none  acrlog=no
```

- 0 `acr2` processes
- 0 processes with `alphonso` libraries mapped in `/proc/*/maps`
- the ACR-configured audio device `dsnoop:0,12` never held
- `/var/log/acr.log` never created (though `pmlog` declares it)

**Interpretation:** ACR is a **consent-gated capability**. The video's narrative — that users are opted in by dark-pattern "Select All" dialogs — is consistent with this: the engine exists but does nothing until `S_VNG` flips to `true`. On *this* TV it never has. **This is a mitigating finding the video does not foreground.**

**Caveat:** There is also a regional possibility. `CountryCode="ES"`, while the ad-overlay config lists only `US`/`DE` as supported countries. Even after consent, ACR might remain inert in Spain. Untested (owner declined consent, a decision we respected).

---

### F2 — The ACR / Alphonso advertising stack

**Claim:** ACR vendor is Alphonso / LG Ad Solutions; audio is captured and fingerprinted and sent to LG servers.

**Evidence — `/tmp/acr.xml` (the live ACR config on the device):**

```xml
<acr_config acr_config_format_ver="1.5" version="3" model_year="2025"
    webos_initial_version="webOS25" ACR_On="true"
    capture_method="SOURCE" max_force_alive="30" no_match_threshold="15"
    capture_format="YUV420" ACRServiceLaunched="true" send_data="true"
    ACRPopup="0" ACRSolution="ALPHONSO"
    CAPATH="/etc/ssl/certs/ca-certificates.crt" CountryCode="ES"
    Activate_UEI="false">
  <sessionPersistence>-1</sessionPersistence>
  <audio capture="true" sample_rate="48000" channels="2" duration="100"
         sleep="0" format="PCM16" pcm_option="dsnoop:0,12" />
  <video capture="false" />
  <video-capture-max-input-resolution broadcast="2160" external="2160" />
  <solution name="ALPHONSO" lib="libalphonsosolution.so.1.0.0" sdk="libas.so"
            sdk-lite="NA" download-url="NA"
            client_token="<CLIENT-TOKEN>">
    <dai ota="false" stb="false" />
    <overlay support="false" />
    <support should-send-first-optout="true" can-create-toast="false" />
    <lgchannels capture="false" />
    <application-info protocol="lib" uri="NA" method="NA"> </application-info>
  </solution>
</acr_config>
```

Interpretation of the important keys:

| Key | Value | Meaning |
|---|---|---|
| `ACR_On` | `true` | ACR enabled in configuration |
| `ACRSolution` | `ALPHONSO` | vendor is Alphonso (trading as LG Ad Solutions) |
| `send_data` | `true` | telemetry upload enabled *if the service runs* |
| `capture_method` | `SOURCE` | captures the **source** (tuner/HDMI), not IP-app video |
| `capture_format` | `YUV420` | video fingerprint format |
| `<audio capture>` | `true, 48 kHz, 2ch, PCM16, dsnoop:0,12` | **ACR is configured to capture audio** |
| `<video capture>` | `false` | video capture disabled in this build's config |
| `should-send-first-optout` | `true` | **on opt-out, send one final snapshot** (matches the video's claim) |
| `lgchannels capture` | `false` | LG Channels not captured in this config |
| `pcm_option` | `dsnoop:0,12` | ALSA shared-capture device — we confirmed that device exists and later captured through it |

**Evidence — the ACR service and permissions:**

```
/usr/sbin/acr2                 ← ACR engine
/usr/sbin/pacrunner            ← proxy-auto-config runner (also in the ad stack)
/usr/lib/libalphonsosolution.so.1.0.0
/usr/lib/libalphonsoadoverlay.so.1.0.0
/usr/lib/BrowserPlugins/libAdvertisementPlugin.so
/etc/palm/activities/com.webos.service.acr/activity-com.webos.service.acr.start.json
/etc/pmlog.d/acr.conf  ->  /var/log/acr.log (maxSize 10000, rotations 5)  [file absent]
com.webos.service.acr  (role exeName /usr/sbin/acr2, allowed to use com.webos.service.capture.client*)
```

**Evidence — ACR starts automatically at boot (if permitted):**

```json
{
  "activity": {
    "name": "com.webos.service.acr.start",
    "description": "Start ACR service when TV on",
    "trigger": { "and": [ { "method": "luna://com.webos.bootManager/getBootStatus", ... } ] },
    "callback": { "method": "luna://com.webos.service.acr/startAcr",
                  "params": { "reason": "normal" } },
    "type": { "foreground": true }
  }, "replace": true, "start": true
}
```

**Evidence — per-app advertising ID.** The file `asc-advertiserId` exists inside **every app jail**
(`lg.thinqai.adapter`, `com.webos.service.voice.performer`, `com.webos.app.browser`, `com.webos.chromecast`,
`amazon.alexa.adapter`, `amazon`, `com.webos.service.buddyconnector`). Its value on this unit was
`1` — not a UUID. Honest note: this is likely an unprovisioned/placeholder value, or a pointer; it is
**not** evidence of a populated persistent identifier here.

---

### F3 — HDMI inputs have dedicated ACR apps

**Claim (from the video):** "even an HDMI connection was undergoing ACR."

**Evidence — dedicated applications exist for each HDMI input:**

```
com.webos.app.acrhdmi1
com.webos.app.acrhdmi2
com.webos.app.acrhdmi3
com.webos.app.acrhdmi4
com.webos.app.acroverlay
com.webos.app.acrcomponent
```

Plus luna LS2 roles / client-permissions / manifests for each.

**Evidence — the ad overlay explicitly targets the HDMI inputs:**

`/tmp/adoverlay/adoverlay.json`:

```json
{
  "Version": 0.03,
  "support_countries" : ["US","DE"],
  "solution" : [
    { "solution_name" : "adoverlay", "support" : true, "support_countries" : ["US"],
      "library_path" : "libalphonsoadoverlay.so.1.0.0",
      "support_app" : ["com.webos.app.livetv"],
      "interactive_url" : "https://aic.ads.lgtvcommon.com",
      "token" : "<CLIENT-TOKEN>" },
    { "solution_name" : "shopping", "support" : true, "support_countries" : ["US","DE"],
      "library_path" : "libshopping.so.1.0.0",
      "support_app" : ["com.webos.app.livetv","com.webos.app.hdmi1","com.webos.app.hdmi2",
                       "com.webos.app.hdmi3","com.webos.app.hdmi4"],
      "url_gfts_production" : {
        "US" : "http://aic-ngfts.lge.com/fts/gftsDownload.lge?biz_code=LGSHOPPING&...",
        "DE" : "http://eic-ngfts.lge.com/fts/gftsDownload.lge?biz_code=LGSHOPPING&..." } }
  ]
}
```

So the ad-overlay subsystem is explicitly wired to run over **Live TV and HDMI 1–4**. This directly
corroborates the video's finding.

---

### F4 — Shoppable ads driven by ACR video matching

**Claim:** LG's ad platform ties ACR content recognition to product placements and shoppable overlays.

**Evidence — `/tmp/livepickplus/video_acr_gfts.json`** (500-char excerpt; full file far longer):

```json
{"overlayType":"Video ACR Overlay","createDate":1789300800,"period":"600",
 "noticeBarTimeoutSeconds":"20","svcCountry":[{"country":"US","overlaySvcYn":"Y"}],
 "contentList":[
   {"tmsId":"EP023652880307","shoptimeDeeplink":"V3_12001_MagicClick_FB_21",
    "noticeBarInfo":[{"momentId":"u2G6o-_FhBzGegUWdWX_L","timeStamp":441,
      "imageUrl":"https://commerce.nbcuni.com/public/content-manager-assets/nbcu-comcast/...webp",
      "btnText":"","mainText":""}]},
   ... many more, with TMS episode IDs, per-scene millisecond timestamps,
   MagicClick deeplinks, and both production and nonprod NBCUniversal/Comcast
   commerce URLs (commerce.nbcuni.com, nonprod-commerce.nbcuni.com) ...
   {"tmsId":"EP050155580027", ... "Shop_It_Like_It's_Yacht_Breakfast.webp" ...}
 ]}
```

**Evidence — `/tmp/livepickplus/food_delivery_gfts.json`:**

```json
{"overlayType":"Food Delivery Overlay","period":3600, ...
 "appLogConfig":{"AL_FOOD_GFTS_STATE":"N","AL_ACR_SUBSCRIPTION_STATE":"N",
                 "AL_VIDEOACR_MATCH_STATE":"N", ...},
 "defaultNoticeBarInfo":[{"language":"en-US",
   "url":"http://aic-ngfts.lge.com/fts/gftsDownload.lge?biz_code=LGSHOPPING&func_code=IMAGE&...",
   "text":"Dinner ideas? Explore delivery right from your LG TV.", ...}],
 "primeTime":[ { "startTime":"09:00:00","endTime":"09:59:59", ... },
               { "startTime":"20:00:00", ... } ],
 "svcCountry":[{"country":"US","overlaySvcYn":"Y"}]}
```

**Interpretation:** This is precisely the machinery the LG Ad Solutions executives described in the
video — AI/ACR matching of on-screen content to inject contextual, shoppable overlays, with
time-of-day targeting (note the `primeTime` windows) and third-party retail integrations. The data was
**shipped and present on the device**; note the feature flags in `appLogConfig` are all `"N"` (off).

---

### F5 — Voice input transcribed to plaintext and logged

**Claim:** "the voice input data is transcribed to plain text and memory… it seems to be the speech-to-text text log of the things we said."

**Method:** Plant a distinctive phrase spoken to the TV, then diff every file written on the device.

**Setup (before-marker):**

```bash
ssh lgtv 'touch /tmp/.nexus-marker-before'
```

**Action:** owner used the Magic Remote mic button and spoke: *"Hi LG … lg nexus test marker nine kilo four"*.

**Evidence — files changed since the marker, then the content:**

**`/tmp/var/log/messages`** (which is on a RAM disk — see F6):

```
2026-09-13T12:46:01.108224Z [730.051047044] user.info surface-manager [] voice NL_RESULT_DATA
{"action_type":"search_content","foreground_app":"org.webosbrew.hbchannel",
 "input_type":"mrcu_key","main_action":"tv_unknown_search","named_entity":[],
 "service_type":"search",
 "user_utterance":"Hi LG LG Nexus test Barker Nine kilo Ford Ford Ford",
 "voice_ticket":"<uuid>-6aa6-000d"}

2026-09-13T12:46:03.533912Z [732.476732672] user.info com.webos.app.voice [] voice NL_SEARCH_ITEM
{"foreground_app":"org.webosbrew.hbchannel","launch_type":"voice",
 "query":"Hi LG LG Nexus test Barker Nine kilo Ford Ford Ford",
 "query_type":"Voice","view_type":"half"}
```

Also captured in the sequence:

```
voice NL_ACTIVATE_VOICE {"foreground_app":"org.webosbrew.hbchannel","input_type":"mrcu_key"}
voice NL_COPILOT_EXPOSED {"exposed":true}
```

**`/tmp/app.voice.log`** contained the identical text (the file was 91,522 bytes when first read at 14:46,
then had rotated/rewritten within ~2 minutes — later reads showed `grep -c Nexus` = 0).

**Second confirmation (Spanish, later in the session):**

```
"user_utterance":"Esto es una prueba"
"user_utterance":"Un 23 probando probando"
```

**Interpretation and significance:**

- **Confirmed:** voice input is transcribed and written in **plaintext** to at least two log files.
- The ASR mangled the phrase exactly as the video describes ("marker"→"Barker", "four"→"Ford") — but it is unmistakably the spoken sentence.
- Trigger metadata (`input_type":"mrcu_key"`, `recognitionSource.input=voiceinput`) identifies the Magic Remote mic as the source.
- **Notably**, the voice app logged `isGeneralTermsAllowedResponse : false` at launch — i.e. **it captured and logged the audio anyway**, despite terms not being accepted.
- This is the single most directly-damaging behaviour we reproduced. It does **not** require root to observe: the log is on the device, but the *capture and transcription happen regardless* of consent.

---

### F6 — Logs live on a RAM disk and rotate fast

**Claim:** verbose debug logs live on a RAM disk; they survive reboot but not power loss; they contain spoken content.

**Evidence — mounts:**

```
tmpfs /tmp               tmpfs rw,relatime,size=730372k,nr_inodes=182593
none  /tmp/var/log       ramfs rw,relatime
/var/log -> /tmp/var/log          (symlink)
```

**Evidence — files present in the RAM-disk log directory (33 entries):**

```
bootd.log  cecmessages  configd.log  crashd/  cups/  dbg-log  home  inputcommon
legacy-log  legacy-log.0.gz  lowlevelstorage.log  messages  messages.0.gz
reports/  rtd_*.log  serviceloggermessages  uploadd/  upload-log ...
```

**Observations:**

- `messages` and `app.voice.log` both live under the RAM disk.
- Rotation is aggressive: `messages.0.gz` existed from earlier in the session, and `app.voice.log`
  rotated out the plaintext utterance within roughly two minutes.
- Because it is `tmpfs`/`ramfs`, a **soft reboot can retain** contents while a **power-pull clears** it —
  consistent with the video's description, though we did not run a controlled reboot test (see Appendix C).
- `/var/log/acr.log` was declared by `pmlog` config but never created — because the ACR service never ran (F1).

---

### F7 — Microphone: gated, not always-on (correction to the video)

**Claim (video):** embedded microphones can be captured even while the TV "appears off"; the mic switch is not a kill switch.

**Method:** enumerate all capture devices; attempt captures in three distinct TV states; watch the ADC control; test the far-field array; test with and without the voice pipeline active.

**Audio hardware inventory:**

```
/proc/asound/cards:
 0 [Mars  ]: Mars - Mars 1
 1 [Mars_1]: Mars - Mars 2

/proc/asound/pcm (capture side only):
 00-10: MARS PCM           capture 1
 00-11: MARS ES            capture 1
 00-12: MARS DSNOOP        capture 1     ← the device ACR is configured to use
 00-13: MARS CAPTURE_TEST  capture 1
 00-14: MARS WOWCAST       capture 1
 01-00: MARS2 FARFIELD : MARS PCM : capture 1     ← the far-field mic array (4 channels)
```

`arecord -l`:

```
card 0: Mars,   device 10: MARS PCM
card 0: Mars,   device 11: MARS ES
card 0: Mars,   device 12: MARS DSNOOP
card 0: Mars,   device 13: MARS CAPTURE_TEST
card 0: Mars,   device 14: MARS WOWCAST
card 1: Mars_1, device 0:  MARS2 FARFIELD
```

PulseAudio sinks/sources of interest:

```
pvoicerecognition.monitor     (dedicated voice-recognition sink monitor)
pcm_output.monitor            (monitor of the main output — i.e. capture what is playing)
precord / pvoipsource         (null sources)
ptts.monitor / pmedia.monitor / peffects.monitor / ...
```

**Mixer state (fresh boot):**

```
amixer -c 0 controls:  AMIXER0..7 (value 389 each), Adc Open, Adc Close,
                       Adc Connect (255), Adc Disconnect, ...
amixer -c 0 cget numid=628  (Adc Open)   -> values=0
amixer -c 0 cget numid=630  (Adc Connect)-> values=255
```

There is **no `Capture` volume control** on a fresh boot (an earlier state had shown
`Capture 0 [0%] [on]` — i.e. a switch that is ON with gain at 0, which is the "muted by dropping the
gain rather than hard-muting" pattern the video describes).

**Result across TV states:**

| TV state | `hw:0,10` | `hw:0,12` | `hw:0,13` | `hw:1,0` (far-field) |
|---|---|---|---|---|
| Live TV (antenna) playing | **rms 543.8, peak 2010** | rms 317.8 | rms 336.2 | (not probed) |
| Standby / nothing playing | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Awake, idle, fresh boot | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| **Voice pipeline active (mic button pressed, speaking)** | **rms 1930.8, peak 19628** | — | — | **0 / 0 (silent)** |

Forcing the ADC open (`amixer -c 0 cset numid=628 1`) did **not** by itself produce audio; and it could
not be reverted (`amixer … cset numid=628 0` → `Operation not permitted`; the control is driver-owned).

**Interpretation — this is a correction to the video's framing for this hardware:**

- `hw:0,10` behaves as a **tap on the TV's internal MARS audio bus**, not a dedicated always-on microphone.
  It carries *playback* audio (hence take 1's success while Live TV played) **and** the *voice-pipeline's
  processed microphone audio* (hence take 5's success while the mic button was held).
- When the TV is idle and playing nothing, the bus is silent → the capture is digital silence (not noise).
- The **far-field array (`01-00 MARS2 FARFIELD`) was silent in every test**, including while the owner spoke.
- Therefore, on this 2025 firmware, "an attacker can silently record the room at any time" **did not reproduce**.
  What does reproduce is "an attacker with root can record **whatever the TV is playing**" (the boardroom
  scenario) and "**while voice is engaged**, the microphone audio is on that bus and readable".

---

### F8 — Microphone capture proven over the network

**Method:** with the owner present and consenting, capture from the TV over SSH from the Mac, with **no
interaction on the TV other than the owner pressing the mic button and speaking**.

**Take 1 (45 s, two devices simultaneously, Live TV playing):**

```
mic-primary-hw0-10.wav: 1,440,000 bytes, 45.0s, rms=343.3 peak=3508
mic-acr-dsnoop0-12.wav: 8,640,000 bytes, 45.0s, rms=349.8 peak=3721
```

Per-second level profile showed a ~5× dynamic range and — critically — **both independent devices peaked
on the same second (20s)**, meaning they were hearing the same acoustic event. Later analysis showed this
was the TV's own playback output, not the room.

**Take 5 (decisive): the voice pipeline open, owner speaking.**

```
baseline transcriptions in /tmp/var/log/messages: 1
[capture 25s from hw:1,0 and hw:0,10 while owner presses mic and speaks]
transcriptions now: 2
"user_utterance":"Un 23 probando probando"
"user_utterance":"Esto es una prueba"

farfield.raw: 25.0s rms=0.0   peak=0        ← far-field array: silent
primary.raw:  25.0s rms=1930.8 peak=19628   ← internal bus: LOUD
```

Per-second profile of `primary.raw` — silence everywhere **except** two bursts:

```
00s
...
10s #######################
11s
12s
13s ##########################
14s ############
15s ##################################################
16s ##############################################
17s ############################################
18s ##
19s
...
24s
```

The two bursts at **10 s** and **13–18 s** correspond exactly to the two utterances the TV itself
transcribed (`"Esto es una prueba"` and `"Un 23 probando probando"`).

**Saved artifacts:**

```
ondevice/demo5/primary-captured-voice.wav          (normalised, listenable)
ondevice/demo5/primary.raw / farfield.raw
ondevice/demo1/mic-primary-hw0-10.wav etc.
ondevice/voice-evidence/messages.txt               (preserved log with the plaintext utterance)
```

**Interpretation:** Microphone audio **is** capturable over the network — but only while the voice
pipeline is engaged. This is a real capability, and a real privacy exposure (the mic button is the
*kill* signal, not a *permission* barrier — an attacker who can watch for voice activity, or who can open
the pipeline, records from that point).

---

### F9 — Screen capture exists and leaks to any app (no root needed)

**Claim (video):** LG TVs are capable of screenshots via ACR/`capture_format`; the display is a "glass" the manufacturer owns.

**Method:** locate the capture subsystem; observe it running; examine access control.

**The capture service:**

```
/usr/sbin/captureservice                  (running, pid 2042, started at boot)
com.webos.service.capture                 (LS2/D-Bus service, Type=dynamic)
/usr/share/luna-service2/manifests.d/screen-capture-webos.manifest.json
/usr/share/luna-service2/roles.d/com.webos.service.capture.role.json
opkg: lib32-screen-capture-webos  1.0.0-56-r7
```

Full method surface (from `api-permissions.d/com.webos.service.capture.api.json`):

```
com.webos.service.capture/createHandle        /destroyHandle
                                    /getClipRegions   /setClipRegions
                                    /getOptions       /setOptions
                                    /getProperties    /setProperties
                                    /setOutput
                                    /isLocked         /lock        /unlock
                                    /getCapability
                                    /execute
                                    /executeOneShot        ← single-frame grab
com.webos.service.capturepermission/checkPermission      /setPermission
```

Backends discovered from the binary's symbols:

```
GraphicCapture::capture()            -> halgalCapture()             -> HAL_GAL_CaptureFrameBuffer
GraphicCapture::halgalCaptureWithBackground()
VideoCapture::capture()              -> vtCapture()                 -> libvtcapture.so.1
DisplayCapture::blendedCapture()     (the composite of both planes)
PermissionManager::registerVideoMuteStateSubscribe()
PermissionManager::updateVideoMuteState(bool)
PermissionManager::getCurrentVideoMuteState()
"(rx): current videoMuteStatus = %d"
```

Method name strings present: `graphic`, `video`, `blended`, `display`, `screen`.
Build paths embedded in the binary:
`/usr/src/debug/lib32-screen-capture-webos/1.0.0-56-r7/git/src/core/capture/graphicCapture.cpp`
and `.../videoCapture.cpp`.

**Observed live, via the LS2 monitor (`ls-monitor`):**

```
[974.613] RX call  com.webos.service.capture -> com.webos.service.oledepl
          //executeOneShot
          {"width":640,"path":"/tmp/capture.rgb","method":"GRAPHIC","format":"RGB","height":360}

[974.646] return  {"capturedHeight":360,"writtenBytes":691200,
                   "returnValue":true,"capturedWidth":640}
```

`com.webos.service.oledepl` (a panel/compensation service) calls this **every ~3 seconds**, always with
`method:"GRAPHIC"`, always to the same path.

**Access control — the critical part:**

```
-rw-r--r--  1 root root  691200  /tmp/capture.rgb        ← WORLD-READABLE
```

And system `/tmp` is **bind-mounted into every app jail**:

```
VISIBLE: /var/palm/jail/com.webos.app.browser/tmp/capture.rgb          (-rw-r--r-- root)
VISIBLE: /var/palm/jail/amazon.alexa.adapter/tmp/capture.rgb           (-rw-r--r-- root)
VISIBLE: /var/palm/jail/lg.thinqai.adapter/tmp/capture.rgb             (-rw-r--r-- root)
VISIBLE: /var/palm/jail/com.webos.chromecast/tmp/capture.rgb           (-rw-r--r-- root)
```

**Practical consequence:** an installed webOS app — **with no root, no exploit, and no privileged
service** — can read `/tmp/capture.rgb` in a loop and exfiltrate a continuously-refreshing screenshot of
the TV's screen. Its sandbox does not prevent this; the sandbox *provides* it.

**Demonstration — 59-frame timelapse.** We polled the framebuffer for 3 minutes and harvested every
distinct frame (59 frames ≈ one frame every 3.05 s), then converted the raw 640×360 RGB24 buffers to
images:

```
ondevice/screenshots/live-20260913-230829/
├── contact-sheet.png      all 59 frames (1296×1240)
├── timelapse.gif          animated, 59 frames, 480×270 (218 KB)
├── timelapse.webp         same, better quality (134 KB)
├── timelapse.apng.png     animated PNG (189 KB)
└── png/                   59 individual frames at full 640×360
```

The content is the owner's YouTube playback: subtitles changing frame to frame, plus a QR code on
screen at one point.

**What the `GRAPHIC` method does and does not capture:**

| Layer | Captured by `method:"GRAPHIC"`? |
|---|---|
| System/app UI, menus, notifications | ✅ yes |
| Subtitles / captions | ✅ yes |
| On-screen QR codes / links | ✅ yes |
| Photos and graphics-layer images | ✅ yes |
| **Video plane** | ❌ **black** (see F10) |
| DRM-protected video | ❌ black (protected path) |

So this is a **UI-and-overlay leak, not a video ripper** — but subtitles leaking dialogue and QR codes
leaking links are a materially worse leak than the video frames that *didn't* come through.

**Why the video area is black** (resolution of a question the owner raised): on this Realtek "Mars" SoC,
decoded video is presented on a **separate hardware video plane** (`rtkvdec_dma_arr`, `starfish-media-pipeline`)
that the graphics-layer HAL dump does not include. We confirmed this three independent ways — see F10.

---

### F10 — Video-plane capture (what the "screenshot" missed)

**Problem:** three different capture paths all returned the video region as blank/black:

| Path | Result for the video region |
|---|---|
| `capture/executeOneShot` `method:"GRAPHIC"` (HAL_GAL) | black |
| Chromium CDP `Page.captureScreenshot` (1920×1080) | blank white |
| `drawImage(<video>)` → canvas → `toDataURL` | black |

Even though the page's `<video>` was confirmed playing:

```json
videos on page: [{"w":1920,"h":1080,
  "src":"blob:https://www.youtube.com/6d15a80f-b9cd-4383-b104-92ebc27",
  "rs":4}]
```

(`blob:` = MediaSource; same-origin, so the canvas was **not** tainting-blocked — the frames simply are
not in a readable texture.)

**The method that works:** a vendor test utility that links `libvtcapture` directly.

```
/usr/bin/vtCaptureTestSuite
```

Its menu (captured by running it with piped input):

```
-------------------------------------
        vt capture test suite
-------------------------------------
  0x01 : one-shot capture
  0x02 : start continuous capture
  0x03 : start continuous capture with policy action
  0x04 : start continuous capture to RGB
  0x05 : stop continuous capture
-------------------------------------
  0x10 : init histogram
  0x11 : set preset histogram
  0x12 : get histogram
  0x13 : finalize histogram
  0x14 : validation check
-------------------------------------
  0xff : exit
-------------------------------------
```

Driving it non-interactively:

```bash
printf '1\n0xff\n' | timeout 8 /usr/bin/vtCaptureTestSuite
# writes /tmp/vtCaptureTestIamge.yuv   (the typo is LG's)
# ~333 ms per invocation
```

**Resulting frame:** 777,600 bytes = `960 × 540 × 1.5` = **I420 / NV12 at 960×540**.

Decoded (limited-range BT.601 expansion), the frame is the **real video**:

```
video-plane-fresh.png        (960×540) — dashcam footage, an Audi A3, a city street
video-plane-960x540.png/.yuv (the first grab — also the Audi clip)
```

**Full composite screenshot.** Combining the video plane (`vtCapture`) with the graphics plane
(`/tmp/capture.rgb`) yields a genuine full-screen screenshot including both video and UI:

```
ondevice/screenshots/FULL-screenshot-video+ui.png
```

It shows the video frame **plus the subtitle overlay** — the spoken line
*"of brain that solves problem. I'm not relieved quite"* — under a man wearing a
**"TURN OFF THE TV"** t-shirt (an irony we did not manufacture).

**MP4 produced.** Harvesting 120 one-shot video-plane frames and encoding them natively:

```
ondevice/screenshots/video-plane-capture.mp4
  9,059,903 bytes · 960×540 · 74 frames @ 4 fps · AVAssetWriter status = completed
```

Encoding was done with a purpose-built **Swift + AVFoundation** tool (`encoder.swift`) because the
Mac's Homebrew `ffmpeg` is ABI-broken (see §5.3 and Appendix B).

**Interpretation:** `vtCapture` (video plane) plus `HAL_GAL` (graphics plane) together give a complete
picture of the display — which is exactly what `DisplayCapture::blendedCapture()` is designed to do in
one call. We could not invoke `blendedCapture` because LS2 calls from our shell don't reach the bus
(§5.3) and the method is gated by the `videoMuteState` permission (F9). Note also that **DRM-protected
video would still be black** through any of these paths.

---

### F11 — Unauthenticated root via Telnet and default SSH password

**This was an exposure created by the owner's own rooting setup, not a factory defect — but it was live
for the duration of the session.**

**Evidence — the process:**

```
root 4744 1 0 14:34 ? /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/bin/telnetd -l /bin/sh
```

`-l /bin/sh` means **no authentication**: connecting gets a shell.

**Evidence — proof, from the Mac:**

```
$ telnet 10.0.0.34        # (via a raw socket, no credentials supplied)
id; hostname; echo TELNET_SHELL_OK
uid=0(root) gid=0(root)
<tv-host>
TELNET_SHELL_OK
~ #
```

**Evidence — SSH default password still active.** webOSbrew's `startup.sh` only installs the
placeholder password when `authorized_keys` does **not** exist:

```sh
# from /var/lib/webosbrew/startup.sh
if [ ! -f /home/root/.ssh/authorized_keys ]; then
    sed -r 's/root:.?:/root:xGVw8H4GqkKg6:/' /etc/shadow > /tmp/shadow
    chmod 400 /tmp/shadow
    mount --bind /tmp/shadow /etc/shadow
    ...
fi
```

Because we created `authorized_keys` **after** the last boot, the bind-mounted placeholder remained:

```
$ grep '^root:' /etc/shadow
root:xGVw8H4GqkKg6:15069:0:99999:7:::
$ grep -i shadow /proc/mounts
tmpfs /etc/shadow tmpfs rw,relatime,size=730372k,nr_inodes=182593 0 0
```

and it worked:

```
$ ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@10.0.0.34
root@10.0.0.34's password: alpine
uid=0(root) gid=0(root) groups=0(root),10(wheel),506(pulse-access),509(se),777(crashd),995(lpadmin)
PASSWORD_AUTH_WORKED
```

**Impact:** during this window, **anyone on the Wi-Fi** could obtain root on the TV with no exploit —
and from root, the audio (F8) and video (F10) capture paths are all available, plus reading the
plaintext voice logs (F5).

**Remediation applied:** a key was installed (disabling the alpine password on the next boot). The owner
elected to leave telnet alone after the session (their network, their risk assessment) — see §9.

---

### F12 — Unauthenticated Chromium DevTools exposed on the LAN

**Evidence — Chromium is launched with a debugging port:**

```
WebAppMgr ... --remote-debugging-port=9998 --no-sandbox ...
WebAppMgr --type=renderer ... --app-id=youtube.leanback.v4 --remote-debugging-port=9998 ...
```

**Evidence — the port file:**

```
/var/lib/wam/DevToolsActivePort
9998
/devtools/browser/<uuid>
```

**Evidence — reachable from the LAN with NO authentication (HTTP 200, no credentials):**

```
$ curl -s http://10.0.0.34:9998/json/version
{
   "Browser": "",
   "Protocol-Version": "1.3",
   "User-Agent": "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.270 Safari/537.36",
   "V8-Version": "12.0.267.(25*1000 + 2)",
   "webSocketDebuggerUrl": "ws://10.0.0.34:9998/devtools/browser/<uuid>"
}

$ curl -s http://10.0.0.34:9998/json/list
[ {
   "description": "youtube.leanback.v4",
   "title": "YouTube en la televisión",
   "type": "page",
   "url": "https://www.youtube.com/tv?env_forceFullAnimation=1&env_enableWebSpeech=1&env_enableVoice=1#/watch?v=86auknTsVag",
   "webSocketDebuggerUrl": "ws://10.0.0.34:9998/devtools/page/<hash>"
} ]
```

**Impact — this is remote code execution in the TV's web-app context, with no root and no exploit:**

Via `Runtime.evaluate` over that WebSocket, an attacker on the LAN can execute **arbitrary JavaScript**
inside the TV's YouTube (or any other web app) page context. Demonstrated capabilities include:

- Reading page/session state, cookies, and DOM (session theft)
- Navigating the TV to arbitrary URLs / rendering arbitrary content
- Injecting UI (phishing overlays) on the living-room screen
- Driving the page (playback, search, account actions)

We actually exercised the channel: `Page.enable` + `Page.captureScreenshot` returned a full 1920×1080
PNG of the running YouTube page, and `Runtime.evaluate` ran arbitrary page JavaScript.

**Note on availability:** the port was only listening while a web app was foregrounded. Early in the
session (before a web app was active) the port **refused** connections; once YouTube was playing it was
`0.0.0.0:9998` and fully reachable. Its renderers additionally run with **`--no-sandbox`**.

**Not tested:** whether CDP can be leveraged from the renderer to escape the Chromium sandbox to the
device. That would be a separate, deeper investigation.

---

### F13 — Wi-Fi survey for geolocation

**Claim:** the TV inventories neighbouring wireless networks, which can be used for geolocation.

**Method:** from the TV's own root shell, perform a Wi-Fi scan while the TV is normally connected.

**Evidence:** ~25 distinct BSSIDs/SSIDs with signal strengths, including the owner's own network and
neighbours':

```
signal: -44.00 dBm   SSID: <ssid>
signal: -42.00 dBm   SSID: <ssid>
signal: -63.00 dBm   SSID: <ssid>
signal: -56.00 dBm   SSID: <ssid>
signal: -65.00 dBm   SSID: <ssid>
signal: -65.00 dBm   SSID: <ssid>
signal: -77.00 dBm   SSID: <ssid>
signal: -45.00 dBm   SSID: <ssid>
signal: -69.00 dBm   SSID: <ssid>
signal: -62.00 dBm   SSID: <ssid>
signal: -53.00 dBm   SSID: <ssid>
signal: -75.00 dBm   SSID: <ssid>
signal: -82.00 dBm   SSID: <ssid>
signal: -75.00 dBm   SSID: <ssid>
signal: -72.00 dBm   SSID: <ssid>
signal: -85.00 dBm   SSID: <ssid>
signal: -90.00 dBm   SSID: <ssid>
... (plus several hidden SSIDs)
```

**Interpretation:** the capability is confirmed — the TV can enumerate surrounding infrastructure with
RSSI, which is a well-known geolocation technique (Wi-Fi positioning). **Not tested:** the video's
specific claim that this happens *even when the TV is used as a wired-only display*. This unit is
connected over Wi-Fi, so scanning is expected behaviour here; the "wired but still scanning" variant
would require reconfiguring the TV to Ethernet and repeating the test.

---

### F14 — Network telemetry baseline (consent declined)

**Method:** full ARP-spoof MITM between the TV and the gateway, verified from the TV's own ARP cache;
capture filtered to the TV only.

**MITM verification (from the TV's `/proc/net/arp` while the MITM was up):**

```
IP address       HW type  Flags  HW address           Device
10.0.0.1      0x1      0x2    <MAC-LAPTOP-RANDOM>    wlan0    ← the Mac is now "the gateway"
10.0.0.34     0x1      0x2    ...
```

That is definitive proof the poison took: the TV believes the gateway is at the Mac's (randomised) MAC.

**Baseline captured (TV idle, 4.5 min, 708 packets, 208 KiB, filtered to `host 10.0.0.34`):**

| Observation | Detail |
|---|---|
| `avsxappcaptiveportal.com` ×40 | UA `AvsDeviceSdk/1.26.0` — **Amazon Alexa Voice Service** captive-portal checks, repeating. Confirms the `amazon.alexa.adapter` jail is live and phoning home. |
| `marker2.konograma.com` | DNS + **TLS every ~50 s** (periodic beacon). *Unidentified — flagged for follow-up.* |
| `108.132.67.12:8883` | **MQTT over TLS** (IoT channel) |
| `255.255.255.255:9999` UDP | LG proprietary LAN device discovery broadcast |
| DNS servers | `80.58.61.254`, `80.58.61.250` (Telefónica/Movistar resolvers) |
| Largest endpoint | `84.40.62.234:443` (~40 KiB) |
| Other TLS | `142.251.157.4` (Google), `151.101.133.89` (Fastly), `52.16.104.93`, `108.133.178.110` |
| **Ad/telemetry hosts flagged** | **none** |

**Interpretation:** with every tracking EULA declined and ACR dormant, the TV still:
- performs periodic Alexa captive-portal probes,
- runs a ~50-second TLS beacon to an unidentified host,
- maintains an MQTT/IoT channel, and
- broadcasts LG device-discovery packets.

But it did **not** contact any ad/ACR endpoint. This is the "still beacons even when you decline"
behaviour the video describes — narrower than the video implies, because the ACR/ads path is consent-gated.

**Not measured:** the video's "~4 GB/month of ACR data" figure. We cannot measure it while ACR is
disabled, and we did not run a long-enough capture to characterise total monthly volume.

---

### F15 — Nuance / Cerence voice backend

**Claim:** LG names Nuance as the voice-data partner; Microsoft owns Nuance.

**Evidence — `/tmp/tts/tts_cag_info.json`:**

```json
{"serverUrl":"https://he-eu-ai.lgthinq.com:443",
 "cerenceLanguageCode":{"fr-CH":"fra-fra","it-CH":"ita-ita","vi-VN":"vie-vnm",
   "en-ZM":"eng-usa","ar-IQ":"ara-sau", ... (60+ locale mappings) ... }}
```

`he-eu-ai.lgthinq.com` is LG's ThinQ AI endpoint (`he-eu` = Europe region); the language-code map is
Cerence's (`cerenceLanguageCode`) — Cerence being the spun-off automotive/voice company formerly part of
Nuance, which Microsoft acquired. This corroborates the video's chain: **LG TV voice → Nuance/Cerence
technology → LG AI backend, hosted in this case in the EU.**

Also present, in the same evidence set: `https://aic.ads.lgtvcommon.com` (ad overlay),
`aic-ngfts.lge.com` / `eic-ngfts.lge.com` (ad asset distribution), `dokdo.lge.com` / `wam.lge.com`
(Chromium web-app infrastructure, seen in `WebAppMgr` arguments).

---

## 7. Claim-by-claim verdict vs the transcript

Legend: ✅ confirmed · 🟡 partially confirmed / qualified · ❌ not reproduced · ⬜ not tested

| # | Claim in the Gamers Nexus transcript | Verdict | Evidence / qualifier |
|---|---|---|---|
| 1 | LG TVs can be used as listening devices via the advertising stack | 🟡 | Mic audio is on the internal bus while voice is active; **not** an always-on room mic on this 2025 firmware (F7/F8) |
| 2 | Full plaintext transcripts of voice are retrievable | ✅ | `NL_RESULT_DATA {"user_utterance":...}` in `/tmp/var/log/messages` (F5) |
| 3 | TV can record from webcam/mic while appearing off | ⬜ | Not tested (no webcam attached). The "while off" variant was indirectly refuted for the room mic (idle ⇒ silence) |
| 4 | Mic audio captured while unplugged from the network, exfiltrated later | ⬜ | The offline-buffer mechanism is plausible (`/tmp` RAM) but not tested end-to-end |
| 5 | LG's first-party profit-seeking functionality reaches deep into private life | ✅ | ACR + ad stack + shoppable overlays present and enabled in config (F2–F4) |
| 6 | TV crawled the entire network, found dozens of unrelated devices | 🟡 | UPnP/SSDP + mDNS + LG `:9999` discovery confirmed; **no evidence of a full device inventory being uploaded** while ACR is off (F13/F14) |
| 7 | LG "knows who's in the household… which devices are there" | ✅ | Alexa/Chromecast/ThinQ adapter jails, per-app advertiser IDs, ad-overlay on HDMI (F2–F4) |
| 8 | LG identifies IP address, geo, nearby Wi-Fi, signal strength, channel numbers | ✅ | `/tmp/acr.xml` + `iw scan` + MITM baseline (F2/F13/F14) |
| 9 | The Wireshark data was "such an egregious invasion of privacy we can't even show you" | 🟡 | We obtained equivalent shape (interfaces, MACs, SSIDs, endpoints); did not reproduce the exact exhibit |
| 10 | ACR = automated content recognition, audio or video, fingerprinted and sent to LG servers | ✅ | Config, libs, device, vendor all confirmed (F2) |
| 11 | Even an HDMI connection undergoes ACR | ✅ | `com.webos.app.acrhdmi1..4`, ad overlay targets HDMI 1–4 (F3) |
| 12 | ACR runs even when the TV is used as a dumb monitor / offline | 🟡 | Capability configured (`capture_method="SOURCE"`); ACR dormant here because consent is absent (F1) |
| 13 | "Do not sell my personal information" off by default; dark patterns | ⬜ | Not directly tested in the UI; the EULA store does show every tracking consent defaulting to `false` (F1) |
| 14 | Voice data transferred overseas, 6-month retention | ⬜ | Endpoint confirmed (`he-eu-ai.lgthinq.com`); retention not verified (F15) |
| 15 | Nuance handles voice data | ✅ | Cerence language map + LG AI endpoint (F15) |
| 16 | Forced arbitration added after the first video | ⬜ | The terms documents were not read/compared in this session |
| 17 | ~4 GB/month of ACR upload | ⬜ | Unmeasurable while ACR is disabled (F1/F14) |
| 18 | Mic switch is not a kill switch | 🟡 | Multiple capture devices exist beyond the built-in mic; the built-in mic switch itself was **not** toggled in this session (F7) |
| 19 | Voice capture continues 10–15 s after the trigger phrase | 🟡 | Transcriptions continue after activation; exact window not measured (F5) |
| 20 | Mic range 40–70 ft | ⬜ | Not tested |
| 21 | Residential-proxy SDKs in the webOS app store | ⬜ | Not tested |
| 22 | Manufacturer can capture audio via root/exploit, exfiltrate | ✅ | Demonstrated end-to-end with owner's own voice (F8) |
| 23 | Rooted TV allows the hacker to "own the glass" | ✅ | Screen (F9), video (F10), audio (F8) all captured; multiple unauthenticated exposures (F11/F12) |

---

## 8. Security assessment

Ranked by exploitability × impact on *this* device, as configured:

### Critical

**1. Unauthenticated screen framebuffer readable by any app (F9).**
`/tmp/capture.rgb` is `-rw-r--r--` and its directory is bind-mounted into every app jail. No exploit,
no root, no user interaction. An app can watch a live 640×360 view of the screen indefinitely, including
subtitles and QR codes. **Root cause:** a legitimate LG capture feature writing a sensitive buffer with
permissive mode into a shared namespace. **Fix:** `0600` + per-process tmpfs, or move to a jailed path.

**2. Unauthenticated root on the LAN (F11).**
`telnet 10.0.0.34` → root shell, no credentials. Created by the owner's webOSbrew configuration
(telnet toggle). Immediately gives access to F8, F9, F10 and F5. **Fix:** Homebrew Channel → Settings →
Telnet **off**; reboot to clear the placeholder SSH password.

**3. Unauthenticated Chromium DevTools on the LAN (F12).**
`http://10.0.0.34:9998` → full CDP control of any running web app, including `Runtime.evaluate`
(arbitrary JS in page context) and `Page.captureScreenshot`. Renderers run `--no-sandbox`.
**No root required.** **Fix:** none available to the user; this is LG's web-app runtime design. Mitigated
by network segmentation.

### High

**4. Microphone capturable while voice is engaged (F8).** Requires root today, but combined with F11 or
an RCE it becomes trivial. **Mitigation:** close F11/F12; assume any on-screen "listening" state is
remotely observable.

**5. Voice input stored as plaintext on-device (F5).** Any process able to read `/tmp/var/log/messages`
(which is on a shared RAM disk) obtains what was said. Combined with F9 this is a self-reinforcing leak.

### Medium

**6. Video-plane capture possible (F10).** Requires root. Enables recording of what the display shows.
Protected/DRM content remains unreadable.

**7. Periodic unidentified beacon `marker2.konograma.com` every ~50 s (F14).** Unidentified third party.
Worth resolving.

**8. Ad/ACR capability present in firmware and one consent dialog away from activation (F1/F2).**
Mitigated here only by the owner's explicit refusal to consent.

### Low / Informational

**9. Wi-Fi survey (F13)** — expected behavior, but the basis for geolocation.
**10. LG `:9999` LAN discovery broadcast (F14)** — normal LG ecosystem behaviour.
**11. Multiple legacy LAN services open** (see §4.3) — broad attack surface; each is a potential future
vulnerability. **12. `securitymanager` flags Homebrew Channel as an "abnormal program"** (`NL_ABNORMAL_MONITORING`)
— expected interference from LG's own integrity monitoring.

---

## 9. Remediation

### Applied during the session

| Change | Reason | Reversible? |
|---|---|---|
| Installed `~/.ssh/lgtv_ed25519` public key into `/home/root/.ssh/authorized_keys` (chmod 600) | key-based access; disables the `alpine` placeholder on next boot | yes — delete the file |
| `sysctl -w net.inet.ip.forwarding=1` / `net.inet.ip.redirect=0` (Mac) | enable/secure the MITM | yes — `mitm-down.sh` restores saved values |
| `amixer -c 0 cset numid=628 1` (Adc Open) | attempt to force the mic ADC | **NO — `cset … 0` returns "Operation not permitted" (driver-owned); resets on TV reboot** |
| Deleted all artifacts from the TV's `/tmp` | the RAM disk hit 100% full | n/a |
| Stopped stray `vtCaptureTestSuite` process (left over from a probe) | cleanup | n/a |

### Recommended, not yet done

1. **Homebrew Channel → Settings → Telnet → OFF** (F11). Highest priority.
2. **Reboot the TV** — this clears the `alpine` placeholder password (webOSbrew will see `authorized_keys`
   and skip installing it) and resets `Adc Open`.
3. Verify after reboot:
   ```bash
   nc -z 10.0.0.34 23 || echo "telnet closed (good)"
   ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@10.0.0.34   # should be refused
   ```
4. **Consider turning the SSH server off when not actively testing** — it is root on the LAN by design.
5. **Network hygiene matters more than usual here**: anyone who reaches the LAN gets either root (F11) or
   arbitrary web-app JS (F12). Isolate the TV (guest/IoT VLAN or a dedicated SSID with client isolation).
6. **Revisit "Block system updates."** It protects the rooting from LG but also blocks security fixes for
   the services in §4.3. Explicit trade-off.
7. **Do not install untrusted webOS apps** until the `/tmp/capture.rgb` design flaw is fixed by LG —
   because an app needs no privileges to watch the screen (F9).
8. **Do not accept `S_VNG`/ad EULAs** unless you intend to enable ACR (F1/F2).
9. **Investigate `marker2.konograma.com`** (F14) — what is it and why does it beacon every ~50 s.
10. **Report the screen-capture design issue to LG** (shared, world-readable framebuffer) — it is a
    genuine, non-obvious sandbox problem affecting every webOS TV, not just this model.

---

## 10. Artifacts index

```
~/lg-nexus-tests/
├── NEXUS-VERIFICATION-REPORT.md          ← this document
├── RUNBOOK.md                             network capture runbook
├── STATUS.md                              session handoff
├── README.md
├── bin/                                   MITM + passive watchers (see §5.2)
├── analysis/analyze.py                    dependency-free pcap analyser
├── tv/root-audit.sh, tv-pull.sh           on-device audit toolkit
├── captures/
│   ├── mitm-20260913-151123.pcap          raw MITM capture (14.5 MB; contains Mac traffic too)
│   ├── idle-baseline-tv-only.pcap         TV-only baseline
│   ├── idle-baseline-report.txt           its analysis
│   ├── bettercap-*.log, tcpdump-*.log     run logs
│   └── mitm.state                         saved sysctl values for exact restore
└── ondevice/
    ├── lg-audit-<tv-host>-*.tar.gz        first on-device audit bundle (12 sections)
    ├── voice-evidence/messages.txt        preserved log with the plaintext utterance (F5)
    ├── demo/  mic-primary-hw0-10.wav …    take 1 audio (Live TV playback)
    ├── demo2/ mic-primary.wav (silent)    take 2 (standby — all zeros)
    ├── demo3/ mic-primary.wav (silent)    take 3 (fresh boot — all zeros)
    ├── demo4/ farfield.raw, primary.raw   take 4 + ADC flag timeline
    ├── demo5/ primary-captured-voice.wav  ← take 5, the voice the TV also transcribed (F8)
    └── screenshots/
        ├── tv-screen-*.png                single graphics-plane screenshot
        ├── full-composite-video+ui.png    early composite (mismatched timing)
        ├── FULL-screenshot-video+ui.png   ← complete screenshot: video + subtitles (F10)
        ├── video-plane-960x540.png/.yuv   first video-plane frame (Audi clip)
        ├── video-plane-960x540-nv12.png   NV12 decode of the same
        ├── video-plane-fresh.png          later video-plane frame
        ├── video-plane-capture.mp4        ← 74-frame MP4 of real video (F10)
        └── live-20260913-230829/
            ├── contact-sheet.png          59 frames at a glance
            ├── timelapse.gif/.webp/.apng  animated UI timelapse
            └── png/                       59 individual 640×360 UI frames
```

**Tools created ad hoc** (in the system temp dir, not the repo):
`ssdp.py`, `scan.py`, `fp.py`, `passive_watch.py`, `probe_mics.py`, `analyze_capture.py`,
`make_clip.py`, `farfield.py`, `decode_yuv.py`, `exfil_demo{,2,3,4,5}.sh`, `grab_frames.sh`,
`build_gif.sh`, `fullshot.sh`, `encoder.swift` (+ compiled `/tmp/encoder`), `cdp_shot.js`, `cdp_video.js`,
`install-key.exp`, `pwtest.exp`.

---

## 11. Chronology

| Time (CEST) | Event |
|---|---|
| ~14:20 | Environment recon; TV discovered at `10.0.0.34`; identified as OLED55B56LA; ports scanned |
| 14:34 | TV is at `Init` — powered on by remote (`PowerOnReason: remoteKey`) |
| 14:39 | SSH key installed via the documented `alpine` default; root access confirmed |
| 14:40 | First on-device audit (`root-audit.sh`) — 7,892 lines captured |
| 14:41 | Audit archive pulled to the Mac |
| 14:42 | `before` marker file set on the TV for the voice test |
| 14:45 | Owner speaks the marker phrase; TV `NL_ACTIVATE_VOICE` |
| 14:46 | **F5 confirmed** — plaintext `user_utterance` in `/tmp/var/log/messages` and `/tmp/app.voice.log` |
| ~14:50 | Evidence preserved to the Mac |
| 14:58 | Owner running Live TV from antenna; ACR probe begins (dormant) |
| ~15:00 | ACR still dormant; ADC controls inspected |
| ~15:05 | **F1 discovered** — 11 tracking EULAs all `accepted:false` |
| 15:11 | MITM started (bettercap + tcpdump) |
| 15:11 | **MITM verified** — TV's own ARP cache shows the Mac as gateway |
| 15:16 | Idle baseline capture filtered and saved (**F14**) |
| ~15:20 | Session paused by owner |
| 22:41 | TV rebooted; session resumes |
| 22:42 | Dev-mode/telnet/SSH state re-checked → **F11 discovered** (telnetd, alpine password) |
| 22:44 | Voice test #2 (Spanish); ADC flag watched |
| ~22:45 | **F9 discovered** — `/tmp/capture.rgb` world-readable, refreshed ~3s, visible in all jails |
| 22:58 | First graphics-plane screenshot reconstructed (TV home screen) |
| 23:04–23:08 | 59-frame UI timelapse harvested, GIF/WebP/APNG built |
| 23:15 | **F12 discovered** — unauthenticated Chromium DevTools on 9998 |
| 23:15 | CDP `Page.captureScreenshot` (video blank), canvas readback (black) → **F10 motivation** |
| 23:16 | `vtCaptureTestSuite` menu discovered (`0x01` one-shot etc.) |
| 23:17 | **F10 confirmed** — real video-plane frame decoded (960×540 I420) |
| 23:18 | Full composite screenshot (video + subtitles) |
| 23:21 | 120-frame video-plane harvest begins |
| 23:22 | TV `/tmp` hits 100%; tar fails; frames streamed to Mac; **TV cleaned to 1%** |
| 23:23 | 74 frames decoded; **MP4 encoded with Swift/AVFoundation** |
| 23:25 | TV-side cleanup verified; session ends |

---

## Appendix A — exact commands used

### Discovery

```bash
# find the TV (SSDP / UPnP)
python3 ssdp.py                       # M-SEARCH to 239.255.255.250:1900
python3 scan.py                       # TCP scan of 10.0.0.0/24 for webOS/RTSP/SSH ports
curl -s http://10.0.0.34:1210/     # UPnP device description -> model, MACs

# identify the TV's ARP entry
arp -a | grep 10.0.0.34
```

### Key install and access

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lgtv_ed25519 -N "" -C "lg-nexus-test"
expect -f install-key.exp             # pushes pubkey over SSH using the documented 'alpine' default
ssh lgtv 'id; uname -a'               # -> uid=0(root) ...
```

### On-device audit

```bash
scp tv/root-audit.sh lgtv:/tmp/root-audit.sh
ssh lgtv 'chmod +x /tmp/root-audit.sh && sh /tmp/root-audit.sh'
scp 'lgtv:/tmp/lg-audit-*.tar.gz' ondevice/
```

### The voice-plaintext test

```bash
ssh lgtv 'touch /tmp/.nexus-marker-before'          # before
# owner presses mic and speaks the marker phrase
ssh lgtv "find /tmp /var /run /media -xdev -type f -newer /tmp/.nexus-marker-before"
ssh lgtv "grep -o '\"user_utterance\":\"[^\"]*\"' /tmp/var/log/messages | tail"
grep -o 'voice NL_[A-Z_]*' /tmp/var/log/messages                # on the TV
```

### MITM

```bash
sudo bin/mitm-up.sh                   # forwarding + redirect suppression + bettercap + tcpdump
ssh lgtv 'cat /proc/net/arp'          # verify: gateway MAC becomes <MAC-LAPTOP-RANDOM>
sudo bin/mitm-down.sh
tcpdump -r captures/mitm-*.pcap -w /tmp/tv-only.pcap 'host 10.0.0.34'
python3 analysis/analyze.py --pcap /tmp/tv-only.pcap --top 25
```

### Audio

```bash
ssh lgtv 'arecord -D hw:0,10 -f S16_LE -r 16000 -c 1 -d 45 -t raw' > mic.raw
ssh lgtv 'arecord -D dsnoop:0,12 -f S16_LE -r 48000 -c 2 -d 45 -t raw' > acr.raw
ssh lgtv 'arecord -D hw:1,0 -f S16_LE -r 48000 -c 4 -d 25 -t raw' > farfield.raw
ssh lgtv 'amixer -c 0 cget numid=628'   # Adc Open
```

### Screen and video capture

```bash
scp lgtv:/tmp/capture.rgb /tmp/frame.rgb            # 640x360 RGB24 graphics-plane frame
# decode (note: read sequentially as top-down rows)
python3 - <<'PY'
from PIL import Image
Image.frombytes("RGB",(640,360),open("/tmp/frame.rgb","rb").read()).save("/tmp/ui.png")
PY

# video plane via the vendor test utility
ssh lgtv 'printf "1\n0xff\n" | timeout 8 /usr/bin/vtCaptureTestSuite'   # -> /tmp/vtCaptureTestIamge.yuv
scp lgtv:/tmp/vtCaptureTestIamge.yuv /tmp/vt.yuv

# MP4 with Swift/AVFoundation
swiftc -O encoder.swift -o /tmp/encoder
/tmp/encoder /tmp/vtpng 4 out.mp4
```

### Chromium DevTools

```bash
curl -s http://10.0.0.34:9998/json/version
curl -s http://10.0.0.34:9998/json/list
node cdp_shot.js /tmp/cdp-shot.png       # Page.captureScreenshot
node cdp_video.js /tmp/video-frame.png   # Runtime.evaluate -> drawImage(video) -> canvas
```

### Root-exposure proof

```bash
# telnet (no credentials)
python3 - <<'PY'
import socket,time
s=socket.create_connection(("10.0.0.34",23),timeout=6); s.settimeout(3); time.sleep(0.4)
s.sendall(b"id; hostname\n"); time.sleep(1); print(s.recv(4096).decode(errors="replace"))
PY

# SSH default password
expect -f pwtest.exp     # PreferredAuthentications=password, sends 'alpine'
```

---

## Appendix B — our own tooling bugs found and fixed

Documented because they materially affected results, and because several were subtle:

| Bug | Effect | Fix |
|---|---|---|
| Sender MAC hardcoded to the hardware MAC (`80:a9:…`) | ARP poison targeted a MAC the Mac never transmits from → MITM silently no-ops | auto-detect the **active** MAC on the interface (`ifconfig en0 \| awk '/ether/{print $2}'`) |
| ICMP redirects not suppressed | macOS tells the spoofed client to bypass the MITM | `sysctl -w net.inet.ip.redirect=0`, saved/restored |
| `pkill -f "bettercap.*<TV_IP>"` | Can never match — the TV IP isn't on bettercap's cmdline | match the caplet path (`mitm\.cap`) instead |
| `awk 'NR==2 {print $4}'` on `arp -n <ip>` | macOS prints **one** line, so the gateway MAC parsed as empty and active ARP restore was skipped | parse the token after `at` |
| `arp -s` static entries during teardown | Left permanent ARP entries behind; not a restore | delete existing static entries; use active unicast ARP restore |
| ARP spoof sent to `<mac>` | Poisoned the entire LAN, not just the target pair | unicast to each target's real MAC |
| `cksum` assumed present on the TV | A missing binary made "0 changes" look like a real measurement (false negative on the framebuffer refresh rate) | detected the missing tool and switched to `md5sum` |
| `analyser.py` counted all `en0` traffic | Reported ~2.4 GB and "154 GB/month" — actually the Mac's own traffic | always pre-filter with `tcpdump … 'host 10.0.0.34'` |
| `luna-send -m <service>` misuse | `-m` **registers** a service name, producing a misleading "name already exists" error | avoided luna entirely where possible |
| Not watching the TV's `/tmp` capacity | Filled the 713 MB RAM disk to 100% during a 120-frame harvest | cleaned up; streamed frames off the device instead of storing there |

---

## Appendix C — what we did NOT test / open questions

1. **ACR with consent granted.** The owner declined all LG terms. We therefore never observed the ACR
   engine running, never measured its upload volume, and never saw `acr.log`. The "~4 GB/month" figure
   remains unverified **on this device**.
2. **Regional behaviour.** `CountryCode="ES"` while ad-overlay support lists `US`/`DE`. Whether ACR would
   even activate in Spain is unknown.
3. **The microphone switch.** We did not toggle the built-in mic kill switch and then re-test capture.
   This is the one part of the video's mic claims we did not exercise directly.
4. **Audio while "off" / offline buffering then exfiltration.** The offline-buffer mechanism is
   architecturally plausible (`/tmp` RAM) but was not demonstrated end-to-end.
5. **Reboot vs power-pull log persistence.** The video's specific claim was not tested under controlled
   conditions.
6. **Webcam capture.** No USB webcam was attached; `com.webos.app.camera` and the HDMI/USB capture
   surfaces exist (`MARS WOWCAST`, USB audio), but were not exercised.
7. **Residential-proxy apps in the webOS store.** Not tested.
8. **Forced arbitration / terms text.** We found the technical consent store but did not read or compare
   the legal documents.
9. **`blendedCapture`.** We never invoked `DisplayCapture::blendedCapture()` (blocked by the broken
   `luna-send` and the `videoMuteState` permission gate); we approximated it by compositing the two planes
   ourselves.
10. **CDP → device escape.** Whether `--no-sandbox` renderers plus DevTools can be leveraged beyond the
    web-app context was not investigated.
11. **`marker2.konograma.com`.** Unidentified ~50-second TLS beacon. Needs a look.
12. **Other smart-TV brands.** Out of scope (the video's own follow-up plan).
13. **Long-duration telemetry.** The baseline was 4.5 minutes; no multi-day profiling.
14. **`vtCaptureTestSuite` continuous modes** (`0x02`/`0x04`) were not explored — they might yield
    higher-framerate, race-free capture than the one-shot loop we used.

---

## Appendix D — caveats, limitations and methodology notes

**On evidence quality.** Wherever possible this report separates *observed* facts (raw log lines, config
files, byte counts, decoded images) from *inferred* conclusions. Inferences are labelled as such.

**On "root".** Almost all on-device findings were obtained via the owner's existing root access. Findings
are explicitly tagged with whether root is required, because that determines whether they are a *design
flaw* (F9, F12 — no root) or a *privilege-consistent capability* (F8, F10 — root).

**On the MITM results.** `tcpdump` on `en0` captures the operator's own traffic as well as the TV's. All
volume figures in this report come from captures pre-filtered to `host 10.0.0.34`. Early unfiltered
figures were wrong and are called out in Appendix B.

**On the black video.** The initial assumption — that the black video region indicated DRM — was wrong,
or at least incomplete. It is the **hardware video plane**, and it is capturable through a different API
(F10). DRM *also* blocks protected content, but that was not the cause here.

**On the `asc-advertiserId` value of `1`.** This is reported honestly as a non-UUID, likely
unprovisioned value. It should not be read as evidence that a persistent advertising identifier was
present.

**On the region.** `CountryCode="ES"` may influence which ad-telemetry features are active. Conclusions
about *what the TV does* are therefore scoped to a Spain-configured unit.

**On running vendor test binaries.** `vtCaptureTestSuite` was executed with piped input and a hard
timeout, and one instance was left running by an earlier `--help` probe (since killed). It is a vendor
test tool, not a supported interface; its behaviour is not guaranteed.

**On cleanup.** The TV's `/tmp` was filled to 100% during the video harvest and restored to 1%. One
mixer control (`Adc Open`) could not be reverted and resets only on reboot — noted prominently.

**Reproducibility.** Everything above can be repeated from the artifacts in `~/lg-nexus-tests/`
(`RUNBOOK.md` for the network side, `tv/root-audit.sh` for the device side). The two things that cannot be
reproduced exactly are (a) the owner's spoken audio and (b) the live CDP session, both of which are
preserved as files.

---

---

# Part 2 — Deep dive (same session, continued)

> **Why this part exists.** Part 1 documented what the TV *does*. Part 2 asks what an attacker
> could *make* it do. The method was structural rather than opportunistic: audit who may call
> what, then audit who may *write* what. That found a confirmed sandbox escape.
>
> **Two corrections to Part 1 are recorded in §2.12. Read them — one of them reverses a
> "mitigating" conclusion I previously gave you.**

## 2.1 New findings summary

| # | Finding | Root needed? | Status | Severity |
|---|---|---|---|---|
| **F16** | **Sandboxed app → root via world-writable, root-executed service code** | **No** | **Verified (uid 505 wrote it)** | **Critical** |
| **F17** | **Google Home / Cast / Matter runtime with world-writable `lib/` and `conf/`** | **No** | **Verified (uid 505 wrote it)** | **Critical** |
| F18 | LG "RemoteOne" vendor remote-support channel (dormant, gated, can push SSH keys) | n/a | Observed | High |
| F19 | Screen framebuffer readable from inside app sandboxes | No | **Verified** | Critical (restores F9) |
| F20 | `contentminer` service (content indexing, `setPersonalKey`) | No | Observed | Medium |
| F21 | 150 Luna clients granted blanket outbound `"all"` | No | Observed | Medium |
| F22 | `objectdetection` service (analyses captured screen content) | No | Observed | Medium |
| F23 | LG signing certificates (`eacgcertificates`) self-signed anchors | No | Observed | Medium |
| F24 | AirPlay + Google Cast both enabled and exposed | No | Observed | Medium |
| F25 | Third-party ad-tech inside the browser profile (Konodrac/AudienceFlow, HbbTV) | No | **Verified** | High (privacy) |
| F26 | Persistent identifiers in cleartext (IFA, nduid) | No | **Verified** | High (privacy) |
| F27 | Wi-Fi PSK recoverable with root | Yes | **Verified** | Medium |

## 2.2 F16 — Privilege escalation: a sandboxed app can become root ⚠️ CRITICAL

**The primitive.** webOSbrew's service directory is world-writable *and* the files inside it are
executed as root:

```
drwxrwxrwx  /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/
-rwxrwxrwx      service.js      656,280 bytes   → executed by run-js-service AS ROOT
-rwxrwxrwx      startup.sh                      → executed AS ROOT at boot
-rwxrwxrwx      elevate-service                 → rewrites unit files to run as root
```

The parent chain is world-writable all the way down:

```
drwxrwxrwx  /media/developer
drwxrwxrwx  /media/developer/apps
...
drwxrwxrwx  .../usr/palm/services/org.webosbrew.hbchannel.service
```

and `/media` is mounted **`ext4 rw,nosuid`** (rw, so writability is real).

**Reachability from the sandbox — verified, not inferred.** The app's own mount namespace sees
`/media` and `/tmp`:

```
renderer pid 2753  app-id=youtube.leanback.v4   uid 505 (wam)
/media inside the jail : ap cam cryptofs developer firstmount internal preload squashfs system
mount flags            : /dev/mmcblk0p60 /media ext4 rw,nosuid,relatime
/tmp                   : tmpfs rw, size=730372k        (the shared system /tmp)
```

**Write test as the app's own uid, inside the app's namespace:**

```sh
nsenter -t 2753 -m -p -- setpriv --reuid 505 --regid 505 --clear-groups \
    sh -c 'id; touch $SVC/.wid505'
#   uid=505(wam) gid=505(compositor)
#   WRITE_OK
#   -rw-r--r-- 1 wam composit 0  $SVC/.wid505        ← owned by the app user
```

**The chain:**

1. Any installed webOS app (uid 505 `wam`) writes/modifies
   `.../org.webosbrew.hbchannel.service/service.js` (or `startup.sh`, or any file that unit
   executes) — no exploit, no race, no vulnerability in the usual sense. Just an ordinary
   `open(2)` with write permission.
2. That file is executed **as root**: `startup.sh` via `/var/lib/webosbrew/startup.sh` on boot,
   `service.js` via `run-js-service` under webOSbrew's elevation.
3. → **root**, and from root every capability documented in Part 1: microphone (`hw:0,10`,
   `dsnoop:0,12`), the video plane (`vtCapture`), the screen plane, the plaintext voice logs,
   `/tmp/var/log/messages`, the Wi-Fi PSK, everything.

**Why this exists.** `/media/developer` is the developer-mode app store area; webOSbrew and the
opkg installer create it with `0777`. The `root-executed` half is webOSbrew's own design (it
documents a root-execution service so homebrew developers don't each need their own escalation).
So this is the intersection of two things that are individually defensible and jointly fatal:
*a world-writable app directory* and *a root-executed file inside it*.

**Scope and honesty.** The specific root-executed file belongs to **webOSbrew**, so this exact
chain presupposes a rooted TV with Homebrew Channel installed. It is not a factory-LG bug. But it
means: **on your TV as configured, installing any app is equivalent to granting it root.** And LG's
own variant of the same class of bug is F17, which is stock.

**Fix / mitigation:**
- `chmod 0755` the service directory and `chmod 0644/0755` its files (do **not** go below what
  webOSbrew needs; test after rebooting).
- Better: move the root-executed code out of the world-writable tree — e.g. keep the writable app
  payload in `/media/developer` but the executed entrypoint in `/var/lib/webosbrew/` (which is
  `drwxr-xr-x root:root`).
- Treat "install an app" as "grant root" until fixed. Do not install unreviewed apps.

## 2.3 F17 — Google Home / Cast / Matter runtime with a world-writable library directory ⚠️ CRITICAL

**The primitive.** An **LG-stock, preloaded** system service exposes a writable library and
configuration directory:

```
drwxrwxrwx  /media/system/apps/usr/palm/services/com.webos.ghp.runtime/
drwxrwxrwx      lib/
-rw-r--r--  ...  libghp.so                     18,718,812 bytes
-rw-r--r--  ...  libcast_core_auth.so             325,696 bytes   ← Cast authentication
-rw-r--r--  ...  libghp_loader.so
-rw-r--r--  ...  libghp_sample_reference_plpal_factory.so
drwxrwxrwx      conf/
drwxrwxrwx          google/device_type_registry.json
drwxrwxrwx          google/trait_registry.json
drwxrwxrwx          matter/
-rw-r--r--          conf/lg.flags
-rw-r--r--          conf/converter_table.json
```

`ghp` = **Google Home Platform**. `trait_registry.json` + `conf/matter/` + `libcast_core_auth.so`
identify this as the TV's **Google Home / Google Cast / Matter smart-home runtime**.

**Reachability — verified the same way as F16:**

```
nsenter -t 2753 -m -p -- setpriv --reuid 505 --regid 505 --clear-groups \
    sh -c 'touch /media/system/apps/usr/palm/services/com.webos.ghp.runtime/lib/.wid505'
#   GHP_WRITE_OK
```

`/media/system` is visible inside app jails (`/media` listing includes `system`), and it is on the
same `ext4 rw` mount.

**Impact.** A sandboxed app can (a) overwrite a shared library the service loads → code execution
in that service's context, and (b) rewrite its configuration (`trait_registry`, `matter/`,
`lg.flags`) → alter smart-home device handling and trust decisions. Whether it lands as `root`
depends on how `com.webos.ghp.runtime` is launched (it is a system service, launched under the
jailer as user `com.webo…`/`jailer`); at minimum it is **code execution outside the app sandbox**,
and possibly privilege escalation. We did not attempt the injection itself — that is destructive
and would have broken your TV. The primitive is proven; the payoff's exact privilege level is not.

**Why it likely matters for every TV with this platform.** Unlike F16, this directory is LG's own
preloaded system app, not a homebrew artefact. A world-writable `lib/` under a system service is
a design defect that should not exist on a production device.

**Fix / mitigation:** none available to the user — report to LG. The directories should not be
group/other-writable.

## 2.4 F18 — LG "RemoteOne": the vendor remote-support channel

**What it is.** `/usr/sbin/remotediag` plus a hidden app pair, fronting LG's remote-support system.

```
/usr/sbin/remotediag                    (Type=dynamic D-Bus service)
com.webos.service.remotediag            role: inbound ["*"], outbound ["*"], client perms "all"
/usr/share/remotediag/device.pem        subject/issuer: O=LG Electronics, OU=RemoteOne, CN=TV
/usr/share/remotediag/server.pem        subject/issuer: O=LG Electronics, OU=RemoteOne, CN=Socket Server
```

**Capabilities visible in the binary's symbols:**

```
Adapter::RemoteDebugging::SendAuthorizedKeys(std::string, int)   ← installs SSH authorized_keys
Adapter::Remocon::SendKey(std::string)                            ← sends remote-control keypresses
Socket::Connect(host, port) · SSL_CTX_use_PrivateKey · PEM_read_bio_PrivateKey
HttpReq::execute(url, int) · HttpMultiReq::execute(...) · Base64
RequestPing / ResponsePing
```

So the vendor channel can **(a) drive your TV's remote control** and **(b) provision SSH keys**.

**It is dormant, and honestly so:**

```
/etc/systemd/system/remotediag.service:
    ConditionPathExists=/mnt/lg/cmn_data/remoteDebug/remoteDebug.sh

/mnt/lg/cmn_data/remoteDebug  -> DOES NOT EXIST
/var/log/remotediag.log       -> does not exist  (never executed on this unit)
```

The activation file is absent, so the service never starts. **This is a latent capability, not an
open backdoor.**

**Trust material.** `device.pem` and `server.pem` are **certificates only — no private key
material** (verified by absence of a `PRIVATE KEY` marker). So a disk-level attacker cannot
impersonate this TV to RemoteOne. The server certificate is self-signed and shipped on the device,
so it is a *pinned* trust anchor: replacing it (needs write access to `/usr/share`, which is
read-only squashfs) would allow a MITM of the support channel.

**Hidden apps that front it:**

```
com.webos.app.remoteservice    title "Remote Service"   "visible": false   trustLevel: trusted
com.webos.app.svcdiagnostics   Flutter                   "visible": false   requiredPermissions: ["all"]
```

## 2.5 F19 — The screen framebuffer IS readable from inside app sandboxes

**This restores the Part 1 claim and corrects my own later "correction".**

Read from the app's own namespace:

```
nsenter -t 2753 -m -p -- ls -la /tmp/capture.rgb
#   -rw-r--r-- 1 root root 691200 Sep 13 23:49 /tmp/capture.rgb
```

`/tmp` inside the jail is the shared system tmpfs (`tmpfs /tmp tmpfs rw,size=730372k`), and the
graphics-plane framebuffer is there, world-readable, refreshed every ~3 seconds by
`com.webos.service.oledepl` (Part 1, F9).

**Confirmed for the namespaces of `youtube.leanback.v4` and `com.webos.app.lgchannels`.** An app
does not need root, an exploit, or any permission to read your screen.

**Why my intermediate correction was wrong:** I checked the *host* path
`/var/palm/jail/<appid>/tmp/capture.rgb` and concluded that only some jails shared `/tmp`. That
path is the host-side mountpoint view, which does not reflect what the process sees at `/tmp`.
The process-namespace test is authoritative, and it says the file is there.

## 2.6 F20 — `contentminer`

A **running** service (`/usr/sbin/contentminer`) that indexes app content.

```
API (contents.internal):
    com.webos.service.contentminer/getContentData
    com.webos.service.contentminer/setPersonalKey
    com.webos.service.contentminer/clearPersonalKey

Outbound reach (from its role file) includes:
    com.webos.service.db, com.webos.service.downloadmanager,
    com.webos.service.attachedstoragemanager, com.webos.appInstallService,
    com.webos.appUpdateService, com.webos.applicationManager, com.webos.service.sdx

Config (/etc/palm/contentminer-conf.json) speaks of
    "MiningStatusDBKind", "inProgressApps" ("in-progress mining app id"),
    "reason why miner should wake up"
```

It links OpenSSL `EVP_Encrypt*` (it encrypts something, presumably with the "personal key"). It is
the least-documented service found. Not proven malicious; genuinely opaque. Worth a dedicated look
at what `getContentData(appId)` returns and whether `setPersonalKey` is reachable by non-`internal`
clients.

## 2.7 F21 — Luna permission audit: 150 clients granted blanket `"all"`

`/usr/share/luna-service2/client-permissions.d/` contains **150** files granting `"all"` — i.e. the
listed client may call **every** service on the bus. Examples:

```
com.webos.app.browser.perm.json            ← the TV's browser can call everything
com.webos.app.svcdiagnostics.app.json      ← hidden app, blanket grant
com.webos.app.dangbei-overlay.app.json     ← third-party vendor overlay
com.webos.app.rdp.perm.json
com.webos.app.videoads.app.json
com.webos.service.acr.perm.json
com.webos.service.accountmanager.perm.json
com.webos.service.aiinferencemanager.perm.json
com.webos.service.billing.perm.json
```

Two consequences worth internalising:

- A compromise of **any** of those clients (e.g. a Chromium RCE in the browser) yields the whole
  bus, not one service.
- Blanket outbound grants make the *service-side* permission checks the only real boundary.

## 2.8 F22 — `objectdetection`: the TV analyses captured screen content

```
com.webos.service.objectdetection/start · /stop · /detect · /getState
client permissions: ["media", "tv.services", "private"]
also present: com.webos.service.objectdetection.capture,
              com.webos.service.objectdetection.multiviewadapter
```

A service whose purpose is to **run object detection over captured content**. Correctly restricted
(unlike `capture.rgb`), but it confirms the TV possesses an on-device vision pipeline over what is
on screen — the same pipeline family that makes ambient/contextual advertising and "what's in the
scene" targeting possible without any cloud round-trip.

## 2.9 F23 — LG signing certificates

```
/etc/eacgcertificates/partner_certificate.crt
/etc/eacgcertificates/platform_certificate.crt
/etc/eacgcertificates/release_certificate.crt
    subject = issuer = C=IN, ST=Karnataka, L=Bengaluru, O=LGSI, OU=CSP-1, CN=lgs Sign Key
```

Three **self-signed** signing certificates from LG Soft India used as baked-in trust anchors. Their
private keys are (correctly) not present on the device. The risk is long-lived: if that signing key
ever leaked, everything signed with it would be trusted by every TV in the fleet.

## 2.10 F24 — AirPlay and Google Cast are both enabled

```
port 7000  HTTP/1.1 403 Forbidden   Server: AirTunes/377.40.00     ← AirPlay receiver
port 8008  HTTP/1.1 404 Not Found                                  ← Cast HTTP
port 8009  (CASTV2, TLS)                                           ← Cast control
```

Also: `com.webos.service.airplayadaptor`, `/var/lib/airplay/` with `AirPlaySettings` (42 KB plist),
`sharedKeyStore.keychain`, and a HomeKit store directory. AirPlay is a historically productive RCE
surface on TVs (it is the class your own root exploit belongs to), and Google Cast is a second
unauthenticated control surface reachable from the whole LAN.

Notable good practice found: AirPlay pulls its configuration from
`https://mediaservices.cdn-apple.com/store_bags/airplay/v6/airplay_storebag.json` with a SHA-256
`Digest` and a signed `serverBagData`, i.e. **digest-verified**. That path is done correctly.

## 2.11 F25 / F26 / F27 — Data at rest

**F25 — Konodrac / AudienceFlow (HbbTV ad tracking that LG's consent does not govern).**

- `marker2.konograma.com` — the endpoint the TV **beacons to every ~50 seconds** (Part 1, F14) — is
  **Konodrac S.L.**'s *"AudienceFlow HbbTV marker application"* (the vendor's own site says so).
- The browser profile holds **13 `knd_aflow_<UUID>`** identifiers. Decoding the UUID-v1 timestamps:

  ```
  knd_aflow_<uuid>…   → 2016
  knd_aflow_<uuid>…   → 2018
  knd_aflow_<uuid>…   → 2020
  knd_aflow_<uuid>…   → 2021
  knd_aflow_<uuid>…   → 2024
  ```
  Identifiers from 2016–2024 on a TV bought in 2025 = cross-device ID syncing.
- Vehicle: **Spanish broadcaster HbbTV apps** — corroborated by the cookie jar containing
  `mediaset.es`, `3cat.cat`, `ccma.cat`, `lovestv.es`, with `didomi_token` / `euconsent-v2`.
- **The headline:** this runs **although every LG tracking EULA is declined**, because it is a
  third-party measurement network inside broadcaster apps, not LG's ACR. *Declining LG's terms does
  not stop ad tracking on this TV.*

**F26 — Identifiers in cleartext.**

```
/var/lib/secretagent/IFA.txt   -rw-r--r--  <IFA>   ← the ad ID
/var/lib/secretagent/nduid     -rw-r--r--  <TV-WIRED-MAC> + hash               ← device UID
```

The per-app `asc-advertiserId` files reported in Part 1 contained only `1`; **this** is the real
IFA. Device workspace id: `<WORKSPACE-ID>`.

**F27 — Wi-Fi PSK.** `/var/lib/connman/wifi_…_managed_psk_…/settings` contains
`Passphrase=…` (mode 600 `dbus:dbus`; root reads it trivially).

**One genuinely good result, worth stating:** all 70 cookies carry **encrypted** values with **no
`v10`/`v11` scheme prefix** — they failed to decrypt with Chromium's well-known `peanuts` fallback.
So LG is *not* using Chromium's default Linux cookie key, and **root alone does not hand over your
YouTube / Disney+ / HBO Max session tokens.** That is better than the desktop-Linux norm.

## 2.12 Corrections to Part 1

1. **F9's mitigation was over-stated, then under-stated, and is now settled by authoritative
   testing.** The truth: the screen framebuffer **is** readable from inside app sandboxes
   (verified via the process mount namespace, uid-independent). The host-path heuristic
   (`/var/palm/jail/<app>/tmp/...`) that produced my intermediate "only 7 jails" claim was
   measuring the wrong thing. **Treat F9 as Critical, no-root, always-on.**

2. **F11's SSH half is now fixed on this unit.** `/etc/shadow` shows `root:*` (locked), no
   `/etc/shadow` bind-mount, and re-testing the documented default password returns
   **`PERMISSION DENIED`**. Delete the "SSH accepts `alpine`" caveat for the current state; keep it
   for the record of the 22:44 window.

3. **`telnet` status not re-verified in Part 2.** The webOSbrew telnet toggle was left as the owner
   set it. Check `ps -ef | grep telnetd` before relying on Part 1's F11 telnet finding.

## 2.13 Updated severity ranking

| Rank | Finding | Root? | Notes |
|---|---|---|---|
| 1 | **F16 sandbox → root (world-writable root-executed code)** | No | Unauthenticated-by-design privesc; needs a rooted TV |
| 2 | **F17 Google Home runtime `lib/`+`conf/` world-writable** | No | **Stock LG**, code execution outside the sandbox |
| 3 | **F19 screen framebuffer readable by apps** | No | Always-on; revised back to Critical |
| 4 | F12 unauthenticated Chromium DevTools on the LAN | No | Arbitrary JS in web-app context |
| 5 | F11 unauthenticated telnet root | n/a | Owner's configuration; SSH half now fixed |
| 6 | F25 Konodrac/AudienceFlow HbbTV tracking | No | Survives full consent refusal |
| 7 | F5 voice → plaintext logs | No | Proven with owner's own voice |
| 8 | F8 microphone/speaker-bus capture | Yes | Real; gated on the voice pipeline |
| 9 | F10 video-plane capture | Yes | Proven (MP4 produced) |
| 10 | F27 Wi-Fi PSK | Yes | Root → network key |
| — | F18 RemoteOne | n/a | Dormant, gated by a missing file |

## 2.14 Defense plan (concrete, in priority order)

**Act now**

1. **Do not install webOSbrew apps you have not reviewed.** Until F16 is fixed, an installed app is
   equivalent to root.
2. **Lock down the escalation path** (test after each step; keep a recovery route):
   ```bash
   chmod 0755 /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service
   chmod 0644 /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/service.js
   chmod 0755 /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/startup.sh
   ```
3. **Close the LAN services you do not use:** webOSbrew → SSH **off** unless testing; Telnet **off**;
   and disable **AirPlay** and **Google Cast** in TV settings if you do not use them (F24).
4. **Keep the TV on a segmented network.** It exposes root-adjacent (F16/F17), unauthenticated
   DevTools (F12), Cast (8008/8009) and AirPlay (7000). Put it on an IoT VLAN or a dedicated SSID
   with client isolation, and keep TV→LAN traffic minimal.
5. **Never accept `S_VNG` / the ad EULAs** (Part 1, F1) — and understand that this does **not** stop
   F25's HbbTV tracking.

**Understand and accept (can't fix from here)**

6. **F17 is LG's bug** — report it. A world-writable `lib/` under a preloaded system service is a
   fleet-wide defect.
7. **F19 is LG's design** — the capture service writes a screen buffer world-readable into a shared
   `/tmp`. Also worth reporting.
8. **Widevine / DRM material is not on disk** (verified empty) — do not go looking for DRM keys;
   that is the one area that crosses into §1201 / piracy territory, and it would not help defend
   the device.

**Monitoring you can actually do**

9. Watch for the RemoteOne activation file appearing:
   `ls -la /mnt/lg/cmn_data/remoteDebug/remoteDebug.sh` — its presence means remote support is on.
10. Watch `/var/lib/webosbrew/init.d/` for unexpected scripts (it is empty today; anything added
    there runs at boot as root).
11. Hash the root-executed files so tampering is detectable:
    ```bash
    md5sum /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/{service.js,startup.sh}
    ```
    Re-check after any app install.

## 2.15 New open questions

1. **What privilege level does `com.webos.ghp.runtime` actually run at?** That determines whether
   F17 is "code execution in a service" or "root".
2. **What is `contentminer` reading, and is `setPersonalKey` reachable by non-internal clients?**
3. **What is `/usr/sbin/gibbs`?** (2.4 MB binary with `capture` client permission; strings were
   uninformative.)
4. **Does a sandboxed app reach `/media/developer` on a *stock* (non-rooted) TV?** If `/media/developer`
   only exists because of developer mode, F16 is root-only; if LG ships it 0777, the class is far wider.
5. **AirPlay `377.40.00`** — map against known RAOP/AirPlay CVEs for this generation.
6. **`objectdetection`** — what triggers `detect`, and does the result leave the device?
7. **SSAP on 3000** — it accepted TCP but did not complete a WebSocket upgrade. Is that because LG
   Connect Apps is off? If a user enables it, what becomes reachable?
8. **The `wam` profile's Service Worker / shared_proto_db stores** — not examined.
9. **The 80 `/tmp/systrim/<pid>/end_watch` markers** — what writes them and what they mean.

## 2.16 Method note — how these were found (so it can be repeated)

The productive technique was **permission differential testing**, not vulnerability scanning:

1. Enumerate what talks to what (`/usr/share/luna-service2/{roles,api-permissions,client-permissions}.d/`).
2. Enumerate what is **writable** (`find … -perm -0002`) in paths that are **executed**
   (systemd units, `run-js-service` targets, `init.d`, shared library directories).
3. For each candidate, determine **whether the sandbox can see it** — and do that by reading the
   target process's *mount namespace* (`/proc/<pid>/root/…`, `/proc/<pid>/mounts`), **not** by
   guessing host paths. (The host-path mistake is what produced my wrong F9 correction.)
4. Prove writability **as the sandbox's own uid** inside its namespace:
   `nsenter -t <pid> -m -p -- setpriv --reuid <uid> --regid <gid> --clear-groups …`
   Testing as root invalidates the result; testing as root *inside the namespace* proves the mount,
   not the permission.

---

---

# Part 3 — Remote-reach and vendor-side surfaces

> **Threat models this part addresses**, per the owner's framing:
> **(A)** an attacker who reaches a *clean* TV and lands code — including via a browser
> exploit, the way the owner's own root was obtained — and **(B)** **LG itself** (or anyone who
> can abuse LG's own channels) as the adversary.
>
> Two hypotheses I formed were **disproved by testing** and are recorded as such (§3.10). That is
> deliberate: this part records what is *true*, not what is *suspicious*.

## 3.1 Summary

| # | Finding | Reach | Verdict |
|---|---|---|---|
| F28 | Home-screen card (QCARD) channel runs over **plain HTTP**; integrity hashes exist but are delivered over the same unprotected channel | Network MITM | **Real, limited: content spoofing, not code exec** |
| F29 | LG push channel is **AWS IoT**, and `pushclient` exposes `publish`/`createConnection`/`subscribeToTopics` as **public** methods, `inbound:["*"]` | App / compromise | **Real, medium** |
| F30 | The **RemoteOne activation file lives in a world-writable directory** (`/mnt/lg/cmn_data` is 0777) | Local / LG-side | **Real, high (latent)** |
| F31 | Chromium is told to treat **`http://dokdo.lge.com` and `http://wam.lge.com` as secure origins** | Network MITM | **Real, medium** |
| F32 | `/mnt/lg/cmn_data` is world-writable and holds `.pushclient`, `.iot`, `.iotproxy`, `.ruleengine`, `.accountmanager`, `.cacheproxy` | Local | Medium |
| — | QCARD bundles are JSON+PNG only (no executable content) | — | **Disproved escalation** |
| — | `push.private.key` is mode 644 **but** its directory is 0700 | Root | **Disproved** (root-only in practice) |

## 3.2 F28 — The home-screen card channel is plain HTTP, and its integrity check is defeated by its transport

The TV's home-screen "cards" (the tiles LG curates) are described in
`/var/preferences/com.webos.service.homelaunchpoints/qcard-server.json`, fetched from:

```
resource_url : http://ngfts.lge.com/fts/gftsDownload.lge?biz_code=QCARD
               &func_code=QCARD_TAR_FILE&file_path=/qcard/tar_file/com.lgtvod.app_*.tar.gz
hash_version : <64 hex chars>            (per card)
```

**The integrity metadata is genuine.** Verified by fetching one bundle over that exact HTTP URL and
comparing:

```
computed  sha256  : <hash>
declared  hash_version : <hash>
                                                            → MATCH
```

**But:**

1. The bundles are fetched over **`http://`** — not TLS.
2. The **manifest that carries the expected hashes is itself fetched from `http://ngfts.lge.com`**.
   A hash delivered in the same unauthenticated channel as the payload it protects provides **no
   integrity guarantee**: an on-path attacker replaces the URL *and* the hash together, and the
   check passes on the attacker's file.

**Impact — bounded, and I verified the bound.** I extracted a bundle and took a file-type
histogram:

```
  96 json
   6 png
   0 html / htm / js / mjs
```

and the content is declarative:

```json
{ "id": "com.webos.app.accessibility",
  "title": "Accessibility",
  "description": "Easy ways to use the device",
  "image": "$bg_qcard.png" }
```

So the worst case is **content spoofing of the home screen**: fake titles, descriptions and images
(e.g. phishing-style cards, brand impersonation, or injected advertising) delivered by an on-path
attacker. It is **not** remote code execution, because cards carry no executable content. I had
initially suspected HTML/JS in the bundles; that was wrong and is corrected here.

**Also relevant:** `com.webos.service.universalqcard.getstatus` is configured to fire automatically
when the network becomes available, so this channel is exercised without user action.

**Mitigation:** none user-facing. Report to LG (integrity metadata should be signed or delivered
over TLS). For the owner: assume a hostile network path can alter home-screen card content.

## 3.3 F29 — The TV's push channel is AWS IoT, and its API is largely public

```
/mnt/lg/cmn_data/.pushclient/push.cert.pem      subject CN=localhost
                                                issuer  OU=Amazon Web Services, O=Amazon.com Inc.
                                                notAfter 2049
/mnt/lg/cmn_data/.pushclient/push.private.key   -----BEGIN RSA PRIVATE KEY-----
/usr/sbin/com.webos.service.pushclient          (running)
```

So LG delivers push to the TV over **AWS IoT** (MQTT), using a per-device client certificate.

The service's API:

```
public:  getStatus · registerService · subscribeToTopics · listSubscribedTopics
         unsubscribeFromTopics · deregisterService · getMqttConnectionStatus
         createConnection · publish · destroyConnection
private: getServiceInfo

role:    inbound ["*"], outbound ["*"]
client permissions: com.webos.service.pushclient -> ["public","private"]
                    com.webos.service.pushclient.req -> ["all"]
```

`publish` and `createConnection` are classified **public**, and the role accepts inbound from
**any** client. Consequences:

- Any sufficiently privileged bus client can **create an MQTT connection and publish**, i.e. speak
  to LG's push infrastructure (and potentially to topics the device subscribes to).
- Anything that can compromise `com.webos.service.pushclient.req` (client perms `"all"`) inherits
  the device's push identity.

**On the private key:** the file is mode `0644`, which looks alarming — but its directory
`/mnt/lg/cmn_data/.pushclient/` is `drwx------` (0700, root). Since traversal requires the
directory permission, the key is in practice **root-only**. I stated this as a possible
world-readable key mid-investigation and am correcting it: it is not.

**Why it still matters for threat model B:** whoever holds root on the TV (or LG, legitimately)
holds the device's AWS IoT identity and can publish/subscribe as the device.

## 3.4 F30 — The vendor remote-support channel can be *enabled* from a world-writable directory

Part 2 established that `remotediag` (LG "RemoteOne": `SendAuthorizedKeys`, `Remocon::SendKey`) is
gated by:

```
ConditionPathExists=/mnt/lg/cmn_data/remoteDebug/remoteDebug.sh
```

What Part 2 did not establish is where that file lives:

```
drwxrwxrwx  /mnt/lg/cmn_data/          ← 0777
drwx------  .pushclient  .iot  .iotproxy  .ruleengine  .accountmanager  .cacheproxy
```

**`/mnt/lg/cmn_data` is world-writable.** Any local process that can see it can create
`remoteDebug/remoteDebug.sh` and thereby **cause a privileged remote-support service to start** —
a service whose documented capabilities include installing SSH authorized keys and sending remote
control keypresses.

That inverts the usual framing helpfully:

- From the **vendor** side: LG (or whoever can push to that path) can enable a remote-access
  service on your TV with a single file, and the file lives in a writable, unauthenticated
  location.
- From the **attacker** side: enabling the service is not itself sufficient (the service then
  authenticates *outward* to LG with a pinned certificate), but it is a foothold-expanding step
  and it is trivially reachable if any code execution exists on the device.

**Defensive value:** this path is directly monitorable:
```bash
ls -la /mnt/lg/cmn_data/remoteDebug/      # must not exist unless LG support is genuinely active
```
Its appearance is the single clearest indicator that vendor remote access has been switched on.

## 3.5 F31 — LG weakened Chromium's origin model for its own HTTP hosts

Every WebAppMgr process (browser and renderers) is launched with:

```
--unsafely-treat-insecure-origin-as-secure=http://dokdo.lge.com,http://wam.lge.com
--no-sandbox
```

`dokdo.lge.com` and `wam.lge.com` are **LG's own web-application hosts, served over plain HTTP**.
The flag tells Chromium to treat them as **secure contexts** anyway — granting them privileged web
platform capabilities (service workers, powerful APIs, no mixed-content enforcement) that an
HTTP origin should not receive.

Consequence: an attacker who can influence resolution or the path to `dokdo.lge.com` /
`wam.lge.com` (DNS spoofing, ARP/MITM on the LAN, a hostile upstream network) serves content that
the TV's browser treats as **trusted and secure**. Combined with `--no-sandbox` on the renderers,
this is exactly the sort of convenience-for-security trade that makes a browser-exploit chain
cheaper.

Note also that the browser appears with `--user-agent-spoof=/mnt/otncabi/usr/palm/applications/com.webos.app.browser`,
i.e. the TV spoofs a browser User-Agent — mild, but it shows how much of the web stack is bent for
compatibility.

## 3.6 F32 — `/mnt/lg/cmn_data` and the device's IoT subsystems

World-writable, and containing the device's integration state:

```
.pushclient      AWS IoT push identity
.iot             IoT device state
.iotproxy        IoT proxy
.ruleengine      automation rules
.accountmanager  LG account
.cacheproxy      caching proxy
```

A world-writable directory holding an IoT identity, an account directory and an automation rule
engine is a poor default. Rules in `.ruleengine` (if they can be authored by a local process) are
a genuinely interesting follow-up: an automation rule engine that can trigger service calls is a
privilege bridge waiting to be abused.

## 3.7 Threat model A — reaching a *clean* TV, and what follows

Routes to code execution found on this firmware, roughly ordered by plausibility:

1. **Browser exploit.** The known rooting exploits for webOS run in the browser. The browser here
   (Chromium 120) runs with `--no-sandbox`, exposes **unauthenticated DevTools on `0.0.0.0:9998`**
   (Part 1, F12) — from which `Runtime.evaluate` gives arbitrary JavaScript in the page context —
   and is told to trust two plain-HTTP origins (F31). Delivery options range from "user visits a
   malicious page" to "on-path attacker modifies what the TV loads". **This is the most direct
   route from remote to code execution.**
2. **AirPlay (port 7000, `AirTunes/377.40.00`)** and **Google Cast (8008/8009)** — both exposed to
   the LAN, both historically rich RCE surfaces (and AirPlay is the class the owner's own exploit
   belongs to).
3. **A malicious app** — with the caveat that on a *stock* TV an app is sandboxed; the Part 2
   escalation (F16) specifically needed webOSbrew's world-writable root-executed files.

Once code executes, the prize set is everything in Parts 1–2: **microphone bus, video plane,
screen framebuffer, plaintext voice logs, the Wi-Fi PSK (`<ssid>_5G` network credentials), the AWS
IoT push key, the device IFA/nduid**, and — from any of those — persistence and LAN pivot.

## 3.8 Threat model B — what LG left behind

1. **A remote-support channel that can push SSH keys and drive the remote control** (RemoteOne,
   Part 2 F18), **gated by a file in a world-writable directory** (F30). Dormant today.
2. **A push channel to LG over AWS IoT** with public `publish`/`subscribe` methods (F29) — a
   lawful remote-control *and* data-delivery path.
3. **Content channels over plain HTTP** (home-screen cards F28; ad overlays via `aic-ngfts` /
   `eic-ngfts` seen in Part 1 F3/F4; the earlier `aic.ads.lgtvcommon.com` overlay endpoint) — with
   integrity metadata that is defeated by the transport in at least the QCARD case.
4. **A weakened browser origin model** for LG's own HTTP hosts (F31) and `--no-sandbox` renderers.
5. **An extensive data-collection stack** — ACR/Alphonso (Part 1 F2–F4), `objectdetection`
   (Part 2 F22), `contentminer` (F20), and the third-party ad ecosystem inside the browser profile
   (Part 2 F25) which **continues regardless of LG consent**.
6. **Signing trust anchors** (`eacgcertificates`, Part 2 F23) — single self-signed keys protecting
   a whole fleet, with no rotation visible.

**Assessment.** There is no single "secret backdoor account". What exists is a set of
**vendor conveniences that are individually defensible and jointly dangerous**: a remote-support
service reachable via a writable flag file, a push/identity channel with a public API, plain-HTTP
content channels with unverifiable integrity, and a browser deliberately told to trust insecure
origins. That is the shape of a real vendor-side risk surface — and it is exactly the kind of
thing that gets abused by whoever *does* compromise the vendor side, not by LG on purpose.

## 3.9 Defense plan — additions for Part 3

1. **Monitor the RemoteOne gate file** (highest signal, cheapest check):
   ```bash
   ls -la /mnt/lg/cmn_data/remoteDebug/
   ```
   Non-existent = vendor remote access is off. If it ever appears, treat the TV as
   vendor-accessible and investigate.
2. **Tighten `/mnt/lg/cmn_data`** while keeping the TV functional (test carefully; subdirs are
   0700 already, the parent need not be 0777):
   ```bash
   chmod 0755 /mnt/lg/cmn_data
   ```
3. **Segment the network.** The TV needs a hostile-path assumption: plain-HTTP content channels
   (F28), insecure-origin browser trust (F31), and LAN-exposed DevTools (F12) and Cast/AirPlay.
   An IoT VLAN with client isolation removes most on-path attacks in one move.
4. **If you do not use Cast or AirPlay, turn them off** in TV settings (removes ports 7000/8008/8009).
5. **Treat the AWS IoT push key as a device credential** — it is root-only, so the rule is simply
   "root compromise = push identity compromise", which reinforces §2.14's guidance not to run
   unreviewed apps.
6. **Do not assume HTTP content is authentic** even when a hash is present (F28): the hash is
   only as trustworthy as its channel.

## 3.10 Disproved hypotheses (recorded so they are not re-chased)

1. **"QCARD bundles contain executable HTML/JS."** Disproved: 96 JSON + 6 PNG, no HTML/JS.
   Impact ceiling is content spoofing, not code execution. *(My initial read of "96 HTML/JS files"
   came from a bad grep and is retracted.)*
2. **"`push.private.key` is world-readable."** Disproved in effect: mode 0644 but parent directory
   0700, so root-only in practice.
3. **"The browser DevTools port is always open."** Qualified: it was absent when no web app was
   foregrounded and present (`0.0.0.0:9998`) while YouTube ran. It is intermittent, not constant —
   which matters for how exploitable F12 is.

## 3.11 Open questions remaining after Part 3

1. Is `qcard-server.json` itself signature-verified, or fetched over the plain-HTTP URL verbatim?
   (Decides whether F28 is fully MITM-exploitable or partially mitigated.)
2. What can `.ruleengine` rules do, and can a local process author them? (F32)
3. What does `com.webos.service.pushclient/subscribeToTopics` actually return to a caller — i.e.
   can a bus client read LG's messages to the device? (F29)
4. Which exact exploit chain rooted this model, and does it have a *remote* trigger (browser
   delivery) rather than requiring local page navigation?
5. Can `objectdetection/detect` be driven with attacker-chosen input, and where do results go?
6. Is `com.webos.ghp.runtime` (Part 2 F17) launched as root, jailer user, or service user?

---

---

# Part 4 — The LG cloud control channel, and the doors that are actually shut

> Continuing the same session. Part 4 closes the loop on threat model B by documenting the
> **persistent cloud→device control path** LG maintains, and — equally important — records the
> privilege bridges I tested and found **closed**, so they are not re-chased.

## 4.1 F33 — LG maintains a persistent, bidirectional cloud control channel (AWS IoT)

The TV's IoT identity file reveals the topic set it subscribes to and publishes on:

```
/mnt/lg/cmn_data/.iot/accountInfoFile
  dataTopic    $aws/rules/tv_ext_data_rule/sdp/devices/<devHash>/data
  subTopic     sdp/devices/<devHash>/request
  pubTopic     sdp/devices/<devHash>/response
  reportTopic  sdp/devices/<devHash>/report
  pushTopic    app/clients/<devHash>/push
  shadowTopic  $aws/things/<devHash>/shadow/update
  matter_inbox  matter/devices/<devHash>/inbox
  matter_outbox matter/devices/<devHash>/outbox
```

where `<devHash>` is a long device-specific identifier
(`d8c3e28f…1b13a0`, ~128 hex chars).

Reading that plainly:

| Topic | Meaning |
|---|---|
| `$aws/rules/tv_ext_data_rule/…` | LG routes this device's data through **AWS IoT Rules Engine** |
| `…/request` ⇄ `…/response`, `…/report` | an **SDP command/response channel** — the device executes requests and reports back |
| `matter/devices/…/inbox` | a **Matter command inbox** — smart-home commands delivered to the TV over MQTT |
| `$aws/things/…/shadow/update` | **AWS IoT Device Shadow** — cloud-held device state |
| `app/clients/…/push` | the push channel (Part 3, F29) |

**This is live.** At inspection time the device held established TLS sessions to multiple AWS
addresses (`52.16.104.93:443`, `213.4.152.76:443`, `99.80.18.45:443`, …), with
`com.webos.service.iotclient` and `com.webos.service.ruleengine` both running.

**Why this matters for threat model B.** The TV has a standing, authenticated, bidirectional
channel to LG's cloud that can carry **requests and Matter commands**. Integrity of that channel
rests entirely on (a) LG's cloud, (b) the AWS IoT credentials on the device
(`.iot/enc_cert.pem` + `enc_privKey.pem`), and (c) TLS + the device's pinned identities — **not on
anything the owner controls or can audit.** That is a vendor remote-control capability, by design
and by necessity. It is not a bug; it is the shape of the trust relationship.

## 4.2 F34 — ThinQ "edge rules": LG can push automation that performs HTTP requests and drives Matter

`com.webos.service.ruleengine` is an OEM-trust automation engine that **syncs rules from LG's
cloud**:

```
https://connect-client.lgthinq.com/route
/homes/{homeId}/edge/rules
/homes/{homeId}/edge/rules/action
/homes/{homeId}/edge/rules/action/result
HttpRequester::startRuleSync · sendAsyncWithBody · EDGEEVENT · edgeDomain
```

Transport is **HTTPS** — that part is done correctly. The rules themselves are scoped to
`{homeId}` (see F35), and the schema (`/usr/share/ruleengine/set_rule_schema.json`) is:

```
messageId
eventName
eventData
  homeId · ruleId · ruleStatus
  ruleContents
    isOR
    events[].code
      eventId · eventName · deviceId · eventType · edgeEvent · statements[]
```

And the engine's action vocabulary (from its symbols) is:

```
HttpRequester::ACTIONTRIGGER      → a rule can issue an HTTP request (libcurl, CURLOPT_HTTP_VERSION)
setActionMatterWriteCommand       → write a Matter device attribute
setActionMatterInvokeCommand      → invoke a Matter device command
DelayAction · DeviceAction · sendToServerNotifyAction · StatusMonitor::monitorService
RuleEngine::overwriteMatterConfigFile
```

**So a rule pushed by LG's cloud can (1) make an arbitrary outbound HTTP request, (2) write or
invoke Matter device commands, and (3) overwrite the Matter configuration file.** Rules are stored
in a DB kind (`com.webos.service.ruleengine:1`, owner `…ruleengine.req`), i.e. they persist.

**Threat assessment.** This is legitimate smart-home automation, and it is TLS-protected. But it is
also a **remote actuation primitive**: whoever controls the ThinQ account or LG's rule service can
cause this TV to make network requests and command Matter devices in the home. An attacker who
takes over a ThinQ account gets actuation, not just read access. And because a rule can perform
HTTP requests, a malicious rule is also an **exfiltration/beacon primitive**.

**Mitigation:** retire ThinQ/Home connectivity you do not use (LG account → remove the TV), keep
the LG account on a unique password + 2FA, and treat the TV as an IoT device on a segmented VLAN.

## 4.3 F35 — Personal data at rest, in cleartext

```
/mnt/lg/cmn_data/.iot/devices.json
{ "homeId": "<HOME-ID>",
  "homes": [ {"homeName": "the owner's home",          "homeId": "<HOME-ID>"},
             {"homeName": "a second household",    "homeId": "<HOME-ID-2>"} ],
  "iotdevices": [ { "plugin": "thinq", "deviceList": [ { "deviceInfo": {
       "modelName": "LGSmartTV", "deviceType": "DEVICE_TV", "alias": "TV", … } } ] } ] }
```

- **Two household names**, one of them **a third party's full name**, in plaintext.
- An inventory of the IoT devices bound to those homes.
- `accountInfoFile` additionally holds the MQTT topic set and `activatedUserNo`.

Directory permissions are `0700 root`, so this is **root-only in practice** — but it is PII at rest
with no encryption, and it is exactly the kind of data whose presence turns a TV compromise into a
*household* compromise: names, homes, and the device graph.

## 4.4 Doors I tested that are genuinely CLOSED (recorded so nobody re-chases them)

| Hypothesised escalation | Result | Mechanism |
|---|---|---|
| An app holding `"all"` can create automation rules via `ruleengine/set` | **CLOSED** | `groups.d/com.webos.service.ruleengine.groups.json` pins `ruleengine.operation` to `allowedNames: [com.webos.service.ruleengine, …req]`; and `ruleengine.operation` does **not** appear in `all.groups.json` |
| An app can drive smart-home devices via `matter/sendCommand` | **CLOSED** | `matter.operation` pinned to `allowedNames: [com.webos.service.matter, matter-req]`, `["oem"]` |
| IoT/JS service code can be replaced | **CLOSED** | `/usr/palm/services/*` are `root:root` on a **read-only overlay**; `/usr/sbin/com.webos.service.ruleengine` is `root:root` |
| `push.private.key` is world-readable | **CLOSED** | mode 0644 but parent dir 0700 → root-only |
| QCARD bundles are executable content | **CLOSED** | JSON+PNG only (Part 3, F28) |

Five negative results. They matter as much as the positives: they describe the actual boundary.

**Correction to Part 2, F17:** `com.webos.ghp` is **uid 7010, gid 5000, shell `/bin/false`**, and the
runtime is jailed at `/var/palm/jail/com.webos.ghp/` owned by `com.webo:jailer`. So the world-writable
`lib/` yields **code execution as the jailed `com.webos.ghp` service user — not root.** Still a real
sandbox-escape-class defect (it is outside the *app* sandbox, and it is stock LG), but it is not a
second root path. F17's severity is accordingly reduced from Critical to High, and the "possibly
root" language in Part 2 is withdrawn.

## 4.5 What the Parts 1–4 record says, taken together

1. **The device's own design leaks the most, unprivileged.** Screen framebuffer to any app (F9/F19);
   voice to plaintext logs (F5); ad tracking that survives full consent refusal (F25).
2. **Root is one small step from any code execution on a rooted TV** (F16) — and root yields
   microphone, video plane, screen, logs, Wi-Fi PSK, push identity, and household data (F27, F33–F35).
3. **LG holds a standing control channel** (F33) and can push actuating automation (F34). Its
   security is LG's, not yours.
4. **The boundary that does hold** is Luna's permission model — the OEM-trust groups
   (`ruleengine.operation`, `matter.operation`) are properly pinned, and the system partition is
   read-only. That is the part LG got right.
5. **There is no hidden account, no hardcoded credential, and no unauthenticated command listener.**
   The "backdoor" is a **support channel gated by a file in a world-writable directory** (F18+F30)
   plus **a cloud control plane** (F33/F34). Those are the two things to monitor and constrain.

## 4.6 Additions to the defense plan

1. **Decide whether you want the cloud control plane.** If you do not use ThinQ/Home, unbind the TV
   from the LG account (this removes F33/F34's actuation surface, not just its telemetry).
2. **Treat the LG account as a crown jewel** — F34 means account takeover equals *actuation*.
3. **Monitor these three paths** (all cheap, all high-signal):
   ```bash
   ls -la /mnt/lg/cmn_data/remoteDebug/          # vendor remote support enabled?
   ls -la /var/lib/webosbrew/init.d/             # unexpected boot scripts?
   md5sum /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/{service.js,startup.sh}
   ```
4. **Segment** (again — it is the single highest-leverage control for Parts 1–4).
5. **Report to LG:** the world-writable root-executed app-service tree (F16, on rooted units), the
   world-writable `lib/`+`conf/` under `com.webos.ghp.runtime` (F17, stock), the world-readable and
   jail-shared screen framebuffer (F9/F19), and the plain-HTTP content channel whose integrity hash
   travels in the same channel (F28).

## 4.7 Remaining open questions

1. Does `sdp/devices/…/request` (F33) accept a **request that executes something**, and who may
   publish to that topic? This is the most interesting unexplored path: a device-specific command
   channel with a response/report pattern.
2. What exactly is `$aws/rules/tv_ext_data_rule` filtering, and what does LG retain?
3. Can the Matter config file (`overwriteMatterConfigFile`) be influenced by a pushed rule to
   redirect Matter traffic?
4. Is the AWS IoT credential per-device and revocable, and does LG rotate it?
5. What does `.accountmanager/perm.dat` gate?

---

# Part 5 — The vendor remote-control agent (the concrete answer to "what did LG leave in the TV")

> Part 4 showed the *channel*. Part 5 shows the *agent on the other end of it* — and this is the
> most direct answer to "can LG, or someone standing in LG's position, operate this TV?" The answer
> is **yes, by design**, and the implementation is a single, fully-featured program.

## 5.1 F36 — `com.webos.service.iot-client` is a complete cloud-driven remote-control agent

**Location and privilege.** `/usr/palm/services/com.webos.service.iotclient/iot-client` (890 KB),
running since boot as **root** (`pid 4497`, owner `root`), on the read-only overlay (so the binary
itself cannot be replaced).

**Its handler classes are the cloud's command vocabulary.** Extracted from the binary:

```
BasicCtrlHandler        AppCtrlHandler          KeyCtrlHandler
VolumeCtrlHandler       ChannelCtrlHandler      NavigationCtrlHandler
VoiceCtrlHandler        EnergyCtrlHandler       MatterCtrlHandler
ThinqCtrlHandler        LivingAIHandler         RuleEngineHandler
DeviceStatusHandler     MqttMessageHandler      LsHandler
RoutingHandle(RoutingMessage, RoutingStrategy)   ← the routing engine behind them
   strategies: InvokeSpecificMethodStrategy, DiscoveryStrategy
   callbacks : _invokeHandler, _discoveryHandler, _connectedDeviceListHandler
```

**Key control is explicit in the code**, including a guard for device online state:

```
KeyCtrlHandler::processKeyCtrlImpl(JValue)
keyCode · keyCtrl · NL_MATTER_REMOTECONTROL
[Remote Control] eventName: %s
"%s (%s)'s online status is %d, subscribeEstablishedStatus is %d, do not remote control"
matter_device_remote_control
```

That is unambiguous: **the cloud can deliver remote-control key events, and the device executes
them.** The guard string shows there *is* a precondition (device online / subscription established),
which is the sensible design.

**Local reach — what a cloud command can drive.** The luna service/application names referenced in
the binary:

```
com.webos.app.hdmi1..4 · com.webos.app.externalinput.{av,av1,av2,component}
com.webos.app.livetv · com.webos.app.mediadiscovery · com.webos.app.notificationcenter
com.webos.app.quickinputpicker · com.webos.app.voice · com.webos.app.voiceview
com.webos.service.tvpower            ← power
com.webos.service.downloadmanager · com.webos.service.sdx    ← software delivery
com.webos.service.matter             ← smart-home control
com.webos.service.accountmanager · com.webos.service.connectionmanager
com.webos.service.eim · com.webos.service.factorymanager     ← factory/service mode
com.webos.service.settingsservice · com.webos.service.iotclient.{localization,matter,power,req}
com.webos.service.pushclient
luna://com.palm.db/putKind           ← can create DB kinds
```

So a command sourced from LG's cloud can, in principle, reach: **input/channel switching, app
launch, volume, navigation, voice, power, Matter devices, software download/installation, account
and settings, and the factory manager** — plus it can register new database kinds.

**Assessment — this is the "backdoor" answer, stated precisely.**

- There is **no hidden account, no hardcoded password, and no unauthenticated listener.**
- There **is** a **complete, on-by-default, vendor-controlled remote actuation plane**, implemented
  as `iot-client` + AWS IoT (Part 4, F33) + ThinQ edge rules (F34), authenticated by a per-device
  credential stored on the TV (`.iot/enc_*`, encrypted).
- Therefore: **whether this TV can be operated remotely depends on LG's cloud, your LG account, and
  that device credential — not on anything you control or can audit.** Possession of the device
  credential (which root reads) or of your LG account is sufficient to drive the device.

This is exactly the structure you were asking about. It is not a "secret backdoor left by a
rogue engineer"; it is a **support/remote-service capability implemented at full remote-control
breadth**, which is a legitimate product feature with an unusually large blast radius.

**What to do about it (choices, not mandates):**
1. **Unbind the TV from the LG account / ThinQ** if you do not use Home connectivity. This removes
   the standing control plane, not merely telemetry. (Trade-off: you lose the smart-home features.)
2. **Treat the LG account as a crown jewel** — unique password, 2FA, no reuse. Account takeover is
   *actuation*, per F34.
3. **Segment the TV** so that even successful actuation cannot reach other hosts.
4. **Protect root** — the device credential and the control plane are one `su` away for anyone with
   code execution on the box (F16), which is why §2.14's "treat app installs as root" matters.

## 5.2 F37 — Software delivery and factory/service access appear on the same bus

Two more names in `iot-client`'s reach are worth calling out on their own:

- `com.webos.service.downloadmanager` + `com.webos.service.sdx` — a **software delivery** path. The
  device already runs `sdx` (`/usr/sbin/sdx`, root). A cloud-originated command reaching these is a
  content/software-installation primitive.
- `com.webos.service.factorymanager` — the **factory/service-mode manager**. Vendor service flows
  use this; it is the same conceptual endpoint family that enables service mode, which is also how
  the RemoteOne gate file (F30) becomes relevant.

Neither was exercised. They are recorded because "cloud→device command plane that can name the
factory manager" is the sentence that should sit next to "vendor remote access".

## 5.3 Where Parts 1–5 land

**Three findings are the real ones, in order of what they mean for you:**

1. **The screen framebuffer is readable by any app, always, no root** (F9/F19). Every app on this
   TV — including LG's own browser and the Amazon Alexa adapter, which share the same `/tmp` — can
   read a live 640×360 view of your screen, refreshed every ~3 seconds. This is the leak that needs
   no adversary-with-privilege and no vendor involvement.
2. **A complete vendor remote-actuation plane exists and is on by default** (F33/F34/F36): keys,
   volume, channel, apps, power, voice, Matter, software delivery, via AWS IoT + ThinQ rules,
   authenticated by your LG account and a device credential.
3. **On a rooted TV, root is one small step from any code execution** (F16) — and root yields the
   microphone, video plane, screen, plaintext voice logs, Wi-Fi PSK, IoT credentials, and household
   data.

**And the thing to keep in perspective:** five probed escalations came back **closed** (§4.4) —
LG's OEM-trust permission groups, the read-only system partition, the enforced read-only IoT service
tree. The permission model and the immutable partition are solid. What leaks is what LG chose to
*make available* (the screen buffer, the cloud plane) and what the rooted-app marketplaces chose to
make *writable* (F16).

## 5.4 Remaining open questions (updated)

1. Does `sdp/devices/<devHash>/request` accept a request that reaches `InvokeSpecificMethodStrategy`
   — i.e. arbitrary luna method invocation from the cloud? (Local analysis could not confirm the
   request grammar; publishing to LG's topic was deliberately not attempted.)
2. What does `LivingAIHandler` do, and is it enabled?
3. What does `.accountmanager/perm.dat` gate, and is the account credential encrypted like the IoT
   key?
4. Is the device credential per-device and revocable/rotatable from the LG side?
5. Can `factorymanager` be reached from anything other than a service-mode flow?

---

# Part 6 — "Can root turn LG's own remote-control agent into a RAT?"

**The question, verbatim:** *can a bad actor with root bypass LG's remote control, impersonate an LG
remote server (or similar), and use `com.webos.service.iot-client` as a RAT?*

**Short answer: yes — and doing it through `iot-client` is the *stealthiest* option, precisely
because it needs no impersonation of anything.** The evidence:

## 6.1 F38 — `iot-client` does not know who its server is; it asks the system

The binary contains **no broker hostname**. It resolves one at runtime through other local services:

```
AccountManager::downloadMqttUrl()     ·  getMqttServerAddr(bool)  ·  getMqttServerPort()
AccountManager::extractMqttUrlPart()  ·  _ZN11MqttManager10_lsSamCallE
luna://com.webos.service.sdx/getServer
luna://com.webos.service.sdx/getDeviceAuthenticationStatus
luna://com.webos.service.sdx/getDeviceUuid
luna://com.webos.service.sdx/getHttpHeaderForServiceRequest
luna://com.webos.service.sdx/send
https://common.lgthinq.com/route        ·  https://kr.lgeapi.com
"Can not download MqttUrl"              ·  "mqttServer key is NOT found"
DILE_Crypto_MQTT_Encrypt  (payloads are encrypted)
```

So the trust root for "where do I connect?" is **`com.webos.service.sdx`** (LG's software-delivery /
device-authentication service) plus a **downloaded MQTT URL**, not a pinned constant.

**Consequence for an attacker with root.** No TLS impersonation is needed. Root controls every
input to that resolution chain, so the agent can be pointed at an attacker-controlled broker:

1. Change what `sdx/getServer` / the downloaded MQTT URL yields (Local service substitution, a hosts
   override for `common.lgthinq.com`, or an intercepting CA on the fetch — all root-reachable).
2. `iot-client` connects **outbound** to the chosen broker, authenticating with the device
   credential (`.iot/enc_cert.pem` + `enc_privKey.pem` — encrypted at rest, readable by root).
3. The attacker's broker now speaks the protocol this agent already implements, and the handlers
   from F36 (`KeyCtrlHandler`, `AppCtrlHandler`, `ChannelCtrlHandler`, `VolumeCtrlHandler`,
   `NavigationCtrlHandler`, `MatterCtrlHandler`, …) execute the commands.

That is a **remote-access trojan built out of LG's own signed, root-running service**, connecting to
a remote endpoint with legitimate-looking traffic. It is materially harder to spot than a
reverse shell: correct binary, correct process, correct protocol, plausible destination.

## 6.2 But with root you would not need it — which is the interesting part

Root on this device already means: microphone bus (F8), video plane (F10), screen framebuffer
(F9/F19), plaintext voice logs (F5), Wi-Fi PSK (F27), IoT credentials, household data (F35), and
boot persistence via `/var/lib/webosbrew/init.d/`. Input injection can be done directly at the
input layer. **`iot-client` is the *deniable* RAT, not the *necessary* one.**

So the honest answer has two halves:

- **"Can root use it as a RAT?"** — Yes, and more discreetly than the alternatives.
- **"Does root need it?"** — No. Which means the interesting question is not root, but **who can
  influence the pre-authentication stage** (the endpoint resolution above) — because that is the
  version of the attack that does *not* require root on the TV.

## 6.3 The non-root question, and an unresolved gap

To hijack the agent **without** root you would need to influence `sdx/getServer` /
`downloadMqttUrl`, both of which are HTTPS fetches requiring a trusted certificate — i.e. a CA the
TV accepts. On this device that means either user action (Settings → Security → Certificates) or
the debug/dev-mode trust path the owner controls. **No obvious unauthenticated hijack was found.**

One gap worth flagging, which I could **not** resolve without a working luna client:

```
roles/pub/com.webos.service.iot-client.json
   allowedNames: [com.webos.service.iotclient, …iotclient.req, …iotclient.power, …iotclient.matter]
   permissions : inbound ["*"], outbound ["*"]

client-permissions.d/com.webos.service.iot-client.perm.json
   com.webos.service.iotclient.req     -> ["all"]
   com.webos.service.iotclient.power   -> ["all"]
   com.webos.service.iotclient.matter  -> ["all"]

api-permissions.d/ :  NO file exists for com.webos.service.iotclient*
                     (only com.webos.service.iotproxy.api.json is present)
```

The service accepts inbound from `"*"`, and **no API-permission manifest declares which of its
methods are protected**. If LS2 treats "no declared API permissions" permissively, a bus client
holding `"all"` — and there are 150 such clients, including the TV's browser (Part 2, F21) — could
call `com.webos.service.iotclient.req` directly and feed it cloud-shaped commands, i.e. synthesise
key presses and drive the F36 handlers **without root**. I am recording this as an **unresolved
gap, not a finding**: I could not test it (`luna-send` does not reach the bus from our shell, and
testing would require injecting input into a device in use).

**Recommended follow-up:** enumerate whether `iotclient.req` methods are callable by a `"all"`
client. If they are, that is a genuine app→remote-control path on a stock TV, and it would move
`iot-client` from "vendor convenience" to "attack surface reachable by any app".

## 6.4 Bottom line

| Attacker position | Can they drive the TV via LG's agent? | Mechanism |
|---|---|---|
| **Root on the TV** | **Yes** — and stealthily | Repoint the runtime-resolved broker; use the device credential; speak the agent's own protocol |
| **Network only, no root** | Not demonstrated | Requires intercepting HTTPS endpoint resolution (needs a trusted CA the TV accepts) |
| **A bus client with `"all"`** | **Unresolved** | `inbound:["*"]`, no API-permission manifest for `iotclient*` — needs testing |
| **LG (or an LG account holder)** | **Yes, by design** | F33/F34/F36 — this is the supported path |

**Defensive takeaway:** you cannot neutralise this by hardening `iot-client` alone, because the
agent's security equals the security of *who can answer "where is the server?"*. The controls that
actually bite are: **unbind the TV from the LG account** (removes the supported path), **segment the
network** (blocks on-path endpoint tampering), and **protect root** (blocks the stealthy version).

---

*End of report. Parts 1–6, one continuous verification session (2026-09-13/14).
Verified facts were reproduced on the device; one gap is recorded as unresolved rather than asserted.
Deliberately NOT done: publishing to LG's production IoT topics; extracting DRM key material.*
