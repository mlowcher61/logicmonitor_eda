# LogicMonitor + Event-Driven Ansible Auto-Remediation

Closed-loop auto-remediation solution that connects **LogicMonitor** alerts to **Ansible Automation Platform (AAP) 2.6** through **Event-Driven Ansible (EDA)**. When LogicMonitor detects an issue, a webhook fires to EDA, which opens a ServiceNow incident, pauses for human approval, then executes targeted remediation — all without manual intervention beyond the approval step.

---

## Architecture Overview

```
LogicMonitor Alert
       │
       │  HTTP POST (webhook)
       ▼
EDA Controller (port 5000)
       │
       │  Matches rulebook condition
       ▼
AAP Workflow Template
       │
       ├─── Node 1: Create ServiceNow Incident
       │
       ├─── Approval Node  ◄── Human reviews & approves
       │
       └─── Node 2: Remediation Playbook
                  │
                  └─── Resolves ServiceNow Incident on success
```

---

## Repository Structure

```
logicmonitor-eda-aap/
├── collections/
│   └── requirements.yml              # Certified collection dependencies (Automation Hub)
├── rulebooks/
│   └── lm_remediation.yml            # EDA rulebook — single webhook listener, 3 rules
├── playbooks/
│   ├── logicmonitor_configure.yml    # One-time: configure LM integrations, chains, and alert rules
│   ├── snow_create_incident.yml      # Opens ServiceNow incident; publishes sys_id artifact
│   ├── cisco_no_shut.yml             # Cisco IOS: no-shut Tunnel0/Tunnel1 + resolve SNOW
│   ├── cpu_httpd_restart.yml         # Linux/Windows: restart httpd/IIS + resolve SNOW
│   ├── disk_space_cleanup.yml        # Linux: clean /tmp, log archives, journal + resolve SNOW
│   ├── cisco_snmp_trap.yml           # One-time: configure SNMPv2c traps toward LogicMonitor
│   └── tasks/
│       ├── lm_api_call.yml           # Reusable: LMv1 HMAC-SHA256 auth + API request helper
│       └── lm_alert_rule.yml         # Reusable: idempotent LM alert rule create helper
└── setup/
    └── aap_setup.yml                 # Provisions all required AAP objects (run once)
```

---

## Monitored Events & Remediation Workflows

| # | LogicMonitor Trigger | DataSource | DataPoint | Condition | AAP Workflow |
|---|---|---|---|---|---|
| 1 | Cisco protected interface down | `Cisco_IOS_Interfaces` | `ifOperStatus` | instance = `Tunnel0` or `Tunnel1`, alertStatus = `active` | `LM - Cisco Interface Remediation` |
| 2 | High CPU / web server down | `Linux_CPU` / `WinCPU` | `CPUBusyPercent` | severity = `critical` | `LM - CPU High Utilization Remediation` |
| 3 | Disk space critical | `Linux_Disk` | `Capacity` | severity = `error` or `critical` | `LM - Disk Space Remediation` |

> **Note:** Verify your LogicMonitor datasource and datapoint names match those above. They may differ by LM version or customization. Update `rulebooks/lm_remediation.yml` if needed.

---

## What Each Workflow Does

### Workflow 1 — Cisco Interface Remediation
1. Creates a ServiceNow incident with alert details (category: Network, group: Network Operations)
2. Pauses for approval — reviewer sees the affected device and interface in the SNOW ticket
3. Connects to the Cisco IOS router via SSH and issues `no shutdown` on the interface
4. Verifies the interface reaches `up/up` state (retries for up to 60 seconds)
5. Resolves the ServiceNow incident with before/after state and running config

### Workflow 2 — CPU High Utilization Remediation
1. Creates a ServiceNow incident with CPU % and alert details (category: Software, group: Application Support)
2. Pauses for approval
3. Detects OS (Linux or Windows) automatically via `gather_facts`
4. **Linux:** restarts `httpd` (RHEL/CentOS) or `apache2` (Debian/Ubuntu), verifies service is active, tests HTTP response
5. **Windows:** restarts `W3SVC` (IIS), verifies service state
6. Resolves the ServiceNow incident

### Workflow 3 — Disk Space Remediation
1. Creates a ServiceNow incident with filesystem and utilization details (category: Infrastructure, group: Server Operations)
2. Pauses for approval
3. Removes `/tmp` files older than 7 days
4. Removes compressed log archives (`*.gz`, `*.bz2`, `*.xz`) in `/var/log` older than 30 days
5. Vacuums systemd journal to 200 MB
6. Resolves the SNOW incident if disk drops below 80%; escalates urgency if still critical

---

## Prerequisites

Before running the setup playbook, ensure the following exist in AAP:

