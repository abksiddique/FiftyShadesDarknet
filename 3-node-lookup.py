#!/usr/bin/env python3
# =============================================================================
#  Script   : node-lookup.py
#  Version  : 2.0
#
#  Title    : Fifty Shades of the Darknet — Router Node Deep Lookup
#
#  Changelog v2.0 (critical fixes):
#    - ADDED Method C: XOR Routing Key Analysis for floodfill nodes
#      Floodfills STORE LeaseSets nearest to them in XOR space.
#      Computes SHA256(dest_hash XOR daily_modifying_key) and finds
#      which LeaseSets this floodfill is responsible for storing.
#      Based on I2P RoutingKeyGenerator.java protocol implementation.
#    - FIXED Method D: Comprehensive eepsite scan
#      Now reads ALL addressbook files (hosts.txt, local.txt,
#      published.txt, subscriptions.txt), fetches addressbook page
#      from console, and scans ALL active LeaseSets the console
#      knows about — not just the 20 on the summary page.
#    - ADDED: Router detail page scrape for associated LeaseSets
#    - ADDED: Distinction between "stores LeaseSet" (floodfill) vs
#      "appears as gateway" vs "definitively hosts" (own VM)
#
#  Eepsite Association Methods:
#    A: eepPriv.dat → SHA256(dest) → b32   DEFINITIVE own-VM only
#    B: Gateway scan — router appears as inbound tunnel entry point
#       (with 3-hop tunnels this is routing participation, not hosting)
#    C: XOR routing key (floodfills only) — floodfill stores LeaseSet
#       for destinations nearest to it in XOR space (protocol-based)
#    D: Full addressbook scan — all known eepsites checked for B+C
#
#  Author   : Siddique Abubakr Muntaka, PhD Candidate
#             Information Technology | University of Cincinnati, Ohio, USA
#  Advisor  : Dr. Jacques Bou Abdo
#             Multi-domain and Information Operations, Resilience and
#             Anonymity Group (MIRAGe-UC)
#
#  Usage    : python3 node-lookup.py
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
OWN_HASH    = ""

# =============================================================================
#  DISPLAY HELPERS
# =============================================================================
def hdr():       print(f"  {DIM}{'═'*68}{RESET}")
def div():       print(f"  {DIM}{'─'*68}{RESET}")
def row(l, v):   print(f"  {BOLD}{l:<26}{RESET} {v}")
def stp(n, m):   print(f"\n  {BOLD}{CYAN}[Step {n}]{RESET}  {m}")
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
#  PARSE RouterInfo .dat
# =============================================================================
def parse_dat(filepath: str) -> dict:
    r = {"hash":"","caps":"","version":"","transports":[],"has_ip":False,
         "has_intro":False,"known_routers":0,"source":"local","filepath":filepath}
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
            elif k == "router.version": r["version"] = v
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
        (r"Published:\s*([\d\w\s]+ago)",    "published"),
        (r"Signing Key:\s*(\S+)",            "signing_key"),
        (r"Encryption Key:\s*(\S+)",         "enc_key"),
        (r"caps\s*=\s*([A-Za-z]{1,12})",     "caps"),
        # FIX: version stops at first non-version character (was picking up HTML stats)
        (r"router\.version\s*=\s*([\d]+\.[\d]+\.[\d]+)", "version"),
        (r"netId\s*=\s*(\d+)",               "netid"),
    ]:
        m = re.search(pat, c)
        if m: r[key] = m.group(1).strip()
    # Fallback version pattern: two-part like 0.9.68
    if not r["version"]:
        m = re.search(r"router\.version\s*=\s*([\d]+\.[\d]+)", c)
        if m: r["version"] = m.group(1).strip()
    m = re.search(r"netdb\.knownRouters\s*=\s*(\d+)", c)
    if m:
        try: r["known_routers"] = int(m.group(1))
        except: pass
    m = re.search(r"netdb\.knownLeaseSets\s*=\s*(\d+)", c)
    if m:
        try: r["known_leasests"] = int(m.group(1))
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
def print_router_block(r: dict, label: str = "ROUTER DETAILS"):
    sid = classify(r.get("caps",""), r.get("has_ip",False), r.get("has_intro",False))
    sd  = SHADES.get(sid, SHADES[0])
    hdr(); print(f"  {BOLD}{label}{RESET}"); hdr()
    row("Hash",             r.get("hash","N/A"))
    row("I2P Version",      r.get("version","N/A"))
    row("Capabilities",     r.get("caps","N/A") or "none")
    row("Direct IP",        "Yes" if r.get("has_ip")    else "No")
    row("Introducers",      "Yes" if r.get("has_intro") else "No")
    row("Published",        r.get("published","N/A"))
    row("Signing Key",      (r.get("signing_key","") or "N/A")[:52])
    row("Encryption Key",   (r.get("enc_key","") or "N/A")[:52])
    row("Known Routers",    str(r.get("known_routers", 0)))
    row("Known LeaseSets",  str(r.get("known_leasests", 0)))
    row("Network ID",       r.get("netid","N/A"))
    row("Data Source",      r.get("source","N/A"))
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

