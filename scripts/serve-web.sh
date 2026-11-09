#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
slideblaster2_root="$(cd -- "${script_directory}/.." && pwd)"
web_root="${slideblaster2_root}/hosts/web"
port="${1:-4173}"

if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
  echo "Port must be an integer from 1 through 65535." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required by the dependency-free development server." >&2
  exit 1
fi

# Find the first open port at or after the requested one, so a busy default
# does not abort the development server.
selected_port="$(python3 - "${port}" <<'PYTHON'
import socket
import sys

start = int(sys.argv[1])
for candidate in range(start, 65536):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", candidate))
        except OSError:
            continue
    print(candidate)
    break
else:
    sys.exit(1)
PYTHON
)" || {
  echo "No open port available at or after ${port}." >&2
  exit 1
}

if [[ "${selected_port}" != "${port}" ]]; then
  echo "Port ${port} is in use; using ${selected_port} instead." >&2
fi

echo "Serving SlideBlaster at http://127.0.0.1:${selected_port}/"
cd "${web_root}"
exec python3 -c '
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import sys

class NoStoreHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        super().do_GET()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), NoStoreHandler).serve_forever()
' "${selected_port}"