| Requirement | Details |
|---|---|
| **AAP Project** | Named `LogicMonitor Automation`, synced to this repo's SCM URL |
| **Inventory: Network Devices** | Contains Cisco IOS routers; hostnames must match LogicMonitor `##HOST##` values |
| **Inventory: Managed Servers** | Contains Linux and/or Windows servers managed by LogicMonitor |
| **Credential: net_cred** | Machine credential type; SSH access to Cisco devices |
| **Credential: linux_server_cred** | Machine credential type; SSH access to Linux/Windows servers (update name in vars if different) |
| **EDA Controller** | Configured with an AAP Controller token under Controllers |

---

## Deployment Guide

### Step 1 — Install Certified Collections

Configure `ansible.cfg` with your Automation Hub token, then run:

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

Your `ansible.cfg` needs:

```ini
[galaxy]
server_list = automation_hub

[galaxy_server.automation_hub]
url = https://console.redhat.com/api/automation-hub/
auth_url = https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
token = <your_automation_hub_token>
```

---

### Step 2 — Run the AAP Setup Playbook

The setup playbook provisions all AAP objects in a single run:
- ServiceNow and LogicMonitor custom credential types and credentials
- Localhost inventory
- 6 job templates
- 3 workflow templates with approval nodes

**Set your AAP controller connection via environment variables:**

```bash
export CONTROLLER_HOST=https://your-aap-controller.example.com
export CONTROLLER_USERNAME=admin
export CONTROLLER_PASSWORD=yourpassword
```

**Run the setup playbook:**

```bash
ansible-playbook setup/aap_setup.yml
```

The playbook is idempotent — safe to re-run if you need to update or recreate objects.

**Key variables in `setup/aap_setup.yml` (review before running):**

| Variable | Default | Description |
|---|---|---|
| `aap_organization` | `Default` | AAP organization to create objects under |
| `aap_project_name` | `LogicMonitor Automation` | Name of the AAP project pointing to this repo |
| `network_inventory` | `Network Devices` | Inventory containing Cisco routers |
| `server_inventory` | `Managed Servers` | Inventory containing Linux/Windows servers |
| `cisco_credential_name` | `net_cred` | Machine credential for Cisco SSH |
| `server_credential_name` | `linux_server_cred` | Machine credential for server SSH/WinRM |
| `snow_credential_name` | `servicenow` | Name for the created ServiceNow credential |
| `sn_host` | *(your instance URL)* | ServiceNow instance URL |
| `lm_credential_name` | `logicmonitor` | Name for the created LogicMonitor credential |
| `lm_company` | `ACME` | LogicMonitor account subdomain — **update before running** |
| `lm_access_id` | *(placeholder)* | LogicMonitor API access ID — **update before running** |
| `lm_access_key` | *(placeholder)* | LogicMonitor API access key — **update before running** |
| `approval_timeout` | `3600` | Seconds before an approval node times out (0 = never) |

> **Security note:** Move `sn_password` and `lm_access_key` out of plaintext for production. Use an external vault or pass them at runtime: `ansible-playbook setup/aap_setup.yml -e @vault_file.yml`

---

### Step 3 — Configure LogicMonitor via Playbook

`logicmonitor_configure.yml` automates all LogicMonitor configuration through the LM REST API. It creates three objects from scratch:

| Object | Name | Purpose |
|---|---|---|
| HTTP Integration | `EDA Auto-Remediation Webhook` | Delivers alert payloads via HTTP POST to the EDA listener on port 5000 |
| Escalation Chain | `EDA Auto-Remediation Chain` | Routes matching alerts to the HTTP integration immediately (0-minute delay) |
| Alert Rule × 3 | `EDA - Cisco Interface Down` / `EDA - CPU High Utilization` / `EDA - Disk Space Critical` | Filters alerts by datasource and datapoint and assigns the escalation chain |

All three tasks are **idempotent** — re-running the playbook skips objects that already exist.

#### Before running

Update the `logicmonitor` credential in AAP with your real values. API tokens are created in LogicMonitor under **Settings → Users and Roles → API Tokens**.

#### Run from AAP

Launch the `LM - Configure LogicMonitor` job template. No extra variables are needed for a standard run.

#### Run from the command line

```bash
export CONTROLLER_HOST=https://your-aap-controller.example.com
ansible-playbook playbooks/logicmonitor_configure.yml
```

The `LM_COMPANY`, `LM_ACCESS_ID`, and `LM_ACCESS_KEY` environment variables must be present (injected automatically when run as an AAP job template with the `logicmonitor` credential attached).

#### Verify your datasource names first (optional but recommended)

LogicMonitor datasource names vary between LM versions and installed packages. Before creating alert rules, you can run the playbook in discovery mode to list every active datasource name in your LM instance:

