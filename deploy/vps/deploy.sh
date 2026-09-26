#!/usr/bin/env bash
#
# deploy.sh — build + phát hành 1 môi trường trên VPS (pm2, KHÔNG Docker).
#
# Mô hình: MỘT thư mục git clone thường, build tại chỗ. Không mirror bare, không
# releases/, không symlink `current`. CI gọi:
#
#   cd /opt/simple-next-<target> && bash deploy/vps/deploy.sh <branch> <prod|staging>
#
# Tham số 1 nhận tên nhánh, tag, hoặc SHA commit (để lùi về đúng bản tốt).
#
# ĐÁNH ĐỔI so với mô hình nhiều release — đọc trước khi quyết định đổi:
# - `npm run build` ghi đè `.next` lúc app đang đọc ⇒ phải `pm2 stop` TRƯỚC ⇒
#   **downtime = thời gian build**. `npm ci` không còn là nguồn downtime vì chỉ
#   chạy khi `package-lock.json` thật sự đổi.
# - Không giữ bản cũ trên đĩa ⇒ rollback tự động phải **build lại**.
# Đổi lại: không tốn ~300MB mỗi bản, không có symlink trỏ treo, `git checkout`
# chính là trạng thái thật của app.
#
# Biến môi trường (đều có mặc định):
#   VPS_BASE       — thư mục app (/opt/simple-next-<target>)
#   VPS_SECRETS    — thư mục file env, NGOÀI repo (/opt/simple-next-secrets)
#   HEALTH_TIMEOUT — giây chờ /api/health (mặc định 90)

set -euo pipefail

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "LỖI: $*" >&2; exit 1; }

# ── Input ─────────────────────────────────────────────────────────────────────
BRANCH="${1:-}"
TARGET="${2:-}"

case "$TARGET" in
  prod)
    BRANCH="${BRANCH:-main}"
    PORT="${PROD_PORT:-3119}"
    PM2_NAME="simple-next-prod"
    ENV_NAME="prod"
    ;;
  staging)
    BRANCH="${BRANCH:-dev}"
    PORT="${STAGING_PORT:-3118}"
    PM2_NAME="simple-next-staging"
    ENV_NAME="staging"
    ;;
  *)
    die "cách dùng: $0 <branch> <prod|staging>   (vd: $0 dev staging)"
    ;;
esac

APP="${VPS_BASE:-/opt/simple-next-$ENV_NAME}"
SECRETS="${VPS_SECRETS:-/opt/simple-next-secrets}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
ENV_FILE="$SECRETS/$ENV_NAME.env"
HEALTH_URL="http://127.0.0.1:$PORT/api/health"
ECOSYSTEM="$APP/deploy/vps/ecosystem.config.cjs"

# ── Preflight ─────────────────────────────────────────────────────────────────
[ -d "$APP/.git" ] || die "$APP chưa git clone — xem docs/deploy-vps.md §2.3"
command -v node >/dev/null || die "chưa cài Node.js (cần >=20, xem docs §2.1)"
command -v pm2  >/dev/null || die "chưa cài pm2 (npm i -g pm2)"

# File env là TUỲ CHỌN ở app này (không có secret nào). Nếu có thì đọc để bơm vào
# process — thiếu file chỉ là cảnh báo, không chặn deploy.
if [ -f "$ENV_FILE" ]; then
  log "đọc env từ $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  log "không có $ENV_FILE — chạy với env mặc định (không sao cho app này)"
fi

# ── Chọn commit đích ──────────────────────────────────────────────────────────
# BRANCH nhận cả 3 dạng: tên nhánh (`main`), tag, hoặc SHA commit đã có trong clone
# (dùng để lùi về đúng một bản tốt). Fetch TẤT CẢ branch trước nên SHA cũ cũng có
# sẵn — không phụ thuộc server bật allowAnySHA1InWant.
git -C "$APP" fetch --prune --tags origin
SHA="$(git -C "$APP" rev-parse --verify --quiet "origin/$BRANCH^{commit}" || true)"
if [ -z "$SHA" ]; then
  SHA="$(git -C "$APP" rev-parse --verify --quiet "$BRANCH^{commit}" || true)"
fi
[ -n "$SHA" ] || die "không tìm thấy '$BRANCH' — không có nhánh/tag cùng tên trên remote, cũng không phải SHA có trong clone"
HEAD_SHA="$(git -C "$APP" rev-parse --verify --quiet HEAD || true)"
log "đích: $BRANCH @ $SHA · hiện tại: ${HEAD_SHA:-<chưa có>}"

