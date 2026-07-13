# Module 01 — canonical state

Module 01 has no GitOps state: its end state is simply the running Talos+Cilium cluster.
There is nothing here for `catch-up.sh` to push.

Catch-up for this module = (re)create the cluster:

```bash
./scripts/destroy-cluster.sh   # if a broken cluster exists
./scripts/create-cluster.sh
lab/01-cluster/verify.sh
```
