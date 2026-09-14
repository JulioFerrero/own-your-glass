#!/usr/bin/env python3
# sniff.py — on-device packet sniffer for the rooted webOS TV.
#
# Uses socket.AF_PACKET + ETH_P_ALL via Python's stdlib (struct, socket,
# select, time). tcpdump / libpcap / dumpcap are NOT installed on this
# device and netfilter is absent — but AF_PACKET works on any kernel that
# supports it. Pure stdlib, no third-party imports, no compiled modules.
#
# Two modes:
#   live text   — one line per interesting event, flushed, so an operator
#                 on the other end of `ssh lgtv '... sniff.sh'` sees the
#                 TV's connections stream in real time.
#   --pcap FILE — write a libpcap-format capture (magic 0xa1b2c3d4, v2.4,
#                 linktype 1 / Ethernet) that opens cleanly in Wireshark.
#
# Surfaced events: DNS queries (UDP/53), TLS SNI from ClientHello, TCP
# SYN attempts, and sinkhole hits (destination 0.0.0.0 or ::1 — i.e. one
# of our /etc/hosts block entries winning against the resolver). Malformed
# payloads are counted and skipped, never crashed on.

import argparse
import os
import select
import signal
import socket
import struct
import sys
import time

PROG = "sniff"

DLT_EN10MB   = 1
ETH_P_IP     = 0x0800
ETH_P_IP6    = 0x86DD
ETH_P_VLAN   = 0x8100

PCAP_MAGIC   = 0xA1B2C3D4
PCAP_VERSION = (2, 4)

DEFAULT_EXCLUDE_PORTS = {22, 9998}

HELP_EPILOG = """\
examples:
  sniff.sh --seconds 30                              # 30 s of live text
  sniff.sh --pcap /tmp/tv.pcap --seconds 60          # 60 s into a pcap file
  sniff.sh --dns --sni --quiet --seconds 5           # quiet: only DNS + SNI
  sniff.sh --all --seconds 10                        # full firehose
  sniff.sh --exclude-port 443 --exclude-port 80 ...  # ignore common ports

SNI names HTTPS destinations even though the payload is encrypted — that
is the only place the destination hostname appears in cleartext for TLS.
"""


def now_hms():
    return time.strftime("%H:%M:%S", time.localtime())


def ip_str_v4(b):
    return ".".join(str(x) for x in b)


def ip_str_v6(b):
    return ":".join("%04x" % int.from_bytes(b[i:i+2], "big")
                     for i in range(0, 16, 2))


def emit(stream, line):
    stream.write(line)
    stream.flush()


def parse_dns_name(payload, off):
    labels = []
    cur = off
    end = None
    while cur < len(payload):
        ln = payload[cur]
        if ln == 0:
            cur += 1
            end = cur
            break
        if (ln & 0xC0) == 0xC0:
            if cur + 1 >= len(payload):
                return None, cur + 2
            ptr = ((ln & 0x3F) << 8) | payload[cur + 1]
            if ptr >= cur:
                return None, cur + 2
            sub, _ = parse_dns_name(payload, ptr)
            if sub is None:
                return None, cur + 2
            labels.append(sub)
            cur += 2
            end = cur
            break
        if cur + 1 + ln > len(payload):
            return None, len(payload)
        labels.append(payload[cur+1:cur+1+ln].decode("ascii", errors="replace"))
        cur += 1 + ln
    if end is None:
        return None, cur
    name = ".".join(labels)
    if name.endswith("."):
        name = name[:-1]
    return name, end


def parse_dns_query(payload):
    if len(payload) < 12:
        return None
    flags = struct.unpack_from(">H", payload, 2)[0]
    qdcount = struct.unpack_from(">H", payload, 4)[0]
    if qdcount < 1 or ((flags >> 15) & 1) == 1:
        return None
    name, off = parse_dns_name(payload, 12)
    if name is None or off + 4 > len(payload):
        return None
    qtype, _qclass = struct.unpack_from(">HH", payload, off)
    return name, qtype


DNS_QTYPE = {1: "A", 2: "NS", 5: "CNAME", 15: "MX",
             16: "TXT", 28: "AAAA", 33: "SRV", 65: "HTTPS"}


