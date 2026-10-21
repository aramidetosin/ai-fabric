# ai-fabric — runbook: from a bare host to a working lab

This is the operational sequence. `README.md` is the design reference (why the fabric looks like it
does, the VLAN/VRF plan, EVPN details, network-operator and storage notes) — read this file to
*run* the lab, that one to *understand* it.

What you end up with: a simulated AI cluster — a frontend fabric (Cumulus VX **or** Cisco Nexus
9300v depending on profile), an 8-rail IP Infusion OcNOS backend, a Palo Alto PA-VM firewall, a
Juniper vEX out-of-band switch, and **39 Kubernetes nodes** (6 control + 32 GPU-shaped + 1 storage)
running Cilium, Multus rail NADs, Longhorn, Harbor, MinIO and an inference stack behind a Gateway.

The network topology is in `diagrams/` — `ai-fabric-32gpu.png` / `.svg` and the editable
`.excalidraw`, regenerable with `diagrams/gen_topology.py`. Per-port cabling is in `cabling/`.

---

## 0. Know what you need before you start

**This is a large lab.** It is not a laptop lab.

| | |
|---|---|
| RAM | **~337 GB allocated** across ~62 VMs. Measured ~**210 GB resident** once KSM merges the identical guests. 256 GB is the realistic floor; 384 GB is comfortable. |
| CPU | 64+ threads. Measured on dual-socket Xeon (128 threads); load sits in the 20–45 range during bring-up. |
| Disk | ~450 GB for guest disks (`nodes/`) plus image storage. NVMe/SSD — spinning disk times the switches out. |
| Host OS | Linux with KVM, Docker and `containerlab` (built against 0.79). Keep KSM on (`ksmtuned`) — that is what makes the memory fit. |

Per-device allocation if you need to size differently: Nexus 9300v **10 GB** each (budget the full
10 — they settle lower but peak there), OcNOS rail leaves 6 GB / spines 4 GB, PA-VM 16 GB, vEX 5 GB,
control guests 8 GB, GPU guests 3 GB, storage guest 6 GB.

**Run one big lab per host.** Sharing a host with another sizeable lab exhausts memory and the host
starts shedding guests.

---

## 1. Secrets — do this first

The published copy is sanitised. The two lab logins default to `admin` (the containerlab
convention) so the lab comes up out of the box; the **kubeadm join token and certificate key
have no usable default** and must be generated, or stage 2 fails.

```bash
cp .env.example .env
$EDITOR .env                  # set every value; generation commands are in the comments
set -a; . ./.env; set +a      # export before gen.py / up.sh
```

Then create your own key file (the original was removed for publication):

```bash
cp common/authorized_keys.example common/authorized_keys
cat ~/.ssh/id_ed25519.pub >> common/authorized_keys
# and set LAB_WORKSTATION_KEY_COMMENT in .env to that key's comment
```

If you use the `ndfc=True` profile flag, also replace the placeholder `NDFC_USER` hash in `gen.py`
— see the note in `.env.example`.

---

## 2. Images

