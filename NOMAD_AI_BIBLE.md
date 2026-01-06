# Nomad AI Bible: Complete Guide to Deploying AI/ML Workloads on Nomad

## Table of Contents

1. [Introduction & Core Concepts](#introduction--core-concepts)
2. [Job Types Deep Dive](#job-types-deep-dive)
3. [Volumes & Storage Patterns](#volumes--storage-patterns)
4. [Multi-Stage Deployment Pattern](#multi-stage-deployment-pattern)
5. [Networking & Service Discovery](#networking--service-discovery)
6. [Resource Management](#resource-management)
7. [AI/ML Specific Patterns](#aiml-specific-patterns)
8. [Practical Examples](#practical-examples)
9. [Storage Backends: SurrealDB](#storage-backends-surrealdb)
10. [Quick Reference](#quick-reference)

---

## Introduction & Core Concepts

### What is Nomad?

Nomad is a flexible, distributed workload orchestrator developed by HashiCorp. It manages containerized and non-containerized applications across a cluster of machines, providing:

- **Workload Versatility**: Supports Docker containers, VMs, raw executables, and Java applications
- **Scalability**: Manages thousands of nodes across multiple regions
- **Simplicity**: Single binary agent, no external dependencies
- **Integration**: Seamless integration with Consul (service discovery) and Vault (secrets)

### Key Concepts

#### Jobs
A **job** is the primary configuration unit in Nomad. It declares a workload and its requirements. Jobs are written in HashiCorp Configuration Language (HCL) and define:

- **Job Type**: `service` (long-running), `batch` (one-time), or `system` (every node)
- **Groups**: Logical collections of tasks that run together
- **Tasks**: Individual units of work (containers, executables, etc.)
- **Allocations**: Running instances of a job on specific nodes

#### Job Structure
```hcl
job "example" {
  region      = "home"
  datacenters = ["dc1"]
  type        = "service"  # or "batch" or "system"

  group "web" {
    count = 1
    
    task "app" {
      driver = "docker"
      # ... task configuration
    }
  }
}
```

#### Allocations
An **allocation** is a mapping between a task group and a node. When Nomad schedules a job, it creates allocations that bind task groups to specific nodes. Each allocation has a unique ID and lifecycle.

### Nomad Architecture in Your Cluster

Your cluster setup:
- **Head Node** (`192.168.128.111`): Nomad server (cluster management)
- **Worker Nodes**: Nomad clients (run workloads)
- **Consul**: Service discovery and health checking
- **NFS Server**: Shared storage for models, caches, and data

### Job Types

1. **Service Jobs**: Long-running applications (vLLM, Ollama, SGLang)
2. **Batch Jobs**: One-time tasks (setup scripts, initialization)
3. **System Jobs**: Run on every eligible node (monitoring agents)

---

## Job Types Deep Dive

### Service Jobs

Service jobs are for long-running applications that should be restarted if they fail.

#### Basic Service Job Structure
```hcl
job "my-service" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "service"

  group "app" {
    count = 1

    network {
      port "http" {
        to = 8000
      }
    }

    restart {
      attempts = 3
      delay    = "15s"
      interval = "10m"
      mode     = "delay"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "30s"
      auto_revert      = true
    }

    task "app" {
      driver = "docker"
      config {
        image = "myapp:latest"
        ports = ["http"]
      }

      service {
        name = "my-service"
        port = "http"
        tags = ["traefik.enable=true"]
        
        check {
          type     = "http"
          path     = "/health"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
```

#### Key Service Job Features

**Restart Policy**: Controls how Nomad handles task failures
```hcl
restart {
  attempts = 3        # Max restart attempts
  delay    = "15s"    # Delay between restarts
  interval = "10m"    # Reset attempt counter after interval
  mode     = "delay"  # or "fail"
}
```

**Update Strategy**: Controls rolling updates
```hcl
update {
  max_parallel     = 1      # Update one at a time
  min_healthy_time = "30s"  # Wait 30s before considering healthy
  auto_revert      = true   # Revert to previous version on failure
}
```

**Service Registration**: Automatic Consul registration
```hcl
service {
  name = "my-service"
  port = "http"
  tags = ["traefik.enable=true", "api"]
  
  check {
    type     = "http"
    path     = "/health"
    interval = "30s"
    timeout  = "3s"
  }
}
```

### Batch Jobs

Batch jobs run once and exit. Perfect for initialization, setup, or one-time tasks.

#### Example: Database Setup Job
```hcl
job "neo4j-setup" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "batch"

  group "setup" {
    task "neo4j-init" {
      driver = "docker"
      
      config {
        image = "neo4j:5.26"
        command = "cypher-shell"
        args = [
          "-a", "neo4j.service.consul:7687",
          "-u", "neo4j",
          "-p", "ChAnGeMe",
          "CREATE CONSTRAINT cognee_node_id IF NOT EXISTS FOR (n:CogneeNode) REQUIRE n.id IS UNIQUE;"
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
```

#### Batch Job Characteristics

- **No Restart Policy**: Batch jobs don't restart on failure
- **Exit Codes**: Use exit codes to indicate success (0) or failure (non-zero)
- **Dependencies**: Can be used as dependencies for service jobs (manual coordination)

### System Jobs

System jobs run on every eligible node. Useful for monitoring agents, log collectors, or node-level services.

```hcl
job "node-monitor" {
  type = "system"
  
  group "monitor" {
    task "agent" {
      driver = "docker"
      config {
        image = "prom/node-exporter:latest"
      }
    }
  }
}
```

---

## Volumes & Storage Patterns

Nomad supports two primary volume types: **CSI volumes** (block storage) and **NFS volumes** (shared file storage).

### CSI Volumes (Block Storage)

CSI volumes provide block-level storage, typically via iSCSI. Best for:
- Database storage (Neo4j, PostgreSQL)
- Single-node write workloads
- High-performance I/O requirements

#### Creating a CSI Volume

Create a `volume.hcl` file:
```hcl
id           = "neo4j-data"
name         = "neo4j-data"
type         = "csi"
plugin_id    = "org.democratic-csi.iscsi"
capacity_min = "8GiB"
capacity_max = "8GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "block-device"
}

mount_options {
  fs_type     = "ext4"
  mount_flags  = ["noatime"]
}
```

**Register the volume:**
```bash
nomad volume register volume.hcl
```

#### Using CSI Volumes in Jobs

```hcl
group "app" {
  volume "neo4j-data" {
    type            = "csi"
    read_only       = false
    source          = "neo4j-data"
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  task "neo4j" {
    driver = "docker"
    config {
      image = "neo4j:5.26"
    }

    volume_mount {
      volume      = "neo4j-data"
      destination = "/data"
      read_only   = false
    }
  }
}
```

#### CSI Volume Access Modes

- **single-node-writer**: Only one node can write (databases)
- **multi-node-reader**: Multiple nodes can read (shared caches)
- **multi-node-multi-writer**: Multiple nodes can write (rare, requires application coordination)

### NFS Volumes (Shared File Storage)

NFS volumes provide shared file storage accessible from multiple nodes. Perfect for:
- HuggingFace model cache
- Shared model storage
- Multi-node read/write workloads
- Large file storage

#### Creating an NFS Volume

Create a `volume.hcl` file:
```hcl
type = "csi"
id = "hf-cache"
name = "hf-cache"
plugin_id = "nfsofficial"
external_id = "hf-cache"

capability {
  access_mode = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.128.111"  # NFS server IP
  share = "/mnt/pool0/share/hf-cache"  # NFS export path
  mountPermissions = "0"  # Root permissions
}

mount_options {
  fs_type = "nfs"
  mount_flags = ["timeo=30", "intr", "vers=4", "_netdev", "nolock"]
}
```

**Register the volume:**
```bash
nomad volume register volume.hcl
```

#### Using NFS Volumes in Jobs

```hcl
group "vllm" {
  volume "hf-cache" {
    type            = "csi"
    read_only       = false
    source          = "hf-cache"
    access_mode     = "multi-node-multi-writer"
    attachment_mode = "file-system"
  }

  task "vllm" {
    driver = "docker"
    config {
      image = "nvcr.io/nvidia/vllm:latest"
    }

    volume_mount {
      volume      = "hf-cache"
      destination = "/root/.cache/huggingface"
      read_only   = false
    }

    env {
      HF_HOME = "/root/.cache/huggingface"
    }
  }
}
```

### Volume Lifecycle

1. **Create Volume Definition**: Write `volume.hcl` file
2. **Register Volume**: `nomad volume register volume.hcl`
3. **Use in Job**: Reference in job's `volume` block
4. **Mount in Task**: Use `volume_mount` in task configuration
5. **Manage Volume**: `nomad volume status`, `nomad volume detach`, `nomad volume delete`

### When to Use Each Volume Type

| Use Case | Volume Type | Access Mode |
|----------|-------------|-------------|
| Database (Neo4j, PostgreSQL) | CSI (iSCSI) | single-node-writer |
| Model Cache (shared) | NFS | multi-node-multi-writer |
| Application Data (single node) | CSI (iSCSI) | single-node-writer |
| Model Storage (shared) | NFS | multi-node-multi-writer |
| High I/O Performance | CSI (iSCSI) | single-node-writer |

---

## Multi-Stage Deployment Pattern

Many applications require initialization before the main service starts. Use **setup jobs** (batch) followed by **service jobs**.

### Pattern Overview

1. **Setup Job** (batch): Initialize database, create schemas, set up volumes
2. **Service Job** (service): Run the main application

### Example: Neo4j Setup Pattern

#### Step 1: Setup Job (`setup.job`)
```hcl
job "neo4j-setup" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "batch"

  group "setup" {
    task "neo4j-init" {
      driver = "docker"
      
      config {
        image = "neo4j:5.26"
        command = "cypher-shell"
        args = [
          "-a", "neo4j.service.consul:7687",
          "-u", "neo4j",
          "-p", "ChAnGeMe",
          "CREATE CONSTRAINT cognee_node_id IF NOT EXISTS FOR (n:CogneeNode) REQUIRE n.id IS UNIQUE;"
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
```

#### Step 2: Service Job (`nomad.job`)
```hcl
job "neo4j" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "service"

  group "neo4j" {
    count = 1

    volume "neo4j-data" {
      type            = "csi"
      read_only       = false
      source          = "neo4j-data"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

    task "neo4j" {
      driver = "docker"
      config {
        image = "neo4j:5.26"
      }

      volume_mount {
        volume      = "neo4j-data"
        destination = "/data"
        read_only   = false
      }

      service {
        name = "neo4j"
        port = "bolt"
      }
    }
  }
}
```

#### Deployment Workflow

```bash
# 1. Create and register volume
nomad volume register volume.hcl

# 2. Run setup job (one-time)
nomad job run setup.job

# 3. Verify setup completed successfully
nomad job status neo4j-setup

# 4. Run main service job
nomad job run nomad.job
```

### Prestart Tasks (Alternative Pattern)

For simpler initialization, use **prestart tasks** within the same job:

```hcl
group "app" {
  volume "data" {
    type            = "csi"
    source          = "app-data"
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  # Prestart task runs before main task
  task "prep-disk" {
    driver = "docker"
    
    volume_mount {
      volume      = "data"
      destination = "/volume/"
      read_only   = false
    }
    
    config {
      image   = "busybox:latest"
      command = "sh"
      args    = ["-c", "mkdir -p /volume/config && chmod -R 777 /volume/"]
    }
    
    resources {
      cpu    = 200
      memory = 128
    }

    lifecycle {
      hook    = "prestart"
      sidecar = false
    }
  }

  task "app" {
    driver = "docker"
    # ... main application
  }
}
```

### Best Practices

- **Use setup jobs** for complex initialization (database schemas, external dependencies)
- **Use prestart tasks** for simple volume preparation
- **Idempotent operations**: Setup jobs should be safe to run multiple times
- **Dependency coordination**: Manually coordinate setup → service (or use external orchestration)

---

## Networking & Service Discovery

### Host Networking

Host networking mode gives tasks direct access to the host's network stack. Best for:
- Services that need specific ports
- Performance-critical applications
- Services that need to discover other services on the network

#### Host Network Configuration
```hcl
group "app" {
  network {
    mode = "host"
    port "http" {
      static       = 8000
      host_network = "lan"  # or "tailscale", "public"
    }
  }

  task "app" {
    driver = "docker"
    config {
      image = "myapp:latest"
      ports = ["http"]
    }
  }
}
```

#### Host Network Ports

- **Static Ports**: Fixed port numbers (e.g., `static = 8000`)
- **Dynamic Ports**: Nomad assigns available ports (omit `static`)
- **Host Network Names**: Reference network names from Nomad config (`lan`, `tailscale`, `public`)

### Bridge Networking (Default)

Bridge networking provides container isolation with port mapping:

```hcl
group "app" {
  network {
    port "http" {
      to = 8000  # Container port
    }
  }

  task "app" {
    driver = "docker"
    config {
      image = "myapp:latest"
      ports = ["http"]
    }
  }
}
```

**Accessing services**: Use `${NOMAD_ADDR_http}` or Consul service discovery.

### Consul Integration

Nomad automatically registers services with Consul when you define a `service` block:

```hcl
task "app" {
  service {
    name = "my-service"
    port = "http"
    tags = [
      "traefik.enable=true",
      "api",
      "version=v1"
    ]
    
    check {
      type     = "http"
      path     = "/health"
      port     = "http"
      interval = "30s"
      timeout  = "3s"
    }
  }
}
```

#### Service Discovery

Services are discoverable via Consul DNS:
- **Service Name**: `my-service.service.consul`
- **FQDN**: `my-service.service.consul:8000`
- **SRV Records**: Automatic load balancing across instances

#### Traefik Integration

Tag services for Traefik routing:
```hcl
tags = [
  "traefik.enable=true",
  "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)",
  "traefik.http.routers.myapp.tls=true"
]
```

### Service Health Checks

Nomad supports multiple health check types:

```hcl
check {
  type     = "http"      # or "tcp", "grpc", "script"
  path     = "/health"
  port     = "http"
  interval = "30s"
  timeout  = "3s"
  method   = "GET"       # for HTTP checks
}
```

---

## Resource Management

### CPU and Memory

Allocate CPU (MHz) and memory (MB) for each task:

```hcl
resources {
  cpu    = 2000   # 2000 MHz = 2 CPU cores
  memory = 16384  # 16 GB
}
```

**Best Practices:**
- Allocate based on actual usage (monitor first)
- Leave headroom for system processes
- Use resource constraints to prevent over-allocation

### GPU Scheduling

Nomad supports NVIDIA GPU scheduling via the `nvidia-gpu` plugin.

#### GPU Resource Definition
```hcl
resources {
  cpu    = 2000
  memory = 16384
  device "gpu" {
    count = 1
    constraint {
      attribute = "${device.vendor}"
      value     = "nvidia"
    }
  }
}
```

#### Docker GPU Configuration
```hcl
task "vllm" {
  driver = "docker"
  config {
    image   = "nvcr.io/nvidia/vllm:latest"
    runtime = "nvidia"  # Use NVIDIA runtime
    ports   = ["http"]
  }

  env {
    NVIDIA_VISIBLE_DEVICES     = "all"
    NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
  }
}
```

#### Multiple GPUs
```hcl
device "gpu" {
  count = 2  # Request 2 GPUs
  constraint {
    attribute = "${device.vendor}"
    value     = "nvidia"
  }
}
```

### Node Constraints

Pin jobs to specific nodes using constraints:

#### Constraint by Node Name
```hcl
constraint {
  attribute = "${node.unique.name}"
  operator  = "set_contains"
  value     = "klo01,spark-node"
}
```

#### Constraint by Meta Attributes
```hcl
constraint {
  attribute = "${meta.shared_mount}"
  operator  = "="
  value     = "true"
}
```

#### Constraint by GPU Count
```hcl
constraint {
  attribute = "${attr.nvidia.gpu.count}"
  operator  = ">="
  value     = "2"
}
```

### Scaling

#### Horizontal Scaling (Count)
```hcl
group "workers" {
  count = 3  # Run 3 instances
}
```

#### Dynamic Scaling
```bash
# Scale up
nomad job scale workers 5

# Scale down
nomad job scale workers 2
```

#### Vertical Scaling (Resources)
Edit the job file and run:
```bash
nomad job run updated-job.hcl
```

---

## AI/ML Specific Patterns

### Model Serving Patterns

#### Pattern 1: vLLM (High-Performance Inference)

vLLM provides fast inference for large language models:

```hcl
job "vllm" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  group "vllm" {
    network {
      mode = "host"
      port "http" {
        to           = 8000
        host_network = "lan"
      }
    }

    restart {
      attempts = 3
      delay    = "30s"
      interval = "10m"
      mode     = "delay"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "45s"
      auto_revert      = true
    }

    task "vllm" {
      driver = "docker"
      config {
        image   = "nvcr.io/nvidia/vllm:25.09-py3"
        runtime = "nvidia"
        ports   = ["http"]
        command = "bash"
        args = [
          "-lc",
          "python3 -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port ${NOMAD_PORT_http} --model ${var.vllm_model}"
        ]
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
      }

      service {
        name = "vllm"
        port = "http"
        tags = ["traefik.enable=true"]

        check {
          type     = "tcp"
          port     = "http"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 2000
        memory = 16384
        device "gpu" {
          count = 1
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}
```

#### Pattern 2: Ollama (Local Model Serving)

Ollama runs models locally with automatic model management:

```hcl
job "ollama" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  group "web" {
    network {
      mode = "host"
      port "web" {
        to           = 11434
        host_network = "lan"
      }
    }

    task "ollama" {
      driver = "docker"
      config {
        image      = "ollama/ollama"
        runtime    = "nvidia"
        dns_servers = [var.dns_server_ip]
        volumes = [
          "${var.ollama_data_dir}:/root/.ollama",
        ]
        ports = ["web"]
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        OLLAMA_MODELS              = "llama3.2:3b,codellama:7b"
      }

      service {
        name = "ollama"
        port = "web"
        tags = ["traefik.enable=true"]

        check {
          type     = "tcp"
          port     = "web"
          interval = "30s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = 200
        memory = 30000
      }
    }
  }
}
```

#### Pattern 3: SGLang Gateway (Multi-Model Router)

SGLang Gateway routes requests to multiple models:

```hcl
job "sglang-gateway" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  group "gateway" {
    network {
      mode = "host"
      port "http" {
        to           = 30000
        host_network = "lan"
      }
    }

    volume "hf-cache" {
      type            = "csi"
      read_only       = false
      source          = "hf-cache"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    restart {
      attempts = 3
      delay    = "30s"
      interval = "10m"
      mode     = "delay"
    }

    task "gateway" {
      driver = "docker"
      config {
        image   = "sglang/sglang-gateway:latest"
        runtime = "nvidia"
        ports   = ["http"]
        command = "python3"
        args = [
          "-m", "sglang_router.launch_router",
          "--port", "${NOMAD_PORT_http}",
          "--host", "0.0.0.0"
        ]
      }

      volume_mount {
        volume      = "hf-cache"
        destination = "/root/.cache/huggingface"
        read_only   = false
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        HF_HOME                    = "/root/.cache/huggingface"
        HF_TOKEN                   = "${var.hf_token}"
      }

      service {
        name = "sglang-gateway"
        port = "http"
        tags = ["traefik.enable=true"]

        check {
          type     = "http"
          path     = "/health"
          port     = "http"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 2000
        memory = 16384
        device "gpu" {
          count = 1
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}
```

### Multi-Model Setup

Run multiple models on different nodes:

#### Model 1: Mistral 24B (Orchestrator)
```hcl
job "mistral-24b" {
  # ... configuration
  constraint {
    attribute = "${node.unique.name}"
    operator  = "="
    value     = "spark-node"  # DGX Spark with 128GB VRAM
  }
  
  resources {
    device "gpu" {
      count = 8  # Use all GPUs on Spark
    }
  }
}
```

#### Model 2: Mistral 7B (Agent)
```hcl
job "mistral-7b" {
  # ... configuration
  constraint {
    attribute = "${node.unique.name}"
    operator  = "set_contains"
    value     = "klo01,pop-os-node"  # Nodes with 16GB GPUs
  }
  
  resources {
    device "gpu" {
      count = 1
    }
  }
}
```

### GPU Distribution Strategy

**Heterogeneous Cluster Setup:**
- **DGX Spark** (128GB VRAM): Large models (Mistral 24B, orchestrator)
- **16GB GPU Nodes**: Smaller models (Mistral 7B, agents)
- **Multiple 16GB GPUs**: Parallel agent instances

**Nomad automatically schedules** based on:
- GPU availability
- Resource constraints
- Node constraints

### Model Caching: HuggingFace Cache on NFS

Share model cache across all nodes to avoid redundant downloads:

#### Step 1: Create NFS Volume for HF Cache

`hf-cache-volume.hcl`:
```hcl
type = "csi"
id = "hf-cache"
name = "hf-cache"
plugin_id = "nfsofficial"
external_id = "hf-cache"

capability {
  access_mode = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.128.111"
  share = "/mnt/pool0/share/hf-cache"
  mountPermissions = "0"
}

mount_options {
  fs_type = "nfs"
  mount_flags = ["timeo=30", "intr", "vers=4", "_netdev", "nolock"]
}
```

**Register:**
```bash
nomad volume register hf-cache-volume.hcl
```

#### Step 2: Use in All Model Jobs

```hcl
group "vllm" {
  volume "hf-cache" {
    type            = "csi"
    read_only       = false
    source          = "hf-cache"
    access_mode     = "multi-node-multi-writer"
    attachment_mode = "file-system"
  }

  task "vllm" {
    # ... configuration
    
    volume_mount {
      volume      = "hf-cache"
      destination = "/root/.cache/huggingface"
      read_only   = false
    }

    env {
      HF_HOME = "/root/.cache/huggingface"
      HF_TOKEN = "${var.hf_token}"
    }
  }
}
```

**Benefits:**
- Models downloaded once, shared across nodes
- Faster startup (no re-download)
- Consistent model versions
- Reduced bandwidth usage

### Orchestrator Pattern: Multi-Agent Systems

Deploy an orchestrator model (Mistral 24B) that coordinates multiple agent models (Mistral 7B):

#### Architecture
```
┌─────────────────┐
│  Orchestrator   │  Mistral 24B on DGX Spark
│  (Mistral 24B)  │
└────────┬────────┘
         │ Coordinates
         │
    ┌────┴────┬──────────┬──────────┐
    │         │          │          │
┌───▼───┐ ┌──▼───┐ ┌───▼───┐ ┌───▼───┐
│Agent 1│ │Agent 2│ │Agent 3│ │Agent 4│  Mistral 7B on 16GB GPUs
│Mistral│ │Mistral│ │Mistral│ │Mistral│
│  7B   │ │  7B   │ │  7B   │ │  7B   │
└───────┘ └───────┘ └───────┘ └───────┘
```

#### Orchestrator Job
```hcl
job "orchestrator" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${node.unique.name}"
    operator  = "="
    value     = "spark-node"
  }

  group "orchestrator" {
    network {
      mode = "host"
      port "http" {
        to           = 8001
        host_network = "lan"
      }
    }

    volume "hf-cache" {
      type            = "csi"
      source          = "hf-cache"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    task "orchestrator" {
      driver = "docker"
      config {
        image   = "nvcr.io/nvidia/vllm:latest"
        runtime = "nvidia"
        ports   = ["http"]
        command = "bash"
        args = [
          "-lc",
          "python3 -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port ${NOMAD_PORT_http} --model mistralai/Mistral-24B-Instruct"
        ]
      }

      volume_mount {
        volume      = "hf-cache"
        destination = "/root/.cache/huggingface"
        read_only   = false
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        HF_HOME                    = "/root/.cache/huggingface"
      }

      service {
        name = "orchestrator"
        port = "http"
        tags = ["traefik.enable=true", "orchestrator"]
      }

      resources {
        cpu    = 8000
        memory = 131072
        device "gpu" {
          count = 8
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}
```

#### Agent Jobs (Scalable)
```hcl
job "agent" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${node.unique.name}"
    operator  = "set_contains"
    value     = "klo01,pop-os-node"
  }

  group "agents" {
    count = 4  # Run 4 agent instances

    network {
      mode = "host"
      port "http" {
        to           = 8002
        host_network = "lan"
      }
    }

    volume "hf-cache" {
      type            = "csi"
      source          = "hf-cache"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    task "agent" {
      driver = "docker"
      config {
        image   = "nvcr.io/nvidia/vllm:latest"
        runtime = "nvidia"
        ports   = ["http"]
        command = "bash"
        args = [
          "-lc",
          "python3 -m vllm.entrypoints.openai.api_server --host 0.0.0.0 --port ${NOMAD_PORT_http} --model mistralai/Mistral-7B-Instruct"
        ]
      }

      volume_mount {
        volume      = "hf-cache"
        destination = "/root/.cache/huggingface"
        read_only   = false
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        HF_HOME                    = "/root/.cache/huggingface"
        ORCHESTRATOR_URL           = "http://orchestrator.service.consul:8001"
      }

      service {
        name = "agent"
        port = "http"
        tags = ["traefik.enable=true", "agent"]
      }

      resources {
        cpu    = 2000
        memory = 16384
        device "gpu" {
          count = 1
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}
```

**Communication:**
- Orchestrator discovers agents via Consul: `agent.service.consul:8002`
- Agents discover orchestrator: `orchestrator.service.consul:8001`
- Use HTTP/OpenAI API for coordination

---

## Practical Examples

### Example 1: Complete SGLang Gateway Deployment

#### Step 1: Create NFS Volume for HF Cache

`nomad_jobs/ai-ml/sglang-gateway/hf-cache-volume.hcl`:
```hcl
type = "csi"
id = "sglang-hf-cache"
name = "sglang-hf-cache"
plugin_id = "nfsofficial"
external_id = "sglang-hf-cache"

capability {
  access_mode = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.128.111"
  share = "/mnt/pool0/share/hf-cache"
  mountPermissions = "0"
}

mount_options {
  fs_type = "nfs"
  mount_flags = ["timeo=30", "intr", "vers=4", "_netdev", "nolock"]
}
```

#### Step 2: Create SGLang Gateway Job

`nomad_jobs/ai-ml/sglang-gateway/nomad.job`:
```hcl
job "sglang-gateway" {
  region      = var.region
  datacenters = [var.datacenter]
  type        = "service"

  meta {
    job_file = "nomad_jobs/ai-ml/sglang-gateway/nomad.job"
    version  = "1"
  }

  group "gateway" {
    network {
      mode = "host"
      port "http" {
        to           = 30000
        host_network = "lan"
      }
    }

    volume "hf-cache" {
      type            = "csi"
      read_only       = false
      source          = "sglang-hf-cache"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    restart {
      attempts = 3
      delay    = "30s"
      interval = "10m"
      mode     = "delay"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "45s"
      auto_revert      = true
    }

    task "gateway" {
      driver = "docker"
      config {
        image   = "sglang/sglang-gateway:latest"
        runtime = "nvidia"
        ports   = ["http"]
        command = "python3"
        args = [
          "-m", "sglang_router.launch_router",
          "--port", "${NOMAD_PORT_http}",
          "--host", "0.0.0.0"
        ]
      }

      volume_mount {
        volume      = "hf-cache"
        destination = "/root/.cache/huggingface"
        read_only   = false
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        HF_HOME                    = "/root/.cache/huggingface"
        HF_TOKEN                   = "${var.hf_token}"
      }

      service {
        name = "sglang-gateway"
        port = "http"
        tags = ["traefik.enable=true"]

        check {
          type     = "http"
          path     = "/health"
          port     = "http"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 2000
        memory = 16384
        device "gpu" {
          count = 1
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}

variable "region" {
  type = string
}

variable "datacenter" {
  type = string
}

variable "hf_token" {
  type        = string
  description = "HuggingFace token for model access"
}
```

#### Step 3: Deploy

```bash
# Register volume
nomad volume register nomad_jobs/ai-ml/sglang-gateway/hf-cache-volume.hcl

# Run job
nomad job run -var-file=../../.envrc nomad_jobs/ai-ml/sglang-gateway/nomad.job
```

### Example 2: vLLM with Shared HF Cache

Use the existing vLLM job and add HF cache volume:

```hcl
job "vllm" {
  # ... existing configuration

  group "vllm" {
    volume "hf-cache" {
      type            = "csi"
      read_only       = false
      source          = "hf-cache"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    task "vllm" {
      # ... existing configuration

      volume_mount {
        volume      = "hf-cache"
        destination = "/root/.cache/huggingface"
        read_only   = false
      }

      env {
        NVIDIA_VISIBLE_DEVICES     = "all"
        NVIDIA_DRIVER_CAPABILITIES = "compute,utility"
        HF_HOME                    = "/root/.cache/huggingface"
        HF_TOKEN                   = "${var.hf_token}"
      }
    }
  }
}
```

### Example 3: Multi-Agent System Setup

#### Deploy Orchestrator
```bash
nomad job run orchestrator.job
```

#### Deploy Agents
```bash
nomad job run agent.job
```

#### Verify Services
```bash
# Check orchestrator
consul catalog services | grep orchestrator

# Check agents
consul catalog services | grep agent

# Test connectivity
curl http://orchestrator.service.consul:8001/health
curl http://agent.service.consul:8002/health
```

### Example 4: Ray Cluster for Distributed Training

#### Ray Head (from existing job)
```hcl
job "ray-head" {
  # ... existing configuration
  # Runs on any node, coordinates workers
}
```

#### Ray Workers (from existing job)
```hcl
job "ray-worker" {
  # ... existing configuration
  # Runs on GPU nodes, connects to head
  constraint {
    attribute = "${node.unique.name}"
    operator  = "set_contains"
    value     = "${var.allowed_nodes}"  # GPU nodes
  }
  
  resources {
    device "gpu" {
      count = var.gpu_count
    }
  }
}
```

**Deploy:**
```bash
# Start head
nomad job run ray-head/nomad.job

# Start workers (on GPU nodes)
nomad job run -var='allowed_nodes=spark-node,klo01,pop-os-node' -var='gpu_count=1' ray-worker/nomad.job
```

---

## Quick Reference

### Common Commands

#### Job Management
```bash
# Run a job
nomad job run job.hcl

# Check job status
nomad job status <job-name>

# View job logs
nomad alloc logs <allocation-id>

# Stop a job
nomad job stop <job-name>

# Restart a job
nomad job restart <job-name>

# Scale a job
nomad job scale <job-name> <count>

# Inspect a job
nomad job inspect <job-name>
```

#### Volume Management
```bash
# Register a volume
nomad volume register volume.hcl

# List volumes
nomad volume list

# Check volume status
nomad volume status <volume-id>

# Detach a volume
nomad volume detach <volume-id> <allocation-id>

# Delete a volume
nomad volume delete <volume-id>
```

#### Node Management
```bash
# List nodes
nomad node status

# Check node details
nomad node status <node-id>

# Drain a node (stop new allocations)
nomad node drain -enable <node-id>

# Re-enable a node
nomad node drain -disable <node-id>
```

#### Allocation Management
```bash
# List allocations
nomad alloc status <allocation-id>

# View allocation logs
nomad alloc logs <allocation-id>

# Execute command in allocation
nomad alloc exec <allocation-id> <command>

# Restart allocation
nomad alloc restart <allocation-id>
```

### Job File Template

```hcl
job "example" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "service"

  meta {
    job_file = "nomad_jobs/category/job-name/nomad.job"
    version  = "1"
  }

  constraint {
    attribute = "${meta.shared_mount}"
    operator  = "="
    value     = "true"
  }

  group "app" {
    count = 1

    network {
      mode = "host"
      port "http" {
        to           = 8000
        host_network = "lan"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "volume-name"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

    restart {
      attempts = 3
      delay    = "15s"
      interval = "10m"
      mode     = "delay"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "30s"
      auto_revert      = true
    }

    task "app" {
      driver = "docker"
      config {
        image   = "myapp:latest"
        runtime = "nvidia"
        ports   = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      env {
        PORT = "${NOMAD_PORT_http}"
      }

      service {
        name = "my-service"
        port = "http"
        tags = ["traefik.enable=true"]

        check {
          type     = "http"
          path     = "/health"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 1000
        memory = 2048
        device "gpu" {
          count = 1
          constraint {
            attribute = "${device.vendor}"
            value     = "nvidia"
          }
        }
      }
    }
  }
}

variable "region" {
  type = string
}
```

### Volume Template

#### CSI Volume (iSCSI)
```hcl
id           = "volume-name"
name         = "volume-name"
type         = "csi"
plugin_id    = "org.democratic-csi.iscsi"
capacity_min = "10GiB"
capacity_max = "10GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "block-device"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
```

#### NFS Volume
```hcl
type = "csi"
id = "volume-name"
name = "volume-name"
plugin_id = "nfsofficial"
external_id = "volume-name"

capability {
  access_mode = "multi-node-multi-writer"
  attachment_mode = "file-system"
}

context {
  server = "192.168.128.111"
  share = "/mnt/pool0/share/path"
  mountPermissions = "0"
}

mount_options {
  fs_type = "nfs"
  mount_flags = ["timeo=30", "intr", "vers=4", "_netdev", "nolock"]
}
```

### Troubleshooting

#### Job Won't Start
```bash
# Check job status
nomad job status <job-name>

# Check allocation status
nomad alloc status <allocation-id>

# View allocation logs
nomad alloc logs <allocation-id>

# Check node resources
nomad node status <node-id>
```

#### Volume Issues
```bash
# Check volume status
nomad volume status <volume-id>

# Check volume plugin
nomad plugin status

# Verify NFS mount on node
ssh <node> "mount | grep nfs"
```

#### GPU Issues
```bash
# Check GPU availability
nomad node status <node-id>

# Verify NVIDIA runtime
docker run --rm --runtime=nvidia nvidia/cuda:11.0-base nvidia-smi

# Check GPU plugin
nomad plugin status nvidia-gpu
```

#### Service Discovery Issues
```bash
# Check Consul services
consul catalog services

# Check service health
consul health service <service-name>

# Test DNS resolution
dig <service-name>.service.consul
```

#### Network Issues
```bash
# Check port availability
netstat -tuln | grep <port>

# Test connectivity
curl http://<service-name>.service.consul:<port>/health
```

### Environment Variables

Common environment variables in Nomad jobs:

- `${NOMAD_PORT_<name>}`: Port number for named port
- `${NOMAD_IP_<name>}`: IP address for named port
- `${NOMAD_ADDR_<name>}`: Full address (IP:port) for named port
- `${NOMAD_JOB_NAME}`: Name of the job
- `${NOMAD_TASK_NAME}`: Name of the task
- `${NOMAD_ALLOC_ID}`: Allocation ID
- `${NOMAD_NODE_NAME}`: Node name

### Best Practices Summary

1. **Use service jobs** for long-running applications
2. **Use batch jobs** for initialization and setup
3. **Use NFS volumes** for shared model caches
4. **Use CSI volumes** for database storage
5. **Register services** with Consul for discovery
6. **Use health checks** for reliable service registration
7. **Set resource limits** based on actual usage
8. **Use constraints** to pin jobs to specific nodes
9. **Use update strategies** for zero-downtime deployments
10. **Monitor allocations** and adjust resources as needed

---

---

## Storage Backends: SurrealDB

### SurrealDB Overview

SurrealDB is a multi-model database that combines the functionality of a traditional database with the flexibility of a document database, graph database, and real-time collaborative database. It's written in Rust and provides:

- **Multi-model**: Document, graph, and relational data in one database
- **Real-time**: Built-in real-time subscriptions
- **SQL-like query language**: SurrealQL for querying
- **Embedded or distributed**: Can run embedded or as a distributed cluster
- **Authentication**: Built-in authentication and authorization

### SurrealDB Docker Basics

Based on the [official SurrealDB Docker documentation](https://surrealdb.com/docs/surrealdb/installation/running/docker):

#### Key Points:
- **Image**: `surrealdb/surrealdb:latest`
- **Default Port**: `8000` (listens on all interfaces by default)
- **Storage Engine**: Uses RocksDB for on-disk storage
- **Authentication**: Enabled by default in v2.0+ (use `--unauthenticated` to disable)
- **Command Format**: `start [options] <storage-path>`

#### Basic Docker Run:
```bash
docker run --rm -p 8000:8000 surrealdb/surrealdb:latest start
```

#### With Persistent Storage:
```bash
docker run --rm -p 8000:8000 \
  -v /mydata:/mydata \
  --user $(id -u) \
  surrealdb/surrealdb:latest start \
  rocksdb:/mydata/mydatabase.db
```

#### With Authentication:
```bash
docker run --rm -p 8000:8000 \
  -v /mydata:/mydata \
  surrealdb/surrealdb:latest start \
  --user root \
  --pass secret \
  rocksdb:/mydata/mydatabase.db
```

#### Logging Levels:
- Default: `info`
- Options: `debug`, `info`, `warn`, `error`
- Use `--log <level>` flag

### Deploying SurrealDB with Nomad

#### Step 1: Create Volume Definition

Create `nomad_jobs/storage-backends/surrealdb/volume.hcl`:

```hcl
# SurrealDB database storage volume (Dynamic Host Volume using NFS)
# For volume registration - requires node_id and host_path
type = "host"
name = "surrealdb-data"
node_id = "781790f9-602e-4100-6783-7eeb55db185c"  # angmar (head node where NFS is mounted)
host_path = "/home/shared/surrealdb"
capacity = "10GiB"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}
```

#### Step 2: Create NFS Directory on Server

On the NFS server (head node), create the directory:
```bash
sudo mkdir -p /mnt/pool0/share/surrealdb && sudo chmod 755 /mnt/pool0/share/surrealdb
```

#### Step 3: Register the Volume

```bash
nomad volume register nomad_jobs/storage-backends/surrealdb/volume.hcl
```

#### Step 4: Create Nomad Job

Create `nomad_jobs/storage-backends/surrealdb/nomad.job`:

```hcl
job "surrealdb" {
  region      = var.region
  datacenters = ["dc1"]
  type        = "service"

  meta {
    job_file = "nomad_jobs/storage-backends/surrealdb/nomad.job"
    version  = "1"
  }

  group "surrealdb" {
    count = 1

    network {
      mode = "host"
      port "http" {
        static       = 8001  # Use non-standard port to avoid conflicts
        host_network = "lan"
      }
    }

    volume "surrealdb-data" {
      type      = "host"
      read_only = false
      source    = "surrealdb-data"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "30s"
      auto_revert      = true
    }

    task "surrealdb" {
      driver = "docker"

      config {
        image = "surrealdb/surrealdb:latest"
        args = [
          "start",
          "--bind", "0.0.0.0:8000",  # Bind to all interfaces on port 8000 inside container
          "--user", "root",
          "--pass", "ChAnGeMe",
          "--log", "info",
          "rocksdb:/data/surrealdb.db"
        ]
        ports = ["http"]
      }

      volume_mount {
        volume      = "surrealdb-data"
        destination = "/data"
        read_only   = false
      }

      service {
        name = "surrealdb"
        tags = ["database", "graph-db", "ai"]
        port = "http"

        check {
          type     = "tcp"
          port     = "http"
          interval = "30s"
          timeout  = "3s"
        }
      }

      resources {
        cpu    = 500
        memory = 2048
      }
    }
  }
}

variable "region" {
  type = string
  default = "global"
}
```

#### Step 5: Deploy the Job

```bash
make deploy-surrealdb
# or
nomad job run nomad_jobs/storage-backends/surrealdb/nomad.job
```

### Important Configuration Notes

1. **Port Mapping**: 
   - SurrealDB listens on port `8000` inside the container
   - Nomad maps it to port `8001` on the host (to avoid conflicts)
   - Use `--bind 0.0.0.0:8000` to ensure SurrealDB listens on all interfaces

2. **Storage Path**:
   - Mount volume to `/data` in container
   - Use `rocksdb:/data/surrealdb.db` as the storage path
   - The `.db` extension is required for RocksDB storage

3. **Authentication**:
   - Authentication is enabled by default in v2.0+
   - Set `--user` and `--pass` for initial root user
   - Credentials are persisted in storage after first run

4. **Resource Allocation**:
   - CPU: 500 MHz minimum (adjust based on workload)
   - Memory: 2048 MB minimum (RocksDB can be memory-intensive)

### Connecting to SurrealDB

Once deployed, SurrealDB is accessible at:
- **HTTP/REST**: `http://192.168.128.111:8001` (or via Consul: `surrealdb.service.consul:8001`)
- **WebSocket**: `ws://192.168.128.111:8001/rpc`
- **SDKs**: Use any SurrealDB SDK with the connection string

### Example Connection (JavaScript)

```javascript
import { Surreal } from "surrealdb.js";

const db = new Surreal();
await db.connect("http://surrealdb.service.consul:8001/rpc");
await db.signin({
  user: "root",
  pass: "ChAnGeMe"
});
await db.use({ ns: "test", db: "test" });
```

### Troubleshooting

1. **Container exits immediately**: Check logs with `nomad alloc logs <alloc-id> surrealdb`
2. **Port conflicts**: Change the static port in the job file
3. **Permission errors**: Ensure NFS directory has correct permissions (755)
4. **Authentication issues**: Verify `--user` and `--pass` are set correctly

### Comparison with Other Graph Databases

| Feature | SurrealDB | Neo4j | Memgraph |
|---------|-----------|-------|---------|
| Multi-model | ✅ Yes | ❌ No | ❌ No |
| Real-time | ✅ Built-in | ⚠️ Plugins | ⚠️ Plugins |
| SQL-like | ✅ SurrealQL | ⚠️ Cypher | ⚠️ Cypher |
| Embedded | ✅ Yes | ❌ No | ❌ No |
| Setup Complexity | ⭐ Low | ⭐⭐ Medium | ⭐⭐ Medium |

---

## Conclusion

This guide covers the essential patterns and practices for deploying AI/ML workloads on Nomad. Use it as a reference when:

- Creating new jobs
- Setting up shared storage
- Deploying multi-model systems
- Troubleshooting issues
- Optimizing resource allocation

For more information, refer to the [official Nomad documentation](https://developer.hashicorp.com/nomad/docs) and [SurrealDB documentation](https://surrealdb.com/docs).

---

*Last Updated: 2026-01-02*

