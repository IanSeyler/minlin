"""A small web server reporting on the VM it runs in.

Serves an HTML page at / and the same data as JSON at /metrics.json, on
port 80. Request logs go to stderr, which is the serial console.
"""

import json
import os
import platform
import sys
import time
from html import escape
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 80
STARTED = time.time()


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def meminfo():
    """/proc/meminfo as {field: kB}, or {} if it can't be read."""
    info = {}
    for line in (read("/proc/meminfo") or "").splitlines():
        key, _, value = line.partition(":")
        fields = value.split()
        if fields and fields[0].isdigit():
            info[key] = int(fields[0])
    return info


def metrics():
    uname = os.uname()
    mem = meminfo()
    uptime = read("/proc/uptime")
    loadavg = read("/proc/loadavg")
    st = os.statvfs("/")
    return {
        "python": {
            "version": sys.version,
            "implementation": platform.python_implementation(),
            "executable": sys.executable,
            "pid": os.getpid(),
            "uptime_s": round(time.time() - STARTED, 1),
        },
        "system": {
            "kernel": f"{uname.sysname} {uname.release}",
            "kernel_build": uname.version,
            "machine": uname.machine,
            "hostname": uname.nodename,
            "cpus": os.cpu_count(),
            "uptime_s": float(uptime.split()[0]) if uptime else None,
            "loadavg": loadavg.split()[:3] if loadavg else None,
            "cmdline": read("/proc/cmdline"),
        },
        "memory_kb": {
            "total": mem.get("MemTotal"),
            "free": mem.get("MemFree"),
            "available": mem.get("MemAvailable"),
            "buffers": mem.get("Buffers"),
            "cached": mem.get("Cached"),
        },
        "disk_kb": {
            "total": st.f_blocks * st.f_frsize // 1024,
            "free": st.f_bavail * st.f_frsize // 1024,
        },
    }


def render_html(data):
    sections = []
    for title, values in data.items():
        rows = "".join(
            f"<tr><th>{escape(k)}</th><td>{escape(str(v))}</td></tr>"
            for k, v in values.items()
        )
        sections.append(f"<h2>{escape(title)}</h2><table>{rows}</table>")
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>minlin</title>
<style>
body {{ font-family: sans-serif; max-width: 50em; margin: 2em auto; padding: 0 1em; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ text-align: left; padding: .3em .6em; border-bottom: 1px solid #ddd; vertical-align: top; }}
th {{ width: 12em; }}
td {{ font-family: monospace; word-break: break-all; }}
</style></head>
<body><h1>Hello from minlin</h1>{"".join(sections)}
<p><a href="/metrics.json">metrics.json</a></p></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body, ctype = render_html(metrics()), "text/html; charset=utf-8"
        elif self.path == "/metrics.json":
            body, ctype = json.dumps(metrics(), indent=2), "application/json"
        else:
            self.send_error(404)
            return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind looks up our FQDN, which would try DNS;
        # the VM has no resolver configured, so skip it.
        self.socket.bind(self.server_address)
        self.server_name, self.server_port = "minlin", self.server_address[1]


if __name__ == "__main__":
    print(f"Serving on port {PORT}")
    Server(("", PORT), Handler).serve_forever()
