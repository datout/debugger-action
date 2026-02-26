#!/bin/bash

set -eo pipefail

uriencode() {
  s="${1//'%'/%25}"
  s="${s//' '/%20}"
  s="${s//'"'/%22}"
  s="${s//'#'/%23}"
  s="${s//'$'/%24}"
  s="${s//'&'/%26}"
  s="${s//'+'/%2B}"
  s="${s//','/%2C}"
  s="${s//'/'/%2F}"
  s="${s//':'/%3A}"
  s="${s//';'/%3B}"
  s="${s//'='/%3D}"
  s="${s//'?'/%3F}"
  s="${s//'@'/%40}"
  s="${s//'['/%5B}"
  s="${s//']'/%5D}"
  printf %s "$s"
}

# For mount docker volume, do not directly use '/tmp' as the dir
TMATE_TERM="${TMATE_TERM:-screen-256color}"
TIMESTAMP="$(date +%s%3N)"
TMATE_DIR="/tmp/tmate-${TIMESTAMP}"
TMATE_SOCK="${TMATE_DIR}/session.sock"
TMATE_SESSION_NAME="tmate-${TIMESTAMP}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# Shorten this URL to avoid mask by Github Actions Runner
README_URL="https://github.com/tete1030/safe-debugger-action/blob/master/README.md"
README_URL_SHORT="$(curl -si https://git.io -F "url=${README_URL}" | tr -d '\r' | sed -En 's/^Location: (.*)/\1/p')"

cleanup() {
  if [ -n "${container_id}" ] && [ "x${docker_type}" = "ximage" ]; then
    echo "Current docker container will be saved to your image: ${TMATE_DOCKER_IMAGE_EXP}"
    docker stop -t1 "${container_id}" > /dev/null
    docker commit --message "Commit from safe-debugger-action" "${container_id}" "${TMATE_DOCKER_IMAGE_EXP}"
    docker rm -f "${container_id}" > /dev/null
  fi
  # Cleanup web terminal processes if any
  if [ -n "${CLOUDFLARED_PID:-}" ] && kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then
    kill "${CLOUDFLARED_PID}" 2>/dev/null || true
  fi
  if [ -n "${TTYD_PID:-}" ] && kill -0 "${TTYD_PID}" 2>/dev/null; then
    kill "${TTYD_PID}" 2>/dev/null || true
  fi
  tmate -S "${TMATE_SOCK}" kill-server || true
  sed -i '/alias attach_docker/d' ~/.bashrc || true
  rm -rf "${TMATE_DIR}"
}

