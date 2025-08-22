# JavaZone 2025 Platform Engineering Workshop - AI Instructions

## Project Overview

This is a **hands-on workshop repository** for building cloud-native platforms using CNCF tools. The architecture follows a **progressive lab structure** teaching platform engineering concepts through practical implementation.

### Core Architecture Pattern

```
Workshop Labs (lab/) → Automation Scripts (scripts/) → Platform Components
└── 01-talos/          └── install-*.sh           └── Kubernetes Operators
└── 02-networking/     └── dev-setup.sh           └── CNCF Stack
└── 03-gitops/         └── create-*.sh            └── Self-Service Platform
```

## Critical Workflow Knowledge

### Development Environment Setup
- **Always run `./scripts/dev-setup.sh` first** - installs Go tools, kubectl, docker verification
- **Use `mise` for tool management** - defined in `mise.toml` with Talos, kubectl, helm, node 24, go 1.24
- **Scripts are the primary interface** - prefer using existing scripts over raw kubectl/helm commands

### Platform Installation Pattern
1. `./scripts/cloudbox-init.sh` - Initialize base platform
2. `./scripts/install-all-operators.sh` - Deploy all CNCF operators in sequence
3. Individual operators: `install-cloudnative-pg.sh`, `install-strimzi-kafka.sh`, etc.

### Lab Structure Convention
- Each lab in `lab/XX-name/` contains:
  - `README.md` with step-by-step instructions
  - Configuration patches (e.g., `cilium-patch.yml`)
  - Quick reference guides
- **Labs build progressively** - later labs depend on earlier infrastructure

## Technology Stack Specifics

### Kubernetes Distribution: Talos Linux
- **Immutable, API-driven OS** - no SSH/shell access
- **Use `talosctl` not SSH** for cluster management
- **Cilium CNI required** - always disable default CNI with config patches
- **Multi-node default**: 3 controlplanes, 2 workers for HA

### CNCF Operator Stack
- **CloudNativePG**: PostgreSQL clusters (`cnpg-system` namespace)
- **Strimzi**: Kafka clusters (`kafka-system` namespace)
- **MinIO**: Object storage (`minio-operator` namespace)
- **Knative**: Serverless functions (`knative-serving` namespace)
- **Tekton**: CI/CD pipelines (`tekton-pipelines` namespace)
- **ArgoCD**: GitOps delivery
- **Cilium**: eBPF networking and security

### Workshop-Specific Patterns

#### Script Naming Convention
- `install-*.sh` - Deploy individual operators
- `create-*.sh` - Create cluster resources (postgres, kafka)
- `dev-setup.sh` - Development environment preparation
- `cloudbox-init.sh` - Platform initialization

#### Configuration Management
- **Config patches over full manifests** - see `cilium-patch.yml` pattern
- **Namespace isolation** - each operator gets dedicated namespace
- **Helm for operators, kubectl for applications**

#### Troubleshooting Workflow
1. Check operator pods: `kubectl get pods -A | grep -E "(cnpg|kafka|minio|knative)"`
2. Verify CRDs: `kubectl get crd | grep -E "(postgresql|kafka|minio|knative)"`
3. Use `mise run k8s:status` for comprehensive platform health check

## Development Guidelines

### When Adding New Labs
- Follow `XX-name/` directory pattern with zero-padded numbers
- Include comprehensive README with prerequisites, objectives, troubleshooting
- Provide configuration files and quick reference guides
- Test installation scripts for idempotency

### When Modifying Scripts
- **Maintain script execution order** in `install-all-operators.sh`
- Add status checks and verification steps
- Include namespace and CRD validation
- Follow the error handling pattern: `set -e` for strict mode

### Platform Extension Points
- **New operators**: Add install script + update `install-all-operators.sh`
- **New resources**: Use `create-*.sh` pattern for cluster resources
- **New tools**: Add to `mise.toml` tools section
- **New tasks**: Add to `mise.toml` tasks with proper dependencies

## Workshop Context

This is **educational content** for a 4-hour JavaZone workshop. Prioritize:
- **Clear documentation** over complex automation
- **Progressive complexity** - simple concepts first
- **Practical examples** over theoretical explanations
- **Troubleshooting guides** - workshop attendees will encounter issues

The goal is teaching **platform engineering principles** through hands-on CNCF tool implementation, not production-ready infrastructure.