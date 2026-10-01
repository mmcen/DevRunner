#!/bin/sh
# ============================================================
#  tun 一键安装脚本
#  二进制: sing-box 1.14.1 内嵌 cloudflared (sing-cloudflared CLI)
#  支持: systemd / OpenRC (Alpine, Gentoo, Armbian 等)
#  下载源: https://tun.uvn.kdns.fr/{tun-amd64, tun-arm64, tun-armv7}
#
#  用法:
#    sh install.sh                     交互式安装 (自动下载+注册自启)
#    sh install.sh --token <TOKEN>     免交互安装
#    sh install.sh --no-start          安装但暂不启动
#    sh install.sh --uninstall         卸载
#    sh install.sh --base <URL>        自定义下载前缀
# ============================================================
set -u

BASE_URL="${TUN_DOWNLOAD_BASE:-https://tun.uvn.kdns.fr}"
R="${TUN_INSTALL_ROOT:-}"                # 测试用根前缀(真实安装留空)
LIB_DIR="$R/usr/local/lib/tun"
BIN_LINK="$R/usr/local/bin/tun"
ETC="$R/etc/tun"
TOKEN_FILE="$ETC/token"
ENV_FILE="$ETC/env"
UNIT_FILE="$R/etc/systemd/system/tun.service"
RC_FILE="$R/etc/init.d/tun"
LOG_FILE="$R/var/log/tun.log"
VERSION_FILE="$LIB_DIR/VERSION"
SVC="tun"

ESC=$(printf '\033')
if [ -t 1 ]; then
  RED="${ESC}[31m"; GRN="${ESC}[32m"; YLW="${ESC}[33m"; NC="${ESC}[0m"
else
  RED=""; GRN=""; YLW=""; NC=""
fi
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$YLW" "$NC" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"; exit 1; }

usage() {
  cat <<USAGE
用法: sh $0 [选项]
  --token <TOKEN>   安装时直接写入 Tunnel Token (免交互)
  --no-start        安装但暂不启动服务
  --base <URL>      二进制下载地址前缀 (默认 $BASE_URL)
  --uninstall       卸载 tun
示例:
  sh $0
  sh $0 --token eyJhbGciOi...
  sh $0 --token eyJ... --no-start
USAGE
}

TOKEN=""
NO_START=0
DO_UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --token)
      [ $# -ge 2 ] || die "--token 需要一个参数"
      TOKEN="$2"; shift; shift ;;
    --token=*)
      TOKEN="${1#--token=}"; shift ;;
    --no-start)
      NO_START=1; shift ;;
    --uninstall)
      DO_UNINSTALL=1; shift ;;
    --base)
      [ $# -ge 2 ] || die "--base 需要一个参数"
      BASE_URL="$2"; shift; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "未知参数: $1 (查看帮助: sh $0 --help)" ;;
  esac
done

# ---------- 检测 ----------
arch_detect() {
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7*|armv8*) echo "armv7" ;;
    armv6*)        die "检测到 $m:二进制为 ARMv7 编译,无法在 ARMv6 运行" ;;
    *)             die "不支持的架构: $m" ;;
  esac
}

init_detect() {
  if [ -n "$R" ]; then
    INIT_MODE="${TUN_INIT:-none}"
  elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT_MODE=systemd
  elif command -v rc-service >/dev/null 2>&1 && command -v openrc-run >/dev/null 2>&1; then
    INIT_MODE=openrc
  else
    INIT_MODE=none
  fi
}

# 测试模式(R 非空)下不执行真实服务命令
run_svc() { [ -n "$R" ] && return 0; "$@"; }

fetch() { # $1=url $2=out
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    i=0
    while [ $i -lt 3 ]; do
      wget -q -O "$2" "$1" && return 0
      i=$((i + 1)); sleep 2
    done
    return 1
  else
    die "系统缺少 curl / wget, 请先安装 (apk add curl / apt install curl)"
  fi
}

