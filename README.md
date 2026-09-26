# simple-next

App Next.js tối giản, mục đích chính là **test deploy lên VPS** qua GitHub Actions →
SSH → VPS (pm2 + nginx, không Docker), cùng mô hình với `mom-baby-app`.

| Môi trường | Nhánh | nginx | Next.js | URL |
|---|---|---|---|---|
| staging | `dev` | `:8018` | `127.0.0.1:3118` | `http://<IP-VPS>:8018` |
| prod | `main` | `:8019` | `127.0.0.1:3119` | `http://<IP-VPS>:8019` |

- `/` — server-rendered mỗi request, hiện Node version, uptime, version + commit + thời
  điểm build của bản đang chạy và các header nhận được từ nginx.
- `/api/health` — JSON `{ status, version, sha, builtAt, uptime, node, time }`, dùng cho
  health check và cho `deploy.sh` quyết định rollback.

### Biết app đang chạy commit nào

```bash
curl -fsS http://127.0.0.1:3119/api/health    # trên VPS (prod)
curl -fsS http://<IP-VPS>:8019/api/health     # từ ngoài
```

```json
{
  "status": "ok",
  "version": "0.1.0",
  "sha": "fc70613",
  "builtAt": "2026-09-27T01:26:18+07:00",
  "uptime": 6,
  "node": "v26.5.0",
  "time": "2026-09-27T01:26:47.665Z"
}
```

`sha` và `builtAt` được `deploy.sh` export **trước** `npm run build`, nên Next **inline
chúng vào bundle lúc build** — không đọc lúc runtime. Nhờ vậy hai giá trị này luôn mô
tả đúng code đang chạy, kể cả sau `pm2 restart` mà không rebuild, và không bị lệch khi
repo được `git checkout` sang commit khác. Build không đi qua `deploy.sh` (ví dụ ở máy
dev) thì `sha` và `builtAt` là `null` — đó là câu trả lời trung thực, không phải lỗi.

`version` đọc từ `package.json`, không hardcode lần 2. Nguồn sự thật cho cả `/` và
`/api/health` là [`lib/buildInfo.ts`](./lib/buildInfo.ts).

## Local

```bash
npm install
cp .env.example .env       # tuỳ chọn
npm run dev                # http://localhost:3000
```

## Deploy qua GitHub Actions

Push vào `dev` → staging · vào `main` → prod. Workflow không build, chỉ SSH vào VPS và
gọi `deploy/vps/deploy.sh` (build tại chỗ trên VPS). Setup VPS một lần, secrets, và
cách rollback: **[`docs/deploy-vps.md`](./docs/deploy-vps.md)**.

Tóm tắt:

```bash
# 1. trên VPS (một lần)
sudo git clone https://github.com/zymuk/Simple-Next.Js.git /opt/simple-next-prod
sudo git clone https://github.com/zymuk/Simple-Next.Js.git /opt/simple-next-staging
#    + deploy key read-only trong GitHub, nginx, pm2 startup — xem docs §2

# 2. GitHub → Settings → Secrets and variables → Actions:
#    secrets VPS_HOST, VPS_USER, SSH_PRIVATE_KEY (xem docs §3)

# 3. push
git checkout -b dev && git push -u origin dev    # → staging
git checkout main && git push                    # → prod
```

Deploy là idempotent: chạy lại với commit đang chạy và app khoẹe thì không đụng gì.
Mọi nhánh fail (build hỏng, `/api/health` không khoẹe) đều tự checkout về commit trước,
build lại, start lại rồi trả exit 1. Deploy cũng chạy **kể cả khi gate đỏ** — gate đỏ là
cảnh báo để bạn quyết định, không phải chốt chặn.

## Deploy thủ công / rollback

```bash
cd /opt/simple-next-prod
bash deploy/vps/deploy.sh main prod              # hoặc <tên-nhánh> / <commit-sha>
```

Kiểm tra:

```bash
curl -fsS http://127.0.0.1:3119/api/health       # từ VPS
pm2 logs simple-next-prod --lines 50
```

## Scripts

| Script | Việc |
|---|---|
| `npm run dev` | dev server |
| `npm run build` | production build (không cần env) |
| `npm start` | chạy bản build, nhận `PORT` từ env |
| `npm run typecheck` | `tsc --noEmit` (gate của workflow) |

## Cấu trúc deploy

```
.github/workflows/deploy.yml        push dev/main → gate (typecheck + build + audit)
                                   → SSH vào VPS chạy deploy.sh; if: !cancelled()
                                   để deploy vẫn chạy khi gate đỏ
deploy/vps/deploy.sh               git fetch → checkout → npm ci (khi lockfile đổi) →
                                   pm2 stop → rm -rf .next → build → pm2 start →
                                   chờ health → rollback
deploy/vps/ecosystem.config.cjs    cấu hình pm2, dùng chung cho prod & staging
deploy/vps/nginx.conf              reverse proxy :8019 → 3119, :8018 → 3118
docs/deploy-vps.md                 hướng dẫn VPS + secrets + rollback
```

## Ghi chú

- App không có secret nào; `/opt/simple-next-secrets/*.env` là tuỳ chọn (chỉ để đặt
  `APP_MESSAGE`). Thiếu file không làm deploy fail.
- `PORT` không set trong file env trên VPS — `deploy.sh` truyền theo môi trường
  (prod 3119, staging 3118) qua `ecosystem.config.cjs`.
- Muốn nhẹ hơn nữa thì thêm `output: "standalone"` vào `next.config.ts` và đổi
  `ecosystem.config.cjs` sang `node .next/standalone/server.js` (nhớ copy
  `.next/static` và `public` vào `standalone`). Cách hiện tại đơn giản và đủ test.
