#!/bin/bash

set -eo pipefail

uriencode() {
  s="${1//'%'/%25}"
  s="${s//' '/%20}"
  s="${s//'\"'/%22}"
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

TMATE_TERM="${TMATE_TERM:-screen-256color}"
TIMESTAMP="$(date +%s%3N)"
TMATE_DIR="/tmp/tmate-${TIMESTAMP}"
TMATE_SOCK="${TMATE_DIR}/session.sock"
TMATE_SESSION_NAME="tmate-${TIMESTAMP}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SSH_LINE=""
WEB_LINE=""
WEB2_LINE=""
TTYD_PID=""
CLOUDFLARED_PID=""
TMATE_READY=0

cleanup() {
  if [ -n "${container_id:-}" ] && [ "x${docker_type:-}" = "ximage" ]; then
    echo "Current docker container will be saved to your image: ${TMATE_DOCKER_IMAGE_EXP}"
    docker stop -t1 "${container_id}" > /dev/null || true
    docker commit --message "Commit from safe-debugger-action" "${container_id}" "${TMATE_DOCKER_IMAGE_EXP}" || true
    docker rm -f "${container_id}" > /dev/null || true
  fi

  if [ -n "${CLOUDFLARED_PID:-}" ] && kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then
    kill "${CLOUDFLARED_PID}" 2>/dev/null || true
  fi
  if [ -n "${TTYD_PID:-}" ] && kill -0 "${TTYD_PID}" 2>/dev/null; then
    kill "${TTYD_PID}" 2>/dev/null || true
  fi

  if command -v tmate >/dev/null 2>&1 && [ -S "${TMATE_SOCK}" ]; then
    tmate -S "${TMATE_SOCK}" kill-server 2>/dev/null || true
  fi

  sed -i '/alias attach_docker/d' ~/.bashrc 2>/dev/null || true
  rm -rf "${TMATE_DIR}" 2>/dev/null || true
}

setup_web_terminal() {
  # Web2 is independent from tmate: ttyd + Cloudflare Quick Tunnel.
  # Can be disabled by setting DISABLE_WEB_TERMINAL=1.
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
      echo "::warning::Unsupported arch for Web2 terminal: ${arch}"
      return 0
      ;;
  esac

  echo "Setting up Web2 first (ttyd + trycloudflare)..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 "${ttyd_url}" -o "${TMATE_DIR}/ttyd"; then
    echo "::warning::Failed to download ttyd, Web2 disabled"
    return 0
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 15 "${cf_url}" -o "${TMATE_DIR}/cloudflared"; then
    echo "::warning::Failed to download cloudflared, Web2 disabled"
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

  linebuf "${TMATE_DIR}/ttyd" -o -p "${port}" -i 127.0.0.1 -W \
    bash -lc 'cd "'"${TMATE_SESSION_PATH}"'" 2>/dev/null || true; trap "touch /tmp/remote_done" EXIT; bash -l' \
    >"${TMATE_DIR}/ttyd.log" 2>&1 &
  TTYD_PID=$!

  linebuf "${TMATE_DIR}/cloudflared" tunnel --url "http://127.0.0.1:${port}" --no-autoupdate \
    >"${TMATE_DIR}/cloudflared.log" 2>&1 &
  CLOUDFLARED_PID=$!

  local i
  for i in $(seq 1 "${WEB2_READY_TIMEOUT_SEC:-45}"); do
    WEB2_LINE="$(awk 'match($0, /https:\/\/[-0-9a-z]+\.trycloudflare\.com/) {print substr($0, RSTART, RLENGTH); exit}' "${TMATE_DIR}/cloudflared.log" | tr -d '\r' || true)"
    [ -n "${WEB2_LINE}" ] && break
    if [ -n "${CLOUDFLARED_PID:-}" ] && ! kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [ -z "${WEB2_LINE}" ]; then
    echo "::warning::Web2 URL not found (trycloudflare). Will try tmate."
    echo "::warning::cloudflared log (last 30 lines):"
    tail -n 30 "${TMATE_DIR}/cloudflared.log" 2>/dev/null || true
  else
    echo "Web2 ready: ${WEB2_LINE}"
  fi
}

notify_web2_first() {
  [ -n "${WEB2_LINE:-}" ] || return 0

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Remote Access"
      echo ""
      echo "- Web2 (primary, passwordless): ${WEB2_LINE}"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "TG" ]]; then
    echo -n "Sending Web2 information to Telegram Bot......"
    curl -ksS --data chat_id="${TELEGRAM_CHAT_ID}" \
      --data "text=Web2 已就绪（主连接）: ${WEB2_LINE}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null || true
    echo "done"
  elif [[ -n "${PUSH_PLUS_TOKEN:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "PUSH" ]]; then
    echo -n "Sending Web2 information to pushplus......"
    curl -ksS --data token="${PUSH_PLUS_TOKEN}" --data title="Web2连接地址" \
      --data "content=Web2: ${WEB2_LINE}" "http://www.pushplus.plus/send" >/dev/null || true
    echo "done"
  fi
}

notify_tmate_optional() {
  [ "${TMATE_READY}" -eq 1 ] || return 0

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "- SSH (tmate, optional): ${SSH_LINE}"
      echo "- Web (tmate, optional): ${WEB_LINE}"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "TG" ]]; then
    echo -n "Sending optional tmate information to Telegram Bot......"
    curl -ksS --data chat_id="${TELEGRAM_CHAT_ID}" \
      --data "text=tmate 备用连接已就绪\nSSH: ${SSH_LINE}\nWeb: ${WEB_LINE}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null || true
    echo "done"
  elif [[ -n "${PUSH_PLUS_TOKEN:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "PUSH" ]]; then
    echo -n "Sending optional tmate information to pushplus......"
    curl -ksS --data token="${PUSH_PLUS_TOKEN}" --data title="tmate备用连接" \
      --data "content=SSH: ${SSH_LINE}<br>Web: ${WEB_LINE}" "http://www.pushplus.plus/send" >/dev/null || true
    echo "done"
  fi
}

if [[ -n "${SKIP_DEBUGGER:-}" ]]; then
  echo "Skipping debugger because SKIP_DEBUGGER environment variable is set"
  exit 0
fi

now_date="$(date)"
timeout=$(( ${TIMEOUT_MIN:=30} * 60 ))
kill_date="$(date -d "${now_date} + ${timeout} seconds" 2>/dev/null || true)"
TMATE_SESSION_PATH="$(pwd)"
remote_done_file="/tmp/remote_done"
rm -f "${remote_done_file}" 2>/dev/null || true
mkdir -p "${TMATE_DIR}"
container_id=''

# 1) Bring up Web2 first. It does not depend on tmate.
setup_web_terminal || true
notify_web2_first || true

# 2) tmate is now optional. Never let it block Web2 or the build indefinitely.
echo "Setting up optional tmate SSH/Web access..."
TMATE_INSTALL_OK=1
if [ -n "${DISABLE_TMATE:-}" ] && [ "x${DISABLE_TMATE}" != "x0" ]; then
  TMATE_INSTALL_OK=0
  echo "tmate disabled by DISABLE_TMATE; Web2-only mode enabled"
elif ! command -v tmate >/dev/null 2>&1; then
  if [ -x "$(command -v brew 2>/dev/null || true)" ]; then
    if ! timeout "${TMATE_INSTALL_TIMEOUT_SEC:-180}" brew install tmate > /tmp/brew.log 2>&1; then
      TMATE_INSTALL_OK=0
      echo "::warning::tmate installation timed out/failed; Web2 remains available"
    fi
  elif [ -x "$(command -v apt-get 2>/dev/null || true)" ]; then
    if ! timeout "${TMATE_INSTALL_TIMEOUT_SEC:-180}" "${SCRIPT_DIR}/tmate.sh"; then
      TMATE_INSTALL_OK=0
      echo "::warning::tmate installation timed out/failed; Web2 remains available"
    fi
  else
    TMATE_INSTALL_OK=0
    echo "::warning::No supported package manager for tmate; Web2 remains available"
  fi
fi

if [ "${TMATE_INSTALL_OK}" -eq 1 ] && command -v tmate >/dev/null 2>&1; then
  [ -e ~/.ssh/id_rsa ] || ssh-keygen -t rsa -f ~/.ssh/id_rsa -q -N "" || true
  echo "Running optional tmate..."

  if [ -n "${TMATE_DOCKER_IMAGE:-}" ] || [ -n "${TMATE_DOCKER_CONTAINER:-}" ]; then
    if [ -n "${TMATE_DOCKER_CONTAINER:-}" ]; then
      docker_type="container"
      container_id="${TMATE_DOCKER_CONTAINER}"
    else
      docker_type="image"
      if [ -z "${TMATE_DOCKER_IMAGE_EXP:-}" ]; then
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
    ) || true
  else
    echo "unalias attach_docker 2>/dev/null || true" >> ~/.bashrc
    (
      cd "${TMATE_DIR}"
      TERM="${TMATE_TERM}" tmate -v -S "${TMATE_SOCK}" new-session -s "${TMATE_SESSION_NAME}" -c "${TMATE_SESSION_PATH}" -d \; set-option default-terminal "${TMATE_TERM}"
    ) || true
  fi

  if timeout "${TMATE_READY_TIMEOUT_SEC:-60}" tmate -S "${TMATE_SOCK}" wait tmate-ready; then
    TMATE_READY=1
    SSH_LINE="$(tmate -S "${TMATE_SOCK}" display -p '#{tmate_ssh}' 2>/dev/null | cut -d ' ' -f2 || true)"
    WEB_LINE="$(tmate -S "${TMATE_SOCK}" display -p '#{tmate_web}' 2>/dev/null || true)"
    echo "tmate ready."
    [ -n "${SSH_LINE}" ] && echo -e " SSH：\e[32m ${SSH_LINE} \e[0m"
    [ -n "${WEB_LINE}" ] && echo -e " Web：\e[33m ${WEB_LINE} \e[0m"
    notify_tmate_optional || true
  else
    echo "::warning::tmate did not become ready within ${TMATE_READY_TIMEOUT_SEC:-60}s; continuing with Web2 only"
    if [ -S "${TMATE_SOCK}" ]; then
      tmate -S "${TMATE_SOCK}" kill-server 2>/dev/null || true
    fi
    TMATE_READY=0
  fi
