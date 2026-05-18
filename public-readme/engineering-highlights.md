# Engineering highlights

Four decisions worth talking through. Each one is a real call I made in this lab, with the trade-offs honest and the receipts in the code.

---

## 1. The hot tier has no RAID, and that's the point

The NVMe in the Proxmox box holds everything that's running - the hypervisor itself, every LXC rootfs, every VM disk, every `/opt/<service>` working directory. There's no mirror, no parity, no second drive. If that NVMe dies, every running service goes down at the same moment.

That's deliberate. The contract is **"this IaC repo plus the latest tarballs on the warm-fast tier is the complete disaster-recovery payload."** Adding RAID on the hot path doubles the cost of the fast storage to protect data that already has a better copy a few metres away on the NAS. RAID solves the "drive failed, services keep running" problem - I'm solving the more pessimistic "drive failed, full rebuild from cold start, no data loss" problem instead, because that scenario covers every cause of hot-tier failure (drive, controller, motherboard, ransomware, accidental `rm -rf`), not just disk wear.

The receipts for that claim are concrete:

- [`deploy-proxmox.sh`](../deploy-proxmox.sh) reinstalls the hypervisor end-to-end from a fresh Proxmox install with one command. Network bridges, storage mounts, LXC ID mapping, the golden Ubuntu cloud-init template, all of it.
- [`deploy-services.sh`](../deploy-services.sh) brings every service back online from scratch.
- Every stateful service in [`services/`](../services/) has a `nightly-backup.sh` that writes a timestamped tarball to `/mnt/backups/<service>/backups/` with 7-day retention, and a matching `restore.sh` that takes the latest tarball and reseeds the running container.

The thing I haven't done yet is the cold tier - an offsite-style replica that protects against the NAS itself dying. That's the one open gap in the model and it's flagged in the [storage page](architecture.md#4-storage) of the architecture tour.

---

## 2. One canonical writer per IaC artefact

Twice in this lab I got bitten by the same shape of bug: two scripts both wrote into the same config file, in different formats, in unpredictable order. Each time it manifested as a silent failure that surfaced minutes-to-days later as a 404 in production.

**First incident.** Traefik's [`update.sh`](../services/docker/traefik/update.sh) was pushing `routes.yml` raw, while [`deploy.sh`](../services/docker/traefik/deploy.sh) ran `envsubst` over the same file before pushing. Result: a deploy worked fine, but the next update would silently overwrite the deployed file with raw `${VAR}` placeholders. Backends became literally `http://${KASM_CT_IP}:3000`. Nothing alerted on it because the file *parsed* fine, it just routed nowhere.

**Second incident.** The docs service's `deploy.sh` had an `update_traefik_routes()` function that auto-generated a marker-delimited block inside Traefik's `routes.yml`. At some point a hand edit landed two unrelated routers (n8n, scrapper-admin) *inside* the marker block. The next docs deploy would have stripped them with the rest of the block.

The lesson from both: **if two scripts can write the same file, eventually one of them will clobber the other's work, and you won't notice until something user-visible breaks**. The fix isn't more discipline. It's removing the shared write path.

After the second incident, the cleanest solution was the most aggressive one: **kill the auto-generation entirely and make `routes.yml` hand-managed**. The docs service still autodiscovers Docusaurus sites and spawns one container per site, but if you add a new site you have to add the Traefik router yourself. The docs deploy script now runs a sanity check at the end and prints a loud warning if a discovered site doesn't have a router in `routes.yml`. Silent auto-generation is replaced with loud "you need to do this manually."

The bash hygiene rule I came out with:
> **One writer per artefact.** If a config file needs values from multiple sources, the canonical writer should `envsubst` or template at write-time. No script gets to overwrite a file another script is also writing to.

The runtime-env handling in `deploy-services.sh` follows this rule end-to-end now: the runtime template lives in `configs/<name>.runtime.env`, `deploy-services.sh` is the only writer, `envsubst` resolves `${TRAEFIK_DOMAIN}` / `${PUBLIC_DOMAIN}` at push time, and the result lands on the VM as a literal `.env` that Docker Compose reads with no further substitution.

---

## 3. Three shapes, twelve services, one library

Every service in this lab fits one of three deployment shapes:

| Shape | Library file | Used by |
|-------|--------------|---------|
| LXC + Docker | [`services/lib/docker-service.sh`](../services/lib/docker-service.sh) | 9 services |
| Native LXC | [`services/lib/lxc-service.sh`](../services/lib/lxc-service.sh) | Jellyfin only |
| QEMU VM | [`services/lib/vm-service.sh`](../services/lib/vm-service.sh) | 2 services (Nextcloud, Media Pipeline) |

The library functions handle the cross-cutting concerns: container creation/teardown, Docker installation, port-wait health checks, SMB and NFS fstab management, network configuration, SSH key injection. A service's own `deploy.sh` reads as orchestration ("create the LXC, push the source, build the image, start the container, wait for health, register with Portainer agent") - the library does the actual work.

