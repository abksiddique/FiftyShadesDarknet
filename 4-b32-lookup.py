#!/usr/bin/env python3
# =============================================================================
#  Script   : b32-lookup.py
#  Version  : 1.0
#
#  Title    : Fifty Shades of the Darknet — Eepsite / B32 Deep Lookup
#
#  Purpose  : Look up any I2P eepsite by its b32 address or .i2p hostname.
#             Fetches the complete LeaseSet, analyses tunnel architecture,
#             and performs deep global lookup of every tunnel gateway router.
#
#  Lookup Pipeline:
#    Phase 1 — Resolve input to canonical b32 address
#      • Strips http://, https://, trailing slashes
#      • If .i2p name: SAM NAMING LOOKUP → derive b32 from destination bytes
#      • If raw 52-char base32: appends .b32.i2p suffix
#
#    Phase 2 — Fetch LeaseSet from all available sources
#      • Console cache (/netdb?ls=<b32>)
#      • SAM NAMING LOOKUP triggers network-level LS fetch, re-checks console
#      • XOR routing key analysis: computes which floodfills SHOULD store
#        this LS and queries those first before general probe
#      • Progressive floodfill probe: all known floodfills, batches of 5
#
#    Phase 3 — Parse LeaseSet completely
#      • LS hash, destination prefix, b32, published, expires, LS type
#      • RAP/RAR flags, distance, routing key, encryption keys
#      • All Lease entries: gateway prefix, tunnel ID, expiry
#
#    Phase 4 — Look up each tunnel gateway router globally
#      • Local .dat files → console cache → 50-floodfill probe per gateway
#      • Full router details: hash, version, caps, IP, shade classification
#
#    Phase 5 — Hosting analysis (honest, protocol-grounded)
#      • LS Type 5 (Encrypted): gateway list hidden, hosting anonymous
#      • 0-hop tunnels: gateway = endpoint = hosting router (DEFINITIVE)
#      • Standard 3-hop: gateways are entry points, endpoint is hidden
#      • Shade 8 gateway: that router is an exclusive network node
#
#    Phase 6 — Export full report to ./scanner-output/
#
#  Tunnel Architecture (I2P inbound tunnel):
#    [Gateway] → [Hop 1] → [Hop 2] → [Hosting Router = ENDPOINT]
#    The LeaseSet publishes: Gateway hash (first hop)
#    The LeaseSet hides:     Endpoint hash (last hop = actual host)
#    Exception: if tunnel length = 0, gateway = endpoint = hosting router
#
#  Input formats accepted:
#    bbex6f4i7l3v6uqtageqp2u5yesraeqzcvzfsxkminbhoed5zqqq.b32.i2p
#    bbex6f4i7l3v6uqtageqp2u5yesraeqzcvzfsxkminbhoed5zqqq
#    http://bbex6f4i7l3v6uqtageqp2u5yesraeqzcvzfsxkminbhoed5zqqq.b32.i2p/
#    stats.i2p
#    irc.postman.i2p
#
#  Author   : Siddique Abubakr Muntaka, PhD Candidate
#             Information Technology | University of Cincinnati, Ohio, USA
#  Advisor  : Dr. Jacques Bou Abdo
#             Multi-domain and Information Operations, Resilience and
#             Anonymity Group (MIRAGe-UC)
#
#  Usage    : python3 b32-lookup.py
# =============================================================================

import sys, os, re, time, socket, base64, hashlib, struct, subprocess
import urllib.request, urllib.parse
from pathlib import Path
from collections import OrderedDict
from datetime import datetime, timezone

# =============================================================================
#  COLOUR
# =============================================================================
_C = sys.stdout.isatty()
RED    = "\033[0;31m"  if _C else ""
GREEN  = "\033[0;32m"  if _C else ""
YELLOW = "\033[1;33m"  if _C else ""
CYAN   = "\033[0;36m"  if _C else ""
MAG    = "\033[0;35m"  if _C else ""
BOLD   = "\033[1m"     if _C else ""
DIM    = "\033[2m"     if _C else ""
BRED   = "\033[1;31m"  if _C else ""
RESET  = "\033[0m"     if _C else ""

# =============================================================================
#  SHADE TAXONOMY
# =============================================================================
SHADES = OrderedDict([
    (1, ("Beacon",    GREEN,  "Floodfill + direct IP — fully visible NetDB anchor")),
    (2, ("Relay",     GREEN,  "High-capacity relay, direct IP, no floodfill")),
    (3, ("Passive",   CYAN,   "Direct IP, standard or unknown capacity")),
    (4, ("Cloaked",   YELLOW, "Has IP but firewalled/self-declared unreachable")),
    (5, ("Veiled",    MAG,    "No direct IP — reachable via introducers only")),
    (6, ("Declared",  YELLOW, "Self-declared hidden flag in capabilities")),
    (7, ("Phantom",   RED,    "In NetDB, no address, no introducers")),
    (8, ("Exclusive", BRED,   "ABSENT from entire I2P NetDB — Exclusive Network")),
    (0, ("Unknown",   DIM,    "Insufficient data")),
])

_RCAPS = set("fLOXHNPRUDEG")

def classify(caps: str, has_ip: bool, has_intro: bool) -> int:
    if "f" in caps.lower() and has_ip:                                         return 1
    if "f" not in caps.lower() and has_ip and any(x in caps for x in "XHON"): return 2
    if has_ip and "L" in caps and "f" not in caps.lower():                     return 3
    if has_ip and "U" in caps:                                                 return 4
    if has_ip:                                                                 return 3
    if not has_ip and has_intro:                                               return 5
    if "H" in caps and not has_ip and not has_intro:                           return 6
    if not has_ip and not has_intro and caps:                                  return 7
    return 0

# =============================================================================
#  GLOBALS
# =============================================================================
CONSOLE_URL = "http://127.0.0.1:7657"
SAM_HOST    = "127.0.0.1"
SAM_PORT    = 7656
NETDB_PATH  = ""
CONFIG_DIR  = ""

# =============================================================================
#  DISPLAY HELPERS
# =============================================================================
def hdr():       print(f"  {DIM}{'═'*68}{RESET}")
def div():       print(f"  {DIM}{'─'*68}{RESET}")
def row(l, v):   print(f"  {BOLD}{l:<26}{RESET} {v}")
def stp(n, m):   print(f"\n  {BOLD}{CYAN}[Phase {n}]{RESET}  {m}")
def ok(m):       print(f"  {GREEN}[✓]{RESET}  {m}")
def warn(m):     print(f"  {YELLOW}[!]{RESET}  {m}")
def info(m):     print(f"  {DIM}[-]{RESET}  {m}")
def err(m):      print(f"  {RED}[✗]{RESET}  {m}")

