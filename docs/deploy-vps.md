# Triển khai simple-next lên VPS Ubuntu (pm2 + nginx, không Docker)

Next.js 15 App Router, chạy bằng `next start` dưới pm2, nginx làm reverse proxy.
Cùng mô hình với `mom-baby-app`, khác ở chỗ app rất nhỏ, cổng riêng để chạy song song
trên cùng VPS, và CI là **GitHub Actions** (`.github/workflows/deploy.yml`).

## 1. Kiến trúc

| Môi trường | Nhánh | nginx | Next.js | URL |
|---|---|---|---|---|
| staging | `dev` | `:8018` | `127.0.0.1:3118` | `http://<IP-VPS>:8018` |
| prod | `main` | `:8019` | `127.0.0.1:3119` | `http://<IP-VPS>:8019` |

Cổng khác `mom-baby-app` (`:80 → 3000`, `:8001 → 3002`) để không đụng nhau.

App chỉ lắng nghe trên loopback → **không truy cập trực tiếp được**, mọi request đi qua
nginx (giữ `X-Real-IP` / `X-Forwarded-Proto` mà trang `/` hiển thị để kiểm chứng).

Mỗi môi trường là **một thư mục git clone thường**, không chung nhau:

```
/opt/simple-next-prod/          (hoặc -staging)
├── .git/            repo bình thường, HEAD = commit đang chạy (detached)
├── node_modules/    cài lại khi lockfile đổi
├── .next/           build tại chỗ
└── deploy/vps/      script + ecosystem.config.cjs + nginx.conf (nằm trong repo)
/opt/simple-next-secrets/        (TUỲ CHỌN — app này không có secret)
├── prod.env
└── staging.env
```

`deploy.sh` làm đúng: `git fetch` → `git checkout <commit>` → (`npm ci` **chỉ khi
lockfile đổi**) → `pm2 stop` → `rm -rf .next` → `npm run build` → `pm2 start` → chờ
`/api/health`. Mọi nhánh fail đều quay về commit trước rồi build lại.

`rm -rf .next` trước khi build là cố ý: build chồng lên `.next` của commit trước từng
gặp `PageNotFoundError: Cannot find module for page: /_document` (app vẫn `pm2 stop`
rồi nên không tốn downtime, và app này build lại chỉ vài chục giây).

**Đánh đổi của mô hình build-tại-chỗ:** `npm run build` ghi đè `.next` của đúng thư mục
app đang chạy nên phải `pm2 stop` trước ⇒ downtime mỗi lần deploy bằng thời gian build
(với app này chỉ ~15–30s, không phải 3–5 phút như mom-baby), và rollback cũng phải build
lại. Đổi lại không tốn ~300MB mỗi bản, không có symlink trỏ treo.

`npm ci` **không** chạy mỗi lần — chỉ khi `package.json`/`package-lock.json` đổi so với
commit đang chạy, hoặc `node_modules` chưa có. Bỏ hẳn `npm ci` thì sai: commit mới thêm
dependency sẽ chạy trên `node_modules` cũ — build xanh, `/api/health` xanh, rồi lúc dùng
chức năng mới mới `MODULE_NOT_FOUND`.

Thư mục clone ở trạng thái **detached HEAD** (đúng commit workflow deploy). Đừng
`git pull` tay trong thư mục này — dùng `deploy.sh` để deploy lại qua đúng một đường.

## 2. Chuẩn bị VPS (một lần)

### 2.1 Công cụ

```bash
sudo apt update && sudo apt install -y nginx git curl
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm i -g pm2

mkdir -p ~/.ssh && chmod 700 ~/.ssh
# KHÔNG dùng `echo key >> known_hosts` — dùng ssh-keyscan:
ssh-keyscan <IP-VPS> >> ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts
```

`known_hosts` ở đây là của **user bạn chạy pm2**, không phải root. Nếu dùng user khác để
chạy app thì copy sang `~user/`.

### 2.2 Swap

Bắt buộc nếu VPS còn app khác đang chạy và không có swap:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### 2.3 Thư mục app + deploy key