**From AAP:** Launch `LM - Configure LogicMonitor` with the extra variable:
```
lm_discover_only=true
```

**From the command line:**
```bash
ansible-playbook playbooks/logicmonitor_configure.yml -e "lm_discover_only=true"
```

The playbook will print a sorted list of all datasource names and exit without making any changes. Compare the output against the defaults used in the alert rules:

| Alert Rule | Default Datasource | Default DataPoint |
|---|---|---|
| EDA - Cisco Interface Down | `Cisco_IOS_Interfaces` | `ifOperStatus` |
| EDA - CPU High Utilization | `*` (any) | `CPUBusyPercent` |
| EDA - Disk Space Critical | `Linux_Disk` | `Capacity` |

If your LM instance uses different names, update the `alert_rules` var in `playbooks/logicmonitor_configure.yml` before running, or pass overrides as extra variables.

#### How LM authentication works

Every API call to LogicMonitor uses **LMv1 HMAC-SHA256** authentication. The reusable helper `playbooks/tasks/lm_api_call.yml` handles this automatically:

1. Takes the HTTP method, resource path, and request body
2. Computes `HMAC-SHA256(AccessKey, method + epoch_ms + body + /santaba/rest<path>)`
3. Base64-encodes the signature and builds the `Authorization: LMv1 <id>:<sig>:<epoch>` header
4. Executes the `uri` call and returns the result in `lm_response`

The access key is never written to disk — it stays in the environment variable injected by the `logicmonitor` credential.

---

### Step 4 — Configure SNMP Traps on Cisco Devices (one-time)

Run the `LM - Cisco SNMP Trap Configuration` job template from AAP, or directly:

```bash
ansible-playbook playbooks/cisco_snmp_trap.yml -e "logicmonitor_ip=<collector_ip>"
```

This configures on all hosts in the `cisco` inventory group:
- SNMPv2c community `claudeaccess` (RW)
- Trap destination pointing to the LogicMonitor collector
- Trap source interface: `Tunnel1`
- Traps enabled: `linkup`, `linkdown`, `bgp`, `config`

---

### Step 5 — Create the EDA Rulebook Activation

In the EDA Controller UI:

1. Navigate to **Rulebook Activations → Create**
2. Set the rulebook to `rulebooks/lm_remediation.yml`
3. Under **Controllers**, select the AAP Controller token credential
4. Set **Restart Policy** to `Always`
5. Save and enable the activation

The activation listens on **port 5000** for incoming HTTP POST webhooks.

---

## ServiceNow Credential

The setup playbook creates a **custom credential type** named `ServiceNow` in AAP. It injects the following environment variables into any job template that uses it:

| Environment Variable | Description |
|---|---|
| `SN_HOST` | ServiceNow instance URL |
| `SN_USERNAME` | ServiceNow username |
| `SN_PASSWORD` | ServiceNow password |

These variables are consumed by the `servicenow.itsm.incident` module in all playbooks. No credential values are hardcoded in the playbooks themselves.

---

## LogicMonitor Credential

The setup playbook creates a **custom credential type** named `LogicMonitor` in AAP. It injects the following environment variables into any job template that uses it:

| Environment Variable | Description |
|---|---|
| `LM_COMPANY` | LogicMonitor account subdomain (e.g. `acme` for `acme.logicmonitor.com`) |
| `LM_ACCESS_ID` | LogicMonitor API access ID |
| `LM_ACCESS_KEY` | LogicMonitor API access key (secret) |

These are consumed by `playbooks/logicmonitor_configure.yml` and `playbooks/cisco_snmp_trap.yml`. The access key is used exclusively inside the `lm_api_call.yml` helper to compute HMAC signatures in memory — it is never written to disk or logged.

To create API tokens in LogicMonitor: **Settings → Users and Roles → API Tokens → Add**.

---

## Workflow Approval

Each workflow pauses at an **approval node** before executing remediation. To approve:

1. In AAP, navigate to **Jobs** or **Workflow Approvals**
2. Find the pending approval for the triggered workflow
3. Review the linked ServiceNow incident for full alert context
4. Click **Approve** to proceed or **Deny** to cancel

Approvals time out after **1 hour** by default (configurable via `approval_timeout` in `setup/aap_setup.yml`).

---

## Collections Used

All collections are sourced from Red Hat Automation Hub (certified content).

| Collection | Purpose |
|---|---|
| `ansible.eda` | EDA rulebook source plugins and actions |
| `ansible.controller` | AAP object provisioning (setup playbook) |
| `servicenow.itsm` | ServiceNow incident create/update/resolve |
| `cisco.ios` | Cisco IOS configuration and command execution |
| `ansible.windows` | Windows service management |
