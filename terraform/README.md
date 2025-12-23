## Terraform bootstrap (head or worker)

This Terraform + shell helper provisions the local metal node as either the head or a worker by installing dependencies, wiring `direnv`, prompting for extra API keys, and then running the existing Ansible playbook with the correct inventory.

### Usage

From the repo root:

```bash
cd terraform
terraform init
terraform apply \
  -var role=head \
  -var head_ip=192.168.128.111 \
  -var 'extra_api_keys=["ANTHROPIC_API_KEY","COHERE_API_KEY"]'
```

Or for a worker (auto-detects the local IP and registers as a client):

```bash
terraform apply \
  -var role=worker \
  -var head_ip=192.168.128.111
```

Notes:
- The script prompts once for sudo to install packages (ansible, direnv, python3, jq).
- Additional API keys are written to `.envrc.local` (not committed) and `direnv allow` is run automatically.
- `head_ip` also seeds NFS shares; override with `-var nfs_server=...` if your NFS server differs.
