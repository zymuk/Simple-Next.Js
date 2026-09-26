import nextCoreWebVitals from "eslint-config-next/core-web-vitals";
import nextTypeScript from "eslint-config-next/typescript";

const eslintConfig = [
  {
    ignores: [".next/**", "node_modules/**", "next-env.d.ts"],
  },
  ...nextCoreWebVitals,
  ...nextTypeScript,
  {
    // `deploy/vps/ecosystem.config.cjs` là config CommonJS mà pm2 `require()` lúc
    // start — `require()` ở đây là BẮT BUỘC theo định dạng file, không phải lỗi
    // style. Tắt riêng một rule thay vì ignore cả thư mục, để các rule khác vẫn có
    // hiệu lực với file này.
    files: ["deploy/**/*.cjs"],
    rules: {
      "@typescript-eslint/no-require-imports": "off",
    },
  },
];

export default eslintConfig;