elf_check() {
  magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

# ---------- 卸载 ----------
do_uninstall() {
  init_detect
  if [ -t 0 ]; then
    printf '确认卸载 tun (二进制+服务, 配置默认保留)? [y/N]: '
    read -r yn
    case "$yn" in y*|Y*) ;; *) echo "已取消"; exit 0 ;; esac
  fi
  if [ "$INIT_MODE" = "systemd" ]; then
    run_svc systemctl stop "$SVC" 2>/dev/null
    run_svc systemctl disable "$SVC" 2>/dev/null
    rm -f "$UNIT_FILE"
    run_svc systemctl daemon-reload 2>/dev/null
  elif [ "$INIT_MODE" = "openrc" ]; then
    run_svc rc-service "$SVC" stop 2>/dev/null
    run_svc rc-update del "$SVC" default 2>/dev/null
    rm -f "$RC_FILE"
  fi
  rm -rf "$LIB_DIR"
  rm -f "$BIN_LINK" "$LOG_FILE" "$R/run/tun.pid"
  if [ -t 0 ]; then
    printf '同时删除配置与 Token (%s)? [y/N]: ' "$ETC"
    read -r yn2
    case "$yn2" in y*|Y*) rm -rf "$ETC"; ok "配置已删除" ;; *) echo "配置已保留: $ETC" ;; esac
  fi
  ok "tun 已卸载"
}

# ---------- 写入服务定义 ----------
write_service_systemd() {
  mkdir -p "$(dirname "$UNIT_FILE")"
  cat > "$UNIT_FILE" <<UNIT_EOF
[Unit]
Description=tun - Cloudflare Tunnel (embedded cloudflared from sing-box 1.14.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
ExecStart=$LIB_DIR/tun run
Restart=always
RestartSec=5
TimeoutStopSec=35
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF
  run_svc systemctl daemon-reload
}

write_service_openrc() {
  mkdir -p "$(dirname "$RC_FILE")"
  if command -v supervise-daemon >/dev/null 2>&1; then
    cat > "$RC_FILE" <<'RC_SUP_EOF'
#!/sbin/openrc-run

description="tun - Cloudflare Tunnel (embedded cloudflared from sing-box 1.14.1)"

supervisor=supervise-daemon
command="/usr/local/lib/tun/tun"
command_args="run"
output_log="/var/log/tun.log"
error_log="/var/log/tun.log"
umask=077

depend() {
	need net
	use dns
}

start_pre() {
	if [ -s /etc/tun/token ]; then
		CF_TUNNEL_TOKEN="$(cat /etc/tun/token)"
		export CF_TUNNEL_TOKEN
	fi
}
RC_SUP_EOF
  else
    cat > "$RC_FILE" <<'RC_SSD_EOF'
#!/sbin/openrc-run

description="tun - Cloudflare Tunnel (embedded cloudflared from sing-box 1.14.1)"

command="/usr/local/lib/tun/tun"
command_args="run"
command_background="yes"
pidfile="/run/tun.pid"
output_log="/var/log/tun.log"
error_log="/var/log/tun.log"
umask=077

depend() {
	need net
	use dns
}

start_pre() {
	if [ -s /etc/tun/token ]; then
		CF_TUNNEL_TOKEN="$(cat /etc/tun/token)"
		export CF_TUNNEL_TOKEN
	fi
}
RC_SSD_EOF
  fi
  chmod 755 "$RC_FILE"
}

# ---------- 管理器(嵌入,独立也可用) ----------
write_manager() {
  mkdir -p "$(dirname "$BIN_LINK")"
  cat > "$BIN_LINK" <<'__TUN_MANAGER_EMBED__'
#!/bin/sh
# ============================================================
#  tun — Cloudflare Tunnel 服务管理器(交互式菜单 + 命令行)
#  二进制: sing-box 1.14.1 内嵌 cloudflared (sing-cloudflared CLI)
#  兼容: systemd / OpenRC / 无 init(手动模式)
#  由 install.sh 自动安装到 /usr/local/bin/tun
# ============================================================
set -u

# ---- 路径(可用环境变量覆盖,便于测试/自定义)----
BINARY="${TUN_BINARY:-/usr/local/lib/tun/tun}"
ETC_DIR="${TUN_ETC:-/etc/tun}"
TOKEN_FILE="${TUN_TOKEN_FILE:-$ETC_DIR/token}"
ENV_FILE="${TUN_ENV_FILE:-$ETC_DIR/env}"
LOG_FILE="${TUN_LOG_FILE:-/var/log/tun.log}"
VERSION_FILE="${TUN_VERSION_FILE:-/usr/local/lib/tun/VERSION}"
PID_FILE="${TUN_PID_FILE:-/run/tun.pid}"
BASE_URL="${TUN_DOWNLOAD_BASE:-https://tun.uvn.kdns.fr}"
SVC="tun"
MGR_VER="1.0.0"
INIT="${TUN_INIT:-}"

# ---- 颜色(非 tty 自动关闭)----
ESC=$(printf '\033')
if [ -t 1 ]; then
  R="${ESC}[31m"; G="${ESC}[32m"; Y="${ESC}[33m"; B="${ESC}[36m"; DIM="${ESC}[2m"; N="${ESC}[0m"
else
  R=""; G=""; Y=""; B=""; DIM=""; N=""
fi

ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[ !! ]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; exit 1; }
hr()   { printf '%s\n' "----------------------------------------------------------------"; }

need_root() {
  [ "$(id -u)" = "0" ] || die "此操作需要 root 权限 (sudo tun $cmd)"
}

# ---- init 系统检测 ----
init_detect() {
  [ -n "$INIT" ] && return 0
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT=systemd
  elif command -v rc-service >/dev/null 2>&1 && command -v openrc-run >/dev/null 2>&1; then
    INIT=openrc
  else
    INIT=none
  fi
}

init_name() {
  init_detect
  case "$INIT" in
    systemd) echo "systemd" ;;
    openrc)  echo "OpenRC" ;;
    *)       echo "无 init(手动模式)" ;;
  esac
}

