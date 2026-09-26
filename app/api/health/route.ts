import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({
    status: "ok",
    uptime: Math.round(process.uptime()),
    node: process.version,
    time: new Date().toISOString(),
  });
}
