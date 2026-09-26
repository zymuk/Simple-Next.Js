import { headers } from "next/headers";

import { BUILD_INFO } from "@/lib/buildInfo";

export const dynamic = "force-dynamic";

const startedAt = Date.now();

function uptime() {
  const s = Math.floor((Date.now() - startedAt) / 1000);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${d}d ${h}h ${m}m ${s % 60}s`;
}

export default async function Home() {
  const h = await headers();

  const info = [
    { label: "Node", value: process.version },
    { label: "Uptime (process)", value: uptime() },
    { label: "PORT", value: process.env.PORT ?? "(default 3000)" },
    { label: "NODE_ENV", value: process.env.NODE_ENV ?? "-" },
    { label: "APP_MESSAGE", value: process.env.APP_MESSAGE ?? "(not set)" },
    { label: "Version", value: BUILD_INFO.version },
    { label: "Git SHA", value: BUILD_INFO.sha ?? "(not set)" },
    { label: "Build time", value: BUILD_INFO.builtAt ?? "-" },
  ];

  const request = [
    { label: "Host", value: h.get("host") ?? "-" },
    { label: "X-Real-IP", value: h.get("x-real-ip") ?? "(missing)" },
    { label: "X-Forwarded-Proto", value: h.get("x-forwarded-proto") ?? "(missing)" },
    { label: "User-Agent", value: h.get("user-agent") ?? "-" },
  ];

  return (
    <main>
      <h1>simple-next</h1>
      <p className="lead">
        Trang này render ở server mỗi request, dùng để kiểm tra chuỗi{" "}
        <code>nginx → PM2 → Next.js</code> sau khi deploy.
      </p>

      <h2>Runtime</h2>
      <div className="grid">
        {info.map((item) => (
          <div className="card" key={item.label}>
            <dt>{item.label}</dt>
            <dd>{item.value}</dd>
          </div>
        ))}
      </div>

      <h2>Request headers (nhận từ nginx)</h2>
      <div className="grid">
        {request.map((item) => (
          <div className="card" key={item.label}>
            <dt>{item.label}</dt>
            <dd>{item.value}</dd>
          </div>
        ))}
      </div>

      <h2>Kiểm tra nhanh</h2>
      <div className="card">
        <span className="status">Ứng dụng đang chạy</span>
        <p style={{ margin: "0.5rem 0 0" }}>
          Health check: <a href="/api/health">/api/health</a>
        </p>
      </div>

      <footer>Rendered at {new Date().toISOString()}</footer>
    </main>
  );
}