# ---- 架构检测 ----
arch_detect() {
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)        echo "amd64" ;;
    aarch64|arm64)       echo "arm64" ;;
    armv7*|armv8*)       echo "armv7" ;;
    armv6*)              die "检测到 $m:本版本二进制为 ARMv7 编译,无法在 ARMv6 运行(需 GOARM=6 重编)" ;;
    *)                   die "不支持的架构: $m" ;;
  esac
}

# ---- 服务状态 ----
is_running() {
  init_detect
  case "$INIT" in
    systemd) systemctl is-active --quiet "$SVC" 2>/dev/null ;;
    openrc)  rc-service "$SVC" status >/dev/null 2>&1 ;;
    *)       [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null ;;
  esac
}

is_enabled() {
  init_detect
  case "$INIT" in
    systemd) systemctl is-enabled --quiet "$SVC" 2>/dev/null ;;
    openrc)  rc-update show default 2>/dev/null | grep -q "[[:space:]]$SVC[[:space:]]*|" ;;
    *)       return 1 ;;
  esac
}

svc_start() {
  init_detect
  case "$INIT" in
    systemd) systemctl start "$SVC" ;;
    openrc)  rc-service "$SVC" start ;;
    *)
      is_running && { warn "已在运行"; return 0; }
      [ -s "$TOKEN_FILE" ] || die "未设置 Token, 请先运行: tun token"
      CF_TUNNEL_TOKEN="$(cat "$TOKEN_FILE")" nohup "$BINARY" run >>"$LOG_FILE" 2>&1 &
      echo $! > "$PID_FILE"
      ok "已启动 (pid $(cat "$PID_FILE"))"
      ;;
  esac
}

svc_stop() {
  init_detect
  case "$INIT" in
    systemd) systemctl stop "$SVC" ;;
    openrc)  rc-service "$SVC" stop ;;
    *)
      if [ -s "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
        ok "已停止"
      else
        warn "未在运行"
      fi
      ;;
  esac
}

svc_restart() {
  init_detect
  case "$INIT" in
    systemd) systemctl restart "$SVC" ;;
    openrc)  rc-service "$SVC" restart ;;
    *)       svc_stop; sleep 1; svc_start ;;
  esac
}