def parse_tls_sni(payload):
    if len(payload) < 9:
        return None
    if payload[0] != 0x16:
        return None
    if payload[1] != 0x03:
        return None
    if payload[2] not in (0x01, 0x02, 0x03, 0x04):
        return None
    rec_len = struct.unpack_from(">H", payload, 3)[0]
    if 5 + rec_len > len(payload):
        return None
    if payload[5] != 0x01:
        return None
    p = 9
    if p + 2 + 32 > len(payload):
        return None
    p += 2 + 32
    sid_len = payload[p]
    p += 1 + sid_len
    if p + 2 > len(payload):
        return None
    cs_len = struct.unpack_from(">H", payload, p)[0]
    p += 2 + cs_len
    if p + 1 > len(payload):
        return None
    cm_len = payload[p]
    p += 1 + cm_len
    if p + 2 > len(payload):
        return None
    ext_len = struct.unpack_from(">H", payload, p)[0]
    p += 2
    ext_end = min(p + ext_len, len(payload))
    while p + 4 <= ext_end:
        ext_type, ext_body_len = struct.unpack_from(">HH", payload, p)
        body_start = p + 4
        body_end = body_start + ext_body_len
        if body_end > ext_end:
            return None
        if ext_type == 0:
            if body_start + 5 > body_end:
                return None
            list_len = struct.unpack_from(">H", payload, body_start)[0]
            name_off = body_start + 2
            if name_off + 3 > body_end:
                return None
            name_type = payload[name_off]
            name_len = struct.unpack_from(">H", payload, name_off + 1)[0]
            name_start = name_off + 3
            if name_start + name_len > body_end:
                return None
            if name_type != 0:
                p = body_end
                continue
            return payload[name_start:name_start + name_len].decode("ascii", errors="replace")
        p = body_end
    return None


def strip_vlan(frame):
    if len(frame) < 18:
        return frame, ETH_P_IP
    tpid = struct.unpack_from(">H", frame, 12)[0]
    if tpid == ETH_P_VLAN:
        inner_tpid = struct.unpack_from(">H", frame, 16)[0]
        return frame[:12] + frame[18:], inner_tpid
    return frame, tpid


def parse_l3(frame):
    stripped, etype = strip_vlan(frame)
    if etype == ETH_P_IP:
        return parse_ipv4(stripped, 14)
    if etype == ETH_P_IP6:
        return parse_ipv6(stripped, 14)
    return None


def parse_ipv4(frame, off):
    if off + 20 > len(frame):
        return None
    ihl = (frame[off] & 0x0F) * 4
    if ihl < 20 or off + ihl > len(frame):
        return None
    total = struct.unpack_from(">H", frame, off + 2)[0]
    proto = frame[off + 9]
    src = frame[off+12:off+16]
    dst = frame[off+16:off+20]
    flags_frag = struct.unpack_from(">H", frame, off + 6)[0]
    mf = (flags_frag >> 13) & 0x1
    frag_off = flags_frag & 0x1FFF
    payload_off = off + ihl
    return {
        "family": 4, "proto": proto, "src": src, "dst": dst,
        "payload_off": payload_off, "frag_off": frag_off, "mf": mf,
    }


def parse_ipv6(frame, off):
    if off + 40 > len(frame):
        return None
    payload_len = struct.unpack_from(">H", frame, off + 4)[0]
    proto = frame[off + 6]
    src = frame[off+8:off+24]
    dst = frame[off+24:off+40]
    return {
        "family": 6, "proto": proto, "src": src, "dst": dst,
        "payload_off": off + 40, "frag_off": 0, "mf": 0,
        "payload_len": payload_len,
    }


def parse_udp(payload):
    if len(payload) < 8:
        return None
    sport, dport, ulen = struct.unpack_from(">HHH", payload, 0)
    return sport, dport, ulen


def parse_tcp(payload):
    if len(payload) < 20:
        return None
    sport, dport = struct.unpack_from(">HH", payload, 0)
    data_off = (payload[12] >> 4) * 4
    flags = payload[13]
    return sport, dport, data_off, flags


def direction_for(frame, my_mac):
    if len(frame) < 12 or my_mac is None:
        return None
    dst = frame[0:6]
    src = frame[6:12]
    if src == my_mac:
        return "OUT"
    if dst == my_mac:
        return "IN"
    return None


def format_ip(family, b):
    return ip_str_v4(b) if family == 4 else ip_str_v6(b)


def is_sinkhole_v4(dst):
    return dst == b"\x00\x00\x00\x00"


def is_sinkhole_v6(dst):
    return dst == (b"\x00" * 15) + b"\x01"


def pcap_global_header(linktype=DLT_EN10MB):
    vmaj, vmin = PCAP_VERSION
    return struct.pack("<IHHiIII",
            PCAP_MAGIC, vmaj, vmin, 0, 0, 65535, linktype)


