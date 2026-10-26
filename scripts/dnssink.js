#!/usr/bin/env node
// dnssink.js — on-device DNS sinkhole resolver (Node.js, no modules).
//
// Listens on 127.0.0.2:53 (UDP + TCP) on a rooted LG webOS TV and answers
// queries for the blocklisted names with a sinkhole (0.0.0.0 for A, :: for
// AAAA, NXDOMAIN otherwise); everything else is forwarded to the upstream
// resolver dns.sh discovered, and the reply is relayed byte-for-byte with
// the client's transaction ID. The blocklist is /var/lib/own-your-glass/hosts
// (written by modules/network.sh from etc/blocklist-*.txt), mtime-watched,
// so `oyg harden --only network` is picked up without a restart.
//
// Why Node: every webOS TV ships it (LG lists Node 0.12 on webOS 3.x/4.x,
// 8.12 on 5/6, 12 on 22/23, 16 on 24/25, 20 on 26); python3 is missing on
// older firmware. So this file is ES5 only: no let/const, arrow functions,
// template strings, Map/Set or Buffer.from, which Node 0.12 lacks.
//
// Why on-device, why 127.0.0.2:53, and why resolv.conf is bind-mounted
// rather than ConnMan reconfigured: see docs/FINDINGS.md (F14g, F44) and the
// post-mortem in scripts/dns.sh. This was a port of dnssink.py; behaviour,
// flags and log lines are the same.
//
// Robustness: malformed packets are counted and dropped, never crashed on.
// TCP connections are closed 5 s after they open. SIGTERM closes both
// sockets and prints the counters.

'use strict';

var dgram = require('dgram');
var net = require('net');
var fs = require('fs');
var path = require('path');

var PROG = 'dnssink';
var DEFAULT_HOSTS = '/var/lib/own-your-glass/hosts';
var DEFAULT_BIND = '127.0.0.2';
var DEFAULT_PORT = 53;
var DEFAULT_LOG = '/var/lib/own-your-glass/dns-audit.log';
var DEFAULT_UPSTREAM_TIMEOUT = 2.5;
var TCP_IDLE_TIMEOUT = 5.0;
var QTYPE_A = 1;
var QTYPE_AAAA = 28;
var QCLASS_IN = 1;

function alloc(n) {
    if (Buffer.alloc) return Buffer.alloc(n);
    var b = new Buffer(n);
    b.fill(0);
    return b;
}

// Buffer.alloc and a working Buffer.from arrived together (Node 4.5/5.10);
// before that, new Buffer, which newer Node warns about.
function ascii(str) {
    return Buffer.alloc ? Buffer.from(str, 'ascii') : new Buffer(str, 'ascii');
}

function pad(n) { return n < 10 ? '0' + n : String(n); }

function ts() {
    var d = new Date();
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
        'T' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

function now() {
    var t = process.hrtime();
    return t[0] + t[1] / 1e9;
}

function out(line) { process.stdout.write(line + '\n'); }
function errline(line) { process.stderr.write(line + '\n'); }

// --- the blocklist -----------------------------------------------------------

// HostsRules: suffix rules from the hosts file. "0.0.0.0 x.com" and
// "::1 x.com" lines block x.com and every name under it; localhost is never
// matched (blackholing it would cut the box's own loopback traffic).
function HostsRules(file) {
    this.file = file;
    this.mtime = 0;
    this.rules = {};
    this.count = 0;
    this.reload();
}

HostsRules.prototype.reload = function () {
    var rules = {}, count = 0, text;
    try {
        text = fs.readFileSync(this.file, 'ascii');
    } catch (e) {
        if (e.code !== 'ENOENT') errline(PROG + ': cannot read ' + this.file + ': ' + e.message);
        this.mtime = 0; this.rules = {}; this.count = 0;
        return;
    }
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].replace(/^\s+|\s+$/g, '').split(/\s+/);
        if (parts.length < 2) continue;
        if (parts[0] !== '0.0.0.0' && parts[0] !== '::1') continue;
        var name = parts[1].replace(/\.+$/, '').toLowerCase();
        if (!name || name === 'localhost' || /\.localhost$/.test(name)) continue;
        if (!rules.hasOwnProperty(name)) { rules[name] = true; count++; }
    }
    this.rules = rules;
    this.count = count;
    try { this.mtime = fs.statSync(this.file).mtime.getTime(); } catch (e2) { this.mtime = 0; }
};