# ---- Token ----
token_set() {
  need_root "$@"
  tok="${1:-}"
  if [ -z "$tok" ]; then
    printf '请输入 Tunnel Token: '
    read -r tok
    printf '再次输入确认      : '
    read -r tok2
    [ "$tok" = "$tok2" ] || die "两次输入不一致"
  fi
  [ -n "$tok" ] || die "Token 不能为空"

  mkdir -p "$ETC_DIR"
  printf '%s' "$tok" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  # systemd 走 EnvironmentFile=/etc/tun/env (环境变量方式, token 不会出现在 ps 里)
  case "$tok" in
    *[!A-Za-z0-9=+/_.:-]*)
      esc=$(printf '%s' "$tok" | sed 's/["\\]/\\&/g')
      printf 'CF_TUNNEL_TOKEN="%s"\n' "$esc" > "$ENV_FILE" ;;
    *)
      printf 'CF_TUNNEL_TOKEN=%s\n' "$tok" > "$ENV_FILE" ;;
  esac
  chmod 600 "$ENV_FILE"
  ok "Token 已保存 ($ETC_DIR)"

  if [ -t 0 ]; then
    printf '立即重启服务使生效? [Y/n]: '
    read -r yn
    case "$yn" in n*|N*) ;; *) svc_restart; ok "服务已重启" ;; esac
  elif is_running; then
    svc_restart
    ok "服务已重启"
  fi
}

token_masked() {
  if [ -s "$TOKEN_FILE" ]; then
    t=$(cat "$TOKEN_FILE")
    if [ ${#t} -gt 12 ]; then
      echo "$(printf '%s' "$t" | cut -c1-8)****"
    else
      echo "已设置"
    fi
  else
    echo "未设置"
  fi
}

# ---- 自启 ----
autostart() {
  need_root "$@"
  init_detect
  cur=off; is_enabled && cur=on
  want="${1:-}"
  if [ -z "$want" ]; then
    printf '当前自启: %s,切换为? [on/off]: ' "$cur"
    read -r want
  fi
  case "$want" in
    on|enable)
      case "$INIT" in
        systemd) systemctl enable "$SVC" >/dev/null 2>&1 && ok "开机自启: 已开启" ;;
        openrc)  rc-update add "$SVC" default && ok "开机自启: 已开启" ;;
        *) warn "无 init 系统, 无法注册自启" ;;
      esac ;;
    off|disable)
      case "$INIT" in
        systemd) systemctl disable "$SVC" >/dev/null 2>&1 && ok "开机自启: 已关闭" ;;
        openrc)  rc-update del "$SVC" default 2>/dev/null; ok "开机自启: 已关闭" ;;
        *) warn "无 init 系统" ;;
      esac ;;
    *) die "用法: tun autostart on|off" ;;
  esac
}

# ---- 日志 ----
log_tail() {
  n="${1:-50}"
  init_detect
  case "$INIT" in
    systemd) journalctl -u "$SVC" -n "$n" --no-pager ;;
    openrc|none)
      [ -f "$LOG_FILE" ] || { warn "日志文件不存在: $LOG_FILE"; return 0; }
      tail -n "$n" "$LOG_FILE" ;;
  esac
}

log_follow() {
  init_detect
  echo "实时日志 (Ctrl+C 退出)"
  hr
  case "$INIT" in
    systemd) journalctl -u "$SVC" -n 30 -f ;;
    openrc|none)
      [ -f "$LOG_FILE" ] || { warn "日志文件不存在: $LOG_FILE"; return 0; }
      tail -n 30 -f "$LOG_FILE" ;;
  esac
}

# ---- 更新 ----
fetch() { # $1=url $2=out
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    i=0
    while [ $i -lt 3 ]; do
      wget -q -O "$2" "$1" && return 0
      i=$((i + 1)); sleep 2
    done
    return 1
  else
    die "系统缺少 curl / wget, 无法下载"
  fi
}

