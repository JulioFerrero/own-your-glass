import re, sys, os

SRC = "/Users/julio/lg-nexus-tests/NEXUS-VERIFICATION-REPORT.md"
DST = "/Users/julio/Documents/own-your-glass/docs/VERIFICATION-REPORT.md"

text = open(SRC, encoding="utf-8", errors="replace").read()
orig_len = len(text)

EXPLICIT = {
    # device / network hardware identifiers
    "08:27:A8:03:31:28": "<TV-MAC>", "08:27:a8:03:31:28": "<TV-MAC>",
    "58:96:0A:BB:73:77": "<TV-WIRED-MAC>", "58:96:0a:bb:73:77": "<TV-WIRED-MAC>",
    "80:a9:97:1c:cf:0f": "<MAC-LAPTOP-HW>", "80:A9:97:1C:CF:0F": "<MAC-LAPTOP-HW>",
    "f2:23:89:79:35:1a": "<MAC-LAPTOP-RANDOM>", "f2:23:89:79:35:1a".upper(): "<MAC-LAPTOP-RANDOM>",
    "f2:23:89:79:35:1a".upper().replace(":", ":"): "<MAC-LAPTOP-RANDOM>",
    "84:aa:9c:e1:4e:1a": "<MAC-GATEWAY>", "84:AA:9C:E1:4E:1A": "<MAC-GATEWAY>",
    # advertising / device identifiers
    "69d88e48-d6c7-4a55-739b-bf4c2ebfbb33": "<IFA>",
    "58:96:0A:BB:73:7799ca27063ef3304341328b26d400466a3955ecc8": "<NDUID>",
    "d8c3e28f761f14a5f03de4eed31bcb5bae65c45bd0ff38321209875e8912ba030a0d7900d7de9905d5c147249b3989918cb338479b97154da0cbfd719a1b13a0": "<DEVICE-HASH>",
    "LG-webOS25-X-54eGHhzNbjzrzgcM": "<CLIENT-TOKEN>",
    "LG-WebOS25-WebOS-kuC9ySfB91fJvzpn": "<CLIENT-TOKEN>",
    "ES2607150452839": "<WORKSPACE-ID>",
    # households
    "Julio's Home": "the owner's home",
    "Iryna Klitna's Home": "a second household",
    "Iryna Klitna": "a third party",
    "178396640152626619": "<HOME-ID>",
    "178412050429842973": "<HOME-ID-2>",
    # hostnames / usernames
    "OFI74-MACBOOK.local": "<mac-host>",
    "OFI74-MACBOOK": "<mac-host>",
    "LGwebOSTV-zzVK-1.local": "<tv-host>.local",
    "LGwebOSTV": "<tv-host>",
    "/Users/julio": "/Users/<user>",
    "julio@": "<user>@",
    # Wi-Fi SSIDs observed
    "Boris_5G_RPT5G": "<ssid>", "Boris_5G_RPT": "<ssid>", "Boris_5G": "<ssid>", "Boris": "<ssid>",
    "MiFibra-9877-5G": "<ssid>", "MiFibra-9877": "<ssid>", "MiFibra-A8E6-5G": "<ssid>",
    "WIFI_MOSE_PLUS": "<ssid>", "WIFI_MOSE": "<ssid>", "WIFI_MOSE": "<ssid>",
    "MOVISTAR_1410": "<ssid>", "Vodafone_CaSA_5G": "<ssid>", "Vodafone_CaSA": "<ssid>",
    "MIWIFI_Ub3A": "<ssid>", "REDWIFI_USkS": "<ssid>", "sercommBA2508": "<ssid>",
    "Sercomm5420": "<ssid>", "YCCXIpB4xmzWHheb2UrSomt7B9gb1OqL": "<ssid>", "mose": "<ssid>",
}
for k, v in EXPLICIT.items():
    text = text.replace(k, v)
    text = text.replace(k.lower(), v)
    text = text.replace(k.upper(), v)

# any remaining MAC-looking token
text = re.sub(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b", "<mac>", text)
# any remaining UUID
text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<uuid>", text)
# long hex blobs (device ids / hashes)
text = re.sub(r"\b[0-9a-fA-F]{24,}\b", "<hash>", text)
# private LAN addresses -> documentation range
text = re.sub(r"\b192\.168\.1\.(\d{1,3})\b", r"10.0.0.\1", text)
# the ad-cookie identifiers (device-linked)
text = re.sub(r"knd_aflow_[0-9a-fA-F-]+", "knd_aflow_<uuid>", text)
# generic: an explicit owner name
text = re.sub(r"\bJulio\b", "<owner>", text)
text = re.sub(r"\bjulio\b", "<owner>", text)

os.makedirs(os.path.dirname(DST), exist_ok=True)
header = ("> **Redacted for publication.** All device- and network-identifying values in this\n"
          "> report (MAC addresses, SSIDs, advertising/device identifiers, tokens, household\n"
          "> names, LAN addresses) have been replaced with placeholders. The unredacted\n"
          "> original remains private.\n\n")
open(DST, "w", encoding="utf-8").write(header + text)
print(f"wrote {DST}: {orig_len} -> {len(text)} bytes")
