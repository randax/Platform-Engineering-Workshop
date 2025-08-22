# Talos Quick Referance

In this file you'll find usefull commands for interacting with talos linux. full docs are available here : https://www.talos.dev/v1.10/reference/cli/

## Essential Commands

### Cluster Management
```bash
# Create cluster
talosctl cluster create --name platform-cluster

# Destroy cluster
talosctl cluster destroy --name platform-cluster

# List clusters
talosctl cluster list
```

### Node Operations
```bash
# Check health
talosctl health --nodes <IP>

# View services
talosctl services --nodes <IP>

# View logs
talosctl logs <service> --nodes <IP>

# Dashboard (interactive)
talosctl dashboard --nodes <IP>
```

### Configuration
```bash
# Generate config
talosctl gen config <cluster-name> <endpoint>

# Apply configuration
talosctl apply-config --nodes <IP> --file <config.yaml>

# Get current config
talosctl get machineconfig --nodes <IP>
```

### Kubernetes Access
```bash
# Get kubeconfig
talosctl kubeconfig --nodes <IP>

# Merge into existing kubeconfig
talosctl kubeconfig --nodes <IP> --merge
```

### Upgrades

This feature is not available when running talos inside docker container.

```bash
# Upgrade Talos
talosctl upgrade --nodes <IP> --image <image>

# Upgrade Kubernetes
talosctl upgrade-k8s --nodes <IP> --to <version>
```

## Configuration Patches

### Allow scheduling on control planes
```json
[{
  "op": "add",
  "path": "/cluster/allowSchedulingOnControlPlanes",
  "value": true
}]
```

### Disable default CNI (for Cilium)
```json
[{
  "op": "add",
  "path": "/cluster/network/cni",
  "value": {
    "name": "none"
  }
}]
```

## File Locations

- Config files: `./talos-config/`
- Kubeconfig: `~/.kube/config`
- Talos config: `~/.talos/config`