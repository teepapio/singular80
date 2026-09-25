#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"

if [ ! -d node_modules ]; then
  echo "Installiere Abhängigkeiten (einmalig) …"
  npm install
fi

if [ ! -f .env ]; then
  cp .env.example .env
fi

echo ""
echo "  SINGULAR 80 startet …"
echo "  Spiel:      http://localhost:5173"
echo "  Dashboard:  http://localhost:5173/dashboard.html"
echo "  (Discord-Webhook kann im Dashboard unter Einstellungen eingetragen werden)"
echo ""

(
  sleep 4
  xdg-open http://localhost:5173 >/dev/null 2>&1 || true
  sleep 1
  xdg-open http://localhost:5173/dashboard.html >/dev/null 2>&1 || true
) &

exec npm run dev