setup_web_terminal() {
  # Passwordless web terminal (link = token) using ttyd + cloudflared (trycloudflare)
  # Can be disabled by setting DISABLE_WEB_TERMINAL=1
  WEB2_LINE=""
  TTYD_PID=""
  CLOUDFLARED_PID=""

  if [ -n "${DISABLE_WEB_TERMINAL:-}" ] && [ "x${DISABLE_WEB_TERMINAL}" != "x0" ]; then
    return 0
  fi

  local arch ttyd_url cf_url port
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)
      ttyd_url="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64"
      cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
      ;;
    aarch64|arm64)
      ttyd_url="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.aarch64"
      cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
      ;;
    *)
      echo "::warning::Unsupported arch for web terminal: ${arch}"
      return 0
      ;;
  esac

  # Download binaries into TMATE_DIR to avoid polluting the system
  # Do not fail the whole action if download fails; fallback to tmate only
  echo "Setting up passwordless Web terminal (ttyd + trycloudflare)..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 "${ttyd_url}" -o "${TMATE_DIR}/ttyd"; then
    echo "::warning::Failed to download ttyd, Web terminal disabled"
    return 0
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 15 "${cf_url}" -o "${TMATE_DIR}/cloudflared"; then
    echo "::warning::Failed to download cloudflared, Web terminal disabled"
    return 0
  fi
  chmod +x "${TMATE_DIR}/ttyd" "${TMATE_DIR}/cloudflared" || true

  port="${WEB_TERMINAL_PORT:-7681}"

  linebuf() {
    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL -eL "$@"
    else
      "$@"
    fi
  }

  # -o: Accept only one client and exit on disconnection (so "exit" ends this step, like tmate)
  linebuf "${TMATE_DIR}/ttyd" -o -p "${port}" -i 127.0.0.1 -W \
    bash -lc 'cd "'"${TMATE_SESSION_PATH}"'" 2>/dev/null || true; trap "touch /tmp/remote_done" EXIT; bash -l' \
    >"${TMATE_DIR}/ttyd.log" 2>&1 &
  TTYD_PID=$!

  linebuf "${TMATE_DIR}/cloudflared" tunnel --url "http://127.0.0.1:${port}" --no-autoupdate \
    >"${TMATE_DIR}/cloudflared.log" 2>&1 &
  CLOUDFLARED_PID=$!

  # Wait for public URL
  local i
  for i in $(seq 1 120); do
    # Extract the *actual* trycloudflare public URL (ignore the "trycloudflare.com..." info line)
    WEB2_LINE="$(awk 'match($0, /https:\/\/[-0-9a-z]+\.trycloudflare\.com/) {print substr($0, RSTART, RLENGTH); exit}' "${TMATE_DIR}/cloudflared.log" | tr -d '\r' || true)"
    [ -n "${WEB2_LINE}" ] && break
    # If cloudflared exited early, stop waiting
    if [ -n "${CLOUDFLARED_PID:-}" ] && ! kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [ -z "${WEB2_LINE}" ]; then
    echo "::warning::Web2 URL not found (trycloudflare). Use SSH instead."
    echo "::warning::cloudflared log (last 30 lines):"
    tail -n 30 "${TMATE_DIR}/cloudflared.log" 2>/dev/null || true
    return 0
  fi

  return 0
}

if [[ -n "$SKIP_DEBUGGER" ]]; then
  echo "Skipping debugger because SKIP_DEBUGGER enviroment variable is set"
  exit
fi

# Install tmate on macOS or Ubuntu
echo Setting up tmate and openssl...
if [ -x "$(command -v brew)" ]; then
  brew install tmate > /tmp/brew.log
fi
if [ -x "$(command -v apt-get)" ]; then
  "${SCRIPT_DIR}/tmate.sh"
fi

# Generate ssh key if needed
[ -e ~/.ssh/id_rsa ] || ssh-keygen -t rsa -f ~/.ssh/id_rsa -q -N ""

# Run deamonized tmate
echo Running tmate...

now_date="$(date)"
timeout=$(( ${TIMEOUT_MIN:=30}*60 ))
kill_date="$(date -d "${now_date} + ${timeout} seconds")"

TMATE_SESSION_PATH="$(pwd)"
mkdir "${TMATE_DIR}"

container_id=''
if [ -n "${TMATE_DOCKER_IMAGE}" ] || [ -n "${TMATE_DOCKER_CONTAINER}" ]; then
  if [ -n "${TMATE_DOCKER_CONTAINER}" ]; then
    docker_type="container"
    container_id="${TMATE_DOCKER_CONTAINER}"
  else
    docker_type="image"
    if [ -z "${TMATE_DOCKER_IMAGE_EXP}" ]; then
      TMATE_DOCKER_IMAGE_EXP="${TMATE_DOCKER_IMAGE}"
    fi
    echo "Creating docker container for running tmate"
    container_id=$(docker create -t "${TMATE_DOCKER_IMAGE}")
    docker start "${container_id}"
  fi
  DK_SHELL="docker exec -e TERM='${TMATE_TERM}' -it '${container_id}' /bin/bash -il"
  DOCKER_MESSAGE_CMD='printf "This window is running in Docker '"${docker_type}"'.\nTo attach to Github Actions runner, exit current shell\nor create a new tmate window by \"Ctrl-b, c\"\n(This shortcut is only available when connecting through ssh)\n\n"'
  FIRSTWIN_MESSAGE_CMD='printf "This window is now running in GitHub Actions runner.\nTo attach to your Docker '"${docker_type}"' again, use \"attach_docker\" command\n\n"'
  SECWIN_MESSAGE_CMD='printf "The first window of tmate has already been attached to your Docker '"${docker_type}"'.\nThis window is running in GitHub Actions runner.\nTo attach to your Docker '"${docker_type}"' again, use \"attach_docker\" command\n\n"'
  echo "unalias attach_docker 2>/dev/null || true ; alias attach_docker='${DK_SHELL}'" >> ~/.bashrc
  (
    cd "${TMATE_DIR}"
    TERM="${TMATE_TERM}" tmate -v -S "${TMATE_SOCK}" new-session -s "${TMATE_SESSION_NAME}" -c "${TMATE_SESSION_PATH}" -d "/bin/bash --noprofile --norc -c '${DOCKER_MESSAGE_CMD} ; ${DK_SHELL} ; ${FIRSTWIN_MESSAGE_CMD} ; /bin/bash -li'" \; set-option default-command "/bin/bash --noprofile --norc -c '${SECWIN_MESSAGE_CMD} ; /bin/bash -li'" \; set-option default-terminal "${TMATE_TERM}"
  )
