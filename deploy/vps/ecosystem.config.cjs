/**
 * ecosystem.config.cjs — cấu hình pm2 cho app simple-next.
 *
 * Dùng CHUNG cho cả prod lẫn staging: `deploy.sh` truyền `SIMPLE_NEXT_*` qua môi
 * trường rồi gọi `pm2 start <file này> --only <tên>`. Nhờ vậy chỉ có MỘT bản cấu
 * hình trong repo thay vì phải sinh file riêng theo môi trường (dễ lệch).
 *
 * File env nẾU CÓ đặt NGOÀI repo (`/opt/simple-next-secrets/<target>.env`) — không
 * bao giờ commit secret, cũng không nằm trong bất kỳ working tree git nào.
 *
 * Chạy tay để xem cấu hình (không start):
 *   SIMPLE_NEXT_PM2_NAME=simple-next-prod SIMPLE_NEXT_CWD=/opt/simple-next-prod \
 *   SIMPLE_NEXT_PORT=3119 SIMPLE_NEXT_ENV_FILE=/opt/simple-next-secrets/prod.env \
 *   node -e 'console.log(require("./deploy/vps/ecosystem.config.cjs"))'
 */
const fs = require("node:fs");
const path = require("node:path");

/**
 * Đọc file env dạng `KEY=VALUE`. Cố ý tự viết thay vì dùng `dotenv`: file này chạy
 * ở ngữ cảnh pm2 (ngoài app), không muốn phụ thuộc `node_modules` — thứ đang bị
 * `npm ci` xoá lại mỗi lần deploy.
 *
 * Bỏ qua dòng trống và `#`, bóc dấu nháy thừa, KHÔNG nội suy biến ($VAR, backtick)
 * — cần thì viết thẳng giá trị.
 */
function readEnvFile(filePath) {
  const result = {};
  if (!filePath || !fs.existsSync(filePath)) {
    return result;
  }
  for (const rawLine of fs.readFileSync(filePath, "utf8").split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

const appName = process.env.SIMPLE_NEXT_PM2_NAME;
const cwd = process.env.SIMPLE_NEXT_CWD;
const port = process.env.SIMPLE_NEXT_PORT;
const envFile = process.env.SIMPLE_NEXT_ENV_FILE;

for (const [name, value] of Object.entries({ SIMPLE_NEXT_PM2_NAME: appName, SIMPLE_NEXT_CWD: cwd, SIMPLE_NEXT_PORT: port, SIMPLE_NEXT_ENV_FILE: envFile })) {
  if (!value) {
    throw new Error(`Thiếu biến ${name} — phải chạy qua deploy.sh, không chạy tay pm2 start file này.`);
  }
}
if (!fs.existsSync(path.join(cwd, "node_modules"))) {
  throw new Error(`${cwd} chưa có node_modules — chạy deploy.sh để build trước.`);
}

module.exports = {
  apps: [
    {
      name: appName,
      cwd,
      // Chạy qua `npm start` để deploy.sh/CI và production dùng CHUNG một đường gọi
      // `npm run <script>`. `npm start -- -p … -H …` chuyển tiếp tham số xuống
      // `next start`.
      //
      // `interpreter: "none"` vì `npm` là binary, không phải file JS cho node chạy.
      script: "npm",
      args: `start -- -p ${port} -H 127.0.0.1`,
      interpreter: "none",

      // KHÔNG dùng `cluster`: `next start` + multi-process nhân bản module server và
      // các state trong bộ nhớ. Một process.
      instances: 1,
      exec_mode: "fork",

      env: {
        ...readEnvFile(envFile),
        NODE_ENV: "production",
        PORT: port,
        // next start tự set, nhưng đặt tường minh để không phụ thuộc hành vi mặc định.
        NEXT_TELEMETRY_DISABLED: "1",

        // ⚠️ KHÔNG dùng `max_memory_restart` ở đây. Khi `script` là `npm`, cây
        // process là npm → sh -c → node, và pm2 chỉ đo tiến trình `npm` (~75MB,
        // không đổi theo tải của app) chứ không đo tiến trình next. Ngưỡng đó là
        // vanh tính giả — app OOM sẽ chết mà không ai restart.
        //
        // Thay bằng chặn heap của chính V8: vượt ngưỡng thì Node crash → pm2 restart.
        NODE_OPTIONS: "--max-old-space-size=256",
      },
    },
  ],
};