if [ "$HEAD_SHA" = "$SHA" ] && curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
  log "đã ở $SHA và app khỏe — không làm gì (idempotent)"
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
start_app() {
  # `delete` + `start` thay vì `reload`: xoá hẳn rồi start chắc chắn đọc lại cwd và
  # env từ ecosystem.config.cjs.
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  SIMPLE_NEXT_PM2_NAME="$PM2_NAME" \
  SIMPLE_NEXT_CWD="$APP" \
  SIMPLE_NEXT_PORT="$PORT" \
  SIMPLE_NEXT_ENV_FILE="$ENV_FILE" \
    pm2 start "$ECOSYSTEM" --only "$PM2_NAME" --update-env
  pm2 save >/dev/null
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Cổng an toàn duy nhất: KHÔNG BAO GIỜ để VPS ở trạng thái "deploy fail xong rồi
# bỏ luôn, app chết không lời giải thích". Mọi nhánh fail đều quay về commit trước.
fail_and_recover() {
  log "$1"
  if [ -z "$HEAD_SHA" ]; then
    log "đây là deploy đầu tiên — chưa có bản trước để quay về. App sẽ KHÔNG chạy."
    log "xử lý xong thì chạy lại: bash deploy/vps/deploy.sh $BRANCH $ENV_NAME"
  elif [ "$HEAD_SHA" = "$SHA" ]; then
    log "HEAD đã là $SHA và app vẫn không khỏe ⇒ lỗi KHÔNG nằm ở commit này."
    log "kiểm tra env và nginx rồi chạy lại deploy.sh"
  else
    log "quay về $HEAD_SHA — build lại từ đầu (mô hình 1 thư mục không giữ bản cũ)"
    if git -C "$APP" checkout -f --detach "$HEAD_SHA" \
      && (cd "$APP" && npm ci --prefer-offline --no-audit --fund=false) \
      && rm -rf "$APP/.next" \
      && (cd "$APP" && npm run build) \
      && start_app \
      && wait_healthy; then
      log "đã khôi phục, app chạy lại $HEAD_SHA"
    else
      log "KHÔNG khôi phục được — xem 'pm2 logs $PM2_NAME --lines 80' và nhật ký build"
    fi
  fi
  exit 1
}

# ── Deploy ────────────────────────────────────────────────────────────────────
# DỪNG APP TRƯỚC MỌI THỨ ĐỘNG vào thư mục này: `git checkout` đổi file nguồn,
# `npm ci` xoá node_modules, `npm run build` ghi đè `.next` — tất cả đều là thư mục
# mà `next start` đang đọc. Giữ app chạy song song sẽ ra 500 lẻ tẻ giữa lúc deploy.
log "pm2 stop $PM2_NAME"
pm2 stop "$PM2_NAME" >/dev/null 2>&1 || true

log "checkout $SHA"
git -C "$APP" checkout -f --detach "$SHA" || fail_and_recover "checkout thất bại"

# Deploy lùi về commit quá cũ (trước khi có deploy/vps/) sẽ không có file này — báo
# ngay chứ đừng build xong mới fail ở pm2 start.
[ -f "$ECOSYSTEM" ] || fail_and_recover "commit $SHA không có deploy/vps/ecosystem.config.cjs"

# Cài dependency CHỈ khi thật sự cần: lockfile đổi so với commit đang chạy, hoặc
# node_modules chưa có. Đa số deploy chỉ đổi code thuần → bỏ qua npm ci, downtime
# chỉ còn thời gian build.
#
# Bỏ hẳn npm ci thì lúc commit mới thêm dependency, app chạy trên node_modules cũ:
# build xanh, /api/health xanh (nó không import phần mới), rồi lúc user bấm vào
# chức năng mới mới MODULE_NOT_FOUND. Lúc nó chạy thì `npm ci` vẫn cần, và phải
# `ci` chứ không phải `install` để cây trên VPS khớp đúng cây CI đã test.
if [ -d "$APP/node_modules" ] && [ -n "$HEAD_SHA" ] &&
   git -C "$APP" diff --quiet "$HEAD_SHA" "$SHA" -- package.json package-lock.json; then
  log "lockfile không đổi — bỏ qua npm ci, giữ nguyên node_modules"
else
  log "npm ci (lockfile đổi hoặc chưa có node_modules)"
  (cd "$APP" && npm ci --prefer-offline --no-audit --fund=false) ||
    fail_and_recover "npm ci thất bại"
fi

# Hai biến này được INLINE vào bundle lúc build ⇒ trang `/` sẽ hiện đúng commit và
# thời điểm build. Đây là cách nhanh nhất để biết server đang chạy bản nào.
export NEXT_PUBLIC_GIT_SHA="${SHA:0:7}"
export NEXT_PUBLIC_BUILD_TIME="$(date -Iseconds)"

# Xoá `.next` cũ TRƯỚC khi build. `next build` ghi đè nên build chồng lên build cũ
# thường ổn, nhưng đã gặp `PageNotFoundError: Cannot find module for page:
# /_document` khi cache `.next` của commit trước còn sót lại. App đã `pm2 stop` ở
# trên nên xoá ở đây không tốn downtime; app nhỏ nên build lại từ đầu chỉ vài chục
# giây. Đổi lại deploy không bao giờ dính build dở dang của lần trước.
rm -rf "$APP/.next"

log "npm run build"
(cd "$APP" && npm run build) || fail_and_recover "npm run build thất bại"

[ -d "$APP/.next/static" ] || fail_and_recover "thiếu .next/static"

log "pm2 start $PM2_NAME (port $PORT)"
start_app || fail_and_recover "pm2 start lỗi"

log "chờ $HEALTH_URL (tối đa ${HEALTH_TIMEOUT}s)"
wait_healthy || fail_and_recover "KHÔNG khỏe sau ${HEALTH_TIMEOUT}s"

log "OK — $PM2_NAME đang chạy $SHA"
curl -fsS --max-time 5 "$HEALTH_URL" && echo
log "xong — truy cập http://IP-VPS:$( [ "$ENV_NAME" = prod ] && printf 8019 || printf 8018 )"