HostsRules.prototype.refreshIfChanged = function () {
    var mt;
    try {
        mt = fs.statSync(this.file).mtime.getTime();
    } catch (e) {
        if (e.code === 'ENOENT' && (this.mtime !== 0 || this.count)) {
            this.mtime = 0; this.rules = {}; this.count = 0;
            return true;
        }
        return false;
    }
    if (mt !== this.mtime) { this.reload(); return true; }
    return false;
};

HostsRules.prototype.matches = function (qname) {
    if (!qname) return false;
    var labels = qname.replace(/\.+$/, '').toLowerCase().split('.');
    if (!labels.length || labels[labels.length - 1] === '') return false;
    if (labels[labels.length - 1] === 'localhost') return false;
    for (var i = labels.length - 1; i >= 0; i--) {
        if (this.rules.hasOwnProperty(labels.slice(i).join('.'))) return true;
    }
    return false;
};

// --- DNS wire format ---------------------------------------------------------

// parseName(buf, off) -> [name or null, offset after the name]. Follows
// compression pointers backwards only, so a looping packet cannot hang us.
function parseName(buf, off) {
    var labels = [], cur = off, end = -1, jumped = false;
    while (cur < buf.length) {
        var ln = buf[cur];
        if (ln === 0) { cur += 1; if (!jumped) end = cur; break; }
        if ((ln & 0xC0) === 0xC0) {
            if (cur + 1 >= buf.length) return [null, cur + 2];
            var ptr = ((ln & 0x3F) << 8) | buf[cur + 1];
            if (ptr >= cur) return [null, cur + 2];
            if (!jumped) { end = cur + 2; jumped = true; }
            cur = ptr;
            continue;
        }
        if ((ln & 0xC0) === 0x40) return [null, cur + 1];
        if (cur + 1 + ln > buf.length) return [null, buf.length];
        labels.push(buf.toString('ascii', cur + 1, cur + 1 + ln));
        cur += 1 + ln;
    }
    if (end < 0) return [null, cur];
    return [labels.join('.').replace(/\.+$/, ''), end];
}

// parseQuery(buf) -> {name, qtype, qclass} for a query, else null.
function parseQuery(buf) {
    if (buf.length < 12) return null;
    var flags = buf.readUInt16BE(2);
    if (buf.readUInt16BE(4) < 1) return null;
    if ((flags >> 15) & 1) return null;
    var r = parseName(buf, 12);
    if (r[0] === null) return null;
    if (r[1] + 4 > buf.length) return null;
    return { name: r[0], qtype: buf.readUInt16BE(r[1]), qclass: buf.readUInt16BE(r[1] + 2) };
}

function encodeName(qname) {
    var parts = qname.replace(/\.+$/, '').split('.'), bufs = [];
    for (var i = 0; i < parts.length; i++) {
        var b = ascii(parts[i]);
        if (b.length > 63) b = b.slice(0, 63);
        var l = alloc(1); l[0] = b.length;
        bufs.push(l, b);
    }
    bufs.push(alloc(1));
    return Buffer.concat(bufs);
}

function header(txn, flags, qd, an) {
    var h = alloc(12);
    h.writeUInt16BE(txn, 0); h.writeUInt16BE(flags, 2);
    h.writeUInt16BE(qd, 4); h.writeUInt16BE(an, 6);
    return h;
}

function question(qname, qtype) {
    var tail = alloc(4);
    tail.writeUInt16BE(qtype, 0); tail.writeUInt16BE(QCLASS_IN, 2);
    return Buffer.concat([encodeName(qname), tail]);
}

// buildBlocked -> [reply, hadAnswer]: 0.0.0.0 for A, :: for AAAA (TTL 30),
// NXDOMAIN for any other type.
function buildBlocked(qname, qtype, txn) {
    var size = qtype === QTYPE_A ? 4 : (qtype === QTYPE_AAAA ? 16 : 0);
    if (!size) return [Buffer.concat([header(txn, 0x8183, 1, 0), question(qname, qtype)]), false];
    var rr = alloc(10 + size);
    rr.writeUInt16BE(qtype, 0); rr.writeUInt16BE(QCLASS_IN, 2);
    rr.writeUInt32BE(30, 4); rr.writeUInt16BE(size, 8);
    return [Buffer.concat([header(txn, 0x8180, 1, 1), question(qname, qtype), encodeName(qname), rr]), true];
}

function buildServfail(txn, qname, qtype) {
    return Buffer.concat([header(txn, 0x8182, 1, 0), question(qname || '', qtype || QTYPE_A)]);
}

