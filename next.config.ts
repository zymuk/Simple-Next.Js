import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  turbopack: {
    // Chốt workspace root về thư mục project này. Nếu không, Next suy luận nhầm
    // root từ lockfile ngoài repo → trace sai.
    root: import.meta.dirname,
  },
  devIndicators: false,
};

export default nextConfig;
