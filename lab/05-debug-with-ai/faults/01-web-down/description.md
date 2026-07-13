# Fault 01 — spoiler

**Symptom:** `web` pod in `faultlab-01` never becomes Ready; status `ImagePullBackOff` /
`ErrImagePull`.

**Root cause:** image tag typo — `busybox:1.37.00` instead of `1.37.0`. The registry
answers "manifest unknown", kubelet backs off and retries forever.

**Diagnosis path this teaches:**

1. `kubectl -n faultlab-01 get pods` → status column already names it: `ImagePullBackOff`.
2. `kubectl -n faultlab-01 describe pod <pod>` → **Events** at the bottom carry the exact
   registry error, including the full image ref where the typo is visible.
3. Fix at the source (the Deployment, not the pod — pods are cattle):
   `kubectl -n faultlab-01 edit deploy web` or apply `fix.yaml`.

**Lesson:** events (`describe`, `kubectl get events`) are the first stop for any pod that
won't start. The error message contains the answer verbatim more often than people look
at it.

**Verify the fix:** `kubectl -n faultlab-01 wait --for=condition=Available deploy/web --timeout=60s`