**Vendor network images are licensed and are NOT in this repo** — no image name or version ships
here either. Obtain each qcow2 from the vendor, build the container with
[vrnetlab](https://github.com/hellt/vrnetlab), and point the generator at your own tags via `.env`:

```
VEX_IMAGE=    # Juniper vJunos-switch     CVX_IMAGE=   # NVIDIA Cumulus VX
OCNOS_IMAGE=  # IP Infusion OcNOS         PAN_IMAGE=   # Palo Alto PA-VM
NX_IMAGE=     # Cisco Nexus 9300v         NX_BIN=      # the NX-OS .bin inside that image
```

There is no default: leave one unset and the generator emits `SET_IN_ENV/...`, which fails loudly
rather than silently pointing at an image you do not have. The generated switch configs were
written against recent releases of each NOS; older trains may need syntax tweaks.

### The Ubuntu cloud image for the 39 guests

The guests boot an Ubuntu 24.04 cloud image. It is ~600 MB so it is **not** in this repo, and
`up.sh` refuses to start without it:

```bash
mkdir -p images/vm-node/base
curl -L -o images/vm-node/base/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

The file is bind-mounted read-only into every guest, so one copy serves all 39.

The two images the lab builds itself:

```bash
./build-images.sh             # -> ai-fabric-vm-node:latest, ai-fabric-bastion:latest
```

`up.sh` rebuilds them automatically when anything under `images/` is newer than the image.

---

## 3. Pick a profile

```bash
echo site-a-nx > profile              # or: site-a | site-b | site-b-nx
```

| Profile | Frontend | Notes |
|---|---|---|
| `site-a` | Cumulus VX | 4 GPU leaf pairs, storage leaf pair |
| `site-a-nx` | **Cisco Nexus 9300v** | vPC fabric peering, OSPF-unnumbered underlay + iBGP EVPN, VLAN/VRF per tenant |
| `site-b` | Juniper vEX | smaller frontend |
| `site-b-nx` | Nexus | the `-nx` design on a second host |

One generator serves all of them: `python3 gen.py` writes `ai-fabric.clab.yml`,
`configs/<device>.cfg` and `bootstrap/fw.xml`. **Edit `gen.py`, never the generated files.**

---

## 4. Deploy

```bash
./up.sh                       # gen.py -> images -> containerlab deploy -> finish.sh
```

Run it so it survives your SSH session dropping — a disconnect mid-deploy leaves a half-built lab:

```bash
systemd-run --unit=fabric-up --collect --setenv=HOME=/root \
  --property=WorkingDirectory=$PWD --property=TimeoutStartSec=0 \
  /bin/bash -lc './up.sh > up.log 2>&1'
# follow:  tail -f up.log      state: systemctl is-active fabric-up
```

`finish.sh` then runs nine idempotent stages, logged with elapsed time:

1. switches and firewall healthy
2. Kubernetes bootstrap on ctrl1 — **~40 min** first time, ~10 min on existing disks
3. boot-time files on every guest = repository (`node-sync.sh`)
4. all nodes Ready
5. fabric settled — east-west + routed sweeps until three clean rounds in a row
6. node classes, roles and lab CA certificates
7. profile services (Harbor, MinIO, network-operator, inference)
8. every pod Running
9. workstation kit + the operator steps it cannot do for you

**Budget ~90 minutes** for a first deploy on a fast host. Stages are idempotent — re-running
`./finish.sh` after a hiccup resumes rather than restarting.

### If bring-up is slow or the switches time out

On a slower host, cold-starting every switch in the same second overloads the disk and vrnetlab's
console bootstrap loses sync (symptoms: `Login incorrect`, a switch stuck at `loader >`, the PA-VM
stuck at `Enter old password`). The profile key `boot_stagger` spreads them out:

```python
boot_stagger=dict(ocnos=20, nxos_first=240, nxos=60)   # seconds, fed to clab startup-delay
```

---

## 5. Operator steps (stage 9 prints these)

**Open WebUI needs no API key.** `post-deploy.sh` brings up the lab's own model on the GPU nodes
(llama.cpp serving an Apache-2.0 GGUF, two replicas with RPC workers over the rails) and points Open
WebUI at it, so `https://webui.platform.lab.ai` answers chat requests with nothing outside the lab
involved. It prompts for nothing, so plain `ssh` is enough.

Only the *optional* inference gateway (`--gateway`: APISIX + LiteLLM, publishing
`inference.platform.lab.ai`) reaches OpenRouter for its three curated models, and only that branch
prompts for a key — those prompt for secrets and refuse to run without a terminal, so use `ssh -t`:

```bash
./post-deploy.sh                          # the lab's own model + Open WebUI (no key, no terminal needed)
./webui-wire.sh status                    # what Open WebUI points at, and how many models it offers
ssh -t <host> "$PWD/post-deploy.sh --gateway"   # ALSO the gateway (prompts for an OpenRouter key)
ssh -t <host> "$PWD/harbor-password.sh"   # Harbor admin password
ssh -t <host> "$PWD/fw-ui-cert.sh"        # firewall UI certificate from the lab CA
ssh -t <host> "$PWD/fw-backup.sh"         # save the firewall config as the next boot's baseline
./show-creds.sh                           # where the generated service credentials live
```

---

## 6. Prove it works

```bash
./validate-all.sh drills
```

Failure drills run first (disruptive, self-restoring — so everything after them also proves the
fabric recovered), then validation sections A–I, rail traces, an end-to-end trace, PVC traces
through the storage API, an RDMA/SoftRoCE probe, a full device audit and a warning-event sweep.
Each part writes its own directory under `audits/`; the summary lands in `audits/SUMMARY.md`.

A healthy run is **all parts PASS, 0 failed**. A handful of "known platform limitation" entries are
expected — they are virtual-platform gaps, not faults. Firewall-API sections are skipped unless
`FW_PASS` is set.

---

## 7. Day-2

| Task | Command |
|---|---|
| After a host reboot | `./boot.sh` — adopts a running lab, else redeploys on the **existing** guest disks (Kubernetes, Longhorn volumes, Harbor and secrets survive) |
| Clean shutdown | `./down.sh` — clean guest power-off then destroy. `./down.sh fast` skips the guest shutdown (only when the guests have nothing to flush) |
| Changed a boot-time file | `./node-sync.sh` — pushes `images/vm-node/node-files/*` to every guest and applies it live. `CHECK=1` reports drift without changing anything |
| Changed firewall policy | regenerate, then load `bootstrap/fw.xml` onto the PA-VM |
| Collect device state | `./audit.sh` |

**Always run long operations under `systemd-run`.** A backgrounded job dies with the SSH session —
that is how a lab ends up half-destroyed.

---

## 8. Traps worth knowing (each cost real debugging time)

- **`containerlab` keeps its own copy of each startup-config** under `clab-ai-fabric/`. A plain
  `deploy` reuses that stale copy — always `deploy -c` / `--reconfigure` so your regenerated
  `configs/` are what actually load.
- **Never `rsync --delete` into a deployed lab directory.** It wipes `clab-ai-fabric/` and leaves
  the switches unconfigured.
- **`docker restart` on a vrnetlab switch returns it without links.** To recover a wedged switch,
  reload it from inside its own CLI instead.
- **Rail-leaf memory climbs** on the OcNOS VMs. `host/rail-leaf-watchdog.*` reloads a leaf whose
  rail gateway stops answering, and stands down while a deploy or acceptance run is active.
- **QEMU RSS is a high-water mark** — it never falls back when a guest frees memory, so "used"
  figures overstate the steady state.
- **PAN-OS `partial merge` appends new security rules below the catch-all deny.** After loading a
  policy change, re-assert rule order or read the running rulebase back — "commit succeeded" does
  not mean a new rule is reachable.
- Verify any change by **reading state back from the device**, never from a command's exit status.

---

## What was removed for publication

| Removed | Why / how to restore |
|---|---|
| All credentials | placeholders; see `.env.example` |
| `common/authorized_keys` | held the author's real public keys — add your own |
| NX-OS type-5 hash, kubeadm join token + cert key | regenerate your own (commands in `.env.example`) |
| Vendor image names and versions | licensed — build with vrnetlab and set them in `.env` (section 2) |
| `configs/`, `bootstrap/fw.xml`, `*.clab.yml` | generated — run `python3 gen.py` |
| `nodes/`, `shared/`, `ca/`, `publish/`, `audits/` | runtime state, host-specific |
| The per-site directories | site-specific detail |
| Organisation and host names | the two hosts are now `site-a` / `site-b`, DNS `dns-a` / `dns-b` |

The diagrams, cabling matrices, generator and every script are intact.