// retxn: the reply with the current query's transaction ID (cached replies
// carry the ID of the query that filled the cache; clients drop a mismatch).
function retxn(buf, txn) {
    if (buf.length < 2 || buf.readUInt16BE(0) === txn) return buf;
    var b = alloc(buf.length);
    buf.copy(b);
    b.writeUInt16BE(txn, 0);
    return b;
}

function frame(buf) {
    var l = alloc(2);
    l.writeUInt16BE(buf.length, 0);
    return Buffer.concat([l, buf]);
}

// --- upstream ----------------------------------------------------------------

function forwardUdp(upstream, port, payload, timeout, cb) {
    var done = false, sock;
    function finish(r) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { sock.close(); } catch (e) { /* closed */ }
        cb(r);
    }
    try {
        sock = dgram.createSocket(upstream.indexOf(':') >= 0 ? 'udp6' : 'udp4');
    } catch (e) {
        return cb(null);
    }
    var timer = setTimeout(function () { finish(null); }, timeout * 1000);
    sock.on('error', function () { finish(null); });
    sock.on('message', function (msg) { finish(msg); });
    sock.send(payload, 0, payload.length, port, upstream, function (e) { if (e) finish(null); });
}

function forwardTcp(upstream, port, payload, timeout, cb) {
    var done = false, chunks = [], have = 0;
    var sock = net.connect(port, upstream);
    function finish(r) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        sock.destroy();
        cb(r);
    }
    var timer = setTimeout(function () { finish(null); }, timeout * 1000);
    sock.on('error', function () { finish(null); });
    sock.on('close', function () { finish(null); });
    sock.on('connect', function () { sock.write(frame(payload)); });
    sock.on('data', function (d) {
        chunks.push(d); have += d.length;
        var all = Buffer.concat(chunks, have);
        if (all.length >= 2 && all.length >= 2 + all.readUInt16BE(0)) {
            finish(all.slice(2, 2 + all.readUInt16BE(0)));
        }
    });
}

// --- cache -------------------------------------------------------------------

function Cache(maxEntries, ttl) {
    this.max = maxEntries;
    this.ttl = ttl;
    this.data = {};
    this.keys = [];
}

Cache.prototype.get = function (key) {
    if (this.ttl <= 0 || this.max <= 0) return null;
    var e = this.data.hasOwnProperty(key) ? this.data[key] : null;
    if (!e) return null;
    if (e.expires <= now()) { this.drop(key); return null; }
    return e.payload;
};

Cache.prototype.drop = function (key) {
    if (!this.data.hasOwnProperty(key)) return;
    delete this.data[key];
    var i = this.keys.indexOf(key);
    if (i >= 0) this.keys.splice(i, 1);
};

Cache.prototype.put = function (key, payload) {
    if (this.ttl <= 0 || this.max <= 0) return;
    if (this.data.hasOwnProperty(key)) this.drop(key);
    else if (this.keys.length >= this.max) this.drop(this.keys[0]);
    this.data[key] = { payload: payload, expires: now() + this.ttl };
    this.keys.push(key);
};

// --- the resolver ------------------------------------------------------------

function Resolver(opts, rules, auditFd, cache) {
    this.o = opts;
    this.rules = rules;
    this.auditFd = auditFd;
    this.cache = cache;
    this.counts = { q: 0, block: 0, forward: 0, cache_hit: 0, fwd_fail: 0,
                    parse_skip: 0, tcp_conn: 0, udp_pkts: 0, tcp_pkts: 0 };
    this.udp = null;
    this.tcp = null;
}

Resolver.prototype.log = function (line) {
    out(line);
    if (this.auditFd === null) return;
    try { fs.writeSync(this.auditFd, line + '\n'); } catch (e) { /* disk full */ }
};

