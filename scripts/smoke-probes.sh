# scripts/smoke.sh 的探测钩子，兼容两套冒烟环境（dev.sh smoke 和正式 e2e 套件）：
# 两边都给的只有 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN。
# SMOKE_WEB_URL 两边含义不同（dev 侧带入口路径，e2e 侧只有 origin），拼应用接口前一律现场取 origin；
# 不用 dev.sh probes 专有的 dweb/web_get/SMOKE_WEB_ORIGIN（正式套件没有，set -u 会挂）。
# sso=proxy：带核心会话开应用页面，网关注入 Remote-User，应用自动登录并给 Django 会话；
# /api/ 不做代登录（上游设计），靠应用会话认证。无 MCP，清单不声明：MCP=0。
# shellcheck shell=bash disable=SC2034  # SSO/MCP 由冒烟套件读取
SSO=proxy
MCP=0

web_assert() { grep -q 'Baby Buddy'; }   # 每页 <title> 都带上游名

_bb_origin() { # web_url 可能带路径和查询，拼 API 前取 origin
  local u="${SMOKE_WEB_URL%%\?*}" rest="${SMOKE_WEB_URL#*://}"
  printf '%s://%s' "${u%%://*}" "${rest%%/*}"
}

_bb_session() { # jar 里保证有核心会话（-b 保留 jar 里已有的 cookie，只写 -c 会把别的域的会话抹掉）
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_BASE:-}" && -n "${SMOKE_TOKEN:-}" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：SMOKE_JAR/SMOKE_BASE/SMOKE_TOKEN/SMOKE_WEB_URL" >&2; return 1; }
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=${SMOKE_TOKEN}" "$SMOKE_BASE/_wonton/login" ||
    { echo "主人令牌登录不了核心" >&2; return 1; }
}

_bb_api() { # <路径> [curl 参数…]：带用户会话调应用接口。
  # dweb 两边签名不同：dev 套件已带 --jar，e2e 套件是裸 dev.sh web（用自己的默认 jar）。
  # 显式再传 --jar：让取 csrftoken 的 jar 和发请求用的 jar 永远是同一份（e2e 实测：
  # 不传的话 POST 用默认 jar 的会话，X-CSRFToken 却来自 SMOKE_JAR，Django 报 header incorrect）。
  if declare -F dweb >/dev/null; then
    if [[ -n "${SMOKE_JAR:-}" ]]; then
      dweb --jar "$SMOKE_JAR" "$@"
    else
      dweb "$@"
    fi
    return
  fi
  _bb_session || return 1
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' -L "$(_bb_origin)/" ||
    { echo "走不通应用入口（代登录）" >&2; return 1; }
  curl -sS --noproxy '*' --max-time 120 -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$@" "$(_bb_origin)$1"
}

identity_check() { # 应用自己的"当前用户"接口认出的是主人
  local profile
  profile="$(_bb_api /api/profile)" || { echo "profile 接口失败：$profile"; return 1; }
  jq -e --arg owner "${SMOKE_OWNER:-}" '.user.username == $owner' <<<"$profile" >/dev/null ||
    { echo "profile 没认出 $SMOKE_OWNER：$(head -c 200 <<<"$profile")"; return 1; }
}

# 会话认证的写请求要带 CSRF 头（实测 v2.11.0：jar 里只有应用子域发 csrftoken/sessionid，
# 核心发 wonton_session（父域）、网关发 wonton_app（子域））。
# 若日后出现别的同名 cookie，Django 读的是请求里最后出现的那份；挑域最长的总能对上应用子域。
_csrf() {
  awk -F'\t' '$6=="csrftoken" {
    d = $1; sub(/^#HttpOnly_/, "", d)
    if (length(d) > length(best)) best = $7
  } END {print best}' "${SMOKE_JAR:?}"
}

data_write() {
  local marker time child csrf out code
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "缺 SMOKE_STATE" >&2; return 1; }
  marker="probe-$(date +%s)-$RANDOM"
  # Z 结尾：DRF 的 ISO 解析认它，也不用担心 + 在 URL 查询串里被解成空格。
  time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # 先 GET 一次：应用会话（和它带的 csrftoken）建好后再取 token，POST 才能配上。
  out="$(_bb_api /api/children/ -w '\n%{http_code}')" || { echo "列不出宝宝：$out"; return 1; }
  code="${out##*$'\n'}"
  [[ "$code" == 200 ]] || { echo "列宝宝不是 200（$code）：$out"; return 1; }
  child="$(jq -r '.results[0].id // empty' <<<"${out%$'\n'*}")"
  csrf="$(_csrf)"
  if [[ -z "$child" ]]; then
    out="$(_bb_api /api/children/ -X POST -H 'Content-Type: application/json' -H "X-CSRFToken: $csrf" \
      -d '{"first_name":"宝宝","birth_date":"2026-01-01"}' -w '\n%{http_code}')" ||
      { echo "建宝宝请求失败：$out"; return 1; }
    code="${out##*$'\n'}"
    child="$(jq -r '.id // empty' <<<"${out%$'\n'*}")"
    [[ "$code" == 201 && -n "$child" ]] || { echo "建宝宝没成（$code）：$out"; return 1; }
  fi
  out="$(_bb_api /api/notes/ -X POST -H 'Content-Type: application/json' -H "X-CSRFToken: $csrf" \
    -d "{\"child\":$child,\"note\":\"$marker\",\"time\":\"$time\"}" -w '\n%{http_code}')" ||
    { echo "写记录请求失败：$out"; return 1; }
  code="${out##*$'\n'}"
  jq -e --arg m "$marker" '.note == $m' <<<"${out%$'\n'*}" >/dev/null ||
    { echo "写记录没成（$code）：$(head -c 200 <<<"$out")"; return 1; }
  # 接口不支持按内容搜记录，把写入时间一起存下，data_check 按时间过滤后逐条比对。
  jq -nc --arg m "$marker" --arg t "$time" '{marker:$m,time:$t}' >"$SMOKE_STATE"
}

data_check() {
  local state marker time found
  state="${SMOKE_STATE:?}"
  marker="$(jq -r .marker "$state")"
  time="$(jq -r .time "$state")"
  found="$(_bb_api "/api/notes/?date_min=$time")" || { echo "列记录失败：$found"; return 1; }
  jq -e --arg m "$marker" '[.results[].note] | index($m) != null' <<<"$found" >/dev/null ||
    { echo "重装后找不到标记 $marker：$(head -c 200 <<<"$found")"; return 1; }
}
