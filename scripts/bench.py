#!/usr/bin/env python3
"""Paddle resource benchmark: drives a running Paddle through its control bridge (paddle-mcp) over a fixed set of
sites in a window of its own, then records memory by kind and per tab, WebContent process count, idle CPU of Paddle
and its WebKit processes, page-load time and tab-switch time. Writes build/bench/<label>-<time>.json and prints a
summary. Needs controlBridge on, and controlBridgeScripts for pausing video.

    scripts/bench.py [--label NAME] [--sites all|general] [--relay PATH] [--settle SECONDS]

Compare two runs: scripts/bench.py --compare build/bench/a.json build/bench/b.json
Count visible ads on ad-heavy pages (content blocking checks): scripts/bench.py --adcheck --label NAME
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

SITES = [
    "https://en.wikipedia.org/wiki/WebKit",
    "https://www.reddit.com/r/popular/",
    "https://www.youtube.com/watch?v=8ut1aqeygM8",
    "https://github.com/apple/swift",
    "https://www.theverge.com/",
    "https://www.google.com/search?q=webkit+memory",
    "https://x.com/home",
]
# The same pages without the sites that site-specific extensions are for (YouTube, Reddit).
GENERAL_SITES = [url for url in SITES if "youtube.com" not in url and "reddit.com" not in url] + [
    "https://www.apple.com/macos/",
    "https://news.ycombinator.com/",
]
# Ad-heavy pages for --adcheck: each is loaded muted, scrolled, then its visible ad elements are counted.
AD_SITES = [
    "https://www.theverge.com/",
    "https://www.cnn.com/",
    "https://weather.com/",
    "https://www.allrecipes.com/recipe/10813/best-chocolate-chip-cookies/",
    "https://www.dailymail.co.uk/home/index.html",
    "https://www.forbes.com/",
    "https://www.espn.com/",
    "https://minecraft.fandom.com/wiki/Creeper",
    "https://www.speedtest.net/",
    "https://www.wunderground.com/",
]
# Elements that are ads on these sites, counted when at least 30 px tall and wide; the selector list is the
# commonest ad slot markup (Google Publisher Tag, AdSense, Taboola, Outbrain, Amazon, generic ad wrappers).
AD_SCRIPT = r"""
const selectors = ['iframe[id^="google_ads_iframe"]', 'iframe[src*="doubleclick.net"]', 'iframe[src*="googlesyndication"]',
  'ins.adsbygoogle', 'div[id^="div-gpt-ad"]', '[data-google-query-id]', '[id^="taboola-"]', '.trc_rbox_container',
  '.OUTBRAIN', '[data-widget-id][class*="outbrain"]', 'iframe[src*="amazon-adsystem"]', '[class*="ad-slot"]',
  '[class*="AdSlot"]', '[id*="ad-slot"]', '[class^="ad-"]', '[class*=" ad-"]', '[data-ad-unit]', '[data-ad]', '[aria-label="Advertisement"]'];