This means adding a new service is essentially a four-file change:
1. `configs/<name>.env` - the deploy-time config (gitignored, real values)
2. `configs/<name>.env.example` - the committed template showing what variables are needed
3. `services/<shape>/<name>/deploy.sh` - the orchestration, mostly library calls
4. The service-specific runtime files: `docker-compose.yml` for Docker services, `bootstrap.sh` + restore scripts for VMs

There's also a small registry in [`deploy-services.sh`](../deploy-services.sh) (parallel arrays for service name, shape, description) that lets the interactive menu show the new service without any other plumbing.

**Two specific design choices in the library are worth flagging:**

`wait_for_service` had a long-standing bug where it used `curl -sf` (which treats any 4xx as failure) and warned on timeout but returned zero. So a service that returned 404 on `/` - like the .NET API in WebScraper - would loop until the timeout, then claim "smoke test passed" while having tested nothing. The fix in [`docker-service.sh:370`](../services/lib/docker-service.sh) drops `-f` (any HTTP response from a live server is enough to call the listener "up") and returns 1 on timeout. With `set -e` in every caller, that means a real timeout actually fails the deploy. It also catches `--max-time 5` to prevent slow responses from dragging out the loop.

The `services/lib/common.sh::fetch_service_source` function fetches a service's source tarball from a GitHub repo at deploy time, so the lab's own apps (BrowserIsolation, WebScraper) live in their own repos and the IaC just pulls a known ref. This means the lab repo doesn't carry vendored copies of those apps - any source change happens in the app's own repo with its own commit history.

---

## 4. Two apps that outgrew the lab

A homelab is a great forcing function for app design. You build something for yourself, you use it daily, you notice all the edges. Two of the apps that started here got substantial enough to deserve their own public repos:

### BrowserIsolation - [github.com/Vali-Mandeal/BrowserIsolation](https://github.com/Vali-Mandeal/BrowserIsolation)

The Kasm Workspaces open-source bundle ships **eight long-running service containers** plus a per-session container. That's reasonable for a multi-tenant enterprise that needs identity, audit, file sharing, session recording, and so on. It was wildly over-spec for what I actually use the feature for: clicking a dodgy link and seeing it open in a disposable browser.

The replacement is one .NET 9 service. The Sessions API spawns a fresh `lscr.io/linuxserver/firefox` container per request via `Docker.DotNet`, allocates a port from a configured range, and returns a session URL. A YARP reverse proxy forwards `/session/<id>/*` traffic to that container. A background reaper destroys idle sessions after 30 minutes. The whole thing fits in about 200 lines of C# plus a small static HTML launcher.

It's compatible with the official Kasm browser extension - the extension posts to a URL with `#kasm_url=` in the hash, and my launcher reads that hash and spins up a session - so I get the same workflow as the full product without running the full product.

### WebScraper - [github.com/Vali-Mandeal/WebScraper](https://github.com/Vali-Mandeal/WebScraper)

A classified-ads watcher. I built it because manually refreshing marketplace pages is a terrible way to find good deals, and I wanted to keep up with hardware listings during the hours I wasn't at a keyboard.

The shape:
- **.NET 10 minimal API.** Quartz triggers an hourly run (9-22 local), the orchestrator loads active jobs from MongoDB, Playwright headless Chromium walks each target site, an evaluator filters by must-contain / must-not-contain keywords and a max-price threshold, dedupes against previously seen ads by URL-derived ID, persists new ones, and fan-outs to Telegram + SMTP in parallel.
- **React 18 + Vite admin UI.** Lets me manage jobs and watch test runs live (per-ad decisions stream over SignalR as Playwright extracts each card). Built into a static bundle and served by nginx in a sibling container.

The lab's IaC fetches it at deploy time via `fetch_service_source` (see `configs/scraper.env.example` for the convention), so the runtime always pulls a tagged source tree.

### Why both went public

The honest answer is *I wrote the apps for me, but they're useful in shapes that aren't unique to me*. The BrowserIsolation use case - "I want one of the features of Kasm without the rest of Kasm" - is general. The WebScraper use case - "watch a list of sites for things matching my criteria" - is general. Documenting and publishing them costs almost nothing once they exist, and forces a second pass on the design ("would I be embarrassed for someone else to read this?") that ends up improving the code.

The extraction itself was its own small engineering exercise: the lab's IaC was originally a monorepo with the .NET source under `services/`; pulling it out meant adding a fetch-from-GitHub step, sanitising the source for the new repo, writing a README that didn't reference the homelab, designing an architecture diagram, and updating the IaC scripts so they pull the source rather than carry it. The pattern is now generic - any future app I build can graduate the same way.

---

## What this is not

This is a personal homelab and a portfolio piece, not a product. None of the code is intended to be reused as-is by a stranger - the configs are tightly coupled to specific hardware and a specific operator. The interesting parts for a reader are the *decisions*, not the line-by-line implementation.

If something in here is interesting and you want to dig deeper, [the architecture tour](architecture.md) is the depth.