elf_check() { # $1=file
  magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

do_update() {
  need_root "$@"
  a=$(arch_detect)
  was=0; is_running && was=1
  tmp="$BINARY.download.$$"
  echo "正在下载 $BASE_URL/tun-$a ..."
  fetch "$BASE_URL/tun-$a" "$tmp" || { rm -f "$tmp"; die "下载失败, 请检查网络 ($BASE_URL/tun-$a)"; }
  elf_check "$tmp" || { rm -f "$tmp"; die "下载内容不是有效的 ELF 二进制, 放弃安装"; }
  [ "$was" = "1" ] && svc_stop
  chmod 755 "$tmp"
  mv -f "$tmp" "$BINARY"
  date -u "+%Y%m%d-%H%M build $a" > "$VERSION_FILE" 2>/dev/null || true
  [ "$was" = "1" ] && svc_restart && ok "服务已重启"
  ok "更新完成"
}

# ---- 卸载 ----
do_uninstall() {
  need_root "$@"
  printf '确认卸载 tun (二进制+服务, 配置默认保留)? [y/N]: '
  read -r yn
  case "$yn" in y*|Y*) ;; *) echo "已取消"; return 0 ;; esac

  init_detect
  is_running && svc_stop
  case "$INIT" in
    systemd)
      systemctl disable "$SVC" >/dev/null 2>&1
      rm -f /etc/systemd/system/tun.service
      systemctl daemon-reload 2>/dev/null ;;
    openrc)
      rc-service "$SVC" stop >/dev/null 2>&1
      rc-update del "$SVC" default 2>/dev/null
      rm -f /etc/init.d/tun ;;
  esac
  rm -f "$BINARY" "$VERSION_FILE" "$PID_FILE"
  rmdir "$(dirname "$BINARY")" 2>/dev/null
  rm -f /usr/local/bin/tun
  printf '同时删除配置和 Token (%s)? [y/N]: ' "$ETC_DIR"
  read -r yn2
  case "$yn2" in y*|Y*) rm -rf "$ETC_DIR"; ok "已删除 $ETC_DIR" ;; *) echo "配置已保留: $ETC_DIR" ;; esac
  ok "tun 已卸载"
}

# ---- 状态 ----
show_status() {
  init_detect
  echo "init 系统 : $(init_name)"
  if is_running; then
    pid=""
    if [ "$INIT" = "systemd" ]; then
      pid=$(systemctl show "$SVC" -p MainPID 2>/dev/null | cut -d= -f2)
    elif [ -s "$PID_FILE" ]; then pid=$(cat "$PID_FILE"); fi
    printf '%s服务状态 : 运行中%s%s\n' "$G" "${pid:+ (pid $pid)}" "$N"
  else
    printf '%s服务状态 : 已停止%s\n' "$R" "$N"
  fi
  if is_enabled; then
    printf '开机自启 : %s已启用%s\n' "$G" "$N"
  else
    printf '开机自启 : %s未启用%s\n' "$Y" "$N"
  fi
  echo "Token    : $(token_masked)"
  echo "日志     : $(if [ "$INIT" = "systemd" ]; then echo 'journalctl -u tun'; else echo "$LOG_FILE"; fi)"
  if [ -f "$BINARY" ]; then
    size=$(du -k "$BINARY" 2>/dev/null | cut -f1)
    echo "二进制   : $BINARY (${size}KB)"
  else
    printf '%s二进制   : 缺失!%s\n' "$R" "$N"
  fi
  [ -f "$VERSION_FILE" ] && echo "版本     : $(cat "$VERSION_FILE")"
  return 0
}

# ---- 菜单 ----
menu() {
  while :; do
    init_detect
    if is_running; then
      st="${G}● 运行中${N}"
    else
      st="${R}○ 已停止${N}"
    fi
    is_enabled && en="${G}开${N}" || en="${Y}关${N}"
    hr
    printf "  tun · Cloudflare Tunnel 管理菜单  ${DIM}[%s]${N}\n" "$(init_name)"
    printf "  服务: %b   自启: %b   Token: %s\n" "$st" "$en" "$(token_masked)"
    hr
    cat <<'MENU'
   1. 启动服务          2. 停止服务
   3. 重启服务          4. 运行状态
   5. 实时日志          6. 最近日志(50 行)
   7. 设置/修改 Token   8. 开机自启 开/关
   9. 更新二进制        10. 卸载
   0. 退出
MENU
    hr
    printf '请选择 [0-10]: '
    read -r c || { echo; exit 0; }
    case "$c" in
      1) svc_start ;;
      2) svc_stop ;;
      3) svc_restart ;;
      4) show_status ;;
      5) log_follow ;;
      6) log_tail 50 ;;
      7) token_set "" ;;
      8) if is_enabled; then autostart off; else autostart on; fi ;;
      9) do_update ;;
      10) do_uninstall && exit 0 ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    printf '\n按回车返回菜单...'
    read -r _ || exit 0
    printf '%s[2J%s[H' "$ESC" "$ESC"
  done
}

