#!/usr/bin/bash
# Runs inside the image (tests/image/checks.sh feeds it on stdin), after
# systemd-sysusers has created the accounts. Runs Claude Code as dev against a
# fake Messages API on loopback (the container has no other network), and
# checks that the request carries the image's managed CLAUDE.md and the name
# of every managed skill. The fake API refuses the request, so nothing else
# happens. The seeded plugins load only once Claude Code reaches the real API,
# so the VM test checks those.
set -euo pipefail

managed=/usr/lib/android-dev-vm/claude-code
work="$(mktemp -d)"
log="$work/requests"
port=8765

# Writes each request body to $log and answers 400.
python3 -I -c '
import http.server, sys
log, port = sys.argv[1], int(sys.argv[2])
class Fake(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log, "ab") as f:
            f.write(body + b"\n")
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"fake\"}}")
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Fake).serve_forever()
' "$log" "$port" &
server=$!
trap 'kill "$server"' EXIT
for _ in {1..50}; do
  bash -c ">/dev/tcp/127.0.0.1/$port" 2>/dev/null && break
  sleep 0.1
done

# dev has no home in this container, and the project is an empty directory.
mkdir "$work/home" "$work/project"
chown dev:dev "$work/home" "$work/project"
cd "$work/project"
out="$(setpriv --reuid=dev --regid=dev --init-groups env -i HOME="$work/home" PATH=/usr/bin \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-ant-fake \
  timeout 120 claude -p hello </dev/null 2>&1)" || true
[[ -s $log ]] || { echo "      no request reached the fake API:"; printf '%s\n' "$out" | sed 's/^/      /'; exit 1; }

# The home and the project are empty, so only the managed paths can bring our
# text. Skill bodies load only when used, so a skill shows by its description.
bad=0
heading="$(head -n 1 "$managed/CLAUDE.md")"
grep -qF "$heading" "$log" || { echo "      the managed CLAUDE.md isn't in the request"; bad=1; }
for skill in "$managed"/skills/*/SKILL.md; do
  description="$(sed -n 's/^description: //p' "$skill" | cut -c1-60)"
  grep -qF "$description" "$log" || { echo "      $skill isn't in the request"; bad=1; }
done
exit "$bad"
