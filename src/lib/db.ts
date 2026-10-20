import { PrismaClient } from "../generated/prisma/client";
import { PrismaMariaDb } from "@prisma/adapter-mariadb";

// Connection settings come from DATABASE_URL (mysql://user:pass@host:port/db)
// so the same code runs locally (XAMPP) and inside Docker (compose service).
// Fallbacks preserve the original local-dev defaults.
function dbConfig() {
  const url = process.env.DATABASE_URL;
  if (url) {
    try {
      const u = new URL(url);
      return {
        host: u.hostname || "localhost",
        port: u.port ? Number(u.port) : 3306,
        user: decodeURIComponent(u.username || "root"),
        password: decodeURIComponent(u.password || ""),
        database: u.pathname.replace(/^\//, "") || "rcc_hiros",
      };
    } catch {
      // fall through to defaults
    }
  }
  return { host: "localhost", port: 3306, user: "root", password: "", database: "rcc_hiros" };
}

const adapter = new PrismaMariaDb({
  ...dbConfig(),
  connectionLimit: 10,
});

// ═══════════════════════════════════════════════════════════════
// RCC-HIROS — Prisma client singleton
// ═══════════════════════════════════════════════════════════════

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined;
};

export const db =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter,
    log: process.env.NODE_ENV === "development" ? ["error", "warn"] : ["error"],
  });

if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = db;