# ---- 帮助 ----
usage() {
  cat <<USAGE
tun — Cloudflare Tunnel 管理器 (v$MGR_VER)

用法:
  tun                  进入交互式管理菜单
  tun start|stop|restart|status   服务控制
  tun log [N]          查看最近 N 行日志 (默认 50)
  tun logf             实时滚动日志
  tun token [TOKEN]    设置/修改 Tunnel Token
  tun autostart on|off 开机自启 开/关
  tun update           从 $BASE_URL 更新二进制
  tun run [args...]    直接运行二进制 (透传参数)
  tun version          显示版本信息
  tun uninstall        卸载
  tun help             本帮助

服务实现: $(init_name)
USAGE
}

version() {
  echo "管理器   : tun v$MGR_VER"
  echo "init     : $(init_name)"
  echo "架构     : $(uname -m)"
  [ -f "$VERSION_FILE" ] && echo "二进制   : $(cat "$VERSION_FILE")"
  [ -f "$BINARY" ] && echo "路径     : $BINARY"
  command -v sha256sum >/dev/null 2>&1 && [ -f "$BINARY" ] && \
    echo "SHA256   : $(sha256sum "$BINARY" | cut -c1-16)..."
}

# ---- 入口分发 ----
cmd="${1:-menu}"

# 写操作需要 root: 未 root 时自动通过 sudo 重执行
case "$cmd" in
  start|stop|restart|token|autostart|update|uninstall)
    if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then
      exec sudo sh "$0" "$@"
    fi
    ;;
esac

case "$cmd" in
  menu)      menu ;;
  start)     need_root; svc_start ;;
  stop)      need_root; svc_stop ;;
  restart)   need_root; svc_restart ;;
  status)    show_status ;;
  log)       shift; log_tail "${1:-50}" ;;
  logf)      log_follow ;;
  token)     shift; token_set "${1:-}" ;;
  autostart) shift; autostart "${1:-}" ;;
  update)    need_root; do_update ;;
  run)       shift; exec "$BINARY" run "$@" ;;
  version|-v|--version) version ;;
  uninstall) do_uninstall ;;
  help|-h|--help) usage ;;
  *)         usage; echo; die "未知命令: $cmd" ;;
esac
__TUN_MANAGER_EMBED__
  chmod 755 "$BIN_LINK"
}


# ---------- 主流程 ----------
[ "$DO_UNINSTALL" = "1" ] && { do_uninstall; exit 0; }

if [ -z "$R" ] && [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo sh "$0" "$@"
  fi
  die "安装需要 root 权限"
fi

init_detect
ARCH=$(arch_detect)

cat <<BANNER

  ┌─────────────────────────────────────────────┐
  │   tun · Cloudflare Tunnel 一键安装          │
  │   内嵌版 cloudflared (sing-box 1.14.1)      │
  └─────────────────────────────────────────────┘
  架构: $ARCH    init: $INIT_MODE    下载源: $BASE_URL

BANNER

# 已在运行则先停
WAS_RUNNING=0
if [ "$INIT_MODE" = "systemd" ] && systemctl is-active --quiet "$SVC" 2>/dev/null; then
  WAS_RUNNING=1
elif [ "$INIT_MODE" = "openrc" ] && rc-service "$SVC" status >/dev/null 2>&1; then
  WAS_RUNNING=1
fi
[ "$WAS_RUNNING" = "1" ] && { warn "检测到旧版本服务正在运行, 先停止..."; run_svc systemctl stop "$SVC" 2>/dev/null; run_svc rc-service "$SVC" stop 2>/dev/null; }

# 1. 目录
mkdir -p "$LIB_DIR" "$ETC" "$(dirname "$BIN_LINK")" "$(dirname "$LOG_FILE")"

# 2. 下载二进制
echo "下载二进制: $BASE_URL/tun-$ARCH ..."
TMP_DL="$LIB_DIR/.tun.download.$$"
fetch "$BASE_URL/tun-$ARCH" "$TMP_DL" || { rm -f "$TMP_DL"; die "下载失败: $BASE_URL/tun-$ARCH"; }
elf_check "$TMP_DL" || { rm -f "$TMP_DL"; die "下载内容不是有效的 ELF 二进制"; }
chmod 755 "$TMP_DL"
mv -f "$TMP_DL" "$LIB_DIR/tun"
date -u "+%Y%m%d-%H%M build $ARCH" > "$VERSION_FILE" 2>/dev/null || true
ok "二进制已安装: $LIB_DIR/tun"

# 3. Token
if [ -n "$TOKEN" ]; then
  printf '%s' "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  case "$TOKEN" in
    *[!A-Za-z0-9=+/_.:-]*)
      esc=$(printf '%s' "$TOKEN" | sed 's/["\\]/\\&/g')
      printf 'CF_TUNNEL_TOKEN="%s"\n' "$esc" > "$ENV_FILE" ;;
    *) printf 'CF_TUNNEL_TOKEN=%s\n' "$TOKEN" > "$ENV_FILE" ;;
  esac
  chmod 600 "$ENV_FILE"
  ok "Token 已写入 (来自 --token 参数)"