const seen = new Set(); let visible = 0;
for (const sel of selectors) for (const el of document.querySelectorAll(sel)) {
  if (seen.has(el)) continue; seen.add(el);
  const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
  if (r.width >= 30 && r.height >= 30 && cs.display !== 'none' && cs.visibility !== 'hidden' && cs.opacity !== '0') visible++;
}
return {visible, matched: seen.size, height: document.documentElement.scrollHeight};
"""
DEFAULT_RELAYS = [
    "build/DerivedData.noindex/Build/Products/Debug/Paddle.app/Contents/Helpers/paddle-mcp",
    "/Applications/Paddle.app/Contents/Helpers/paddle-mcp",
]


class Bridge:
    """A minimal MCP client over the paddle-mcp relay's stdio."""

    def __init__(self, relay):
        self.proc = subprocess.Popen([relay], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "paddle-bench", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                sys.exit("paddle-mcp closed the connection (is Paddle running with controlBridge on?)")
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply["result"]

    def tool(self, tool_name, **arguments):
        result = self.request("tools/call", {"name": tool_name, "arguments": arguments})
        text = "".join(part.get("text", "") for part in result.get("content", []))
        if result.get("isError"):
            raise RuntimeError(f"{tool_name}: {text}")
        return text

    def state(self):
        text = self.tool("paddle_state")
        return json.loads(text[text.index("{"):])

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def pause_media(bridge, tab):
    """Pauses every video and audio element, a second guard after the tab's mute."""
    try:
        bridge.tool("run_js", tab=tab, script="document.querySelectorAll('video, audio').forEach(m => m.pause()); return 1;")
    except RuntimeError as error:
        print(f"  could not pause media: {error}", flush=True)


def webkit_pids():
    out = subprocess.run(["pgrep", "-f", "com.apple.WebKit."], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def cpu_seconds(pids):
    """Total user+system CPU seconds of `pids` (ps TIME column)."""
    if not pids:
        return 0.0
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for field in out.split():
        parts = field.replace("-", ":").split(":")
        seconds = 0.0
        for part in parts:
            seconds = seconds * 60 + float(part)
        total += seconds
    return total


def paddle_pid():
    out = subprocess.run(["pgrep", "-x", "Paddle"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def run(args):
    relay = args.relay or next((r for r in DEFAULT_RELAYS if os.path.exists(r)), None)
    if not relay:
        sys.exit("no paddle-mcp relay found; pass --relay")
    bridge = Bridge(relay)
    before = {w["id"] for w in bridge.state()["windows"]}
    bridge.tool("menu_action", name="newWindow")
    window = next(w for w in bridge.state()["windows"] if w["id"] not in before)
    print(f"bench window {window['id']}; {len(args.site_list)} sites, settle {args.settle}s", flush=True)
    tabs = []
    # Stopped part way (Ctrl-C, or a kill), the window's tabs still close, so none is left loading or playing.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("stopped"))
    try:
        result = measure(bridge, window, tabs, args)
    finally:
        for tab in tabs:
            try:
                bridge.tool("close_tab", tab=tab)
            except Exception:
                pass
        bridge.close()

    os.makedirs("build/bench", exist_ok=True)
    path = f"build/bench/{args.label}-{time.strftime('%Y%m%d-%H%M%S')}.json"
    with open(path, "w") as f:
        json.dump(result, f, indent=2)
    summarize(result)
    print(f"wrote {path}")


def measure(bridge, window, tabs, args):
    loads = []
    for index, url in enumerate(args.site_list):
        # Silent: a blank tab is muted (Tabs > Mute Tab acts on the window's selected tab, the new one) before the
        # site loads into it; the mute belongs to the tab and survives the navigation.
        reply = bridge.tool("open_url", url="about:blank", window=window["id"], newTab=index > 0)
        tab = re.search(r"tab ([0-9A-F-]{36})", reply).group(1)
        tabs.append(tab)
        bridge.tool("wait_for_load", tab=tab, timeoutSeconds=10)
        bridge.tool("menu_action", name="toggleMute")
        start = time.monotonic()
        bridge.tool("open_url", url=url, window=window["id"], newTab=False)
        bridge.tool("wait_for_load", tab=tab, timeoutSeconds=45)
        seconds = time.monotonic() - start
        loads.append({"url": url, "seconds": round(seconds, 2)})
        print(f"  loaded {url} in {seconds:.1f}s", flush=True)
        pause_media(bridge, tab)

    # Tab switches: each tab once, in order, then read the switch log lines this produced.
    switch_start = time.time()
    for tab in tabs:
        bridge.tool("select_tab", tab=tab)
        time.sleep(1.5)
        pause_media(bridge, tab)
    logs = bridge.tool("logs", sinceSeconds=int(time.time() - switch_start) + 2, maxEntries=200)
    switches = [int(m) for m in re.findall(r"\[switch\].*?activated→shown (\d+) ms", logs)]

    print(f"  settling {args.settle}s", flush=True)
    time.sleep(args.settle)
    pids = webkit_pids() + ([paddle_pid()] if paddle_pid() else [])
    cpu_start, wall_start = cpu_seconds(pids), time.monotonic()
    time.sleep(args.cpu_window)
    idle_cpu = (cpu_seconds(pids) - cpu_start) / (time.monotonic() - wall_start) * 100

    state = bridge.state()
    bench = next(w for w in state["windows"] if w["id"] == window["id"])
    per_tab = [{"url": t["url"], "memoryMB": t.get("memoryMB"), "asleep": t["asleep"], "sharesProcess": t.get("sharesProcess", False)}
               for t in bench["tabs"]]
    web_content = len(subprocess.run(["pgrep", "-f", "com.apple.WebKit.WebContent"], capture_output=True, text=True).stdout.split())
    result = {
        "label": args.label, "time": time.strftime("%Y-%m-%d %H:%M:%S"), "app": state["app"],
        "memoryMB": state["memoryMB"], "webContentProcesses": web_content,
        "benchTabsMB": sum(t["memoryMB"] or 0 for t in per_tab),
        "idleCPUPercent": round(idle_cpu, 1), "loads": loads, "tabs": per_tab,
        "switchShownMs": switches,
    }
    return result


def adcheck(args):
    """Loads AD_SITES one at a time in a muted tab of a window of its own, scrolls each through, and counts the
    visible ad elements (AD_SCRIPT). Writes build/bench/<label>-ads-<time>.json."""
    relay = args.relay or next((r for r in DEFAULT_RELAYS if os.path.exists(r)), None)
    bridge = Bridge(relay)
    before = {w["id"] for w in bridge.state()["windows"]}
    bridge.tool("menu_action", name="newWindow")
    window = next(w for w in bridge.state()["windows"] if w["id"] not in before)
    reply = bridge.tool("open_url", url="about:blank", window=window["id"], newTab=False)
    tab = re.search(r"tab ([0-9A-F-]{36})", reply).group(1)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("stopped"))
    rows = []
    try:
        bridge.tool("wait_for_load", tab=tab, timeoutSeconds=10)
        bridge.tool("menu_action", name="toggleMute")
        for url in AD_SITES:
            bridge.tool("open_url", url=url, window=window["id"], newTab=False)
            try:
                bridge.tool("wait_for_load", tab=tab, timeoutSeconds=30)
            except RuntimeError:
                pass
            pause_media(bridge, tab)
            for fraction in (0.33, 0.66, 1.0, 0.0):
                try:
                    bridge.tool("run_js", tab=tab, script=f"window.scrollTo(0, document.documentElement.scrollHeight * {fraction}); return 1;")
                except RuntimeError:
                    pass
                time.sleep(2)
            pause_media(bridge, tab)
            try:
                text = bridge.tool("run_js", tab=tab, script=AD_SCRIPT)
                counts = json.loads(text[text.index("{"):text.rindex("}") + 1])
            except (RuntimeError, ValueError) as error:
                counts = {"error": str(error)[:120]}
            rows.append({"url": url, **counts})
            print(f"  {counts.get('visible', '?'):>4} visible ads  {url}", flush=True)
    finally:
        try:
            bridge.tool("close_tab", tab=tab)
        except Exception:
            pass
        bridge.close()
    total = sum(r.get("visible", 0) for r in rows)
    print(f"{args.label}: {total} visible ad elements on {len(rows)} pages")
    os.makedirs("build/bench", exist_ok=True)
    path = f"build/bench/{args.label}-ads-{time.strftime('%Y%m%d-%H%M%S')}.json"
    with open(path, "w") as f:
        json.dump({"label": args.label, "total": total, "rows": rows}, f, indent=2)
    print(f"wrote {path}")


def summarize(r):
    m = r["memoryMB"]
    switches = sorted(r["switchShownMs"])
    median = switches[len(switches) // 2] if switches else None
    print(f"\n{r['label']} ({r['app']}, {r['time']})")
    print(f"  total {m['total']} MB = tabs {m['tabs']} + extensions {m['extensions']} + GPU/net {m['gpuAndNetworking']}"
          f" + app {m['app']} + other {m['other']} + workers {m['serviceWorkers']} + helpers {m['helpers']}")
    print(f"  bench tabs {r.get('benchTabsMB')} MB (all of Paddle above, other windows included)")
    print(f"  WebContent processes {r['webContentProcesses']}, idle CPU {r['idleCPUPercent']}%,"
          f" median switch {median} ms, total load {sum(l['seconds'] for l in r['loads']):.1f}s")
    for t in r["tabs"]:
        note = " asleep" if t["asleep"] else (" shared" if t.get("sharesProcess") else "")
        print(f"    {str(t['memoryMB']):>5} MB  {t['url'][:66]}{note}")


def compare(a_path, b_path):
    a, b = (json.load(open(p)) for p in (a_path, b_path))
    print(f"{'':28}{a['label']:>12}{b['label']:>12}{'change':>10}")
    for key in ["total", "tabs", "extensions", "gpuAndNetworking", "app", "other", "serviceWorkers", "helpers"]:
        x, y = a["memoryMB"][key], b["memoryMB"][key]
        print(f"{'memory ' + key + ' MB':28}{x:>12}{y:>12}{y - x:>+10}")
    print(f"{'bench tabs MB':28}{a.get('benchTabsMB', 0):>12}{b.get('benchTabsMB', 0):>12}{b.get('benchTabsMB', 0) - a.get('benchTabsMB', 0):>+10}")
    for key, name in [("webContentProcesses", "WebContent processes"), ("idleCPUPercent", "idle CPU %")]:
        print(f"{name:28}{a[key]:>12}{b[key]:>12}{b[key] - a[key]:>+10.1f}")
    la, lb = sum(l["seconds"] for l in a["loads"]), sum(l["seconds"] for l in b["loads"])
    print(f"{'total load s':28}{la:>12.1f}{lb:>12.1f}{lb - la:>+10.1f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="run")
    parser.add_argument("--relay")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--cpu-window", type=float, default=20)
    parser.add_argument("--sites", choices=["all", "general"], default="all")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"))
    parser.add_argument("--adcheck", action="store_true", help="count visible ads on AD_SITES instead")
    args = parser.parse_args()
    args.site_list = GENERAL_SITES if args.sites == "general" else SITES
    if args.compare:
        compare(*args.compare)
    elif args.adcheck:
        adcheck(args)
    else:
        run(args)