# =============================================================================
#  AGGRESSIVE GLOBAL SEARCH
# =============================================================================
def search_globally(target: str, local_netdb: dict) -> dict:
    ffs   = [h for h, r in local_netdb.items() if "f" in r.get("caps","").lower()]
    total = len(ffs)
    if total == 0:
        warn("No floodfills in local netdb — cannot do global probe.")
        return None

    print(f"  {DIM}  {total} floodfills. Probing batches of 5, re-checking after each...{RESET}")
    probed = 0
    batch  = 5

    for i in range(0, min(total, 500), batch):
        for ff in ffs[i:i+batch]:
            http_get(f"/netdb?r={urllib.parse.quote(ff)}", timeout=6)
            probed += 1
        print(f"  {DIM}  [{probed}/{min(total,500)}] probed...{RESET}", end="\r")

        html = http_get(f"/netdb?r={urllib.parse.quote(target)}", timeout=5)
        if html and "Published:" in html:
            print(f"\n  {GREEN}[✓]{RESET}  Found after {probed} floodfill probes.")
            return parse_router_html(html, target)

        if probed % 20 == 0:
            prefix = target[:2] if len(target) >= 2 else target
            bh = http_get(f"/netdb?r={urllib.parse.quote(prefix)}", timeout=5)
            if bh:
                for h in re.findall(r"routerInfo-([A-Za-z0-9~=\-]{40,})", bh):
                    if h.startswith(target) or target.startswith(h[:len(target)]):
                        dh = http_get(f"/netdb?r={urllib.parse.quote(h)}", timeout=5)
                        if dh and "Published:" in dh:
                            print(f"\n  {GREEN}[✓]{RESET}  Found via bucket sweep after {probed}.")
                            return parse_router_html(dh, h)
        time.sleep(0.1)

    print(f"\n  {YELLOW}[!]{RESET}  Exhausted {probed} floodfill probes — not found.")
    return None

# =============================================================================
#  eepPriv.dat → b32 (CONFIRMED FORMULA, I2P 2.12.0)
# =============================================================================
def derive_b32(filepath: str) -> tuple:
    try:
        data = Path(filepath).read_bytes()
        if len(data) < 390: return "", 0, f"File too small ({len(data)} bytes)"
        cert_t = data[384]
        if cert_t == 0:   ds = 387
        elif cert_t == 5: ds = 387 + struct.unpack(">H", data[385:387])[0]
        else: return "", 0, f"Unknown cert type {cert_t}"
        if ds > len(data): return "", 0, f"dest_size {ds} > file {len(data)}"
        b32 = base64.b32encode(hashlib.sha256(data[:ds]).digest()
                                ).decode().lower().rstrip("=") + ".b32.i2p"
        return b32, ds, ""
    except Exception as e:
        return "", 0, str(e)

def find_eepsite_configs() -> list:
    if not CONFIG_DIR: return []
    results = []
    cd = Path(CONFIG_DIR) / "i2ptunnel.config.d"
    if not cd.exists(): return []
    for cf in sorted(cd.glob("*.config")):
        try: content = cf.read_text(errors="ignore")
        except Exception: continue
        if "type=httpserver" not in content: continue
        ep = {"name":"","privkey_abs":"","spoofed_host":"",
              "inbound_length":"3","target_port":"","b32":"",
              "dest_size":0,"b32_error":"","config_file":str(cf)}
        for line in content.splitlines():
            l = line.strip()
            if l.startswith("name="): ep["name"] = l[5:]
            elif l.startswith("spoofedHost="): ep["spoofed_host"] = l[12:]
            elif l.startswith("privKeyFile="):
                pkf = l[12:]
                if not os.path.isabs(pkf): pkf = str(Path(CONFIG_DIR)/pkf)
                ep["privkey_abs"] = pkf
            elif l.startswith("option.inbound.length="):
                ep["inbound_length"] = l.split("=")[-1]
            elif l.startswith("targetPort="):
                ep["target_port"] = l.split("=")[-1]
        if ep["privkey_abs"] and os.path.exists(ep["privkey_abs"]):
            b32, ds, e = derive_b32(ep["privkey_abs"])
            ep["b32"] = b32; ep["dest_size"] = ds; ep["b32_error"] = e
        results.append(ep)
    return results

# =============================================================================
#  GET OWN ROUTER HASH
# =============================================================================
def get_own_hash() -> str:
    html = http_get("/netdb?r=.")
    if not html: return ""
    c = clean_html(html)
    m = re.search(r"Router Identity:\s*([A-Za-z0-9~=\-]{40,})", c)
    return m.group(1).strip() if m else ""

# =============================================================================
#  COLLECT ALL KNOWN EEPSITE ADDRESSES — comprehensive sources
# =============================================================================
def derive_b32_from_dest_bytes(dest_bytes: bytes) -> str:
    """Derive b32 from raw destination bytes using same formula as derive_b32()."""
    try:
        if len(dest_bytes) < 390: return ""
        cert_t = dest_bytes[384]
        if cert_t == 0:   ds = 387
        elif cert_t == 5: ds = 387 + struct.unpack(">H", dest_bytes[385:387])[0]
        else: return ""
        if ds > len(dest_bytes): return ""
        return (base64.b32encode(hashlib.sha256(dest_bytes[:ds]).digest())
                .decode().lower().rstrip("=") + ".b32.i2p")
    except Exception:
        return ""