elif [ -s "$TOKEN_FILE" ]; then
  ok "沿用已有 Token: $TOKEN_FILE"
elif [ -t 0 ]; then
  printf '请输入 Tunnel Token (留空跳过, 之后可用 tun token 设置): '
  read -r TOKEN
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    case "$TOKEN" in
      *[!A-Za-z0-9=+/_.:-]*)
        esc=$(printf '%s' "$TOKEN" | sed 's/["\\]/\\&/g')
        printf 'CF_TUNNEL_TOKEN="%s"\n' "$esc" > "$ENV_FILE" ;;
      *) printf 'CF_TUNNEL_TOKEN=%s\n' "$TOKEN" > "$ENV_FILE" ;;
    esac
    chmod 600 "$ENV_FILE"
    ok "Token 已写入"
  fi
else
  warn "未提供 Token (非交互模式)。安装后运行: sudo tun token"
fi
TOKEN_OK=0; [ -s "$TOKEN_FILE" ] && TOKEN_OK=1

# 4. 服务定义
if [ "$INIT_MODE" = "systemd" ]; then
  write_service_systemd
  ok "systemd 服务已写入: $UNIT_FILE"
elif [ "$INIT_MODE" = "openrc" ]; then
  write_service_openrc
  ok "OpenRC 服务已写入: $RC_FILE"
else
  warn "未识别 init 系统, 跳过服务注册 (可用 tun start 手动运行)"
fi

# 5. 管理器
write_manager
[ -x "$BIN_LINK" ] || die "管理器写入失败 ($BIN_LINK) —— 安装中止"
ok "管理命令已注册: $BIN_LINK"

# 6. 自启 + 启动
if [ "$INIT_MODE" = "systemd" ]; then
  run_svc systemctl enable "$SVC" >/dev/null 2>&1 && ok "开机自启: 已启用"
elif [ "$INIT_MODE" = "openrc" ]; then
  run_svc rc-update add "$SVC" default >/dev/null 2>&1 && ok "开机自启: 已启用"
fi

if [ "$NO_START" = "1" ]; then
  warn "按 --no-start 要求, 暂不启动。之后运行: sudo tun start"
elif [ "$TOKEN_OK" = "1" ]; then
  if [ "$INIT_MODE" = "systemd" ]; then
    run_svc systemctl restart "$SVC" && ok "服务已启动"
  elif [ "$INIT_MODE" = "openrc" ]; then
    run_svc rc-service "$SVC" start && ok "服务已启动"
  else
    :
  fi
else
  warn "缺少 Token, 服务暂不启动。运行 sudo tun token 设置后自动重启"
fi

# 7. 摘要
if [ "$INIT_MODE" = "systemd" ]; then LOG_HINT="journalctl -u tun -f"; else LOG_HINT="$LOG_FILE"; fi
cat <<SUMMARY

  安装完成 ✔
  ----------------------------------------
  管理入口 : tun          (直接回车进交互菜单)
  手动控制 : tun start | stop | restart | status
  日志     : tun log | tun logf     [$LOG_HINT]
  Token    : tun token <TOKEN>
  自启开关 : tun autostart on | off
  更新     : tun update
  卸载     : tun uninstall
  ----------------------------------------
SUMMARY
