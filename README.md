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
│   └── requirements.yml          # Certified collection dependencies (Automation Hub)
├── rulebooks/
│   └── lm_remediation.yml        # EDA rulebook — single webhook listener, 3 rules
├── playbooks/
│   ├── snow_create_incident.yml  # Opens ServiceNow incident; publishes sys_id artifact
│   ├── cisco_no_shut.yml         # Cisco IOS: no-shut Tunnel0/Tunnel1 + resolve SNOW
│   ├── cpu_httpd_restart.yml     # Linux/Windows: restart httpd/IIS + resolve SNOW
│   ├── disk_space_cleanup.yml    # Linux: clean /tmp, log archives, journal + resolve SNOW
│   └── cisco_snmp_trap.yml       # One-time: configure SNMPv2c traps toward LogicMonitor
└── setup/
    └── aap_setup.yml             # Provisions all required AAP objects (run once)
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
- ServiceNow custom credential type and credential
- Localhost inventory
- 5 job templates
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
| `approval_timeout` | `3600` | Seconds before an approval node times out (0 = never) |

> **Security note:** Move `sn_password` out of plaintext for production. Use an external vault or pass it at runtime: `ansible-playbook setup/aap_setup.yml -e @vault_file.yml`

---

### Step 3 — Configure SNMP Traps on Cisco Devices (one-time)

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

### Step 4 — Create the EDA Rulebook Activation

In the EDA Controller UI:

1. Navigate to **Rulebook Activations → Create**
2. Set the rulebook to `rulebooks/lm_remediation.yml`
3. Under **Controllers**, select the AAP Controller token credential
4. Set **Restart Policy** to `Always`
5. Save and enable the activation

The activation listens on **port 5000** for incoming HTTP POST webhooks.

---

### Step 5 — Configure LogicMonitor HTTP Integration

In LogicMonitor, create an **HTTP Integration** (Integrations → Add → HTTP Delivery):

- **URL:** `http://<eda-host>:5000`
- **Method:** POST
- **Content-Type:** `application/json`
- **Body template:**

```json
{
  "alertId":     "##ALERTID##",
  "alertStatus": "##ALERTSTATUS##",
  "severity":    "##LEVEL##",
  "host":        "##HOST##",
  "dataSource":  "##DATASOURCE##",
  "dataPoint":   "##DATAPOINT##",
  "instance":    "##INSTANCE##",
  "value":       "##VALUE##",
  "message":     "##MESSAGE##",
  "startEpoch":  "##STARTEPOCH##",
  "threshold":   "##THRESHOLD##",
  "deviceGroup": "##DEVICEGROUP##"
}
```

Attach this integration to the relevant alert rules in LogicMonitor for the datasources you want to monitor.

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
