# webOS 3 and 4

own-your-glass runs on webOS 3 and 4 as well as webOS 10. This page records what was
tested, what differs from webOS 10 and what does not work there.

## Tested TVs

| TV | Year | webOS (`webos_release`) | Firmware | BusyBox | Init |
|---|---|---|---|---|---|
| LG 43UM7300PUA | 2019 | 4.10.1 ("webOS TV Lite") | 05.40.80 | 1.24.1 | upstart 1.10 |
| LG 65UJ6300-UA | 2017 | 3.9.3 (sold as webOS 3.5) | 06.10.55 | 1.22.1 | upstart 1.10 |

Both were rooted with Homebrew Channel (0.7.x). On each, on 2026-10-26:

1. `oyg status` and `oyg harden --dry-run` (every opt-in flag): no script errors, nothing
   written.
2. `oyg harden`, `OYG_AGGRESSIVE=1 oyg harden --only perms` and
   `OYG_NETWORK_BLOCK=1 oyg harden --only network`: exit 0, no errors.
   `oyg verify`: everything OK or N/A.
3. Restart: the boot hook re-applied everything (services stopped again, binds and blocklist
   back, telnet closed by `webosbrew_telnet_disabled`).
4. The control panel's Undo (`oyg restore` with the network flags): the TV was back to its
   state before the first harden: the same services running, LG's app list byte for byte,
   file modes, mounts and blackhole routes gone.
5. Apply again, then: YouTube resolves, HTTPS works, AirPlay (43UM7300) keeps working.

webOS 5 to 9 have not been tested and still need `OYG_FORCE_UNSUPPORTED=1` (testing mode).

## What differs, and how the toolkit handles it

| | webOS 10 | webOS 3 / 4 |
|---|---|---|
| Services | systemd (`systemctl`) | upstart (`initctl`); `lib/common.sh` `oyg_unit_*` pick the right one. Jobs that `respawn` (avahi, rdxd) are stopped with `initctl stop`, so they stay down until the next boot, where the boot hook stops them again (and once more two minutes later, for jobs upstart starts late). `dmost` runs as the job `required_dmost`. |
| Shell | newer BusyBox | BusyBox 1.22 / 1.24: no `$((8#..))`, no `command`; `nslookup` takes no options and prints `Address 1: ip name`. |
| Hidden apps | `blockedSystemAppList/<REGION>.json`, key `blocked_system_applist` | `blockedAppList/<REGION>.json`, key `blocked_applist` (the app manager `/usr/sbin/sam` reads only that). The file is named after the TV's country (`smartServiceCountryCode3`, e.g. `USA.json`); LG's own entries are kept. |
| Microphones | ALSA capture devices on the TV | none: the sound card is playback-only, the microphone is in the Magic Remote (voice module). The mic module reports "no built-in microphone". |
| Variant C (DNS) | available | not available: it restarts ConnMan through systemd. `go-c.sh` refuses before touching anything; the other DNS layers work. |
| Control panel | modern Chromium | Chromium 53-era engine: flex fallbacks for CSS grid, no `gap`, no `padStart`. |
| AirPlay | `mdnsd` (never touched) | the same: on the 43UM7300 AirPlay advertises through `mdnsd`, not avahi, so stopping avahi does not affect it. The 65UJ6300 has no AirPlay. |

## Known limits

- **Homebrew Channel must run at boot.** The boot hook runs from Homebrew Channel's startup
  script. On the 65UJ6300 that script did not run by itself after a restart; it ran when the
  Homebrew Channel app was opened, and the hook re-applied everything then. Until it runs, the
  TV is not hardened (and SSH is off). Most power-offs are a suspend (Quick Start+), so this
  only matters after a real restart.
- **LG Connect Apps off** closes port 3001 (webOS 4) or both 3000 and 3001 (webOS 3), so
  LG's phone remote apps cannot connect. `OYG_POLICY_KEEP="allowMobileDeviceAccess"` keeps it.
- **Busy logs.** Homebrew apps can flood `/tmp/var/log/messages` (Hyperion's grabber wrote
  about 1.4 MB a minute on the 43UM7300), so `logs` shows PARTIAL between its 60-second clears.
- The home-screen layout (`OYG_LAUNCHER_TRIM`) targets webOS 10's launcher and was not tried.