// handle(payload, client, send): answer one query. send(reply) delivers it
// over the transport the query came in on.
Resolver.prototype.handle = function (payload, client, proto, send) {
    var self = this, c = this.counts;
    c.q++;
    if (proto === 'udp') c.udp_pkts++; else c.tcp_pkts++;
    if (payload.length < 12) { c.parse_skip++; return; }
    var txn = payload.readUInt16BE(0);
    var q = parseQuery(payload);
    if (!q) { c.parse_skip++; return; }
    this.rules.refreshIfChanged();
    var key = q.name ? q.name.toLowerCase() + '|' + q.qtype : null;
    if (key !== null) {
        var cached = this.cache.get(key);
        if (cached) { c.cache_hit++; send(retxn(cached, txn)); return; }
    }
    if (this.rules.matches(q.name)) {
        var r = buildBlocked(q.name, q.qtype, txn);
        if (r[1]) c.block++;
        this.log(ts() + '  BLOCK  ' + (q.name || '<root>') + '  ' +
            (q.qtype === QTYPE_A ? '0.0.0.0' : (q.qtype === QTYPE_AAAA ? '::' : 'NXDOMAIN')) +
            '  qtype=' + q.qtype + ' from=' + client + ' proto=' + proto);
        if (key !== null) this.cache.put(key, r[0]);
        send(r[0]);
        return;
    }
    var fwd = proto === 'udp' ? forwardUdp : forwardTcp;
    var attempt = 0;
    (function tryOnce() {
        attempt++;
        fwd(self.o.upstream, 53, payload, self.o.upstreamTimeout, function (resp) {
            if (resp) {
                resp = retxn(resp, txn);
                c.forward++;
                if (key !== null) self.cache.put(key, resp);
                send(resp);
            } else if (attempt < 2) {
                tryOnce();
            } else {
                c.fwd_fail++;
                send(buildServfail(txn, q.name || '', q.qtype || QTYPE_A));
            }
        });
    })();
};

Resolver.prototype.start = function (ready, fail) {
    var self = this, o = this.o, up = false;
    // Errors before both sockets listen are bind failures, fatal; later ones
    // are one bad packet or client and are only logged.
    function onError(what) {
        return function (e) {
            if (!up) fail('bind(' + o.bind + ':' + o.port + ' ' + what + ') failed: ' + e.message);
            else errline(PROG + ': ' + what + ' error: ' + e.message);
        };
    }
    var udp = dgram.createSocket(o.bind.indexOf(':') >= 0 ? 'udp6' : 'udp4');
    udp.on('error', onError('UDP'));
    udp.on('message', function (msg, rinfo) {
        try {
            self.handle(msg, rinfo.address, 'udp', function (reply) {
                udp.send(reply, 0, reply.length, rinfo.port, rinfo.address, function () {});
            });
        } catch (e) {
            errline(PROG + ': handler crash: ' + e.message);
        }
    });
    udp.bind(o.port, o.bind, function () {
        try { udp.setTTL(64); } catch (e) { /* not supported */ }
        var tcp = net.createServer(function (conn) { self.serveTcp(conn); });
        tcp.on('error', onError('TCP'));
        tcp.listen(o.port, o.bind, function () {
            up = true;
            self.udp = udp;
            self.tcp = tcp;
            ready();
        });
    });
};

// One TCP connection: length-prefixed queries until 5 s after it opened.
Resolver.prototype.serveTcp = function (conn) {
    var self = this, buf = alloc(0), client = conn.remoteAddress || '?';
    this.counts.tcp_conn++;
    var timer = setTimeout(function () { conn.destroy(); }, TCP_IDLE_TIMEOUT * 1000);
    conn.on('error', function () { /* reset by peer */ });
    conn.on('close', function () { clearTimeout(timer); });
    conn.on('data', function (d) {
        buf = Buffer.concat([buf, d]);
        while (buf.length >= 2 && buf.length >= 2 + buf.readUInt16BE(0)) {
            var n = buf.readUInt16BE(0), payload = buf.slice(2, 2 + n);
            buf = buf.slice(2 + n);
            try {
                self.handle(payload, client, 'tcp', function (reply) {
                    if (!conn.destroyed) conn.write(frame(reply));
                });
            } catch (e) {
                errline(PROG + ': tcp conn crash: ' + e.message);
            }
        }
    });
};

Resolver.prototype.stop = function () {
    try { if (this.udp) this.udp.close(); } catch (e) { /* closed */ }
    try { if (this.tcp) this.tcp.close(); } catch (e2) { /* closed */ }
};

// --- the watchdog's probe ---------------------------------------------------

// probe(addr, port, name): exit 0 if a DNS reply with our transaction ID
// comes back within 2 s, else 1. Any reply counts (a blocked name answers
// 0.0.0.0). In this file, not `node -e`: on Node 0.12 a datagram sent from
// an -e script never arrived (seen in an i386 container).
function probe(addr, port, name) {
    var q = Buffer.concat([header(0xabcd, 0x0100, 1, 0), question(name, QTYPE_A)]);
    var s = dgram.createSocket(addr.indexOf(':') >= 0 ? 'udp6' : 'udp4');
    setTimeout(function () { process.exit(1); }, 2000);
    s.on('error', function () { process.exit(1); });
    s.on('message', function (m) { process.exit(m.length >= 12 && m.readUInt16BE(0) === 0xabcd ? 0 : 1); });
    s.send(q, 0, q.length, port, addr);
}

