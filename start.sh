#!/usr/bin/env bash
#
# Startet Backend und Dashboard im Hintergrund und öffnet danach direkt das
# Dashboard im Browser — `/`, also die Hauptseite. Es gab einmal eine Landingpage
# davor; die ist weg, ein Klick auf das Symbol zeigt jetzt das Dashboard.
#
#   ./start.sh            starten (idempotent) und das Dashboard öffnen
#   ./start.sh stop       alles wieder beenden
#   ./start.sh desktop    das Symbol für den Schreibtisch installieren
#   ./start.sh status     zeigen, ob es läuft
#
# Zwei Dinge, die hier ausdrücklich *nicht* passieren: Es bleibt kein
# Terminalfenster offen, und es gibt keine Textausgabe. Der Doppelklick auf das
# Symbol soll das Dashboard zeigen, nicht eine Konsole, die man wegklicken muss.
# Deshalb hängt der Dev-Server an `setsid` (eigene Sitzung, kein Elternterminal)
# und schreibt sein Log nach `run/dev.log`.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"

RUN_DIR="$PWD/run"
LOG_FILE="$RUN_DIR/dev.log"
PID_FILE="$RUN_DIR/dev.pid"
DASHBOARD_URL="http://localhost:5173/"
HEALTH_URL="http://127.0.0.1:8787/api/health"

running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

stop() {
  if ! running; then
    echo "Läuft nicht."
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  # Die Prozessgruppe killen: `concurrently` startet zwei Kinder, und ein SIGTERM
  # an `npm` allein ließe den Vite-Server als Waiszeug zurück.
  kill -TERM "-$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null \
    || kill -TERM "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "Beendet."
}

## Wartet, bis das Dashboard antwortet, und öffnet es dann.
##
## Feste `sleep`-Zeiten sind hier der falsche Weg: auf einem langsamen Rechner
## öffnet sich der Browser vorher und zeigt eine Fehlerseite, und das bleibt
## dann so stehen. Stattdessen wird die Seite abgefragt, bis sie da ist.
open_dashboard() {
  local waited=0
  while [ "$waited" -lt 60 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -o /dev/null "$DASHBOARD_URL" 2>/dev/null && break
    else
      # Ohne `curl` gibt es keine Prüfung; dann eben einmal warten.
      [ "$waited" -ge 3 ] && break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  xdg-open "$DASHBOARD_URL" >/dev/null 2>&1 \
    || echo "Bitte $DASHBOARD_URL öffnen." >&2
}

install_desktop() {
  local source="$PWD/packaging/singular80.desktop"
  if [ ! -f "$source" ]; then
    echo "Fehlt: $source" >&2
    return 1
  fi
  mkdir -p "$HOME/.local/share/applications"
  install -m 0755 "$source" "$HOME/.local/share/applications/singular80.desktop"
  echo "Installiert: ~/.local/share/applications/singular80.desktop"
  if [ -d "$HOME/Desktop" ]; then
    install -m 0755 "$source" "$HOME/Desktop/singular80.desktop"
    echo "Installiert: ~/Desktop/singular80.desktop"
  fi
  echo "Je nach Desktop noch einmal abmelden/anmelden, damit das Symbol erscheint."
}

case "${1:-start}" in
  start)
    if running; then
      # Schon da: nur den Browser holen. Der zweite Server am selben Port wäre
      # ein Fehler im Log, den niemand liest.
      open_dashboard
      exit 0
    fi
    if [ ! -d node_modules ]; then
      npm install
    fi
    [ -f .env ] || cp .env.example .env
    mkdir -p "$RUN_DIR"
    # Altes Log abschneiden statt es anzuheften: `>>` lässt die Datei über die
    # Monate wachsen, ohne dass jemand sie öffnet.
    : > "$LOG_FILE"
    setsid nohup npm run dev > "$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
    open_dashboard
    ;;
  stop)
    stop
    ;;
  status)
    if running; then
      echo "Läuft (PID $(cat "$PID_FILE")), Log: ${LOG_FILE#"$PWD"/}"
    else
      echo "Läuft nicht."
    fi
    ;;
  desktop)
    install_desktop
    ;;
  *)
    echo "Aufruf: $0 [start|stop|status|desktop]" >&2
    exit 1
    ;;
esac
