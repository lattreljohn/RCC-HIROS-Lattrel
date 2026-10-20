# RCC-HIROS — Deployment Architecture

**Live URL:** *\<filled in after first deploy — Cloudflare tunnel hostname, e.g. `https://hiros.example.rr.com>`*
**CI/CD pipeline:** [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

---

## 1. Chosen Infrastructure

**Docker Compose (Next.js + MariaDB) on an always-on host, exposed through a Cloudflare Tunnel, deployed by GitHub Actions.**

| Layer | Choice |
|---|---|
| App runtime | Docker image (multi-stage `Dockerfile`, Next.js 16 `standalone` output) |
| Database | MariaDB 11.4 as a Compose service, persistent named volume |
| File storage | `uploads/` Docker volume (employee photos, documents, certificates) |
| Public exposure | Cloudflare Tunnel (`cloudflared`) — no open inbound ports / no IP to manage |
| CI/CD | GitHub Actions: hosted runner for CI, self-hosted runner on the server for CD |
| Fingerprint kiosk | Unchanged: `kiosk-service` (Python + ZKFinger SDK) on `127.0.0.1:8765` |

### Why this fits the architecture

The assignment says to analyze the architecture first — RCC-HIROS is **not** a static site or a pure Next.js frontend:

1. **Stateful filesystem access.** Employee photos/files are written directly to `uploads/` with `fs/promises` (e.g. `src/app/api/employees/[id]/photo/route.ts`, `src/app/api/employees/[id]/files/route.ts`). Any platform with ephemeral containers (Vercel, Netlify, Cloudflare Pages) loses or rejects this without a code refactor to object storage.
2. **MariaDB is a hard dependency.** Prisma 7 runs on MySQL/MariaDB (`@prisma/adapter-mariadb`, `src/lib/db.ts`). Bundled managed MySQL is not free anywhere; Compose gives us a first-class database for $0.
3. **USB hardware on the LAN.** The ZK9500 scanner is served by a Windows-only Python service bound to loopback (`kiosk-service/README.md`). The *web app* can be anywhere, but the kiosk PC must run that service — a serverless platform buys us nothing for this component and must not break its `NEXT_PUBLIC_KIOSK_SERVICE_URL=http://127.0.0.1:8765` contract.
4. **Sensitive HR/personnel data.** Keeping the database and files on a host we control (on-prem or a single tenant VM) satisfies the privacy/audit requirements of an HR system better than sharing serverless multi-tenant infrastructure — this is the assignment's "strictly internal tools with privacy constraints" case.
5. **Cost.** Docker, MariaDB, GitHub Actions and Cloudflare Tunnel are all free (€0/month on-prem; ≈$5/month only if moved to a small VPS). The only paid path in the alternatives (external MySQL + blob storage) was rejected.

### How it scales

- **Vertical:** single `docker compose up` on a bigger host; `connectionLimit: 10` in `src/lib/db.ts` and the Compose restart policy are already in place.
- **Horizontal:** the app container is stateless (state lives in the `db-data` and `uploads` volumes), so it can later be replicated behind a load balancer by switching to S3-compatible storage for `uploads/` and a managed MariaDB — a move explicitly limited by code that touches `process.cwd()/uploads`.

---

## 2. Trade-offs & Rejected Options

| Option | Why rejected |
|---|---|
| **Vercel / Netlify (PaaS)** | No MariaDB, ephemeral filesystem breaks `uploads/` (would need an S3/R2 refactor of ~6 API routes), serverless function limits hurt big PDF/ZIP exports (`@react-pdf/renderer`, `src/lib/zip-store.ts`), and paid add-ons (DB + storage) start where Docker ends at $0. Fine for frontend-only apps — not this one. |
| **Cloudflare Pages/Workers** | Static/edge focus; Workers can't run Prisma+MariaDB or long PDF/ZIP exports, and persistent local storage doesn't exist there. |
| **AWS ECS / Docker on a managed orchestrator** | Right container primitive, but introduces AWS account setup, ECR, task IAM, ALB and billing complexity with no benefit for a single-node course deployment. Docker Compose keeps the *same* container image, so the workload can be lifted to ECS/Railway/Fly later without rewriting. |
| **Plain local/on-prem without containerization** | How it ran in development (XAMPP + `next dev`), but "manual uploads are not permitted" and a bare host drifts between environments (Windows, XAMPP versions, manual start order). Containers make the production environment reproducible. |
| **Local server, no public URL** | The assignment requires a live URL — solved with Cloudflare Tunnel instead of port-forwarding. |

**Limitations of the chosen setup (honest list):**

- Single-host availability: if the server PC/VM is off, the app is off (mitigated by `restart: unless-stopped`, but not by redundancy).
- On-prem bandwidth/latency depend on the host's connection; no CDN caching of static assets (acceptable for an authenticated internal tool).
- `src/middleware.ts` forces HTTPS in production: plain `http://host:3000` requests get a 301 to `https://`. That's exactly what the Cloudflare Tunnel delivers (TLS at the edge, `x-forwarded-proto: https`), but direct LAN access over bare HTTP will loop — use the tunnel URL, or add your own TLS-terminating proxy in front.
- The ZK9500 enrollment flows only work when the browser runs on the kiosk PC (loopback service) — this is a hardware constraint, not a deployment one; the rest of the app is fully remote.
- GitHub self-hosted runner means the deploy job runs with privileges on the server (mitigated: runner configured for this repository only, Docker socket access required).

---

## 3. CI/CD Pipeline Overview

File: **`.github/workflows/deploy.yml`** — triggered on every push and pull request to `main`.

```
push / PR → main
   │
   ├─ job: ci            (GitHub-hosted ubuntu-latest)
   │    1. checkout
   │    2. setup Node.js 24 with npm cache
   │    3. npm ci                  ← exact lockfile install
   │    4. npm run lint             ← ESLint (0 errors enforced by exit code)
   │    5. npm run build            ← prisma generate + next build (type-check
   │                                   + production compile; needs no live DB)
   │
   └─ job: deploy        (self-hosted runner on the app host)
        runs only on push to main, after ci succeeds
        1. checkout
        2. docker compose up -d --build
             (--profile tunnel added automatically when TUNNEL_TOKEN is set)
             • builds the multi-stage image
             • starts MariaDB (healthcheck-gated)
             • container entrypoint runs `prisma migrate deploy`
               → pending migrations applied automatically
             • Next.js standalone server starts on :3000
        3. health check loop against http://localhost:3000
             → workflow fails (and shows compose logs) if the app doesn't respond
```

- **CI** (install + lint + build) runs on *every* PR, so broken code is caught before merge.
- **CD** (build + migrate + deploy) runs *only* after a successful merge/push to `main` — no manual uploads ever.
- Secrets (`DB_USER`, `DB_PASSWORD`, `JWT_SECRET`, `TUNNEL_TOKEN`) are stored as GitHub Actions secrets and injected into Compose at deploy time; `.env` is git-ignored and never checked out.

---

## 4. Runbook

### One-time server setup
1. Install Docker Desktop (or Docker Engine + Compose plugin) on the deploy host.
2. Register a GitHub **self-hosted runner** for this repository on the same host.
3. In the repo **Settings → Secrets and variables → Actions**, add:
   `DB_USER`, `DB_PASSWORD`, `JWT_SECRET` (≥32 random bytes), and optionally `TUNNEL_TOKEN`.
4. (Public URL) Install `cloudflared`, authenticate, create a named tunnel routed to `http://app:3000`, and put its token in `TUNNEL_TOKEN`.

### Everyday flow
```
git push (or merge PR) → main  →  CI runs  →  CD deploys  →  health check
```

### Useful commands
```bash
docker compose up -d --build                # app + db
docker compose --profile tunnel up -d       # + public Cloudflare URL
docker compose exec app npx tsx scripts/create-admin.ts   # first admin user
docker compose logs -f app                  # application logs
docker compose down                         # stop (data volumes are kept)
```

### Local development (unchanged)
XAMPP MariaDB + `npm run dev`; the kiosk service is started on the kiosk PC as described in `kiosk-service/README.md`.