fi

if [ -z "${WEB2_LINE:-}" ] && [ "${TMATE_READY}" -ne 1 ]; then
  echo "::warning::Neither Web2 nor tmate is available. Skipping remote debug and continuing the workflow."
  cleanup
  exit 0
fi

echo ""
echo "______________________________________________________________________________________________"
echo "远程调试已就绪。Web2 为主连接，tmate SSH/Web 为可选备用。"
echo "命令：cd openwrt && make menuconfig"
[ -n "${WEB2_LINE:-}" ] && echo -e " Web2：\e[33m ${WEB2_LINE} \e[0m"
[ -n "${SSH_LINE:-}" ] && echo -e " SSH：\e[32m ${SSH_LINE} \e[0m"
[ -n "${WEB_LINE:-}" ] && echo -e " Web：\e[33m ${WEB_LINE} \e[0m"
echo "如果未连接，将在 ${timeout} 秒后自动跳过；连接后正确 exit 即结束此步骤。"
echo "______________________________________________________________________________________________"

# Wait for Web2 or tmate session to finish, or for the idle timeout.
display_int=${DISP_INTERVAL_SEC:=30}
timecounter=0
ssh_attached_once=0
web_attached_once=0
web_port="${WEB_TERMINAL_PORT:-7681}"

while true; do
  if [ -f "${remote_done_file}" ]; then
    echo "Remote session marked done."
    break
  fi

  tmate_alive=0
  if [ "${TMATE_READY}" -eq 1 ] && [ -S "${TMATE_SOCK}" ]; then
    tmate_alive=1
  fi

  ttyd_alive=0
  if [ -n "${WEB2_LINE:-}" ] && [ -n "${TTYD_PID:-}" ] && kill -0 "${TTYD_PID}" 2>/dev/null; then
    ttyd_alive=1
  fi

  # If both access methods are gone, there is nothing left to wait for.
  if [ ${tmate_alive} -eq 0 ] && [ ${ttyd_alive} -eq 0 ]; then
    break
  fi

  # Web2 uses ttyd -o, so closing the active browser session ends ttyd.
  if [ -n "${WEB2_LINE:-}" ] && [ ${web_attached_once} -eq 1 ] && [ ${ttyd_alive} -eq 0 ]; then
    echo "Web2 session ended."
    break
  fi

  if [ ${tmate_alive} -eq 1 ]; then
    ssh_attached="$(tmate -S "${TMATE_SOCK}" display -p '#{session_attached}' 2>/dev/null || echo 0)"
    ssh_attached="${ssh_attached:-0}"
    if [ "${ssh_attached}" -gt 0 ] 2>/dev/null; then
      ssh_attached_once=1
    elif [ "${ssh_attached_once}" -eq 1 ]; then
      echo "SSH session ended."
      break
    fi
  fi

  if [ -n "${WEB2_LINE:-}" ] && [ ${web_attached_once} -eq 0 ]; then
    if command -v ss >/dev/null 2>&1; then
      ss -tn "sport = :${web_port}" 2>/dev/null | grep -q ESTAB && web_attached_once=1 || true
    fi
  fi

  if [ ${ssh_attached_once} -eq 0 ] && [ ${web_attached_once} -eq 0 ]; then
    if (( timecounter > timeout )); then
      echo "等待连接超时，现在跳过远程调试步骤"
      cleanup
      if [ "x${TIMEOUT_FAIL:-}" = "x1" ] || [ "x${TIMEOUT_FAIL:-}" = "xtrue" ]; then
        exit 1
      else
        exit 0
      fi
    fi
  fi

  if (( timecounter % display_int == 0 )); then
    echo "您可以优先使用 Web2 网页终端；tmate 成功时也可使用 SSH/Web。"
    echo "命令：cd openwrt && make menuconfig"
    [ -n "${WEB2_LINE:-}" ] && echo -e " Web2: \e[33m ${WEB2_LINE} \e[0m"
    [ -n "${SSH_LINE:-}" ] && echo -e " SSH: \e[32m ${SSH_LINE} \e[0m"
    [ -n "${WEB_LINE:-}" ] && echo -e " Web: \e[33m ${WEB_LINE} \e[0m"
    if [ ${ssh_attached_once} -eq 0 ] && [ ${web_attached_once} -eq 0 ]; then
      echo -e "\n如果还未连接，将在 $(( timeout-timecounter )) 秒内自动跳过"
      echo "连接 Web2 或 SSH 后正确 exit 即可继续编译"
    fi
    echo "______________________________________________________________________________________________"
  fi

  sleep 1
  timecounter=$((timecounter+1))
done

echo "The connection is terminated."
cleanup
