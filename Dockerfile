# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────
# RCC-HIROS — multi-stage Next.js 16 (standalone output) image
# ─────────────────────────────────────────────────────────────

# ── Stage 1: dependencies (full install — prisma CLI needed for migrate) ──
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# ── Stage 2: build ──────────────────────────────────────────
FROM deps AS builder
# Client-visible config is inlined at build time
ARG NEXT_PUBLIC_KIOSK_SERVICE_URL=http://127.0.0.1:8765
ENV NEXT_PUBLIC_KIOSK_SERVICE_URL=${NEXT_PUBLIC_KIOSK_SERVICE_URL}
# Build must not require a live DB (prisma generate only)
ENV DATABASE_URL="mysql://root:@localhost:3306/rcc_hiros"
ENV JWT_SECRET="build-placeholder"
COPY . .
RUN npx prisma generate && npx next build

# ── Stage 3: runtime ────────────────────────────────────────
FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# node_modules (incl. prisma CLI + tsx for migrations/seeds)
COPY --from=deps /app/node_modules ./node_modules
# Standalone server bundle
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
# Prisma schema + migrations (applied on container start)
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/package.json ./package.json

EXPOSE 3000
CMD ["sh", "-c", "npx prisma migrate deploy && node server.js"]