```bash
# clone thường (KHÔNG --bare): đây chính là nơi app chạy, build tại chỗ
sudo git clone https://github.com/zymuk/Simple-Next.Js.git /opt/simple-next-prod
sudo git clone https://github.com/zymuk/Simple-Next.Js.git /opt/simple-next-staging

# deploy key để `git fetch` được khi workflow đẩy commit mới
ssh-keygen -t ed25519 -N '' -C simple-next-deploy -f ~/.ssh/simple_next_deploy
cat ~/.ssh/simple_next_deploy.pub
```

**Bắt buộc: public key phải nằm trong `authorized_keys` của user SSH.** Runner
GitHub Actions giữ *private* key, nên VPS phải tin *public* key đó. Thiếu bước này
thì mọi lần deploy đều fail `Permission denied (publickey)` — private key có đúng
cũng vậy. Làm đúng **user** sẽ điền vào secret `VPS_USER`:

```bash
# chạy đúng user mà bạn sẽ điền vào secret VPS_USER
cat ~/.ssh/simple_next_deploy.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Phải là **user đã `chown` thư mục app ở §2.3** — `deploy.sh` cần user đó ghi vào
`/opt/simple-next-*` và chạy pm2. Kiểm tra lại bằng cách thử SSH từ máy local,
đúng như runner sẽ làm:

```bash
ssh -i ~/.ssh/simple_next_deploy <VPS_USER>@<IP-VPS> 'echo OK && whoami'
```

Chỉ khi câu này ra `OK` thì GitHub Actions mới SSH được. Nếu vẫn bị
`Permission denied (publickey)` xem mục chẩn đoán ở §3.1.

Lấy fingerprint và add **read-only deploy key** trong GitHub
(Settings → Deploy keys → Add deploy key, **KHÔNG** tick "Allow write access").

Lưu ý: repo **private** thì deploy key phải có quyền truy cập repo đó; deploy key
chỉ đọc, nên runner cần deploy key (chứ không phải token) để `git fetch`.

```bash
# user chạy pm2 được đọc/ghi trong thư mục app (npm ci/build tại chỗ cần ghi)
sudo chown -R "$USER":"$USER" /opt/simple-next-prod /opt/simple-next-staging

# firewall: chỉ mở SSH + HTTP + 2 cổng nginx của app này
sudo ufw allow 22/tcp
sudo ufw allow 8019/tcp
sudo ufw allow 8018/tcp
sudo ufw enable
```

Không mở `3119`/`3118` ra ngoài — app chỉ nghe loopback, mở cũng vô dụng.

### 2.4 File env (tuỳ chọn)

App này không có secret nào. Nếu muốn đặt `APP_MESSAGE` hoặc đổi `PORT`:

```bash
sudo mkdir -p /opt/simple-next-secrets
sudo chmod 700 /opt/simple-next-secrets
sudo chown -R "$USER":"$USER" /opt/simple-next-secrets
sudo nano /opt/simple-next-secrets/prod.env   # và staging.env
```

Quy tắc để `deploy.sh` và `ecosystem.config.cjs` đọc được:

- mỗi dòng đúng dạng `KEY=value`, không `export`, không thụt đầu dòng trước `KEY`
- giá trị có thể bọc `"` hoặc `'`; **không** nội suy biến (`$VAR`, backtick)
- không comment cùng dòng với giá trị

Thiếu file env KHÔNG làm deploy fail (chỉ log cảnh báo).

### 2.5 nginx + pm2

Thư mục clone ở §2.3 là working tree bình thường nên `nginx.conf` nằm đúng chỗ.
Kiểm tra file có trong commit đang checkout không (lần setup đầu, commit deploy có
thể chưa có trên nhánh đó):

```bash
test -f /opt/simple-next-prod/deploy/vps/nginx.conf \
  || git -C /opt/simple-next-prod fetch origin main && \
     git -C /opt/simple-next-prod checkout -f origin/main
```

Rồi cài (giữ nguyên chuỗi `&&` — xem cảnh báo bên dưới):