def decode_i2p_b64(s: str) -> bytes:
    """Decode I2P modified base64 (uses - and ~ instead of + and /)."""
    try:
        s = s.replace("-", "+").replace("~", "/")
        padding = (4 - len(s) % 4) % 4
        return base64.b64decode(s + "=" * padding)
    except Exception:
        return b""

def collect_all_eepsite_addresses() -> set:
    """
    Collect every known eepsite address from ALL available sources.
    CRITICAL FIX: derives b32 from hosts.txt base64 destinations directly,
    so XOR analysis gets real b32 addresses instead of .i2p names.

    Sources:
      1+2: hosts.txt + all addressbook/*.txt  → parse base64 → derive b32
      3:   Console /dns page
      4:   /netdb?f=3  → lists ALL active LeaseSets (the key missing source)
      5:   /netdb summary pages
    """
    addr_b32  = set()   # confirmed b32 addresses
    addr_name = set()   # .i2p names where b32 is not yet known

    # ── Sources 1+2: addressbook files ────────────────────────────────────
    ab_files = []
    if CONFIG_DIR:
        ab_files.append(Path(CONFIG_DIR) / "hosts.txt")
        ab_dir = Path(CONFIG_DIR) / "addressbook"
        if ab_dir.exists():
            ab_files.extend(ab_dir.glob("*.txt"))

    for ab_file in ab_files:
        if not Path(ab_file).exists(): continue
        try:
            for line in Path(ab_file).read_text(errors="ignore").splitlines():
                line = line.strip()
                if not line or line.startswith("#"): continue
                if "=" in line:
                    # hosts.txt format: name.i2p=base64EncodedDestination
                    parts = line.split("=", 1)
                    name  = parts[0].strip()
                    b64   = parts[1].strip() if len(parts) > 1 else ""
                    # Compute b32 from the base64 destination
                    if b64:
                        dest_bytes = decode_i2p_b64(b64)
                        if dest_bytes:
                            b32 = derive_b32_from_dest_bytes(dest_bytes)
                            if b32:
                                addr_b32.add(b32)
                                continue
                    if name.endswith(".i2p"):
                        addr_name.add(name)
                elif re.match(r"^[a-z2-7]{52}\.b32\.i2p$", line):
                    addr_b32.add(line)
                elif line.endswith(".i2p"):
                    addr_name.add(line)
        except Exception:
            pass

    info(f"After addressbook: {len(addr_b32)} b32 addresses derived, "
         f"{len(addr_name)} .i2p names")

    # ── Source 3: Console /dns ────────────────────────────────────────────
    dns_html = http_get("/dns", timeout=8)
    if dns_html:
        c = clean_html(dns_html)
        for b32 in re.findall(r"[a-z2-7]{52}\.b32\.i2p", c):
            addr_b32.add(b32)

    # ── Source 4: /netdb?f=3 — ALL active LeaseSets ───────────────────────
    # This is the critical missing source. f=3 lists every LeaseSet
    # the local router currently knows about with b32 addresses.
    info("Fetching /netdb?f=3 (all active LeaseSets)...")
    ls_page = http_get("/netdb?f=3", timeout=20)
    if ls_page:
        c = clean_html(ls_page)
        found_b32 = re.findall(r"[a-z2-7]{52}\.b32\.i2p", c)
        for b32 in found_b32:
            addr_b32.add(b32)
        info(f"/netdb?f=3 yielded {len(found_b32)} b32 addresses")

        # Also find LeaseSet hashes and query each for b32
        ls_hashes = re.findall(r"LeaseSet:\s*([A-Za-z0-9~=\-]{40,})", c)
        if ls_hashes:
            info(f"Querying {min(len(ls_hashes),150)} LeaseSet detail pages...")
            for ls_hash in ls_hashes[:150]:
                lh = http_get(f"/netdb?ls={urllib.parse.quote(ls_hash)}",
                              timeout=5)
                if lh:
                    bm = re.search(r"([a-z2-7]{52}\.b32\.i2p)", clean_html(lh))
                    if bm: addr_b32.add(bm.group(1))
                time.sleep(0.04)
    else:
        warn("/netdb?f=3 returned empty.")

    # ── Source 5: netdb summary pages ─────────────────────────────────────
    for page in ["/netdb", "/netdb?f=2"]:
        html = http_get(page, timeout=10)
        if html:
            for b32 in re.findall(r"[a-z2-7]{52}\.b32\.i2p",
                                   clean_html(html)):
                addr_b32.add(b32)

    # Return combined set
    result = set(addr_b32)
    result.update(addr_name)
    return result

# =============================================================================
#  METHOD C: XOR ROUTING KEY ANALYSIS (floodfill nodes only)
#
#  Protocol: I2P RoutingKeyGenerator.java
#    modData    = SHA256(today_as_"yyyyMMdd"_UTF8_bytes)
#    routing_key = SHA256(dest_hash_bytes XOR modData)
#
#  A floodfill node stores LeaseSets whose routing_key is nearest
#  to the floodfill's own router hash in XOR metric space.
#
#  So: for each known LeaseSet destination, compute its routing_key.
#  If the target floodfill's hash is the CLOSEST known floodfill to
#  that routing_key, then the target stores/is responsible for that LS.
# =============================================================================
def xor_distance(a: bytes, b: bytes) -> int:
    """XOR distance between two 32-byte hashes as integer."""
    dist = 0
    for x, y in zip(a, b):
        dist = (dist << 8) | (x ^ y)
    return dist

