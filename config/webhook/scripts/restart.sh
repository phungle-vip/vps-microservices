#!/bin/sh
set -eu

DOCKER="http://docker_api:2375"

TARGET="${1:-}"
[ -z "$TARGET" ] && { echo "missing target"; exit 1; }

# Map target -> service list (compose service names)
# and -> database name that should be dropped & recreated
case "$TARGET" in
  ms_user)      SVCS_APP="ms_user";      SVC_DB="ms_user-mysql";      DBNAME="ms_user" ;;
  ms_route)     SVCS_APP="ms_route";     SVC_DB="ms_route-mysql";     DBNAME="ms_route" ;;
  ms_booking)   SVCS_APP="ms_booking";   SVC_DB="ms_booking-mysql";   DBNAME="ms_booking" ;;
  ms_promotion) SVCS_APP="ms_promotion"; SVC_DB="ms_promotion-mysql"; DBNAME="ms_promotion" ;;
  gateway)      SVCS_APP="gateway";      SVC_DB="";                   DBNAME="" ;;
  all)
    # For 'all', we’ll process each group sequentially
    for t in ms_user ms_route ms_booking ms_promotion gateway; do
      "$0" "$t" || true
    done
    echo "ok"
    exit 0
    ;;
  *) echo "unknown target: $TARGET"; exit 2 ;;
esac

# --- Helpers ---

# Try to detect compose project for better lookups
detect_project() {
  PROJ=$(
    curl -fsS "${DOCKER}/containers/json?filters=%7B%22name%22%3A%5B%22restarter%22%5D%7D" \
    | tr -d '\n' \
    | sed -n 's/.*"com\.docker\.compose\.project":"\([^"]*\)".*/\1/p' \
    | head -n1
  )
  [ -n "${PROJ:-}" ] && echo "$PROJ" || echo ""
}

PROJECT="${COMPOSE_PROJECT_NAME:-$(detect_project)}"

# Find first container ID by label (service + optional project)
find_id_by_service() {
  svc="$1"
  if [ -n "$PROJECT" ]; then
    FILTER="%7B%22label%22%3A%5B%22com.docker.compose.service%3D${svc}%22%2C%22com.docker.compose.project%3D${PROJECT}%22%5D%7D"
  else
    FILTER="%7B%22label%22%3A%5B%22com.docker.compose.service%3D${svc}%22%5D%7D"
  fi
  curl -fsS "${DOCKER}/containers/json?all=1&filters=${FILTER}" \
  | tr -d '\n' \
  | sed -n 's/.*"Id":"\([a-f0-9]\{12,64\}\)".*/\1/p' \
  | head -n1
}

restart_container_by_id() {
  id="$1"
  curl -fsS -X POST "${DOCKER}/containers/${id}/restart" >/dev/null
}

# Exec a command inside a container (returns combined stdout/stderr)
docker_exec() {
  id="$1"; shift
  # Build payload: run via sh -lc '...'
  CMD="$*"
  # Create exec
  exec_id=$(
    curl -fsS -X POST "${DOCKER}/containers/${id}/exec" \
      -H 'Content-Type: application/json' \
      -d "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"sh\",\"-lc\",\"$CMD\"]}" \
    | sed -n 's/.*"Id":"\([^"]*\)".*/\1/p'
  )
  [ -z "$exec_id" ] && { echo "failed to create exec"; return 1; }

  # Start exec (stream output)
  curl -fsS -X POST "${DOCKER}/exec/${exec_id}/start" \
    -H 'Content-Type: application/json' \
    -d '{"Detach":false,"Tty":false}'
}

wipe_database_in_mysql_container() {
  dbsvc="$1"
  dbname="$2"

  [ -z "$dbsvc" ] && return 0
  [ -z "$dbname" ] && return 0

  db_id="$(find_id_by_service "$dbsvc")"
  if [ -z "$db_id" ]; then
    echo "✗ DB container for service '$dbsvc' not found"
    return 1
  fi

  echo "→ Dropping & recreating database '$dbname' in [$dbsvc]..."
  # Root has no password per your compose. Ensure server is up: simple ping loop.
  # Try up to ~20s to avoid race with cold start.
  i=0
  until docker_exec "$db_id" "mysqladmin ping -uroot --silent"; do
    i=$((i+1)); [ $i -gt 20 ] && { echo "✗ mysql not responding"; return 1; }
    sleep 1
  done

  # Drop & recreate DB
  docker_exec "$db_id" "mysql -uroot -e 'DROP DATABASE IF EXISTS \`$dbname\`; CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
  echo "✓ Database '$dbname' reset"
}

# --- Orchestration ---

# 1) Restart app service first (so it releases connections quickly if running)
if [ -n "$SVCS_APP" ]; then
  for svc in $SVCS_APP; do
    app_id="$(find_id_by_service "$svc")"
    if [ -n "$app_id" ]; then
      echo "→ Restarting app [$svc]..."
      restart_container_by_id "$app_id" || echo "✗ Failed to restart $svc"
    else
      echo "ℹ︎ App container for [$svc] not found (maybe down)"
    fi
  done
fi

# 2) Wipe DB (drop & recreate DB in place)
if [ -n "${SVC_DB:-}" ]; then
  wipe_database_in_mysql_container "$SVC_DB" "$DBNAME" || true
fi

# 3) Restart DB container to ensure clean state
if [ -n "${SVC_DB:-}" ]; then
  db_id="$(find_id_by_service "$SVC_DB")"
  if [ -n "$db_id" ]; then
    echo "→ Restarting DB [$SVC_DB]..."
    restart_container_by_id "$db_id" || echo "✗ Failed to restart $SVC_DB"
  fi
fi

# 4) Restart app again (so it reconnects to fresh DB)
if [ -n "$SVCS_APP" ]; then
  for svc in $SVCS_APP; do
    app_id="$(find_id_by_service "$svc")"
    if [ -n "$app_id" ]; then
      echo "→ Restarting app [$svc] again..."
      restart_container_by_id "$app_id" || echo "✗ Failed to restart $svc"
    fi
  done
fi

echo "ok"