```bash
sudo install -m 644 /opt/simple-next-prod/deploy/vps/nginx.conf /etc/nginx/sites-available/simple-next \
  && sudo ln -sfn /etc/nginx/sites-available/simple-next /etc/nginx/sites-enabled/simple-next \
  && sudo nginx -t && sudo systemctl reload nginx
```

⚠️ **Giữ nguyên chuỗi `&&`, đừng tách ra chạy từng dòng.** `ln -s` KHÔNG báo lỗi khi
target chưa tồn tại — nó tạo symlink treo, `nginx -t` sẽ fail với
`open() ".../sites-enabled/simple-next" failed (2: No such file or directory)`. Sửa: chạy
lại đúng chuỗi trên (tạo file đích trước rồi mới link).

### 2.5b Nhiều project trên cùng một VPS

nginx chỉ có MỘT config toàn cục (`/etc/nginx/nginx.conf` → `include
sites-enabled/*`). Mỗi project là 1 cặp file riêng trong `sites-available/` +
`sites-enabled/`; **không** sửa file của project khác.

Ba thứ phải không trùng, trùng là `nginx -t` fail ⇒ `systemctl reload` không chạy ⇒
mất nginx cho **cả VPS**:

1. **Tên file** trong `sites-available`/`sites-enabled` (`simple-next` vs `mom-baby`).
2. **Cổng `listen`.** Đang phân bổ: mom-baby `80` (prod) + `8001` (staging) →
   `127.0.0.1:3000/3002`; simple-next `8019` (prod) + `8018` (staging) →
   `127.0.0.1:3119/3118`.
3. **Tên `upstream`** — `upstream` là namespace **toàn cục**, không nằm trong
   `server {}`. Đây là chỗ dễ vấp nhất: file này dùng `simple_next_prod` /
   `simple_next_staging`, còn mom-baby dùng `mom_baby_prod` / `mom_baby_staging`.
   Nếu cả hai cùng đặt `upstream prod` thì `nginx -t` báo `duplicate upstream`.
4. **`proxy_*` không được đặt ở top level của file.** Đây là bẫy thật đã gặp, và
   nó **không** hiện trong bảng trên vì trông có vẻ "vô hại". File trong
   `sites-enabled/` được `include` vào **bên trong** `http{}`, nên top level của
   file = context `http{}` — **dùng chung với mọi project khác**. Mỗi directive
   giá trị đơn (`proxy_http_version`, `proxy_buffering`, `proxy_buffers`,
   `proxy_connect_timeout`, `proxy_read_timeout`, ...) chỉ nhận **một** lần cho mỗi
   block, nên hai project cùng khai ở top level là:

   ```
   nginx: [emerg] "proxy_http_version" directive is duplicate in
   /etc/nginx/sites-enabled/simple-next:30
   ```

   ⇒ **đặt mọi `proxy_*` vào trong từng `server {}`**, để mỗi project tự chứa.
   (`proxy_set_header` không bị báo vì là directive kiểu block nên nginx cho gộp —
   nhưng để nó ở `http{}` vẫn làm header của project này áp lên project khác.)
   Lỗi báo ở file đọc **sau** trong thứ tự alphabet của `sites-enabled/*`
   (`mom-baby` < `simple-next`), nên file bị chỉ đích không phải file "có vấn đề".

   Hệ quả khi thêm block `listen 443 ssl` sau này: block mới phải **copy lại** khối
   `proxy_*` (đặt trong `server` không được `listen 8019` kế thừa). Thiếu thì
   `X-Forwarded-Proto` không được set ⇒ trang `/` hiện `(missing)`.

**`sites-enabled/default` phải bị gỡ** — nhưng **không phải vì simple-next**. File
`default` của Ubuntu cũng khai `listen 80 default_server`, mà `mom-baby` dùng chính
cổng 80 với `default_server` (`listen 80 default_server` trong
`deploy/vps/nginx.conf` của nó) ⇒ hai block cùng làm default trên `:80` ⇒
`duplicate default server for 0.0.0.0:80`. mom-baby đã gỡ file này trong
setup của nó; simple-next chỉ cần đảm bảo nó vẫn vắng:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

Thứ tự cài (chạy 1 lần; cài mom-baby trước vì nó giữ `default_server` trên :80):