else
  echo "unalias attach_docker 2>/dev/null || true" >> ~/.bashrc
  (
    cd "${TMATE_DIR}"
    TERM="${TMATE_TERM}" tmate -v -S "${TMATE_SOCK}" new-session -s "${TMATE_SESSION_NAME}" -c "${TMATE_SESSION_PATH}" -d \; set-option default-terminal "${TMATE_TERM}"
  )
fi

tmate -S "${TMATE_SOCK}" wait tmate-ready
TMATE_PID="$(tmate -S "${TMATE_SOCK}" display -p '#{pid}')"
TMATE_SERVER_LOG="${TMATE_DIR}/tmate-server-${TMATE_PID}.log"
if [ ! -f "${TMATE_SERVER_LOG}" ]; then
  echo "::error::No server log found" >&2
  echo "Files in TMATE_DIR:" >&2
  ls -l "${TMATE_DIR}"
  exit 1
fi


SSH_LINE="$(tmate -S "${TMATE_SOCK}" display -p '#{tmate_ssh}' |cut -d ' ' -f2)"
WEB_LINE="$(tmate -S "${TMATE_SOCK}" display -p '#{tmate_web}')"

# Optional passwordless Web terminal (ttyd + trycloudflare)
setup_web_terminal || true

  MSG="SSH: ${SSH_LINE}\nWEB: ${WEB_LINE}"
  echo -e "\e[32m  \e[0m"
  echo -e " SSH：\e[32m ${SSH_LINE} \e[0m"
  echo -e " Web：\e[33m ${WEB_LINE} \e[0m"
  [ -n "${WEB2_LINE:-}" ] && echo -e " Web2：\e[33m ${WEB2_LINE} \e[0m"
  # Plain (no-ANSI) full URL line for easy click/copy in GitHub Actions UI
  echo -e "\e[32m  \e[0m"
  
TIMEOUT_MESSAGE="如果您未连接SSH或Web2，则在${timeout}秒内自动跳过，要立即跳过此步骤，只需连接SSH或Web2并退出即可"
echo -e "$TIMEOUT_MESSAGE"

# Also write URLs into the Step Summary (copyable, not truncated by log UI)
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Remote Access"
    echo ""
    echo "- SSH: ${SSH_LINE}"
    echo "- Web: ${WEB_LINE}"
    if [ -n "${WEB2_LINE:-}" ]; then
      echo "- Web2 (passwordless): ${WEB2_LINE}"
      echo ""
      echo "Copy Web2 URL:"
      echo '```'
      echo "${WEB2_LINE}"
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]] && [[ "$INFORMATION_NOTICE" == "TG" ]]; then
  echo -n "Sending information to Telegram Bot......"
  curl -k --data chat_id="${TELEGRAM_CHAT_ID}" --data "text=  Web: ${WEB_LINE}
  Web2: ${WEB2_LINE}

  SSH: ${SSH_LINE}" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
