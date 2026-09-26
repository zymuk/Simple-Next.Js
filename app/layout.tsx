import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "simple-next",
  description: "Minimal Next.js app for testing VPS deploys",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="vi">
      <body>{children}</body>
    </html>
  );
}