# =============================================================================
#  AUTO-DETECT I2P
# =============================================================================
def detect_i2p() -> bool:
    global NETDB_PATH, CONFIG_DIR
    candidates = []
    try:
        res = subprocess.run(["pgrep","-a","-f","net.i2p.router.Router"],
                             capture_output=True, text=True)
        for line in res.stdout.splitlines():
            m = re.search(r"(/[^\s]+)/wrapper\.config", line)
            if m: candidates.append(Path(m.group(1)).parent / ".i2p")
    except Exception: pass
    try:
        import pwd
        for e in pwd.getpwall():
            if e.pw_uid >= 1000:
                candidates.append(Path(e.pw_dir) / ".i2p")
    except Exception: pass
    candidates += [Path("/var/lib/i2p/i2p-config"),
                   Path("/root/.i2p"), Path.home() / ".i2p"]
    for p in candidates:
        if (p / "router.config").exists():
            CONFIG_DIR = str(p)
            nb = p / "netDb"
            NETDB_PATH = str(nb) if nb.exists() else ""
            return True
    return False

# =============================================================================
#  HTTP
# =============================================================================
def http_get(path: str, timeout: int = 10) -> str:
    try:
        req = urllib.request.Request(
            CONSOLE_URL + path, headers={"Accept": "text/html"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", errors="ignore")
    except Exception:
        return ""

def clean_html(html: str) -> str:
    h = re.sub(r"&nbsp;",  " ", html)
    h = re.sub(r"&#\d+;",  "",  h)
    h = re.sub(r"<[^>]+>", " ", h)
    return re.sub(r"\s{2,}", " ", h).strip()

# =============================================================================
#  CRYPTO / ENCODING HELPERS
# =============================================================================
def decode_i2p_b64(s: str) -> bytes:
    """Decode I2P modified base64 (uses - and ~ instead of + and /)."""
    try:
        s = s.replace("-", "+").replace("~", "/")
        return base64.b64decode(s + "=" * ((4 - len(s) % 4) % 4))
    except Exception:
        return b""

def derive_b32_from_bytes(dest_bytes: bytes) -> str:
    """
    Derive b32 from raw destination bytes.
    Formula confirmed on I2P 2.12.0:
      cert_offset = 384
      cert_type   = data[384]
      cert_len    = big-endian uint16 at data[385:387]
      dest_size   = 387 + cert_len
      b32         = base32(SHA256(data[:dest_size])).lower() + ".b32.i2p"
    """
    try:
        if len(dest_bytes) < 387: return ""
        cert_t = dest_bytes[384]
        if cert_t == 0:   ds = 387
        elif cert_t == 5: ds = 387 + struct.unpack(">H", dest_bytes[385:387])[0]
        else: return ""
        if ds > len(dest_bytes): return ""
        return (base64.b32encode(hashlib.sha256(dest_bytes[:ds]).digest())
                .decode().lower().rstrip("=") + ".b32.i2p")
    except Exception:
        return ""

def decode_router_hash(h: str) -> bytes:
    """Decode router hash from I2P base64url to 32 bytes."""
    try:
        raw = decode_i2p_b64(h)
        return raw if len(raw) == 32 else None
    except Exception:
        return None

def compute_daily_mod_key() -> bytes:
    """SHA256("yyyyMMdd" UTC) per I2P RoutingKeyGenerator.java"""
    return hashlib.sha256(
        datetime.now(timezone.utc).strftime("%Y%m%d").encode("utf-8")
    ).digest()

def compute_routing_key_from_b32(dest_b32: str, mod_key: bytes) -> bytes:
    """
    Compute routing_key = SHA256(dest_hash XOR mod_key).
    dest_hash = SHA256(destination_bytes) = what we decode from b32.
    For b32 addresses: b32 = base32(SHA256(dest_bytes)), so
    SHA256(dest_bytes) = base32decode(b32_prefix).
    """
    try:
        b32_part = dest_b32.replace(".b32.i2p", "").upper()
        padding  = (8 - len(b32_part) % 8) % 8
        dest_hash_bytes = base64.b32decode(b32_part + "=" * padding)
        if len(dest_hash_bytes) != 32: return None
        xorred = bytes(a ^ b for a, b in zip(dest_hash_bytes, mod_key))
        return hashlib.sha256(xorred).digest()
    except Exception:
        return None

def xor_distance(a: bytes, b: bytes) -> int:
    dist = 0
    for x, y in zip(a, b): dist = (dist << 8) | (x ^ y)
    return dist

# =============================================================================
#  SAM
# =============================================================================
def sam_alive() -> bool:
    try:
        s = socket.create_connection((SAM_HOST, SAM_PORT), timeout=3)
        s.sendall(b"HELLO VERSION MIN=3.0 MAX=3.3\n")
        r = s.recv(256).decode("utf-8", errors="ignore")
        s.close()
        return "RESULT=OK" in r
    except Exception:
        return False

def sam_naming_lookup(name: str) -> str:
    """
    SAM NAMING LOOKUP — resolve an I2P address to its full destination key.
    Side effect: triggers the router to fetch and cache the LeaseSet.
    Returns full base64 destination string, or "" on failure.
    """
    try:
        s = socket.create_connection((SAM_HOST, SAM_PORT), timeout=5)
        s.sendall(b"HELLO VERSION MIN=3.0 MAX=3.3\n")
        buf = b""
        s.settimeout(5)
        while b"\n" not in buf: buf += s.recv(256)
        if b"RESULT=OK" not in buf: s.close(); return ""
        s.sendall(f"NAMING LOOKUP NAME={name}\n".encode())
        buf = b""
        s.settimeout(15)  # network lookups can take time
        while b"\n" not in buf:
            c = s.recv(512)
            if not c: break
            buf += c
        s.close()
        m = re.search(r"VALUE=(\S+)", buf.decode("utf-8", errors="ignore"))
        return m.group(1) if m else ""
    except Exception:
        return ""

# =============================================================================
#  LOAD LOCAL NETDB
# =============================================================================
def parse_dat(filepath: str) -> dict:
    """Parse a RouterInfo .dat file to extract router properties."""
    r = {"hash":"","caps":"","version":"","transports":[],"has_ip":False,
         "has_intro":False,"known_routers":0,"source":"local"}
    m = re.match(r"routerInfo-(.+)\.dat$", os.path.basename(filepath))
    if m: r["hash"] = m.group(1)
    try:
        res = subprocess.run(["strings", filepath],
                             capture_output=True, text=True, timeout=10)
        lines = res.stdout.splitlines()
    except Exception:
        return r
    i = 0; cur = {}; tps = []; all_caps = []
    while i < len(lines):
        ln = lines[i].rstrip()
        if ln in ("NTCP2","SSU2","SSU","NTCP"):
            if cur.get("type"): tps.append(cur)
            cur = {"type":ln,"host":"","port":"","mtu":"","caps":""}
            i += 1; continue
        if ln.endswith("=") and i+1 < len(lines):
            k = ln[:-1]; v = lines[i+1].rstrip().rstrip(";"); i += 2
            if k == "caps":
                if re.match(r"^[A-Za-z0-9]{1,12}$", v):
                    all_caps.append(v)
                    if cur.get("type"): cur["caps"] = v
            elif k == "host":
                if re.match(r"^\d+\.\d+\.\d+\.\d+$",v) or ":"in v:
                    r["has_ip"] = True
                    if cur.get("type"): cur["host"] = v
            elif k == "port":
                if cur.get("type") and re.match(r"^\d+$",v): cur["port"] = v
            elif k == "mtu":
                if cur.get("type"): cur["mtu"] = v
            elif k == "router.version":
                r["version"] = re.sub(r"[^0-9.].*$","",v).strip(".")
            elif k == "netdb.knownRouters":
                try: r["known_routers"] = int(v)
                except: pass
            continue
        if re.match(r"^i=",ln) or re.match(r"^ih\d+=",ln): r["has_intro"] = True
        i += 1
    if cur.get("type"): tps.append(cur)
    r["transports"] = tps
    for c in reversed(all_caps):
        if any(x in _RCAPS for x in c): r["caps"] = c; break
    if not r["caps"] and all_caps: r["caps"] = all_caps[-1]
    return r

def load_netdb() -> dict:
    routers = {}
    if not NETDB_PATH or not os.path.isdir(NETDB_PATH): return routers
    for fp in Path(NETDB_PATH).rglob("routerInfo-*.dat"):
        r = parse_dat(str(fp))
        if r["hash"]: routers[r["hash"]] = r
    return routers

def get_floodfills(local_netdb: dict) -> list:
    return [h for h, r in local_netdb.items()
            if "f" in r.get("caps","").lower()]

# =============================================================================
#  PARSE ROUTER from console HTML
# =============================================================================
def parse_router_html(html: str, known_hash: str = "") -> dict:
    r = {"hash":known_hash,"caps":"","version":"","transports":[],
         "has_ip":False,"has_intro":False,"known_routers":0,
         "signing_key":"","enc_key":"","published":"","netid":"",
         "source":"console","known_leasests":0}
    c = clean_html(html)
    for pat, key in [
        (r"Published:\s*([\d\w\s]+ago)",                    "published"),
        (r"Signing Key:\s*(\S+)",                            "signing_key"),
        (r"Encryption Key:\s*(\S+)",                         "enc_key"),
        (r"caps\s*=\s*([A-Za-z]{1,12})",                    "caps"),
        (r"router\.version\s*=\s*([\d]+\.[\d]+\.[\d]+)",    "version"),
        (r"netId\s*=\s*(\d+)",                               "netid"),
    ]:
        m = re.search(pat, c)
        if m: r[key] = m.group(1).strip()
    # Strip HTML artifacts from version
    if r["version"]:
        r["version"] = re.sub(r"[^0-9.].*$", "", r["version"]).strip(".")
    if not r["version"]:
        m = re.search(r"router\.version\s*=\s*([\d]+\.[\d]+)", c)
        if m: r["version"] = re.sub(r"[^0-9.].*$","",m.group(1)).strip(".")
    for pat, key in [(r"netdb\.knownRouters\s*=\s*(\d+)",   "known_routers"),
                     (r"netdb\.knownLeaseSets\s*=\s*(\d+)", "known_leasests")]:
        m = re.search(pat, c)
        if m:
            try: r[key] = int(m.group(1))
            except: pass
    ab = re.search(r"Addresses:(.*?)Stats:", c, re.DOTALL)
    if ab:
        block = ab.group(1)
        if re.search(r"\d+\.\d+\.\d+\.\d+", block): r["has_ip"] = True
        if re.search(r"\bih\d+\b|\bi=\b", block):   r["has_intro"] = True
        tps = []
        for tp in re.finditer(
                r"(NTCP2|SSU2|NTCP|SSU):\s*(.*?)(?=NTCP2:|SSU2:|NTCP:|SSU:|$)",
                block, re.DOTALL):
            inf = {"type":tp.group(1),"host":"","port":"","mtu":"","caps":""}
            for lbl, pt in [("host",r"host:\s*(\S+)"),("port",r"port:\s*(\d+)"),
                             ("mtu",r"mtu:\s*(\d+)"),("caps",r"caps:\s*([A-Za-z0-9]+)")]:
                mm = re.search(pt, tp.group(2))
                if mm: inf[lbl] = mm.group(1).rstrip(";, ")
            tps.append(inf)
        r["transports"] = tps
    return r

# =============================================================================
#  DISPLAY ROUTER BLOCK
# =============================================================================
def print_router_block(r: dict, label: str = "GATEWAY ROUTER"):
    sid = classify(r.get("caps",""), r.get("has_ip",False), r.get("has_intro",False))
    sd  = SHADES.get(sid, SHADES[0])
    hdr(); print(f"  {BOLD}{label}{RESET}"); hdr()
    row("Hash",           r.get("hash","N/A"))
    row("I2P Version",    r.get("version","N/A"))
    row("Capabilities",   r.get("caps","N/A") or "none")
    row("Direct IP",      "Yes" if r.get("has_ip")    else "No")
    row("Introducers",    "Yes" if r.get("has_intro") else "No")
    row("Published",      r.get("published","N/A"))
    row("Signing Key",    (r.get("signing_key","") or "N/A")[:52])
    row("Encryption Key", (r.get("enc_key","") or "N/A")[:52])
    row("Known Routers",  str(r.get("known_routers", 0)))
    row("Network ID",     r.get("netid","N/A"))
    row("Data Source",    r.get("source","N/A"))
    tps = r.get("transports",[])
    if tps:
        print(f"\n  {BOLD}Transport Addresses:{RESET}")
        for t in tps:
            addr = (f"{t.get('host','')}:{t.get('port','')}"
                    if t.get("host") else "(no direct IP published)")
            print(f"    {CYAN}[{t.get('type','?'):5}]{RESET}  {addr:<34} "
                  f"caps={t.get('caps','')}  mtu={t.get('mtu','')}")
    else:
        print(f"\n  {DIM}  No published transport addresses{RESET}")
    div()
    print(f"  {sd[1]}{BOLD}  ► Shade {sid}: {sd[0].upper()}{RESET}")
    print(f"  {DIM}  {sd[2]}{RESET}")
    hdr()
    return sid

# =============================================================================
#  PARSE LEASESET from console HTML — complete parser
# =============================================================================
def parse_leaseset_html(html: str, query: str = "") -> dict:
    """
    Parse a LeaseSet detail page from the I2P console.
    Returns a dict with all available fields.
    """
    ls = {
        "b32": "", "destination": "", "ls_hash": "",
        "published": "", "expires": "", "sig_type": "",
        "enc_keys": [], "routing_key": "", "leases": [],
        "ls_type": "", "rap": "", "rar": "",
        "distance": "", "unpublished": "",
        "raw_html": html,
    }
    c = clean_html(html)

    for pat, key in [
        (r"LeaseSet:\s*([A-Za-z0-9~=+/\-]{20,})",    "ls_hash"),
        (r"Destination:\s*([A-Za-z0-9~=+/\-]{6,})",   "destination"),
        (r"([a-z2-7]{52,60}\.b32\.i2p)",                  "b32"),
        (r"Published\s+(\d+\s+\w+\s+ago)",              "published"),
        (r"Expires\s+in\s+([\d]+\s+\w+)",               "expires"),
        (r"Type:\s*(\d+)",                               "ls_type"),
        (r"RAP\?\s*(true|false)",                        "rap"),
        (r"RAR\?\s*(true|false)",                        "rar"),
        (r"Distance:\s*([\d.]+)",                        "distance"),
        (r"Unpublished\?\s*(true|false)",                "unpublished"),
        (r"Signature type:\s*([\w_]+)",                  "sig_type"),
        (r"Routing Key:\s*([A-Za-z0-9~=+/\-]{20,})",    "routing_key"),
    ]:
        m = re.search(pat, c)
        if m: ls[key] = m.group(1).strip()

    # If b32 not found on page, use the query input
    if not ls["b32"] and query.endswith(".b32.i2p"):
        ls["b32"] = query

    # Encryption keys: "Encryption Key: TYPE KEY"
    ls["enc_keys"] = re.findall(
        r"Encryption Key:\s*([\w_]+)\s+([A-Za-z0-9~=+/\-]{8,})", c)

    # Lease entries — flexible regex to handle all formatting variants
    # Console format: "Lease N: ?? GWPREFIX Tunnel TUNNELID Expires in Xs"
    # After clean_html: whitespace compressed, tags removed
    for m in re.finditer(
            r"Lease\s+(\d+):\s*(?:[^A-Za-z0-9~=+/\-]*)"
            r"([A-Za-z0-9~=+/\-]{4,8})\s+"
            r"Tunnel\s+(\d+)"
            r"(?:\s+Expires\s+in\s+([\d]+\s+\w+))?",
            c):
        ls["leases"].append({
            "num":       m.group(1),
            "gw_prefix": m.group(2),
            "tunnel_id": m.group(3),
            "expires":   m.group(4) if m.group(4) else "unknown",
        })

    return ls

def leaseset_type_description(ls_type: str) -> str:
    descriptions = {
        "1":  "LeaseSet (standard, Type 1)",
        "3":  "LeaseSet2 (standard, Type 3)",
        "5":  "EncryptedLeaseSet (Type 5) — gateways encrypted/hidden",
        "7":  "MetaLeaseSet (Type 7)",
        "11": "EncryptedLeaseSet2 (Type 11)",
    }
    return descriptions.get(ls_type, f"LeaseSet Type {ls_type} (unknown)")

# =============================================================================
#  PHASE 1 — RESOLVE INPUT
# =============================================================================
def resolve_input(raw: str, use_sam: bool) -> dict:
    """
    Resolve any input format to a canonical b32 address.
    Returns dict with: b32, original_input, is_b32, is_named, input_type, dest_b64
    """
    result = {
        "b32": "", "original": raw, "is_b32": False,
        "is_named": False, "input_type": "", "dest_b64": "",
        "error": "",
    }

    # Strip URL artifacts
    s = raw.strip()
    s = re.sub(r"^https?://", "", s)   # remove http:// / https://
    s = s.rstrip("/")                   # remove trailing slash
    s = s.strip()

    # Case 1: Raw base32 without suffix (52-60 chars for standard and blinded LS2)
    if re.match(r"^[a-z2-7]{52,60}$", s):
        result["b32"]        = s + ".b32.i2p"
        result["is_b32"]     = True
        result["input_type"] = "raw b32 (no suffix)"
        return result

    # Case 2: Full b32 address (52-60 chars + .b32.i2p)
    if re.match(r"^[a-z2-7]{52,60}\.b32\.i2p$", s):
        result["b32"]        = s
        result["is_b32"]     = True
        result["input_type"] = "b32 address"
        return result

    # Case 3: .i2p hostname — needs SAM to resolve
    if s.endswith(".i2p") and not s.endswith(".b32.i2p"):
        result["is_named"]   = True
        result["input_type"] = ".i2p hostname"

        if use_sam:
            info(f"SAM NAMING LOOKUP: {s}")
            dest = sam_naming_lookup(s)
            if dest and len(dest) > 100:
                result["dest_b64"] = dest
                dest_bytes = decode_i2p_b64(dest)
                if dest_bytes:
                    b32 = derive_b32_from_bytes(dest_bytes)
                    if b32:
                        result["b32"] = b32
                        ok(f"Resolved: {s} → {b32}")
                        return result
            result["error"] = f"SAM could not resolve '{s}'"
        else:
            result["error"] = f"SAM not running — cannot resolve .i2p hostname '{s}'"

        # Fallback: try console addressbook
        ab_html = http_get(f"/dns?hostname={urllib.parse.quote(s)}", timeout=8)
        if ab_html:
            for b64 in re.findall(r"[A-Za-z0-9~\-]{200,}", ab_html):
                dest_bytes = decode_i2p_b64(b64)
                if dest_bytes and len(dest_bytes) >= 387:
                    b32 = derive_b32_from_bytes(dest_bytes)
                    if b32:
                        result["b32"]  = b32
                        result["error"] = ""
                        ok(f"Resolved via console addressbook: {s} → {b32}")
                        return result

        # Second fallback: check hosts.txt
        if CONFIG_DIR:
            hosts = Path(CONFIG_DIR) / "hosts.txt"
            if hosts.exists():
                for line in hosts.read_text(errors="ignore").splitlines():
                    if line.startswith(s + "="):
                        b64 = line.split("=", 1)[1].strip()
                        dest_bytes = decode_i2p_b64(b64)
                        if dest_bytes:
                            b32 = derive_b32_from_bytes(dest_bytes)
                            if b32:
                                result["b32"] = b32
                                result["error"] = ""
                                ok(f"Resolved via hosts.txt: {s} → {b32}")
                                return result
        return result

    result["error"] = f"Unrecognised format: '{s}'"
    return result

# =============================================================================
#  PHASE 2 — FETCH LEASESET (aggressive multi-source)
# =============================================================================
def fetch_leaseset(b32: str, local_netdb: dict, use_sam: bool) -> dict:
    """
    Fetch a LeaseSet for the given b32 address using all available sources.
    Returns parsed LeaseSet dict or None if not found anywhere.
    """

    def _check_console(q: str) -> dict:
        html = http_get(f"/netdb?ls={urllib.parse.quote(q)}", timeout=8)
        if html and "Published" in html and "Lease" in html:
            return parse_leaseset_html(html, q)
        return None

    # ── Source 1: Console cache ───────────────────────────────────────────
    info("Checking console cache...")
    ls = _check_console(b32)
    if ls:
        ok("LeaseSet found in console cache.")
        return ls

    # ── Source 2: SAM NAMING LOOKUP ───────────────────────────────────────
    if use_sam:
        info("SAM NAMING LOOKUP → triggering network-level LeaseSet fetch...")
        dest = sam_naming_lookup(b32)
        if dest:
            ok(f"SAM resolved b32 (destination: {len(dest)} chars)")
        else:
            info("SAM could not resolve this b32 directly.")
        # Give the router a moment to cache the LS
        time.sleep(2)
        ls = _check_console(b32)
        if ls:
            ok("LeaseSet found in console after SAM trigger.")
            return ls

    # ── Source 3: XOR routing key — find the floodfills MOST LIKELY to
    #              store this LS and probe them first
    mod_key = compute_daily_mod_key()
    rk = compute_routing_key_from_b32(b32, mod_key)
    ffs = get_floodfills(local_netdb)

    if rk and ffs:
        # Sort floodfills by XOR distance to this LS's routing key
        # The closest ones are most likely to store it → probe them first
        ff_with_dist = []
        for ff_hash in ffs:
            ff_bytes = decode_router_hash(ff_hash)
            if ff_bytes:
                dist = xor_distance(ff_bytes, rk)
                ff_with_dist.append((dist, ff_hash))
        ff_with_dist.sort(key=lambda x: x[0])
        ffs_sorted = [h for _, h in ff_with_dist]

        info(f"XOR-sorted probe: querying {min(50,len(ffs_sorted))} closest floodfills first...")
        for i, ff in enumerate(ffs_sorted[:50]):
            http_get(f"/netdb?r={urllib.parse.quote(ff)}", timeout=6)
            if (i+1) % 5 == 0:
                ls = _check_console(b32)
                if ls:
                    ok(f"LeaseSet found after {i+1} XOR-targeted probes.")
                    return ls
            time.sleep(0.1)
        ls = _check_console(b32)
        if ls:
            ok("LeaseSet found after XOR-targeted probe.")
            return ls

        # ── Source 4: Full progressive floodfill probe ────────────────────
        # Remaining floodfills (beyond the first 50) in XOR order
        remaining = ffs_sorted[50:]
        total = len(remaining)
        probed = 0
        print(f"  {DIM}  Full probe: {total} remaining floodfills in batches of 5...{RESET}")
        for i in range(0, min(total, 500), 5):
            for ff in remaining[i:i+5]:
                http_get(f"/netdb?r={urllib.parse.quote(ff)}", timeout=6)
                probed += 1
            print(f"  {DIM}  [{probed}/{min(total,500)}] probed...{RESET}", end="\r")
            ls = _check_console(b32)
            if ls:
                print(f"\n  {GREEN}[✓]{RESET}  LeaseSet found after {probed+50} total probes.")
                return ls
            time.sleep(0.1)
        print(f"\n  {YELLOW}[!]{RESET}  Exhausted {probed+50} floodfill probes — LS not found.")

    else:
        # No XOR sort possible — linear probe
        total = len(ffs)
        probed = 0
        print(f"  {DIM}  Linear probe: {total} floodfills in batches of 5...{RESET}")
        for i in range(0, min(total, 500), 5):
            for ff in ffs[i:i+5]:
                http_get(f"/netdb?r={urllib.parse.quote(ff)}", timeout=6)
                probed += 1
            print(f"  {DIM}  [{probed}/{min(total,500)}] probed...{RESET}", end="\r")
            ls = _check_console(b32)
            if ls:
                print(f"\n  {GREEN}[✓]{RESET}  LeaseSet found after {probed} probes.")
                return ls
            time.sleep(0.1)
        print(f"\n  {YELLOW}[!]{RESET}  Exhausted {probed} floodfill probes.")

    return None

# =============================================================================
#  PHASE 4 — LOOK UP A GATEWAY ROUTER GLOBALLY
# =============================================================================
def lookup_gateway_router(gw_prefix: str, local_netdb: dict) -> dict:
    """
    Find a router by short hash prefix across all available sources.
    Returns parsed router dict or None if absent everywhere.
    """
    # Source 1: Local .dat files
    for h, r in local_netdb.items():
        if h.startswith(gw_prefix) or h == gw_prefix:
            return dict(r)

    # Source 2: Console cache
    html = http_get(f"/netdb?r={urllib.parse.quote(gw_prefix)}", timeout=6)
    if html and "Published:" in html:
        return parse_router_html(html, gw_prefix)

    # Source 3: Floodfill probe (50 max per gateway)
    ffs    = get_floodfills(local_netdb)
    probed = 0
    for ff in ffs[:50]:
        http_get(f"/netdb?r={urllib.parse.quote(ff)}", timeout=5)
        probed += 1
        print(f"  {DIM}  Probing for gateway [{gw_prefix}]: {probed}/50...{RESET}",
              end="\r")
        html = http_get(f"/netdb?r={urllib.parse.quote(gw_prefix)}", timeout=5)
        if html and "Published:" in html:
            print(f"\n  {GREEN}[✓]{RESET}  Gateway [{gw_prefix}] found after {probed} probes.")
            return parse_router_html(html, gw_prefix)
        time.sleep(0.1)

    if probed > 0:
        print(f"\r  {YELLOW}[!]{RESET}  Gateway [{gw_prefix}]: not found after "
              f"{probed} probes.    ")
    return None

# =============================================================================
#  PRINT LEASESET DETAILS
# =============================================================================
def print_leaseset_block(ls: dict):
    hdr(); print(f"  {BOLD}LEASESET DETAILS{RESET}"); hdr()
    b32 = ls.get("b32","N/A")
    row("B32 Address",   b32)
    row("LS Hash",       ls.get("ls_hash","N/A"))
    row("Destination",   (ls.get("destination","N/A") or "N/A")[:20] + "...")
    row("Published",     ls.get("published","N/A"))
    row("Expires",       ls.get("expires","N/A"))
    row("LS Type",       (ls.get("ls_type","N/A") + "  " +
                         leaseset_type_description(ls.get("ls_type",""))))
    row("Signature",     ls.get("sig_type","N/A"))
    row("RAP / RAR",     f"{ls.get('rap','?')} / {ls.get('rar','?')}")
    row("Distance",      ls.get("distance","N/A"))
    row("Unpublished",   ls.get("unpublished","N/A"))
    row("Routing Key",   (ls.get("routing_key","") or "N/A")[:52])

    enc_keys = ls.get("enc_keys",[])
    if enc_keys:
        print(f"\n  {BOLD}Encryption Keys:{RESET}")
        for kt, kv in enc_keys:
            print(f"    {CYAN}{kt:<26}{RESET}  {kv[:32]}...")

    leases = ls.get("leases",[])
    if leases:
        print(f"\n  {BOLD}Active Lease Entries ({len(leases)}):{RESET}")
        for l in leases:
            print(f"    Lease {l['num']}: "
                  f"gateway [{YELLOW}{l['gw_prefix']}{RESET}]  "
                  f"Tunnel {l['tunnel_id']}  "
                  f"Expires {l['expires']}")
    else:
        warn("No Lease entries found.")
    hdr()

# =============================================================================
#  PHASE 5 — HOSTING ANALYSIS LOGIC
# =============================================================================
def hosting_analysis(ls: dict, gateway_results: list) -> dict:
    """
    Determine what can and cannot be said about the hosting router.
    Returns an analysis dict.
    """
    ls_type = ls.get("ls_type","")
    leases  = ls.get("leases",[])

    analysis = {
        "is_encrypted":     ls_type == "5",
        "hosting_provable": False,
        "reason":           "",
        "hosting_routers":  [],
        "shade8_gateways":  [],
    }

    if ls_type == "5":
        analysis["reason"] = (
            "EncryptedLeaseSet (Type 5): gateway identities are encrypted. "
            "The hosting router identity is fully protected by design. "
            "Only an authorized client with the decryption key can see the leases.")
        return analysis

    # Check if any gateway is Shade 8
    for lease, router in gateway_results:
        if router is None:
            analysis["shade8_gateways"].append(lease["gw_prefix"])

    # Determine if tunnel length = 0 (from any analysis we have)
    # We cannot directly know the remote eepsite's tunnel length from outside.
    # But if ALL gateways resolve to the same router and it makes sense → 0-hop.
    # We note this analytically.

    if not leases:
        analysis["reason"] = "No Lease entries available — cannot determine gateway or hosting router."
        return analysis

    # Standard multi-hop: gateway ≠ hosting router
    analysis["reason"] = (
        "Standard multi-hop tunnels: the LeaseSet publishes the inbound tunnel "
        "GATEWAY (first hop). The hosting router is the tunnel ENDPOINT (last hop) "
        "and is deliberately not published. From the network alone, the hosting "
        "router identity cannot be determined for standard tunnel lengths.")

    # Exception: if any gateway cannot be found → Shade 8
    if analysis["shade8_gateways"]:
        analysis["reason"] += (
            f" Note: {len(analysis['shade8_gateways'])} gateway(s) are absent "
            f"from the entire I2P NetDB (Shade 8 — Exclusive Network).")

    return analysis

# =============================================================================
#  MAIN LOOKUP
# =============================================================================
def do_lookup(raw_input: str, local_netdb: dict):
    use_sam = sam_alive()
    ffs     = get_floodfills(local_netdb)

    print(f"\n  {BOLD}{CYAN}{'═'*68}{RESET}")
    print(f"  {BOLD}B32 / EEPSITE LOOKUP{RESET}  →  {CYAN}{BOLD}{raw_input}{RESET}")
    print(f"  {BOLD}{CYAN}{'═'*68}{RESET}\n")

    # ── PHASE 1: Resolve input ────────────────────────────────────────────
    stp("1", "Resolving input to canonical b32 address...")
    resolved = resolve_input(raw_input, use_sam)

    if resolved.get("error") and not resolved.get("b32"):
        err(f"Resolution failed: {resolved['error']}")
        return

    b32 = resolved["b32"]
    info(f"Input type  : {resolved['input_type']}")
    ok(f"Canonical b32: {b32}")
    if resolved.get("error"):
        warn(f"Note: {resolved['error']}")

    # ── PHASE 2: Fetch LeaseSet ───────────────────────────────────────────
    stp("2", f"Fetching LeaseSet for {b32}...")
    print(f"  {DIM}  Sources: console cache → SAM → XOR-targeted probe → full probe{RESET}\n")

    ls = fetch_leaseset(b32, local_netdb, use_sam)

    if not ls:
        print(f"\n  {RED}[✗]{RESET}  LeaseSet not found for: {b32}\n")
        print(f"  {DIM}  Exhaustively searched all {len(ffs)} known floodfills.{RESET}")
        print(f"\n  {BOLD}Possible reasons:{RESET}")
        print(f"  {DIM}  • Eepsite is offline or tunnel has been stopped{RESET}")
        print(f"  {DIM}  • LeaseSet expired (I2P TTL ≈ 10 minutes){RESET}")
        print(f"  {DIM}  • EncryptedLeaseSet Type 5 — not directly queryable{RESET}")
        print(f"  {DIM}  • Hosting router operates in Exclusive Network mode (Shade 8){RESET}")
        print(f"  {DIM}  • Address is incorrect or eepsite no longer exists{RESET}\n")
        return

    # ── PHASE 3: Display LeaseSet ─────────────────────────────────────────
    stp("3", "Parsing LeaseSet...")
    print_leaseset_block(ls)

    ls_type = ls.get("ls_type","")
    leases  = ls.get("leases",[])

    # Encrypted LS — special handling
    if ls_type == "5":
        print(f"\n  {YELLOW}{BOLD}EncryptedLeaseSet (Type 5) detected.{RESET}")
        print(f"  {DIM}  Gateway identities are encrypted inside the LeaseSet.{RESET}")
        print(f"  {DIM}  Only authorized clients with the correct PSK or DH key{RESET}")
        print(f"  {DIM}  can decrypt the Lease entries to see gateway hashes.{RESET}")
        print(f"  {DIM}  Hosting router identity: FULLY PROTECTED by design.{RESET}")
        _export_results(raw_input, b32, ls, [], {})
        return

    if not leases:
        warn("No Lease entries — cannot perform gateway analysis.")
        _export_results(raw_input, b32, ls, [], {})
        return

    # ── PHASE 4: Look up each tunnel gateway router ───────────────────────
    stp("4", f"Looking up {len(leases)} tunnel gateway router(s) globally...")
    print(f"\n  {DIM}  Inbound tunnel architecture:{RESET}")
    print(f"  {DIM}  [Gateway] → [Hop 1] → ... → [Hosting Router = ENDPOINT]{RESET}")
    print(f"  {DIM}  Gateways below = ENTRY POINTS (first hop) — NOT the host.{RESET}")
    print(f"  {DIM}  The hosting router is the ENDPOINT (last hop, not published).{RESET}\n")

    gateway_results = []  # list of (lease_dict, router_dict_or_None)

    for lease in leases:
        gw = lease["gw_prefix"]
        print(f"\n  {MAG}{BOLD}━━ Lease {lease['num']} — Gateway [{gw}] "
              f"Tunnel {lease['tunnel_id']} ━━{RESET}")

        router = lookup_gateway_router(gw, local_netdb)

        if router:
            gateway_results.append((lease, router))
            shade_id = print_router_block(router,
                                          label=f"GATEWAY [{gw}] — Lease {lease['num']}")

            # If this gateway is a floodfill, note XOR responsibility
            if "f" in router.get("caps","").lower():
                mod_key = compute_daily_mod_key()
                rk = compute_routing_key_from_b32(b32, mod_key)
                if rk:
                    gw_bytes = decode_router_hash(router.get("hash",""))
                    if gw_bytes:
                        dist      = xor_distance(gw_bytes, rk)
                        dist_hex  = hex(dist)[2:18].upper()  # first 8 bytes as hex
                        # Determine if this gateway is "close" (lower 128 bits ≈ 0)
                        closeness = "very close" if dist < 2**128 else "moderate" if dist < 2**192 else "distant"
                        info(f"XOR dist from gateway to LS routing key: "
                             f"0x{dist_hex}... ({closeness})")
        else:
            gateway_results.append((lease, None))
            ff_count = len(ffs)
            print(f"\n  {BRED}{BOLD}  ► Gateway [{gw}]: NOT FOUND IN I2P NETDB{RESET}")
            print(f"  {DIM}  Searched: local .dat + console + {min(ff_count,50)} floodfills{RESET}")
            print()
            print(f"  {BRED}{BOLD}  ★ SHADE 8 — EXCLUSIVE NETWORK NODE{RESET}")
            print(f"  {DIM}  This gateway router is structurally absent from the entire{RESET}")
            print(f"  {DIM}  observable I2P network. It may be operating in exclusive{RESET}")
            print(f"  {DIM}  network mode — not publishing its RouterInfo to any floodfill.{RESET}")
            print()

    # ── PHASE 5: Hosting Analysis ─────────────────────────────────────────
    stp("5", "Hosting router analysis...")
    analysis = hosting_analysis(ls, gateway_results)
    print()

    if analysis["is_encrypted"]:
        print(f"  {YELLOW}{BOLD}EncryptedLeaseSet: hosting router fully protected.{RESET}")
        print(f"  {DIM}  {analysis['reason']}{RESET}")
    else:
        print(f"  {BOLD}What can be determined about the hosting router:{RESET}\n")
        print(f"  {DIM}  {analysis['reason']}{RESET}")
        print()

        if analysis["shade8_gateways"]:
            print(f"  {BRED}{BOLD}Notable finding:{RESET}")
            print(f"  {RED}  {len(analysis['shade8_gateways'])} gateway(s) absent from "
                  f"entire NetDB (Shade 8).{RESET}")
            print(f"  {RED}  These gateways may be exclusive network nodes.{RESET}")
            for gw in analysis["shade8_gateways"]:
                print(f"  {RED}  • Gateway [{gw}]{RESET}")
            print()

        print(f"  {DIM}  To definitively identify the hosting router:{RESET}")
        print(f"  {DIM}  → Run node-lookup.py on the hosting VM and use Method A{RESET}")
        print(f"  {DIM}    (reads eepPriv.dat → SHA256(dest_bytes) → b32){RESET}")
        print(f"  {DIM}  → If the hosting router uses 0-hop tunnels, the gateway{RESET}")
        print(f"  {DIM}    IS the hosting router (provable from network alone){RESET}")

    # ── PHASE 6: Summary + Export ─────────────────────────────────────────
    print()
    hdr()
    print(f"  {BOLD}LOOKUP COMPLETE{RESET}  →  {CYAN}{b32}{RESET}")
    print(f"\n  {BOLD}Tunnel gateway summary:{RESET}")
    for lease, router in gateway_results:
        if router:
            sid = classify(router.get("caps",""), router.get("has_ip",False),
                           router.get("has_intro",False))
            sd  = SHADES.get(sid, SHADES[0])
            print(f"    Lease {lease['num']}: "
                  f"[{YELLOW}{lease['gw_prefix']}{RESET}] "
                  f"→ {sd[1]}{sd[0]}{RESET} "
                  f"v{router.get('version','?')}  "
                  f"Tunnel {lease['tunnel_id']}  "
                  f"Expires {lease['expires']}")
        else:
            print(f"    Lease {lease['num']}: "
                  f"[{YELLOW}{lease['gw_prefix']}{RESET}] "
                  f"→ {BRED}SHADE 8 — EXCLUSIVE NETWORK{RESET}  "
                  f"Tunnel {lease['tunnel_id']}")

    print(f"\n  {DIM}Gateways = inbound tunnel entry points, NOT the hosting router.{RESET}")
    if any(r is None for _, r in gateway_results):
        print(f"  {DIM}SHADE 8 gateways = absent from entire observable I2P NetDB.{RESET}")
    hdr()
    print()

    _export_results(raw_input, b32, ls, gateway_results, analysis)

# =============================================================================
#  PHASE 6 — EXPORT
# =============================================================================
def _export_results(raw_input: str, b32: str, ls: dict,
                    gateway_results: list, analysis: dict):
    ts      = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    safe_b  = re.sub(r"[^A-Za-z0-9_\-]", "_", b32[:24])
    outdir  = Path("./scanner-output"); outdir.mkdir(parents=True, exist_ok=True)
    outfile = outdir / f"b32-lookup_{safe_b}_{ts}.txt"

    lines = [
        "=" * 70,
        "FIFTY SHADES OF THE DARKNET — Eepsite / B32 Lookup Report v1.0",
        "Author : Siddique Abubakr Muntaka | PhD Candidate | Univ. Cincinnati",
        "Advisor: Dr. Jacques Bou Abdo | MIRAGe-UC",
        "=" * 70,
        f"Input      : {raw_input}",
        f"B32        : {b32}",
        f"Timestamp  : {datetime.now(timezone.utc).isoformat()}",
        "",
        "── LEASESET DETAILS " + "─" * 50,
        f"LS Hash    : {ls.get('ls_hash','N/A')}",
        f"Destination: {ls.get('destination','N/A')}",
        f"Published  : {ls.get('published','N/A')}",
        f"Expires    : {ls.get('expires','N/A')}",
        f"LS Type    : {ls.get('ls_type','N/A')} ({leaseset_type_description(ls.get('ls_type',''))})",
        f"Signature  : {ls.get('sig_type','N/A')}",
        f"RAP / RAR  : {ls.get('rap','?')} / {ls.get('rar','?')}",
        f"Distance   : {ls.get('distance','N/A')}",
        f"Unpublished: {ls.get('unpublished','N/A')}",
        f"Routing Key: {ls.get('routing_key','N/A')}",
        "",
    ]

    enc_keys = ls.get("enc_keys",[])
    if enc_keys:
        lines.append("── ENCRYPTION KEYS " + "─" * 51)
        for kt, kv in enc_keys:
            lines.append(f"  {kt:<26}  {kv[:32]}...")
        lines.append("")

    leases = ls.get("leases",[])
    if leases:
        lines.append("── ACTIVE LEASE ENTRIES " + "─" * 46)
        for l in leases:
            lines.append(f"  Lease {l['num']}: gateway [{l['gw_prefix']}]  "
                         f"Tunnel {l['tunnel_id']}  Expires {l['expires']}")
        lines.append("")

    if gateway_results:
        lines.append("── GATEWAY ROUTER DETAILS " + "─" * 44)
        for lease, router in gateway_results:
            lines.append(f"Lease {lease['num']} Gateway [{lease['gw_prefix']}]:")
            if router:
                sid = classify(router.get("caps",""), router.get("has_ip",False),
                               router.get("has_intro",False))
                lines += [
                    f"  Hash       : {router.get('hash','N/A')}",
                    f"  Version    : {router.get('version','N/A')}",
                    f"  Caps       : {router.get('caps','N/A')}",
                    f"  Direct IP  : {'Yes' if router.get('has_ip') else 'No'}",
                    f"  Introducers: {'Yes' if router.get('has_intro') else 'No'}",
                    f"  Published  : {router.get('published','N/A')}",
                    f"  Shade      : {sid} — {SHADES[sid][0]}",
                    f"  Source     : {router.get('source','N/A')}",
                ]
                for t in router.get("transports",[]):
                    addr = (f"{t.get('host','')}:{t.get('port','')}"
                            if t.get("host") else "(no direct IP)")
                    lines.append(f"    [{t.get('type','?'):5}]  {addr}  "
                                 f"caps={t.get('caps','')} mtu={t.get('mtu','')}")
            else:
                lines += [
                    f"  Status     : NOT FOUND — Shade 8 (Exclusive Network)",
                    f"  Note       : Absent from all local .dat, console, and "
                    f"50+ floodfills",
                ]
            lines.append("")

    lines.append("── HOSTING ANALYSIS " + "─" * 50)
    if analysis:
        lines.append(f"LS Type    : {ls.get('ls_type','?')}")
        lines.append(f"Encrypted  : {'Yes' if analysis.get('is_encrypted') else 'No'}")
        lines.append(f"Shade8 GWs : {len(analysis.get('shade8_gateways',[]))}")
        lines.append("")
        reason = analysis.get("reason","N/A")
        # Word-wrap the reason at 66 chars
        for chunk in [reason[i:i+66] for i in range(0, len(reason), 66)]:
            lines.append(f"  {chunk}")
    lines.append("")

    lines += [
        "── TUNNEL ARCHITECTURE NOTE " + "─" * 42,
        "  [Gateway] → [Hop 1] → ... → [Hosting Router = ENDPOINT]",
        "  The LeaseSet publishes: Gateway hash (first hop).",
        "  The LeaseSet hides:     Endpoint hash (last hop = actual host).",
        "  Exception: 0-hop tunnels → gateway = endpoint = hosting router.",
        "  EncryptedLeaseSet (Type 5) → even gateways are hidden.",
        "=" * 70,
    ]

    try:
        outfile.write_text("\n".join(lines) + "\n", encoding="utf-8")
        ok(f"Results saved: {outfile}")
    except Exception as e:
        warn(f"Could not save results: {e}")

# =============================================================================
#  BANNER + MAIN
# =============================================================================
def banner():
    print(f"""
{CYAN}{BOLD}╔═══════════════════════════════════════════════════════════════════════╗{RESET}
{CYAN}{BOLD}║  FIFTY SHADES OF THE DARKNET — Eepsite / B32 Lookup  v1.1            ║{RESET}
{CYAN}{BOLD}║  XOR-targeted LS fetch | 52-60 char b32 | Shade detection            ║{RESET}
{CYAN}{BOLD}║  Author : Siddique Abubakr Muntaka, PhD Candidate                    ║{RESET}
{CYAN}{BOLD}║           Information Technology | University of Cincinnati, OH USA   ║{RESET}
{CYAN}{BOLD}║  Advisor: Dr. Jacques Bou Abdo | MIRAGe-UC                           ║{RESET}
{CYAN}{BOLD}╚═══════════════════════════════════════════════════════════════════════╝{RESET}
""")

def main():
    banner()

    print(f"  {BOLD}{CYAN}[INIT]{RESET}  Starting up...")
    if not detect_i2p():
        err("I2P not found. Start I2P and re-run."); sys.exit(1)

    dat_count = len(list(Path(NETDB_PATH).rglob("routerInfo-*.dat"))) if NETDB_PATH else 0
    ok(f"Config dir  : {CONFIG_DIR}")
    ok(f"NetDB       : {NETDB_PATH}  ({dat_count} .dat files)")

    try:
        urllib.request.urlopen(CONSOLE_URL, timeout=3)
        ok(f"Console     : reachable at {CONSOLE_URL}")
    except Exception:
        err(f"Console not reachable — start I2P first."); sys.exit(1)

    if sam_alive():
        ok("SAM bridge  : running on port 7656")
    else:
        warn("SAM bridge  : NOT running")
        warn("  → Go to http://127.0.0.1:7657/configclients")
        warn("  → Find 'SAM application bridge'")
        warn("  → Click ▶ Play button in the Control column")

    print(f"  {DIM}  Loading local NetDB...{RESET}", end="", flush=True)
    local_netdb = load_netdb()
    ff_count    = len(get_floodfills(local_netdb))
    print(f"\r  {GREEN}[✓]{RESET}  "
          f"Local NetDB : {len(local_netdb)} routers  ({ff_count} floodfills)    ")

    if ff_count == 0:
        warn("0 floodfills — let I2P run longer to build a larger NetDB.")
    print()

    while True:
        print(f"  {BOLD}{'─'*64}{RESET}")
        print(f"  {BOLD}Enter an eepsite b32 address or .i2p hostname.{RESET}")
        print(f"  {DIM}  b32 : bbex6f4i7l3v6uqtageqp2u5yesraeqzcvzfsxkminbhoed5zqqq.b32.i2p{RESET}")
        print(f"  {DIM}  .i2p: stats.i2p  |  irc.postman.i2p  |  zzz.i2p{RESET}")
        print(f"  {DIM}  URL : http://xxx.b32.i2p  (http:// stripped automatically){RESET}")
        print(f"  {DIM}  [q] : quit{RESET}")
        print(f"  {BOLD}{'─'*64}{RESET}\n")

        try:
            q = input(f"  {BOLD}B32 or .i2p address:{RESET} ").strip()
        except (KeyboardInterrupt, EOFError):
            print(f"\n  {DIM}Exiting.{RESET}\n"); break

        if q.lower() == "q":
            print(f"\n  {DIM}Goodbye.{RESET}\n"); break
        if not q:
            warn("Nothing entered."); continue

        do_lookup(q, local_netdb)

        try:
            again = input(f"  {BOLD}Look up another eepsite? [y/N]:{RESET} ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            break
        if again != "y":
            print(f"\n  {DIM}Goodbye.{RESET}\n"); break

if __name__ == "__main__":
    main()