def compute_daily_mod_key() -> bytes:
    """
    Compute today's daily modifying key.
    Formula: SHA256("yyyyMMdd".encode("UTF-8")) using UTC date.
    """
    today_str = datetime.now(timezone.utc).strftime("%Y%m%d")
    return hashlib.sha256(today_str.encode("utf-8")).digest()

def compute_routing_key(dest_b32: str, mod_key: bytes) -> bytes:
    """
    Compute the routing key for a destination.
    routing_key = SHA256(dest_hash XOR mod_key)
    dest_hash   = SHA256 of the destination bytes.
    For b32 addresses: b32 = base32(SHA256(dest)) so we can reverse.
    """
    try:
        # b32 address = base32(SHA256(destination_bytes))
        # So SHA256(destination_bytes) = base32decode(b32_prefix)
        b32_part = dest_b32.replace(".b32.i2p", "").upper()
        # Pad to valid base32 length
        padding  = (8 - len(b32_part) % 8) % 8
        dest_hash_bytes = base64.b32decode(b32_part + "=" * padding)
        if len(dest_hash_bytes) != 32:
            return None
        # XOR with daily mod key
        xorred = bytes(a ^ b for a, b in zip(dest_hash_bytes, mod_key))
        # SHA256 of XOR result = routing key
        return hashlib.sha256(xorred).digest()
    except Exception:
        return None

def decode_router_hash(router_hash_b64: str) -> bytes:
    """Decode a base64url-ish router hash to bytes."""
    try:
        h = router_hash_b64.replace("-", "+").replace("~", "/")
        padding = (4 - len(h) % 4) % 4
        return base64.b64decode(h + "=" * padding)
    except Exception:
        return None

def method_c_xor_routing_key(target_hash: str, target_bytes: bytes,
                              all_floodfills_bytes: dict,
                              eepsite_addresses: set) -> list:
    """
    For each known eepsite, compute its routing key and check if
    the target floodfill is the closest known floodfill to it.

    Returns list of b32 addresses for which target is the responsible floodfill.
    """
    if not target_bytes:
        return []

    mod_key  = compute_daily_mod_key()
    results  = []
    checked  = 0
    total    = len(eepsite_addresses)

    print(f"  {DIM}  Computing XOR routing keys for {total} eepsites...{RESET}")
    print(f"  {DIM}  Daily mod key: {mod_key.hex()[:16]}...{RESET}")

    for addr in list(eepsite_addresses)[:500]:
        checked += 1
        if checked % 50 == 0:
            print(f"  {DIM}  [{checked}/{min(total,500)}] XOR calculations...{RESET}",
                  end="\r")

        # Only b32 addresses can be used for routing key calc
        if not addr.endswith(".b32.i2p"):
            continue

        rk = compute_routing_key(addr, mod_key)
        if not rk:
            continue

        # Distance from target to this routing key
        target_dist = xor_distance(target_bytes, rk)

        # Check if any other known floodfill is closer
        is_closest  = True
        for ff_hash_b64, ff_bytes in all_floodfills_bytes.items():
            if ff_hash_b64 == target_hash:
                continue
            if ff_bytes and xor_distance(ff_bytes, rk) < target_dist:
                is_closest = False
                break

        if is_closest:
            results.append(addr)

    print(f"\r  {GREEN if results else YELLOW}"
          f"[{'✓' if results else '!'}]{RESET}  "
          f"XOR analysis: {len(results)} eepsites closest to this floodfill.     ")
    return results

# =============================================================================
#  METHOD B+D: COMPREHENSIVE GATEWAY SCAN
#  Check ALL collected eepsite addresses for this router as tunnel gateway
# =============================================================================
def method_bd_gateway_scan(target_hash: str, eepsite_addresses: set) -> list:
    """
    Scan all known eepsite LeaseSets for this router appearing
    as a tunnel gateway (inbound tunnel entry point).
    """
    prefix4  = target_hash[:4]
    matches  = []
    checked  = set()
    total    = len(eepsite_addresses)
    count    = 0

    print(f"  {DIM}  Scanning {total} eepsites for gateway [{prefix4}]...{RESET}")

    for q in list(eepsite_addresses)[:600]:
        if q in checked: continue
        checked.add(q); count += 1
        if count % 20 == 0:
            print(f"  {DIM}  [{count}/{min(total,600)}] checked...{RESET}", end="\r")

        html = http_get(f"/netdb?ls={urllib.parse.quote(q)}", timeout=5)
        if not html or "Lease" not in html:
            continue

        c = clean_html(html)
        for m in re.finditer(
                r"Lease\s+(\d+):\s*(?:[^A-Za-z0-9~=+/\-]*)"
                r"([A-Za-z0-9~=+/\-]{4,8})\s+Tunnel\s+(\d+)"
                r"(?:\s+Expires\s+in\s+([\d]+\s+\w+))?", c):
            gw = m.group(2)
            if target_hash.startswith(gw) or gw.startswith(prefix4):
                bm = re.search(r"([a-z2-7]{52}\.b32\.i2p)", c)
                b32 = bm.group(1) if bm else q
                if not any(x["b32"] == b32 for x in matches):
                    matches.append({
                        "b32":       b32,
                        "lease_num": m.group(1),
                        "gw_prefix": gw,
                        "tunnel_id": m.group(3),
                        "expires":   m.group(4) if m.group(4) else "unknown",
                    })
        time.sleep(0.05)

    print(f"\r  {GREEN if matches else YELLOW}"
          f"[{'✓' if matches else '!'}]{RESET}  "
          f"Scanned {count} eepsites — {len(matches)} gateway match(es).     ")
    return matches