```bash
sudo install -m 644 /opt/mom-baby-prod/deploy/vps/nginx.conf /etc/nginx/sites-available/mom-baby \
  && sudo ln -sfn /etc/nginx/sites-available/mom-baby /etc/nginx/sites-enabled/mom-baby

sudo rm -f /etc/nginx/sites-enabled/default

sudo install -m 644 /opt/simple-next-prod/deploy/vps/nginx.conf /etc/nginx/sites-available/simple-next \
  && sudo ln -sfn /etc/nginx/sites-available/simple-next /etc/nginx/sites-enabled/simple-next

sudo nginx -t && sudo systemctl reload nginx
```

⚠️ `/etc/nginx/sites-available/*` **KHÔNG** tự cập nhật theo repo — `deploy.sh` không
đụng tới nginx (xem §2.6). Sửa `deploy/vps/nginx.conf` trong repo thì phải chạy lại
lệnh `install` ở trên mới có hiệu lực trên VPS.

Kiểm tra:

```bash
ls -l /etc/nginx/sites-enabled/
sudo ss -ltnp | grep -E ':(80|8001|3118|3119|8018|8019)\b'
curl -sI http://127.0.0.1:80   | head -1   # mom-baby prod
curl -sI http://127.0.0.1:8019 | head -1   # simple-next prod
```

Khi cả hai lên HTTPS, cùng phải khai `listen 443 ssl` — lúc đó chỉ MỘT block được
`default_server`, các block còn lại bắt buộc có `server_name` khác nhau, nếu không
lại dính `duplicate default server`.

```bash
# pm2 tự khởi động lại sau reboot
pm2 startup systemd -u "$USER" --hp "$HOME"
pm2 save
```

`pm2 startup` chỉ cần chạy 1 lần; `pm2 save` sau mỗi lần deploy (deploy.sh đã gọi).

## 3. Secrets (GitHub Actions)

Repo → Settings → **Secrets and variables → Actions → New repository secret**:

| Secret | Ví dụ | Ghi chú |
|---|---|---|
| `VPS_HOST` | `203.0.113.10` | IP VPS, không phải domain |
| `VPS_USER` | `ubuntu` | user chạy pm2, **không phải root** |
| `SSH_PRIVATE_KEY` | nội dung `~/.ssh/simple_next_deploy` | dán **nguyên văn** file private key, có header `-----BEGIN OPENSSH PRIVATE KEY-----` và footer; không bọc dấu nháy, không bỏ dòng nào; **xuống dòng LF**, không CRLF |

`SSH_PRIVATE_KEY` phải là **private key đúng cặp** với public key đã nằm trong
`~/.ssh/authorized_keys` của `VPS_USER` trên VPS (§2.3). Dán từ Notepad/Word trên
Windows sẽ kẹp `\r` CRLF, mà OpenSSH parse private key bằng text nên key không đọc
được. Workflow đã có `tr -d '\r'` nên chống được, nhưng nên dán cho đúng ngay.

Hai biến tuỳ chọn là **Variables** (không phải Secret) vì chúng không bí mật:

| Variable | Mặc định trong workflow |
|---|---|
| `DEPLOY_ENABLED` | **mặc định tắt** — phải đặt `true` mới deploy |
| `VPS_PROD_DIR` | `/opt/simple-next-prod` |
| `VPS_STAGING_DIR` | `/opt/simple-next-staging` |

`DEPLOY_ENABLED` là **cổng bật/tắt** của job `deploy`
(`if: ${{ !cancelled() && vars.DEPLOY_ENABLED == 'true' }}`). Chưa tạo variable này thì
job bị **skip** ⇒ push vào `dev`/`main` chỉ chạy gate và workflow **xanh**. Đây là
trạng thái bình thường lúc mới lấy repo về: đừng tạo VPS, đừng điền secret gì cả.

Đặt `DEPLOY_ENABLED = true` khi đã xong §2 (VPS + deploy key) và thêm 3 secret ở
bảng trên. Xóa variable = tắt deploy trở lại mà không sửa file nào.