def pcap_record(ts, data):
    ts_sec = int(ts)
    ts_usec = int((ts - ts_sec) * 1_000_000)
    incl = len(data)
    return struct.pack("<IIII", ts_sec, ts_usec, incl, incl) + data


def open_pcap(path):
    f = open(path, "wb", buffering=0)
    f.write(pcap_global_header())
    return f


class Counts:
    __slots__ = ("total", "dns", "sni", "syn", "blocked",
                 "fragments", "parse_skip", "out", "in_")

    def __init__(self):
        self.total      = 0
        self.dns        = 0
        self.sni        = 0
        self.syn        = 0
        self.blocked    = 0
        self.fragments  = 0
        self.parse_skip = 0
        self.out        = 0
        self.in_        = 0


def port_excluded(sport, dport, excluded):
    return sport in excluded or dport in excluded


def handle_frame(frame, ts, my_mac, want, excluded, counts, out, pcap_fh):
    if pcap_fh is not None:
        pcap_fh.write(pcap_record(ts, frame))

    direction = direction_for(frame, my_mac)
    if direction is None:
        counts.parse_skip += 1
        return

    l3 = parse_l3(frame)
    if l3 is None:
        counts.parse_skip += 1
        return

    if l3.get("frag_off", 0) != 0 or l3.get("mf", 0):
        counts.fragments += 1
        return

    counts.total += 1
    if direction == "OUT":
        counts.out += 1
    else:
        counts.in_ += 1

    src_ip = format_ip(l3["family"], l3["src"])
    dst_ip = format_ip(l3["family"], l3["dst"])

    sinkhole = ((l3["family"] == 4 and is_sinkhole_v4(l3["dst"])) or
                (l3["family"] == 6 and is_sinkhole_v6(l3["dst"])))
    if sinkhole:
        if want["blocked"]:
            counts.blocked += 1
            proto = l3["proto"]
            payload = frame[l3["payload_off"]:]
            port = ""
            if proto == 17:
                udp = parse_udp(payload)
                if udp:
                    sport, dport, _ulen = udp
                    port = " sport=%d dport=%d" % (sport, dport)
            elif proto == 6:
                tcp = parse_tcp(payload)
                if tcp:
                    sport, dport, _do, _f = tcp
                    port = " sport=%d dport=%d" % (sport, dport)
            emit(out, "%s  %-3s  %-6s a blocked domain resolved to the sinkhole (%s%s)\n" %
                 (now_hms(), direction, "BLOCKED->", dst_ip, port))
        return

    proto = l3["proto"]
    payload = frame[l3["payload_off"]:]

    if proto == 17:
        udp = parse_udp(payload)
        if udp is None:
            return
        sport, dport, ulen = udp
        if port_excluded(sport, dport, excluded):
            return
        if sport == 53 or dport == 53:
            data = payload[8:ulen]
            r = parse_dns_query(data)
            if r is not None and want["dns"]:
                name, qtype = r
                counts.dns += 1
                qtype_name = DNS_QTYPE.get(qtype, str(qtype))
                emit(out, "%s  %-3s  %-5s -> query %s (type %s)\n" %
                     (now_hms(), direction, "DNS", name, qtype_name))
        return

    if proto == 6:
        tcp = parse_tcp(payload)
        if tcp is None:
            return
        sport, dport, data_off, flags = tcp
        if port_excluded(sport, dport, excluded):
            return
        is_syn = bool(flags & 0x02) and not (flags & 0x10)
        if want["firehose"]:
            if is_syn:
                tag = "SYN"
            elif (flags & 0x02) and (flags & 0x10):
                tag = "SYN-ACK"
            elif (flags & 0x01):
                tag = "FIN"
            elif (flags & 0x04):
                tag = "RST"
            else:
                tag = "TCP"
            emit(out, "%s  %-3s  %-5s %s -> %s:%d\n" %
                 (now_hms(), direction, "TCP", tag, dst_ip, dport))
            return
        if is_syn and want["syn"]:
            counts.syn += 1
            emit(out, "%s  %-3s  %-5s -> %s:%d (SYN)\n" %
                 (now_hms(), direction, "TCP", dst_ip, dport))
            return
        if want["sni"] and data_off >= 20 and data_off <= len(payload):
            body = payload[data_off:]
            if len(body) >= 9:
                sni = parse_tls_sni(body)
                if sni:
                    counts.sni += 1
                    emit(out, "%s  %-3s  %-5s sni=%s -> %s:%d\n" %
                         (now_hms(), direction, "TLS", sni, dst_ip, dport))
        return