# =============================================================================
#  MAIN LOOKUP
# =============================================================================
def do_lookup(query: str, local_netdb: dict, eepsite_configs: list):
    query = query.strip()
    print(f"\n  {BOLD}{CYAN}{'═'*68}{RESET}")
    print(f"  {BOLD}NODE LOOKUP{RESET}  →  {CYAN}{BOLD}{query}{RESET}")
    print(f"  {BOLD}{CYAN}{'═'*68}{RESET}\n")

    found = None

    # ── Step 1: Local .dat ────────────────────────────────────────────────────
    stp("1", "Searching local NetDB .dat files...")
    for h, r in local_netdb.items():
        if h.startswith(query) or h == query:
            ok(f"Found: {h[:44]}...")
            found = dict(r); found["source"] = "local .dat"; break
    if not found: info("Not in local .dat files.")

    # ── Step 2: Console ───────────────────────────────────────────────────────
    stp("2", "Querying I2P console NetDB API...")
    html = http_get(f"/netdb?r={urllib.parse.quote(query)}")
    if html and "Published:" in html:
        ok("Found in console cache.")
        cr = parse_router_html(html, query)
        if found:
            for k in ("published","signing_key","enc_key","caps","version",
                      "transports","has_ip","has_intro","known_routers",
                      "netid","known_leasests"):
                if not found.get(k) and cr.get(k): found[k] = cr[k]
            found["source"] = "local .dat + console"
        else:
            found = cr
    else:
        info("Not in console local cache.")

    # ── Step 3: Global probe ──────────────────────────────────────────────────
    if not found:
        stp("3", "Global probe — querying ALL known floodfill routers...")
        found = search_globally(query, local_netdb)

    # ── Shade 8: not found anywhere ───────────────────────────────────────────
    if not found:
        ff_count = sum(1 for r in local_netdb.values()
                       if "f" in r.get("caps","").lower())
        print(f"\n  {BRED}{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
        print(f"  {BRED}{BOLD}║  ★  SHADE 8 — EXCLUSIVE NETWORK NODE CONFIRMED               ║{RESET}")
        print(f"  {BRED}{BOLD}║     ABSENT from ALL sources in the I2P ecosystem.            ║{RESET}")
        print(f"  {BRED}{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}")
        print(f"\n  {RED}  Exhaustively searched:{RESET}")
        print(f"  {RED}  • Local NetDB .dat   ({NETDB_PATH}){RESET}")
        print(f"  {RED}  • Console cache       (127.0.0.1:7657){RESET}")
        print(f"  {RED}  • {ff_count} floodfill routers (global probe){RESET}")
        print(f"\n  {YELLOW}  Structural absence = empirical proof of Exclusive Network.{RESET}")
        print(f"  {YELLOW}  — Fifty Shades of the Darknet | MIRAGe-UC{RESET}\n")
        return

    print_router_block(found)

    # ── Step 4: Eepsite association ───────────────────────────────────────────
    stp("4", "Finding eepsites associated with this router...")
    print()

    target_hash = found.get("hash", query)
    is_floodfill = "f" in found.get("caps","").lower()
    this_own = (OWN_HASH and
                (OWN_HASH.startswith(query) or query.startswith(OWN_HASH[:8])
                 or query == OWN_HASH
                 or found.get("hash","").startswith(OWN_HASH[:8])
                 or OWN_HASH.startswith(found.get("hash","")[:8])))

    # ── Step 4a: Collect ALL known eepsite addresses ──────────────────────────
    stp("4a", "Collecting all known eepsite addresses from all sources...")
    print(f"  {DIM}  Sources: hosts.txt, addressbook/, console /dns, console /netdb{RESET}")
    eepsite_addrs = collect_all_eepsite_addresses()
    ok(f"Collected {len(eepsite_addrs)} unique eepsite addresses")

    # ── METHOD A: eepPriv.dat (own VM only) ───────────────────────────────────
    method_a = []
    if this_own and eepsite_configs:
        print()
        print(f"  {BOLD}{GREEN}━━ Method A — Definitive (eepPriv.dat on THIS machine) ━━{RESET}")
        print(f"  {DIM}  SHA256(destination_bytes) → base32 → b32{RESET}")
        print(f"  {DIM}  Confirmed formula. Mathematical proof. Only valid on this VM.{RESET}\n")

        for ep in eepsite_configs:
            if ep.get("b32"):
                ok(f"Eepsite name    : {BOLD}{ep['name']}{RESET}")
                ok(f"B32 address     : {GREEN}{BOLD}{ep['b32']}{RESET}")
                if ep.get("spoofed_host"):
                    ok(f".i2p hostname   : {ep['spoofed_host']}")
                ok(f"Inbound hops    : {ep['inbound_length']}")
                ok(f"Target port     : {ep.get('target_port','N/A')}")
                ok(f"Key file        : {ep['privkey_abs']}")
                print()
                method_a.append(ep)

                info("Verifying LeaseSet is live on network...")
                ls_html = http_get(f"/netdb?ls={urllib.parse.quote(ep['b32'])}")
                if ls_html and "Published" in ls_html and "Lease" in ls_html:
                    ok("LeaseSet IS live — eepsite is currently reachable")
                    c = clean_html(ls_html)
                    for lm in re.finditer(
                            r"Lease\s+(\d+):\s*(?:[^A-Za-z0-9~=+/\-]*)"
                            r"([A-Za-z0-9~=+/\-]{4,8})\s+Tunnel\s+(\d+)"
                            r"(?:\s+Expires\s+in\s+([\d]+\s+\w+))?", c):
                        print(f"    Lease {lm.group(1)}: "
                              f"gateway [{YELLOW}{lm.group(2)}{RESET}]  "
                              f"Tunnel {lm.group(3)}  "
                              f"Expires {lm.group(4) or 'unknown'}")
                    if ep.get("inbound_length") == "0":
                        print(f"\n    {GREEN}0-hop: gateway = endpoint = this router.{RESET}")
                    else:
                        print(f"\n    {DIM}Gateways = inbound tunnel ENTRY POINTS.{RESET}")
                        print(f"    {DIM}This router is the ENDPOINT (last hop).{RESET}")
                else:
                    warn("LeaseSet not live — eepsite tunnel may be stopped.")
                    info("Start: I2P Console → Hidden Services Manager → Start")
                print()
            elif ep.get("b32_error"):
                warn(f"b32 error for '{ep['name']}': {ep['b32_error']}")

    elif this_own:
        info("Method A: no httpserver tunnels on this machine.")
    else:
        info("Method A: only applicable to this VM's own router.")
        info(f"This VM: {OWN_HASH[:24]}..." if OWN_HASH else
             "This VM's hash: (not determined)")
        print()

    # ── METHOD C: XOR Routing Key (floodfills only) ───────────────────────────
    method_c = []
    if is_floodfill:
        print(f"  {BOLD}{CYAN}━━ Method C — XOR Routing Key (Floodfill Storage) ━━{RESET}")
        print(f"  {DIM}  Protocol: I2P RoutingKeyGenerator.java{RESET}")
        print(f"  {DIM}  mod_key = SHA256(today_UTC_as_yyyyMMdd){RESET}")
        print(f"  {DIM}  routing_key = SHA256(dest_hash XOR mod_key){RESET}")
        print(f"  {DIM}  This floodfill STORES LeaseSets closest to it in XOR space.{RESET}")
        print(f"  {DIM}  Only b32 addresses can be analysed (need SHA256 of destination).{RESET}\n")

        # Build bytes map for all known floodfills
        all_ff_bytes = {}
        for h, r in local_netdb.items():
            if "f" in r.get("caps","").lower():
                hb = decode_router_hash(h)
                if hb: all_ff_bytes[h] = hb

        target_bytes = decode_router_hash(target_hash)
        if not target_bytes and len(target_hash) >= 40:
            warn("Could not decode target hash bytes for XOR analysis.")
        elif not all_ff_bytes:
            warn("No local floodfills to compare against.")
        else:
            ok(f"Comparing against {len(all_ff_bytes)} known floodfills")
            info(f"Daily mod key date (UTC): "
                 f"{datetime.now(timezone.utc).strftime('%Y-%m-%d')}")
            print()

            b32_only = {a for a in eepsite_addrs if a.endswith(".b32.i2p")}
            method_c = method_c_xor_routing_key(
                target_hash, target_bytes, all_ff_bytes, b32_only)

            if method_c:
                print(f"\n  {BOLD}This floodfill is the closest known floodfill to "
                      f"{len(method_c)} eepsite(s):{RESET}")
                print(f"  {DIM}  (Stores their LeaseSet per I2P routing key protocol){RESET}\n")
                for b32 in method_c[:20]:
                    print(f"  {CYAN}★{RESET}  {b32}")
                if len(method_c) > 20:
                    info(f"  ... and {len(method_c)-20} more")
            else:
                warn("No known eepsites map closest to this floodfill.")
                info("This is expected if few b32 addresses are in local cache.")
            print()
    else:
        info("Method C (XOR routing key) only applies to floodfill nodes.")
        info(f"This router caps={found.get('caps','?')} — not a floodfill.")
        print()

    # ── METHOD B+D: Comprehensive gateway scan ────────────────────────────────
    inbound_len = (method_a[0].get("inbound_length","3") if method_a else "?")
    print(f"  {BOLD}{CYAN}━━ Method B+D — Comprehensive Gateway Scan ━━{RESET}")
    print(f"  {DIM}  Checks ALL {len(eepsite_addrs)} known eepsites for router "
          f"[{target_hash[:8]}] as tunnel GATEWAY.{RESET}")
    if inbound_len == "0":
        print(f"  {GREEN}  0-hop configured: gateway = endpoint = this router (DEFINITIVE).{RESET}")
    else:
        print(f"  {DIM}  Standard tunnels: gateway = ENTRY POINT, not hosting router.{RESET}")
        print(f"  {DIM}  This shows routing PARTICIPATION, not eepsite hosting.{RESET}")
    print()

    gw_matches = method_bd_gateway_scan(target_hash, eepsite_addrs)

    if gw_matches:
        print(f"\n  {BOLD}Router [{target_hash[:8]}...] appears as tunnel GATEWAY for "
              f"{len(gw_matches)} eepsite(s):{RESET}\n")
        for m in gw_matches:
            print(f"  {GREEN}★{RESET}  B32:     {BOLD}{m['b32']}{RESET}")
            print(f"     Lease #{m['lease_num']}  Tunnel {m['tunnel_id']}  "
                  f"Expires {m['expires']}  GW prefix [{m['gw_prefix']}]")
            if inbound_len == "0":
                print(f"     {GREEN}★ 0-hop: this router IS the host.{RESET}")
            print()
    else:
        warn("No active LeaseSets found with this router as tunnel gateway.")
        print(f"  {DIM}  Possible: leases expired (10 min TTL), multi-hop tunnels,{RESET}")
        print(f"  {DIM}  or no active eepsites routing through this node right now.{RESET}\n")

    # ── SUMMARY ───────────────────────────────────────────────────────────────
    hdr()
    print(f"  {BOLD}LOOKUP COMPLETE{RESET}  →  {CYAN}{query}{RESET}")

    has_results = False
    if this_own and method_a:
        print(f"\n  {GREEN}{BOLD}[A] Definitively hosted eepsites (eepPriv.dat):{RESET}")
        for ep in method_a:
            print(f"    {GREEN}→{RESET}  {ep['b32']}"
                  + (f"  ({ep['name']})" if ep.get("name") else ""))
        has_results = True

    if is_floodfill and method_c:
        print(f"\n  {CYAN}{BOLD}[C] Floodfill stores LeaseSet for (XOR routing key):{RESET}")
        for b32 in method_c[:10]:
            print(f"    {CYAN}→{RESET}  {b32}")
        if len(method_c) > 10:
            print(f"    {DIM}... and {len(method_c)-10} more{RESET}")
        has_results = True

    if gw_matches:
        print(f"\n  {CYAN}{BOLD}[B+D] Tunnel gateway participation observed:{RESET}")
        for m in gw_matches:
            print(f"    {CYAN}→{RESET}  {m['b32']}")
        has_results = True

    if not has_results:
        warn("No eepsite associations found for this router.")
        info("Possible: no active eepsites in observable network right now.")

    print(f"\n  {DIM}Note on methods:{RESET}")
    print(f"  {DIM}  [A] = Definitive proof (own VM only){RESET}")
    print(f"  {DIM}  [C] = Floodfill stores this LeaseSet (protocol-based){RESET}")
    print(f"  {DIM}  [B+D] = Routing participation (not definitive hosting){RESET}")
    hdr()
    print()

    # ── Export results to text file ───────────────────────────────────────
    _export_results(query, found, method_a, method_c, gw_matches)

def _export_results(query: str, router: dict, method_a: list,
                    method_c: list, gw_matches: list):
    """Export lookup results to a timestamped text file."""
    ts       = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    safe_q   = re.sub(r"[^A-Za-z0-9_\-]", "_", query[:20])
    outdir   = Path("./scanner-output")
    outdir.mkdir(parents=True, exist_ok=True)
    outfile  = outdir / f"node-lookup_{safe_q}_{ts}.txt"

    lines = [
        "=" * 70,
        "FIFTY SHADES OF THE DARKNET — Router Node Lookup Report",
        "Author : Siddique Abubakr Muntaka, PhD Candidate",
        "         Information Technology | University of Cincinnati, OH USA",
        "Advisor: Dr. Jacques Bou Abdo | MIRAGe-UC",
        "=" * 70,
        f"Query       : {query}",
        f"Timestamp   : {datetime.now(timezone.utc).isoformat()}",
        "",
        "── ROUTER DETAILS ──────────────────────────────────────────────────",
        f"Hash        : {router.get('hash','N/A')}",
        f"Version     : {router.get('version','N/A')}",
        f"Capabilities: {router.get('caps','N/A')}",
        f"Direct IP   : {'Yes' if router.get('has_ip') else 'No'}",
        f"Introducers : {'Yes' if router.get('has_intro') else 'No'}",
        f"Published   : {router.get('published','N/A')}",
        f"Signing Key : {router.get('signing_key','N/A')}",
        f"Enc Key     : {router.get('enc_key','N/A')}",
        f"Known Rtrs  : {router.get('known_routers',0)}",
        f"Known LSets : {router.get('known_leasests',0)}",
        f"Network ID  : {router.get('netid','N/A')}",
        f"Data Source : {router.get('source','N/A')}",
        "",
    ]

    # Transport addresses
    tps = router.get("transports", [])
    if tps:
        lines.append("── TRANSPORT ADDRESSES ─────────────────────────────────────────────")
        for t in tps:
            addr = (f"{t.get('host','')}:{t.get('port','')}"
                    if t.get("host") else "(no direct IP)")
            lines.append(f"  [{t.get('type','?'):5}]  {addr}  "
                         f"caps={t.get('caps','')}  mtu={t.get('mtu','')}")
        lines.append("")

    # Method A
    if method_a:
        lines.append("── METHOD A: DEFINITIVELY HOSTED EEPSITES (eepPriv.dat) ────────────")
        for ep in method_a:
            lines.append(f"  B32     : {ep['b32']}")
            if ep.get("spoofed_host"):
                lines.append(f"  .i2p    : {ep['spoofed_host']}")
            lines.append(f"  Hops    : {ep.get('inbound_length','?')}")
            lines.append(f"  KeyFile : {ep.get('privkey_abs','?')}")
            lines.append("")

    # Method C
    if method_c:
        lines.append("── METHOD C: FLOODFILL STORES LEASESET (XOR ROUTING KEY) ───────────")
        lines.append("   (Protocol-based: nearest floodfill in XOR space stores this LS)")
        for b32 in method_c:
            lines.append(f"  {b32}")
        lines.append("")

    # Method B+D
    if gw_matches:
        lines.append("── METHOD B+D: TUNNEL GATEWAY PARTICIPATION ────────────────────────")
        lines.append("   (This router appears as inbound tunnel entry point)")
        for m in gw_matches:
            lines.append(f"  B32     : {m['b32']}")
            lines.append(f"  Lease #{m['lease_num']}  Tunnel {m['tunnel_id']}  "
                         f"Expires {m['expires']}")
            lines.append("")

    if not method_a and not method_c and not gw_matches:
        lines.append("── RESULT ──────────────────────────────────────────────────────────")
        lines.append("  No eepsite associations found for this router.")
        lines.append("")

    lines += [
        "── NOTES ───────────────────────────────────────────────────────────",
        "  [A]   = Definitive proof (own VM eepPriv.dat)",
        "  [C]   = Floodfill stores LeaseSet (I2P routing protocol)",
        "  [B+D] = Gateway = inbound tunnel entry point (not hosting proof)",
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
{CYAN}{BOLD}║  FIFTY SHADES OF THE DARKNET — Router Node Lookup  v3.0              ║{RESET}
{CYAN}{BOLD}║  Methods A (eepPriv) | B+D (Gateway) | C (XOR Routing Key)          ║{RESET}
{CYAN}{BOLD}║  Author : Siddique Abubakr Muntaka, PhD Candidate                    ║{RESET}
{CYAN}{BOLD}║           Information Technology | University of Cincinnati, OH USA   ║{RESET}
{CYAN}{BOLD}║  Advisor: Dr. Jacques Bou Abdo | MIRAGe-UC                           ║{RESET}
{CYAN}{BOLD}╚═══════════════════════════════════════════════════════════════════════╝{RESET}
""")

def main():
    global OWN_HASH
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

    print(f"  {DIM}  Detecting own router hash...{RESET}", end="", flush=True)
    OWN_HASH = get_own_hash()
    print(f"\r  {GREEN}[✓]{RESET}  Own router  : "
          f"{OWN_HASH[:24]}...    " if OWN_HASH else
          f"\r  {YELLOW}[!]{RESET}  Own router  : (not determined)    ")

    print(f"  {DIM}  Loading local NetDB...{RESET}", end="", flush=True)
    local_netdb = load_netdb()
    ff_count = sum(1 for r in local_netdb.values()
                   if "f" in r.get("caps","").lower())
    print(f"\r  {GREEN}[✓]{RESET}  "
          f"Local NetDB : {len(local_netdb)} routers  ({ff_count} floodfills)    ")

    if ff_count == 0:
        warn("0 floodfills — let I2P run longer to build a larger NetDB.")

    eepsite_configs = find_eepsite_configs()
    if eepsite_configs:
        ok("Eepsites    : " +
           ", ".join(ep["name"] for ep in eepsite_configs if ep.get("b32")))
    else:
        info("Eepsites    : none configured")
    print()

    while True:
        print(f"  {BOLD}{'─'*64}{RESET}")
        print(f"  {BOLD}Enter a router hash or hash prefix to look up.{RESET}")
        print(f"  {DIM}  Full hash  : ZfHbw9ckD-2r94ldUNV8LuuPuZlkDvjsp4G20Opp5U8={RESET}")
        print(f"  {DIM}  Prefix     : ZfHb  |  SnuN  |  KVOa  |  GIDP{RESET}")
        print(f"  {DIM}  Type [q]   : quit{RESET}")
        print(f"  {BOLD}{'─'*64}{RESET}\n")

        try:
            q = input(f"  {BOLD}Hash or prefix:{RESET} ").strip()
        except (KeyboardInterrupt, EOFError):
            print(f"\n  {DIM}Exiting.{RESET}\n"); break

        if q.lower() == "q":
            print(f"\n  {DIM}Goodbye.{RESET}\n"); break
        if not q:
            warn("Nothing entered."); continue

        do_lookup(q, local_netdb, eepsite_configs)

        try:
            again = input(f"  {BOLD}Look up another node? [y/N]:{RESET} ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            break
        if again != "y":
            print(f"\n  {DIM}Goodbye.{RESET}\n"); break

if __name__ == "__main__":
    main()