Deploy tự động: push vào `dev` → staging; vào `main` → prod. **Deploy luôn chạy, kể cả
khi gate đỏ** (`if: ${{ !cancelled() }}` + `needs`) — gate đỏ là cảnh báo để bạn quyết
định, không phải chốt chặn. Bỏ vế `!cancelled()` khỏi dòng `if` là deploy bị skip khi
gate đỏ.

Deploy **không** chạy trong `pull_request` (workflow chỉ khai báo `on: push`), nên mỗi
PR không tốn một lần build trên VPS. Ngoài ra GitHub không cấp secret cho workflow
chạy bởi PR từ fork — càng không nên dựa vào nó.

Deploy tay (VD VPS vừa setup lại, cần chạy lại không cần commit gì mới): tab
**Actions → deploy → Run workflow**, chọn `target` và nhập `ref` (branch hoặc commit
SHA, bỏ trống = nhánh theo môi trường).

Bảo vệ tương đương "protected variable" của GitLab là **Environment protection rules**:
tạo environment `prod`, thêm rule "Required reviewers" để chỉ workflow được duyệt mới
nhận secret `prod-*`. Lưu ý *required reviewers* chỉ miễn phí với repo **public**;
repo private cần Pro/Team/Enterprise. Repo public thì runner free không giới hạn phút.

### 3.1 Chẩn đoán `Permission denied (publickey)`

Có 3 tầng, kiểm tra từ trên xuống vì mỗi tầng loại được một nhóm nguyên nhân:

1. **Key trong secret có đọc được không?** Bước *Ghi deploy key* chạy
   `ssh-keygen -y -f ~/.ssh/deploy_key`; nếu job dừng ở đó thì key hỏng (thiếu
   header/footer, hoặc dán thiếu dòng) — sửa lại secret.
2. **Job có chạy tới bước deploy không?** Nếu có, tầng 1 đã pass ⇒ key hợp lệ,
   lỗi nằm ở VPS.
3. **Test tay từ máy local**, đúng như runner:

   ```bash
   ssh -i ~/.ssh/simple_next_deploy -o IdentitiesOnly=yes <VPS_USER>@<IP-VPS> 'echo OK && whoami'
   ```

   Không ra `OK` thì kiểm tra trên VPS, đúng user đó:

   ```bash
   # public key có trong authorized_keys không, và có đúng fingerprint không
   ssh-keygen -lf ~/.ssh/authorized_keys
   ssh-keygen -lf ~/.ssh/simple_next_deploy.pub     # hai dòng phải trùng
   ls -ld ~/.ssh && ls -l ~/.ssh/authorized_keys    # phải 700 / 600
   sudo sshd -T | grep -Ei 'pubkeyauthentication|authorizedkeysfile|allowusers'
   ```

| Triệu chứng | Nguyên nhân |
|---|---|
| `authorized_keys` không có dòng nào / thiếu fingerprint | chưa làm bước `>> ~/.ssh/authorized_keys` ở §2.3 |
| có key nhưng vẫn bị từ chối, dán tay từ local cũng bị | sai `VPS_USER`, hoặc `sshd` chặn (`AllowUsers`, `PubkeyAuthentication no`) |
| dán tay từ local được, Actions thì không | secret `SSH_PRIVATE_KEY` dán dở / khác cặp / CRLF — quay lại tầng 1 |
| `Bad permissions` trong log ssh | `chmod 700 ~/.ssh` + `chmod 600 ~/.ssh/authorized_keys` |

## 4. Deploy / quay lại bản cũ (thủ công)

```bash
# deploy (thường không cần — workflow tự gọi)
cd /opt/simple-next-prod
bash deploy/vps/deploy.sh main prod

# xem commit đang chạy
git -C /opt/simple-next-prod log -1 --oneline
```

**Không có `rollback.sh` và không có bản build dự phòng trên đĩa.** Mô hình 1 thư mục
chỉ giữ đúng một bản build, nên quay lại bản cũ = build lại:

- **Deploy fail** (build hỏng / health không khỏe) → `deploy.sh` tự checkout về commit
  trước, build lại, start lại. Không cần can thiệp.
