#!/usr/bin/env bash
set -Eeuo pipefail

: "${VNC_PORT:="5900"}"    # VNC port
: "${MON_PORT:="7100"}"    # Monitor port
: "${WEB_PORT:="8006"}"    # Webserver port
: "${WSD_PORT:="8004"}"    # Websockets port
: "${WSS_PORT:="5700"}"    # Websockets port

# Function to check if a port is in use
portInUse() {
  local port=$1
  # Check if port is being used by any process
  if command -v ss >/dev/null 2>&1; then
    ss_output=$(ss -tuln)
    echo "$ss_output"  | grep -qE ":$port($|[^0-9])" && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat_output=$(netstat -tuln)
    echo "$netstat_output" | grep -qE ":$port($|[^0-9])" && return 0
  else
    # Fallback: try to bind to the port
    if timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
      return 0  # Port is accessible (probably in use)
    else
      return 1  # Port is not accessible (probably free)
    fi
  fi
  return 1
}

# Function to find a free port starting from a base port
findFreePort() {
  local base_port=$1
  local port=$base_port
  
  while portInUse "$port"; do
    ((port++))
    # Safety check to prevent infinite loop
    if (( port > base_port + 2000 )); then
      error "Could not find a free port after checking 2000 ports starting from $base_port"
      return 1
    fi
  done
  
  echo "$port"
  return 0
}

# Auto-adjust ports if they are in use (only when not explicitly set by user)
if [[ "${AUTO_PORT_ADJUST:-Y}" != [Nn]* ]]; then
  # Check and adjust VNC port
  if portInUse "$VNC_PORT"; then
    original_port="$VNC_PORT"
    VNC_PORT=$(findFreePort "$VNC_PORT")
    warn "VNC port $original_port is in use, automatically switching to port $VNC_PORT"
  fi
  
  
  # Check and adjust Monitor port
  if portInUse "$MON_PORT"; then
    original_port="$MON_PORT"
    MON_PORT=$(findFreePort "$MON_PORT")
    warn "Monitor port $original_port is in use, automatically switching to port $MON_PORT"
  fi
  
  # Check and adjust Web port
  if portInUse "$WEB_PORT"; then
    original_port="$WEB_PORT"
    WEB_PORT=$(findFreePort "$WEB_PORT")
    warn "Web port $original_port is in use, automatically switching to port $WEB_PORT"
  fi
  
  # Check and adjust Websocket ports
  if portInUse "$WSD_PORT"; then
    original_port="$WSD_PORT"
    WSD_PORT=$(findFreePort "$WSD_PORT")
    warn "Websocket port $original_port is in use, automatically switching to port $WSD_PORT"
  fi
  
  if portInUse "$WSS_PORT"; then
    original_port="$WSS_PORT"
    WSS_PORT=$(findFreePort "$WSS_PORT")
    warn "Websocket SSL port $original_port is in use, automatically switching to port $WSS_PORT"
  fi
fi

if (( VNC_PORT < 5900 )); then
  warn "VNC port cannot be set lower than 5900, ignoring value $VNC_PORT."
  VNC_PORT="5900"
fi

# 记录下启动的所有端口
HOST_NAME=$(hostname)
HOST_IP=$(ip route get 1 | grep -oP 'src \K\S+')
cat > /var/run/qemu-private/ports << EOF
{
  "VNC_PORT": $VNC_PORT,
  "MON_PORT": $MON_PORT,
  "WEB_PORT": $WEB_PORT,
  "WSD_PORT": $WSD_PORT,
  "WSS_PORT": $WSS_PORT,
  "HOST_NAME": "$HOST_NAME",
  "HOST_IP": "$HOST_IP"
}
EOF

cp -r /var/www/* /run/shm
rm -f /var/run/websocketd.pid

html "Starting $APP for $ENGINE..."

if [[ "${WEB:-}" != [Nn]* ]]; then

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  user="admin"
  [ -n "${USER:-}" ] && user="${USER:-}"

  if [ -n "${PASS:-}" ]; then

    # Set password
    echo "$user:{PLAIN}${PASS:-}" > /etc/nginx/.htpasswd

    sed -i "s/auth_basic off/auth_basic \"NoVNC\"/g" /etc/nginx/sites-enabled/web.conf

  fi

  sed -i "s/listen 8006 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:5700\/;/proxy_pass http:\/\/127.0.0.1:$WSS_PORT\/;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8004\/;/proxy_pass http:\/\/127.0.0.1:$WSD_PORT\/;/g" /etc/nginx/sites-enabled/web.conf

  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then

    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf

  fi

  # Start webserver
  nginx -e stderr

  # Start websocket server
  websocketd --address 127.0.0.1 --port="$WSD_PORT" /run/socket.sh >/var/log/websocketd.log &
  echo "$!" > /var/run/websocketd.pid

fi

return 0