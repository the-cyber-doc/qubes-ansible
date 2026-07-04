# qubes-ansible

Ansible automation for a [Qubes OS](https://www.qubes-os.org/) workstation.
Provisions, configures, and wires together the VM stack from a single entry point.

---

## Goal

Qubes OS is built around strong VM isolation, but managing dozens of VMs by hand
is error-prone and hard to reproduce. This project replaces manual `qvm-*` commands
and GUI clicks with idempotent Ansible playbooks that can rebuild any part of the
system from scratch, or be re-run safely against an already-running setup to push
incremental changes.

Specifically it automates:

- **Dom0** — package updates, utility scripts (e.g. `reset-vm-resources.sh`), and optional secure-boot key management
- **LLM stack** — NVIDIA driver/CUDA installation, Ollama service, model pulling,
  GPU PCI passthrough, and TCP proxy wiring so `claude-code` can reach the model
- **OCR stack** — PDF OCR service backed by the LLM DispVM, with its own TCP proxy
- **sys-gpu** — a shared GPU DispVM template for workloads that need the card but
  not Ollama
- **Messaging** — Signal, WhatsApp (Whatsie), and Chrome in an isolated Fedora AppVM
- **Burp** — a disposable web-testing VM: Burp Suite Community auto-starts its proxy and
  Firefox is pre-configured to route its traffic through Burp; a fresh disposable is spawned
  on every launch
- **Base packages** — `htop` and `tmux` on every Linux template and standalone VM

---

## Design choices

### Why a wrapper script instead of plain `ansible-playbook`

Ansible evaluates the `hosts:` field of every play *before* it loads `vars_files`.
This means any variable used in a `hosts:` pattern must be injected via `-e` (extra
vars) or be in the inventory — it cannot live in a vars file.

`ansible-playbook.sh` solves this transparently. It reads every file under
`playbooks/vars/` plus `group_vars/all.yml`, resolves simple Jinja2 references,
and passes every variable whose name starts with `host_` as an `-e` flag before
forwarding all arguments to `ansible-playbook`.

### `strategy = qubes_proxy`

The `qubes` connection plugin (used for every `appvms`/`templatevms`/`standalonevms`/
`disp_vms` host) talks to target VMs via `qvm-run`, run by the `ansible-playbook`
process itself. With Ansible's default `linear` strategy, that means a target qube's
output is parsed directly inside the controller process — which this project runs
from Dom0. A compromised or malicious qube could exploit that to reach Dom0.

`qubes_proxy` (set globally in `ansible.cfg`) closes that hole: instead of connecting
directly, it proxies the connection through a fresh management disposable
(`disp-mgmt-<template>`) based on the target's own template. A hostile response can
at most compromise that disposable, not the controller. This requires the
`qubes.AnsibleVM` qrexec service — installed by the `qubes-ansible-vm` (Fedora) /
`qubes-ansible` (Debian) package — to be present in every template that will be
targeted; `base.yml` bootstraps it automatically (see below).

### `host_` prefix convention

Variables used directly in a `hosts:` pattern are named `host_<feature>_<descriptor>`
(e.g. `host_llm_template`, `host_ocr_dvm`). The prefix is the signal to the wrapper
that the variable must be pre-injected. All other variables are loaded normally via
`vars_files` at play execution time.

### VM provisioning pattern

Every feature with a DispVM follows the same four-phase sequence:

```
Template → DVM → DispVM → Networking
```

1. **Template** — clone a base Qubes template, temporarily enable networking,
   install packages and services inside the VM, then remove networking and shut down.
   The `base_packages` and `firefox` roles run here first on every template to establish a baseline
   (the `base.yml` play installs Firefox with the `fireshot` and `print_edit_we` optional extensions).
2. **DVM** — create an AppVM with `template_for_dispvms=true`. This is the
   *persistent layer*: bind-dirs are configured here and models are pulled into
   this VM's private volume so they survive DispVM restarts.
3. **DispVM** — create the final stateless VM (`class DispVM`) with PCI passthrough,
   fixed memory, and the DVM as its template. Restarting this VM always starts
   fresh from the DVM snapshot.
4. **Networking** — add a `qubes.ConnectTCP` policy rule in Dom0 and write a
   `qvm-connect-tcp` line into the client VM's `rc.local` so the TCP tunnel is
   re-established on every boot.

### Variable scoping

Variables are split by the scope at which they are meaningful:

| Scope | Location |
|-------|----------|
| Truly global (paths, netvm, Debian version) | `playbooks/group_vars/all.yml` |
| Feature-specific (VM names, ports, memory) | `playbooks/vars/<feature>.yml` |
| Role defaults (URLs, folder paths) | `roles/<role>/defaults/main.yml` |

Each play loads only the vars files it needs. The LLM DispVM play additionally
loads `vars/sys_gpu.yml` to get the GPU PCI IDs. The OCR DVM play loads
`vars/llm.yml` to know the LLM port and DispVM name.

### Windows exclusion

Windows VMs are listed in an explicit `windows_vms` inventory group. Any play that
must skip Windows uses the `:!windows_vms` host pattern exclusion. The `base_packages`
role also guards every task with `when: ansible_os_family == 'Debian'` or
`when: ansible_os_family == 'RedHat'`, so it is harmless even if a Windows host
is accidentally targeted.

### Disabled tasks

`when: 0 > 1` marks tasks that are intentionally disabled. This keeps the YAML
structure intact (variables still need to be defined, the intent is documented)
without removing the code.

---

## File structure

```
.
├── ansible-playbook.sh          # Wrapper — always use this instead of ansible-playbook
├── ansible.cfg                  # Sets inventory = ./inventory, roles_path = ./roles, strategy = qubes_proxy
├── site.yml                     # Top-level entry point; imports all feature playbooks
│
├── inventory/
│   └── hosts.yml                # All VMs grouped by type; windows_vms group for exclusion
│
├── playbooks/
│   ├── base.yml                 # Installs base packages + Firefox on all Linux templates + standalones
│   ├── dom0.yml                 # Dom0: secure boot key management
│   ├── llm.yml                  # LLM stack: template → DVM → DispVM → networking
│   ├── ocr.yml                  # OCR stack: template → DVM → DispVM → networking
│   ├── sys_gpu.yml              # sys-gpu: template → DVM → DispVM
│   ├── messenging.yml           # Messaging: template packages + AppVM autostart
│   ├── burp.yml                 # Burp: template (Burp + Firefox proxy) → disposable template
│   │
│   ├── group_vars/
│   │   └── all.yml              # Global vars: paths, netvm, debian_version
│   │
│   ├── vars/
│   │   ├── llm.yml              # host_llm_template, host_llm_dvm, llm_memory, llm_tcp_port …
│   │   ├── ocr.yml              # host_ocr_template, host_ocr_dvm, ocr_tcp_port …
│   │   ├── sys_gpu.yml          # host_sys_gpu_template, gpu_pci_id_vga, gpu_pci_id_audio …
│   │   ├── messenging.yml       # host_messenging_template, host_messenging_vm …
│   │   └── burp.yml             # host_burp_template, host_burp_dvm, burp_dispvm, burp_proxy_port …
│   │
│   └── tasks/
│       └── clone_template.yml         # Reusable: clone + set netvm + set qrexec_timeout
│
└── roles/
    ├── base_packages/           # htop + tmux + ... on any Linux VM (apt or dnf via ansible_os_family)
    ├── llm_template/            # NVIDIA drivers, CUDA, Ollama service + systemd overrides
    ├── llm_dvm_1/               # Qubes bind-dirs for /usr/share/ollama (model persistence)
    ├── llm_dvm_2/               # Pull Ollama models; create custom 32k/8k context variants
    ├── ocr_template/            # Python3 + venv tooling
    ├── ocr_dvm/                 # Clone local-llm-pdf-ocr, UV venv, .env, start.sh, rc.local
    ├── sys_gpu_template/        # NVIDIA drivers + CUDA (no Ollama)
    ├── sys_gpu_dvm/             # Empty — no additional DVM config needed
    ├── secureboot/              # sbctl backup/restore scripts + kernel install hook
    ├── messenging/              # Chrome, Snap, Signal, Whatsie; autostart symlinks
    ├── burp_template/           # Installs Burp Suite Community + Firefox cert tooling (certutil)
    ├── burp_dvm/                # Burp proxy config + autostart session script (start Burp → trust CA → open Firefox)
    ├── firefox/                 # Firefox install, policies, and skel profile
    └── set_prefs/               # Reusable: set qrexec_timeout / maxmem / memory / vcpus on any VM
```


---

## Firefox role

The `firefox` role installs Firefox and applies a base configuration that works for
any template or AppVM. It is not wired into `site.yml` by default — include it from
whichever feature playbook needs it.

### What the role always does

- Installs `firefox-esr` (Debian) or `firefox` (Fedora/RedHat)
- Deploys an enterprise `policies.json` that:
  - Does not check for default browser
  - Skips the first-run welcome page
  - Sets DuckDuckGo as the homepage
  - Force-installs **uBlock Origin** and **Adblock Plus** (user cannot remove)
- Places a pre-configured profile skeleton in `/etc/skel/.mozilla/firefox/` so every
  AppVM that is created from the template inherits the profile automatically
- Rewrites the `Exec=` lines of the system `.desktop` launcher
  (`firefox-esr.desktop` on Debian, `firefox.desktop` on RedHat) to add
  `-P {{ firefox_profile_name }}`, so launching Firefox always opens the skel
  profile instead of a fresh per-install "dedicated profile" (which would ignore the
  deployed `user.js` and any imported certificates)

### Routing through a proxy

Set `firefox_proxy` to `host:port` when calling the role to add a locked manual-proxy
policy that routes all protocols through that address (left empty by default). The
`burp` playbook uses this to point Firefox at the local Burp listener:

```yaml
- role: firefox
  vars:
    firefox_proxy: "127.0.0.1:{{ burp_proxy_port }}"
```

### Optional extensions

A catalog of pre-defined optional extensions lives in
`roles/firefox/defaults/main.yml` under `firefox_available_extra_extensions`.
Set `firefox_extra_extensions` to a list of catalog keys in the playbook that
calls the role:

```yaml
- hosts: "{{ host_my_template }}"
  connection: qubes
  roles:
    - role: firefox
      vars:
        firefox_extra_extensions:
          - multi_account_containers
          - facebook_container
          - google_container
          - temporary_containers
          - print_edit_we
          - fireshot
          - cookies_txt
```

Optional extensions are installed on first Firefox launch (requires network in the
AppVM) and can be removed by the user, unlike the force-installed base extensions.

Available catalog keys:

| Key | Extension |
|-----|-----------|
| `print_edit_we` | Print Edit WE |
| `fireshot` | FireShot |
| `multi_account_containers` | Firefox Multi-Account Containers |
| `temporary_containers` | Temporary Containers |
| `facebook_container` | Facebook Container |
| `google_container` | Google Container |
| `cookies_txt` | Get cookies.txt LOCALLY |

### Adding a new extension to the catalog

Open `roles/firefox/defaults/main.yml` and add an entry under
`firefox_available_extra_extensions`:

```yaml
firefox_available_extra_extensions:
  # ... existing entries ...
  my_extension:
    install_url: "https://addons.mozilla.org/firefox/downloads/latest/<amo-slug>/latest.xpi"
```

Where `<amo-slug>` is the extension's URL slug on
[addons.mozilla.org](https://addons.mozilla.org) (the last path segment on the
extension's AMO page). Once added, `my_extension` becomes a valid key in any
playbook's `firefox_extra_extensions` list.

### LLM networking topology

```
claude-code (AppVM)
    │  qvm-connect-tcp 11434:@default:11434  (rc.local)
    ▼
qubes.ConnectTCP policy → llm-disp (DispVM, GPU passthrough)
                               │  Ollama :11434

ocr-disp (DispVM)
    │  qvm-connect-tcp 11434:@default:11434  (rc.local)
    ▼
qubes.ConnectTCP policy → llm-disp
```

---

## First-time setup

Secret variables (currently just `admin_user`, your Dom0 username) are kept in an
Ansible-vault-encrypted file that **is committed to the repository** — the ciphertext
is safe to share, only the vault password must be kept private.

### 1. Create and encrypt the vault file

```bash
ansible-vault create playbooks/group_vars/all/secrets.yml
```

Ansible will open your editor. Paste the content from the example file and fill in
your values:

```bash
cat playbooks/group_vars/all/secrets.yml.example
```

Minimal content:

```yaml
admin_user: your_dom0_username
```

Save and close the editor. The file is now AES-256 encrypted on disk and safe to
commit.

### 2. Supply the vault password at runtime

**Option A — prompt each run (simplest):**

```bash
./ansible-playbook.sh site.yml --tags dom0 --ask-vault-pass
```

**Option B — password file (recommended for repeated use):**

```bash
echo 'your_vault_password' > .vault_pass
chmod 600 .vault_pass
```

`.vault_pass` is listed in `.gitignore` and will never be committed. The wrapper
script detects it automatically and passes it to `ansible-playbook` — no extra flag
needed:

```bash
./ansible-playbook.sh site.yml --tags dom0
```

### Adding new secrets

Open the vault for editing:

```bash
ansible-vault edit playbooks/group_vars/all/secrets.yml
```

Add the new variable in plain YAML. It is immediately available in every playbook
and role as a normal Ansible variable — no `vars_files` entry needed because the
vault file lives in `group_vars/all/` and Ansible loads that directory automatically
for every play.

Also add the variable to `secrets.yml.example` (without the real value) so other
users know what to provide.

---

## Testing before running

Ansible syntax checks validate YAML structure and module references without
connecting to any VM. Run this after every change:

```bash
# Check a single playbook
./ansible-playbook.sh playbooks/llm.yml --syntax-check
./ansible-playbook.sh playbooks/ocr.yml --syntax-check
./ansible-playbook.sh playbooks/sys_gpu.yml --syntax-check
./ansible-playbook.sh playbooks/messenging.yml --syntax-check
./ansible-playbook.sh playbooks/burp.yml --syntax-check
./ansible-playbook.sh playbooks/base.yml --syntax-check

# Or via site.yml with a tag
./ansible-playbook.sh site.yml --tags llm --syntax-check
```

**Expected false positive:** outside Dom0, every playbook that uses the `qubesos`
module reports `couldn't resolve module/action 'qubesos'`. This collection is only
installed on Dom0 and is not an error introduced by your change. All other errors
must be fixed before running.

To see which tasks would execute without making any changes:

```bash
./ansible-playbook.sh site.yml --tags llm --list-tasks
./ansible-playbook.sh site.yml --tags llm --check
```

> `--check` (dry-run) has limited usefulness here because many tasks use `command`
> and `shell` modules that always report "skipped" in check mode. Use it as a
> sanity check on variable resolution and conditionals, not as a guarantee.

---

## Running

All commands must be run from **Dom0**, at the project root.
Always use `./ansible-playbook.sh` — never `ansible-playbook` directly.

### Run a single feature end-to-end

```bash
# Provision the full LLM stack (template → DVM → DispVM → networking)
./ansible-playbook.sh site.yml --tags llm

# Provision the OCR stack
./ansible-playbook.sh site.yml --tags ocr

# Provision the GPU passthrough VM
./ansible-playbook.sh site.yml --tags sys-gpu

# Provision the messaging AppVM
./ansible-playbook.sh site.yml --tags messenging

# Provision the Burp disposable web-testing template (Burp + Firefox proxy)
./ansible-playbook.sh site.yml --tags burp

# Apply Dom0 configuration (package updates, scripts — secureboot excluded)
./ansible-playbook.sh site.yml --tags dom0
```

> **Burp disposable usage.** Launch the **Burp Suite Web-Testing Session** entry of
> the `burp-dvm` disposable template (it spawns a fresh disposable). Burp's Community
> EULA is pre-seeded (Java pref `eulafree`) and the session is launched with
> `--config-file`, so Burp starts straight into its proxy without prompts. The session
> script then waits for the proxy, trusts Burp's CA in the Firefox profile, and opens
> Firefox (already routed through Burp), so its force-installed extensions download
> successfully. Progress is logged to `~/.burp-session.log` in the disposable.

### Configure secure boot (Dom0 — explicit opt-in)

The `secureboot` role is tagged `never` and does **not** run as part of the normal
`--tags dom0` run. Invoke it explicitly when you need to (re)deploy the sbctl
backup/restore scripts or the kernel install hook:

```bash
# Run secureboot alongside the full Dom0 setup
./ansible-playbook.sh site.yml --tags dom0,secureboot

# Run secureboot alone (skips package updates and other Dom0 tasks)
./ansible-playbook.sh playbooks/dom0.yml --tags secureboot
```

### Install or update base packages on all Linux VMs

This targets every Linux template and standalone VM in the inventory. Safe to
re-run at any time against already-running systems.

```bash
./ansible-playbook.sh site.yml --tags base

# Or directly against the playbook (same effect)
./ansible-playbook.sh playbooks/base.yml
```

Before touching any template over `connection: qubes`, `base.yml` first bootstraps
the `qubes-ansible-vm` (Fedora) / `qubes-ansible` (Debian) package into every
template that doesn't already have it. This package provides the `qubes.AnsibleVM`
qrexec service that the `qubes_proxy` strategy (see below) needs to proxy a
connection through a management disposable based on that template. The bootstrap
itself runs over `connection: local` with raw `qvm-run` — using `connection: qubes`
here would be circular, since the management disposable it would need is based on
the very template that doesn't have the service yet. Already-bootstrapped templates
are skipped (network is only toggled on and the template only shut down for
templates that actually needed the install).

### Run everything

```bash
./ansible-playbook.sh site.yml
```

### Resume from a specific task

Useful when a long playbook fails partway through and you want to skip the steps
that already succeeded.

```bash
# Resume LLM provisioning from model pulling
./ansible-playbook.sh site.yml --tags llm --start-at-task "Pull Gemma 4 E4B model"

# Resume OCR provisioning from the DVM networking step
./ansible-playbook.sh site.yml --tags ocr --start-at-task "Set network policy for OCR → LLM"
```

### Override a variable at runtime

```bash
# Increase LLM DispVM memory for a session
./ansible-playbook.sh site.yml --tags llm -e "llm_memory=16000"

# Point the LLM template at a different base
./ansible-playbook.sh site.yml --tags llm -e "llm_base_template=debian-13-xfce-custom"

# Change which AppVM gets the LLM TCP tunnel
./ansible-playbook.sh site.yml --tags llm -e "host_llm_claude_code=my-other-vm"
```

### Target a specific VM directly

```bash
# Run only the base_packages role on a single template that is already running
ansible -i inventory/hosts.yml llm-template-debian-13-xfce \
  -m include_role -a name=base_packages --become
```

### Limit execution to a subset of hosts

```bash
# Re-run the LLM playbook but only the plays that target Dom0 (local)
./ansible-playbook.sh playbooks/llm.yml --limit localhost

# Re-run base on Debian templates only
./ansible-playbook.sh playbooks/base.yml --limit 'debian*'
```

---

## Editing workflow (edit outside Dom0, sync in)

Dom0 is intentionally kept minimal, so the project is edited on a separate VM and
synced into Dom0 through a compressed archive rather than a shared folder.

1. **Edit the Ansible project on the VM where it resides** (e.g. `my-ansible-vm`),
   not in Dom0 directly.
2. **Compress the files** with `./compress.sh`. It archives the project root into
   `/tmp`, e.g. `/tmp/qubes-ansible_20260704_152237.tar.7z`.
3. **Copy the archive to Dom0.** From Dom0:
   ```bash
   qvm-run -p my-ansible-vm 'cat /tmp/qubes-ansible_20260704_152237.tar.7z' > /tmp/qubes-ansible.tar.7z
   ```
4. **Extract the archive** from Dom0 with `./compress.sh -d` (extracts every
   `qubes-ansible*.tar.7z` found in `/tmp` into a matching `/tmp/qubes-ansible_.../` directory).
5. **Copy the files into the existing project:**
   ```bash
   cp -rf /tmp/qubes-ansible/* ~/Templates/qubes-ansible
   ```
6. **Run a playbook** as usual from Dom0, e.g.:
   ```bash
   ./ansible-playbook.sh site.yml --tags burp
   ```
