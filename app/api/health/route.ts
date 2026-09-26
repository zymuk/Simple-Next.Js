import { NextResponse } from "next/server";

import { BUILD_INFO } from "@/lib/buildInfo";

export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({
    status: "ok",
    ...BUILD_INFO,
    uptime: Math.round(process.uptime()),
    node: process.version,
    time: new Date().toISOString(),
  });
}