- **Deploy thành công nhưng app lỗi chức năng** → deploy lại một nhánh/commit tốt:

  ```bash
  cd /opt/simple-next-prod
  bash deploy/vps/deploy.sh <nhánh-tốt> prod
  # deploy đúng một commit cũ:
  git -C /opt/simple-next-prod fetch origin <nhánh> \
    && bash deploy/vps/deploy.sh <commit-sha> prod
  ```

Biến ghi đè được: `HEALTH_TIMEOUT` (mặc định 90), `VPS_BASE`, `VPS_SECRETS`,
`PROD_PORT`, `STAGING_PORT`.

Log: `pm2 logs simple-next-prod --lines 50` · `pm2 logs simple-next-staging --lines 50`

## 5. Kiểm tra sau khi deploy

```bash
curl -fsS http://127.0.0.1:3119/api/health    # từ VPS (prod)
curl -fsS http://127.0.0.1:3118/api/health    # staging
curl -I http://<IP-VPS>:8019                  # từ ngoài
```

`/api/health` trả kèm bản build đang chạy — đây là cách **không cần mở trình duyệt**
để biết VPS đang phục vụ commit nào:

```json
{ "status": "ok", "version": "0.1.0", "sha": "fc70613",
  "builtAt": "2026-09-27T01:26:18+07:00", "uptime": 6, "node": "v26.5.0", "time": "..." }
```

So `sha` với `git -C /opt/simple-next-prod rev-parse --short=7 HEAD` là kiểm tra
nhanh nhất xem VPS có đúng commit bạn vừa push không. `sha`/`builtAt` được inline
lúc `npm run build` nên luôn mô tả đúng code đang chạy; `null` nghĩa là bản build đó
không đi qua `deploy.sh` (thường là build tay ở máy dev).

Deploy lùi về commit trước cũng tự đổi `sha` ở đây — nên sau một lần deploy, đọc
`sha` là biết app đang ở bản nào, kể cả bản rollback.

Mở `http://<IP-VPS>:8019` — trang hiện `Version`, `Git SHA` và `Build time`: đó là
commit vừa deploy. Nếu `X-Real-IP` / `X-Forwarded-Proto` hiện `(missing)` thì nginx
chưa forward header đúng.

Deploy lại **cùng một commit** mà app đang khỏe là no-op (deploy.sh log
`đã ở <sha> và app khỏe — không làm gì`) — dùng để kiểm tra workflow mà không đụng app.

## 6. Khi đã có domain + HTTPS

1. Trỏ DNS về VPS, cấp cert (certbot).
2. Sửa **file đang chạy** `/etc/nginx/sites-available/simple-next` theo khối hướng dẫn
   cuối `deploy/vps/nginx.conf`: thêm `server_name`, `listen 443 ssl`, đổi `listen 8019`
   thành redirect 301. Nhớ **commit ngược lại** vào `deploy/vps/nginx.conf` trong repo.
3. `sudo nginx -t && sudo systemctl reload nginx`.
4. Sửa secret `VPS_HOST` thành domain. Muốn deploy chỉ chạy khi có người duyệt thì
   dùng Environment protection rules (xem §3).

## 7. Ghi chú vận hành

- **Dung lượng đĩa:** mỗi môi trường chỉ có MỘT bản build (`node_modules` + `.next`),
  tức ~300MB/môi trường. Không có thư mục release tích tụ theo thời gian.
- **Giới hạn RAM:** `NODE_OPTIONS=--max-old-space-size=256` trong
  `ecosystem.config.cjs`, **không** dùng `max_memory_restart` của pm2 — khi `script` là
  `npm`, pm2 chỉ đo tiến trình `npm` chứ không đo `next`, ngưỡng đó là vanh tính giả.
- **Deploy fail = an toàn:** script quay về commit trước, build lại, start lại, trả exit 1
  (workflow đỏ). Nếu app vẫn hỏng sau khi quay về thì lỗi nằm ở env/cấu hình.
- **Thư mục clone ở detached HEAD:** đừng `git pull`/`git checkout` tay trong
  `/opt/simple-next-*` khi app đang chạy. Mọi thay đổi code trên VPS phải đi qua
  `deploy.sh`.
