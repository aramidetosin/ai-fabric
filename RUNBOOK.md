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
starts shedding guests. Watch for *leftovers* too, not just running labs: another lab's pull-through
registry caches keep holding ports 5002-5005 even when none of its own nodes are up, and this lab's
caches then crash-loop. `registry-cache.sh start` now fails loudly and names the ports, because the
symptom otherwise arrives 20 minutes later as `ImagePullBackOff` on every node with nothing pointing
at a registry. Clear them with `docker ps | grep cache` and `docker stop <name>`.

---

## 1. Secrets — do this first

The published copy is sanitised. The two lab logins default to `admin` (the containerlab
convention) so the lab comes up out of the box; the **kubeadm join token and certificate key
have no usable default** and must be generated, or stage 2 fails.

```bash
cp .env.example .env
$EDITOR .env                  # set every value; generation commands are in the comments
set -a; . ./.env; set +a      # only needed when you run gen.py or another script BY HAND
```

`up.sh` sources `.env` itself, so the `systemd-run` form below needs no extra setup.

Then create your own key file (the original was removed for publication). **Operator keys only** —
anything else in this file is handed to the switches. Two roles matter:

* the **lab host's own root key** becomes NX-OS user `ops`, which the readiness checks
  (`nx-wait.sh`, `lib.sh NX()`) log in with. It is recognised by its `root@<host>` comment, so append
  the `.pub` file, which carries that comment — `ssh-keygen -y` prints the key *without* one.
* **your workstation key** becomes user `admin` (NX-OS allows one key per user).

```bash
cp common/authorized_keys.example common/authorized_keys
cat /root/.ssh/id_ed25519.pub >> common/authorized_keys    # on the LAB HOST -> user `ops`
cat ~/.ssh/id_ed25519.pub     >> common/authorized_keys    # your workstation -> user `admin`
# set LAB_WORKSTATION_KEY_COMMENT in .env to your workstation key's comment
```

Without an `ops` key the deploy stalls for 40 minutes at the Nexus readiness wait and then skips the
vPC fabric-peering TCAM carve, so check that `configs/fe-spine1.cfg` contains `username ops` after
`python3 gen.py`.

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

### Deploying with `containerlab deploy` directly

`up.sh` is a wrapper, not a replacement: the topology is an ordinary containerlab file, so you can
drive it yourself.

```bash
set -a; . ./.env; set +a
python3 gen.py                        # writes ai-fabric.clab.yml, configs/<device>.cfg, bootstrap/fw.xml
containerlab deploy -t ai-fabric.clab.yml --reconfigure --max-workers 8
```

`examples/ai-fabric.clab.example.yml` is that topology for the `site-b-nx` profile (67 nodes, 437
links) with placeholder images and fake secrets, committed so you can read it before running anything.
The real one is generated — it carries your image tags and kubeadm secrets, which is why `*.clab.yml`
is gitignored. `python3 gen.py --dns-zones <dir>` writes the DNS zones and nothing else.

A bare deploy gives you running containers, **not a working cluster**. It skips everything `up.sh`
does around it, each of which exists because of a failure it prevents:

| `up.sh` also does | why |
|---|---|
| holds the guests (`shared/hold-guests`) until the fabric converges | guests that boot first put LACP and MACs onto leaves still being configured, and the data plane keeps stale entries |
| `nx-wait.sh` — every Nexus docker-healthy **and** answering as `ops` | docker-healthy only means vrnetlab finished, not that the config applied |
| `nx-tcam-reload.sh` | vPC fabric peering needs a TCAM carve, which needs a save and a reload |
| re-runs `pc-init.sh` | the PA-VM finishing its boot bounces the PC links, and the kernel drops routes out of a downed device |
| `./finish.sh` | the nine stages below, from the Kubernetes bootstrap to the workstation kit |

Use the bare deploy to bring the topology up and inspect it; use `./up.sh` to get a lab that works.

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
console bootstrap loses sync. Symptoms: `Login incorrect`, a switch stuck at `loader >`, an N9Kv
looping in POAP (`POAP DHCP Discover phase started` over and over in `docker logs`, because the
launcher never answered the "Abort Power On Auto Provisioning" prompt), or the PA-VM stuck at
`Enter old password`. The profile key `boot_stagger` spreads them out:

```python
boot_stagger=dict(ocnos=20, nxos_first=240, nxos=60)   # seconds, fed to clab startup-delay
```

**Do not `docker restart` a wedged node.** containerlab wires each data link as a veth pair into the
container's network namespace, and vrnetlab then bridges every `ethN` to the VM's `tapN` with `tc`
filters installed once, at launch. Restarting the container destroys that namespace: the node comes
back with only `lo` and `eth0`, its launcher waits forever for interfaces that never appear — and
because the two ends of a veth die together, **each peer loses its interface too** (a restarted
border takes `eth8` off both spines and `eth2` off the firewall). Recreating those interfaces by
hand gives you a fabric that looks wired and silently drops flows, because the `tc` filters are gone.

**A wedged N9Kv can usually be recovered on its own, without redeploying.** An NX-OS VM that comes
back from a reload with its management interface dead has often booted its Linux layer while the
switch application never started. Its serial console is inside the container on port 5000, and that
console is the *VM's* shell, not the container's -- check before you type anything:

```bash
N=clab-ai-fabric-fe-ctrl-leaf1
docker exec $N sh -c '(printf "uname -r; ls -d /isan\n"; sleep 5) | timeout 12 telnet 127.0.0.1 5000'
# the VM answers with its own kernel (5.10.x) and /isan; the CONTAINER has neither
docker exec $N sh -c '(printf "reboot\n"; sleep 6) | timeout 12 telnet 127.0.0.1 5000'
```

NX-OS turns that into a sysrq crash-and-reboot, which looks alarming (`nxos_panic: Kernel panic`)
but is how it restarts from bash. The VM reboots with its saved startup-config, the container and
every veth stay in place, and the switch comes back in ~8-12 minutes with its TCAM carve active.
Verify: `ssh ops@<mgmt> "show hardware access-list tcam region | include redirect"`.

If that does not bring it back, re-run the deploy. `up.sh` calls `containerlab deploy --reconfigure`,
which rebuilds every container and every link, and each switch gets a clean console bootstrap:

```bash
systemctl stop fabric-up          # if it is still sitting in the Nexus wait
./up.sh                           # or the systemd-run form above
```

Guest disks under `nodes/` are kept, so the Kubernetes bootstrap resumes in ~10 minutes instead of
~40. If only the *wait* timed out and the switches are actually fine, nothing needs redeploying:
`./nx-wait.sh`, `./nx-tcam-reload.sh` and `./finish.sh` resume from there — all three are idempotent.

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
| Organisation and host names | the two hosts are now `site-a` / `site-b`, DNS `dns-a` / `dns-b`, and the office workstations are unnamed |
| The Ubuntu cloud image | ~600 MB, download it yourself (section 2) |
| An unrelated NMS integration | a vendor product with its own licensed demo VM; nothing in this lab depended on it |

One **functional** rename came with publication: the Kubernetes label domain is now
`node-role.ai-fabric.lab/*` (and `ai-fabric.lab/lb-pool`). It is applied consistently by the
bootstrap and expected consistently by `roles.sh`, `validate.sh`, `netop.sh` and the Cilium LB
pools, so a clean deploy needs nothing from you — but labels you already have on an older cluster
will not match.

The diagrams, cabling matrices, the generator and the scripts are intact, including the inference
gateway tooling in `scripts/`. A few ad-hoc debugging scripts were dropped.