// --- main --------------------------------------------------------------------

function parseArgs(argv) {
    var env = process.env;
    var o = {
        bind: env.OYG_DNS_BIND || DEFAULT_BIND,
        port: parseInt(env.OYG_DNS_PORT || DEFAULT_PORT, 10),
        upstream: env.OYG_DNS_UPSTREAM || '',
        hosts: env.OYG_HOSTS_FILE || DEFAULT_HOSTS,
        audit: env.OYG_DNS_AUDIT || DEFAULT_LOG,
        upstreamTimeout: DEFAULT_UPSTREAM_TIMEOUT,
        cacheSize: 512,
        cacheTtl: 120
    };
    var names = { '--bind': 'bind', '--port': 'port', '--upstream': 'upstream', '--hosts': 'hosts',
                  '--audit': 'audit', '--upstream-timeout': 'upstreamTimeout',
                  '--cache-size': 'cacheSize', '--cache-ttl': 'cacheTtl' };
    for (var i = 0; i < argv.length; i++) {
        var a = argv[i], v = null, eq = a.indexOf('=');
        if (eq > 0) { v = a.slice(eq + 1); a = a.slice(0, eq); }
        if (a === '-h' || a === '--help') {
            out('usage: dnssink.js [--bind ADDR] [--port N] --upstream IP [--hosts FILE] [--audit FILE]\n' +
                '                  [--upstream-timeout SECS] [--cache-size N] [--cache-ttl SECS]\n' +
                '       dnssink.js --probe ADDR PORT NAME   (exit 0 if a sink answers)');
            process.exit(0);
        }
        if (!names.hasOwnProperty(a)) { errline(PROG + ': unknown argument ' + a); process.exit(2); }
        if (v === null) v = argv[++i];
        if (v === undefined) { errline(PROG + ': ' + a + ' needs a value'); process.exit(2); }
        o[names[a]] = v;
    }
    o.port = parseInt(o.port, 10);
    o.upstreamTimeout = parseFloat(o.upstreamTimeout);
    o.cacheSize = parseInt(o.cacheSize, 10);
    o.cacheTtl = parseInt(o.cacheTtl, 10);
    return o;
}

function main() {
    if (process.argv[2] === '--probe') {
        return probe(process.argv[3] || DEFAULT_BIND, parseInt(process.argv[4] || DEFAULT_PORT, 10),
                     process.argv[5] || 'es.nextlgsdp.com');
    }
    var o = parseArgs(process.argv.slice(2));
    var auditFd = null;
    try {
        var dir = path.dirname(o.audit);
        try { fs.mkdirSync(dir); } catch (e) { /* exists */ }
        auditFd = fs.openSync(o.audit, 'a');
    } catch (e2) {
        errline(PROG + ': cannot open audit log ' + o.audit + ': ' + e2.message);
        auditFd = null;
    }
    if (!o.upstream) {
        // dns.sh discovers the upstream and passes it; one implementation.
        errline(PROG + ': no --upstream given (dns.sh always supplies it; manual runs: --upstream <ip>)');
        process.exit(2);
    }
    out(PROG + ': upstream=' + o.upstream + ' (configured)');

    var rules = new HostsRules(o.hosts);
    var resolver = new Resolver(o, rules, auditFd, new Cache(o.cacheSize, o.cacheTtl));
    function shutdown() {
        resolver.stop();
        var c = resolver.counts;
        out('\n' + PROG + ': shutting down — q=' + c.q + ' block=' + c.block + ' forward=' + c.forward +
            ' cache_hit=' + c.cache_hit + ' fwd_fail=' + c.fwd_fail + ' parse_skip=' + c.parse_skip +
            ' udp=' + c.udp_pkts + ' tcp=' + c.tcp_pkts + ' tcp_conn=' + c.tcp_conn);
        process.exit(0);
    }
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
    resolver.start(function () {
        out(PROG + ': listening on ' + o.bind + ':' + o.port + ' (udp+tcp), rules=' + rules.count +
            ', audit=' + (auditFd !== null ? o.audit : '<stdout-only>'));
    }, function (msg) {
        errline(PROG + ': ' + msg);
        process.exit(1);
    });
}

main();
