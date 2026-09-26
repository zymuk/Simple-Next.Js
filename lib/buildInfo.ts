import { version } from "../package.json";

/**
 * Thông tin bản build đang chạy — MỘT nguồn sự thật cho `/api/health` và trang `/`.
 *
 * `sha` và `builtAt` KHÔNG được đọc lúc runtime. `npm run build` INLINE chúng vào
 * bundle (Next thay thế `process.env.NEXT_PUBLIC_*` bằng chuỗi lúc build). Nhờ vậy
 * giá trị mô tả đúng bản ĐÃ BUILD — `pm2 restart` không rebuild thì SHA vẫn đúng
 * với code đang chạy, thay vì đọc nhầm HEAD của repo.
 *
 * `deploy.sh` export 2 biến này ngay trước `npm run build`. Build không đi qua
 * deploy.sh (ví dụ `npm run build` ở máy dev) thì cả hai là `null` — đó là câu trả
 * lời trung thực, KHÔNG phải lỗi: không có commit nào được ghi nhận cho bản build.
 *
 * Vì `/api/health` là JSON cho máy đọc, `null` đúng hơn chuỗi sentinel kiểu
 * `"(not set)"` — client phân biệt được "chưa có" với "rỗng".
 */
export const BUILD_INFO = {
  /** Khớp `package.json` `version` — đọc từ đó, không hardcode lần 2. */
  version,
  /** 7 ký tự đầu của commit mà deploy.sh build. */
  sha: process.env.NEXT_PUBLIC_GIT_SHA ?? null,
  /** ISO 8601 lúc `npm run build` chạy (giờ VPS). */
  builtAt: process.env.NEXT_PUBLIC_BUILD_TIME ?? null,
} as const;