def parse_args():
    p = argparse.ArgumentParser(
        prog=PROG, add_help=True,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=HELP_EPILOG)
    p.add_argument("-i", "--iface", help="capture interface (default: auto)")
    p.add_argument("-d", "--seconds", type=int, default=0,
                   help="stop after N seconds (default: unbounded)")
    p.add_argument("--pcap", help="write libpcap-format capture to FILE")
    p.add_argument("--exclude-port", action="append", type=int, default=[],
                   help="exclude a port (repeatable). Default-excludes TCP 22 + 9998.")
    p.add_argument("--dns", action="store_true", help="show DNS queries")
    p.add_argument("--sni", action="store_true", help="show TLS SNI from ClientHello")
    p.add_argument("--tcp", action="store_true", help="show TCP SYN attempts")
    p.add_argument("--blocked", action="store_true", help="show sinkhole hits")
    p.add_argument("--all", action="store_true",
                   help="dump every packet (firehose; overwhelms ssh)")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="suppress the banner")
    return p.parse_args()


def main():
    args = parse_args()

    iface = args.iface or os.environ.get("OYG_SNIFF_IFACE", "")
    if not iface:
        sys.stderr.write("sniff: no interface (pass -i IFACE)\n")
        sys.exit(2)

    excluded = set(DEFAULT_EXCLUDE_PORTS)
    excluded.update(args.exclude_port)

    explicit = [("dns", args.dns), ("sni", args.sni),
                ("syn", args.tcp), ("blocked", args.blocked)]
    explicit_on = [k for k, v in explicit if v]
    if explicit_on:
        want = {k: (k in explicit_on) for k, _ in explicit}
        want["firehose"] = bool(args.all)
    else:
        want = {k: True for k, _ in explicit}
        want["firehose"] = bool(args.all)

    pcap_fh = open_pcap(args.pcap) if args.pcap else None

    counts = Counts()
    stop_after = args.seconds if args.seconds and args.seconds > 0 else 0
    deadline = time.monotonic() + stop_after if stop_after else 0

    if not args.quiet and pcap_fh is None:
        banner = "sniff: iface=%s exclude_ports=%s seconds=%s categories=%s" % (
            iface,
            ",".join(str(x) for x in sorted(excluded)) or "<none>",
            stop_after or "none",
            "all" if want["firehose"] else
                ",".join(k for k, v in (("dns", want["dns"]), ("sni", want["sni"]),
                                        ("syn", want["syn"]), ("blocked", want["blocked"])) if v) or "<none>",
        )
        out = sys.stdout
        out.write(banner + "\n")
        out.write("sniff: SNI names HTTPS destinations even though the payload is encrypted\n")
        out.flush()

    out = sys.stdout

    try:
        s = setup_socket(iface)
    except OSError as e:
        sys.stderr.write("sniff: bind(%s) failed: %s\n" % (iface, e))
        if pcap_fh:
            pcap_fh.close()
        sys.exit(2)
    my_mac = get_my_mac(s)

    def stop(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        while True:
            if deadline:
                remain = deadline - time.monotonic()
                if remain <= 0:
                    break
                timeout = min(remain, 1.0)
            else:
                timeout = 1.0
            try:
                r, _, _ = select.select([s], [], [], timeout)
            except InterruptedError:
                break
            if not r:
                continue
            try:
                frame, _ = s.recvfrom(65535)
            except BlockingIOError:
                continue
            ts = time.time()
            handle_frame(frame, ts, my_mac, want, excluded, counts, out, pcap_fh)
    except KeyboardInterrupt:
        pass
    finally:
        if pcap_fh:
            pcap_fh.close()

    print_summary(out, counts, iface, args.pcap)
    out.flush()


def setup_socket(iface):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    s.bind((iface, 0))
    s.setblocking(False)
    return s


def get_my_mac(s):
    name = s.getsockname()
    if len(name) >= 5 and isinstance(name[4], (bytes, bytearray)) and len(name[4]) == 6:
        return bytes(name[4])
    return None


def print_summary(out, counts, iface, pcap_path):
    parts = [
        "",
        "summary: iface=%s packets=%d out=%d in=%d" % (
            iface, counts.total, counts.out, counts.in_),
        "  dns=%d sni=%d syn=%d blocked=%d fragments=%d parse_skip=%d" % (
            counts.dns, counts.sni, counts.syn, counts.blocked,
            counts.fragments, counts.parse_skip),
    ]
    if pcap_path:
        parts.append("  pcap written to %s" % pcap_path)
    out.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()