# Module 05 — canonical state

Identical to `module-04` by design: module 05 injects faults into dedicated
`faultlab-*` namespaces, entirely outside the GitOps tree, so the canonical repo state
does not change.

To clear any leftover fault scenarios:

```bash
lab/05-debug-with-ai/restore.sh clean
```