elif [[ -n "$PUSH_PLUS_TOKEN" ]] && [[ "$INFORMATION_NOTICE" == "PUSH" ]]; then
  echo -n "Sending information to pushplus......"
  curl -k --data token=${PUSH_PLUS_TOKEN} --data title="SSH连接代码" --data "content=Web: ${WEB_LINE}
  Web2: ${WEB2_LINE}

  SSH: ${SSH_LINE}" "http://www.pushplus.plus/send"
fi

echo ""
echo ______________________________________________________________________________________________
echo ""

# Wait for connection to close or timeout
display_int=${DISP_INTERVAL_SEC:=30}
timecounter=0

remote_done_file="/tmp/remote_done"
rm -f "${remote_done_file}" 2>/dev/null || true
ssh_attached_once=0
web_attached_once=0
web_port="${WEB_TERMINAL_PORT:-7681}"

while true; do
  # Web2 wrapper will create this file on shell exit
  if [ -f "${remote_done_file}" ]; then
    echo "Remote session marked done."
    break
  fi

  tmate_alive=0
  [ -S "${TMATE_SOCK}" ] && tmate_alive=1

  ttyd_alive=0
  if [ -n "${TTYD_PID:-}" ] && kill -0 "${TTYD_PID}" 2>/dev/null; then
    ttyd_alive=1
  fi

  # Exit conditions:
  # - tmate session ended
  # - or Web2 ended (ttyd -o exits on disconnect)
  if [ ${tmate_alive} -eq 0 ]; then
    break
  fi
  if [ -n "${WEB2_LINE:-}" ] && [ ${ttyd_alive} -eq 0 ]; then
    echo "Web terminal session ended."
    break
  fi

  # Detect SSH attach/detach: connect then exit => continue
  ssh_attached="$(tmate -S "${TMATE_SOCK}" display -p '#{session_attached}' 2>/dev/null || echo 0)"
  ssh_attached="${ssh_attached:-0}"
  if [ "${ssh_attached}" -gt 0 ] 2>/dev/null; then
    ssh_attached_once=1
  elif [ "${ssh_attached_once}" -eq 1 ]; then
    echo "SSH session ended."
    break
  fi

  # Best-effort: detect Web2 has an active connection to disable timeout while in use
  if [ -n "${WEB2_LINE:-}" ] && [ ${web_attached_once} -eq 0 ]; then
    if command -v ss >/dev/null 2>&1; then
      ss -tn "sport = :${web_port}" 2>/dev/null | grep -q ESTAB && web_attached_once=1 || true
    fi
  fi

  # Timeout if nobody connected within timeout
  if [ ${ssh_attached_once} -eq 0 ] && [ ${web_attached_once} -eq 0 ]; then
    if (( timecounter > timeout )); then
      echo "等待连接超时,现在跳过SSH/Web2此步骤"
      cleanup

      if [ "x$TIMEOUT_FAIL" = "x1" ] || [ "x$TIMEOUT_FAIL" = "xtrue" ]; then
        exit 1
      else
        exit 0
      fi
    fi
  fi

  if (( timecounter % display_int == 0 )); then
      echo "您可以使用SSH终端连接，或者使用网页直接连接"
      echo "终端连接IP为SSH:后面的代码，网页连接可使用 Web 或 Web2 链接。Web2 为免密直连（链接即口令）"
      echo "命令：cd openwrt && make menuconfig"
      echo -e "\e[32m  \e[0m"
      echo -e " SSH: \e[32m ${SSH_LINE} \e[0m"
      echo -e " Web: \e[33m ${WEB_LINE} \e[0m"
      [ -n "${WEB2_LINE:-}" ] && echo -e " Web2: \e[33m ${WEB2_LINE} \e[0m"
      echo -e "\e[32m  \e[0m"

     if [ ${ssh_attached_once} -eq 0 ] && [ ${web_attached_once} -eq 0 ]; then
       echo -e "\n如果您还不连接SSH/Web2，\e[31m将在\e[0m $(( timeout-timecounter )) 秒内自动跳过"
       echo "要立即跳过此步骤，只需连接SSH或Web2并正确退出即可"
     fi
    echo ______________________________________________________________________________________________
  fi

  sleep 1
  timecounter=$((timecounter+1))
done

echo "The connection is terminated."
cleanup
