# Door 3 — Security: lock it down, prove it

**You came for:** zero trust made concrete. Default-deny that you watch break
a real workload, least-privilege that you prove back into existence, and a
supply chain your own platform signs.

**Prerequisites:** module 09 (the pipeline is your victim). Module 07 unlocks
the signing arc. `./scripts/catch-up.sh 9` covers everything.

## The mission

The platform works. Nothing about it is locked down: every pod can talk to
every pod, every image is trusted because it exists. Fix that with the
pipeline live, so every policy you write is tested against real traffic
immediately.

## Warm-up (~10 min)

Cilium ships Hubble inside every agent. Watch the pipeline's bloodstream:

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace pipeline -f
```

Upload a photo in the Gallery and read the flows: browser → uploader, uploader →
broker, broker → resizer, resizer → RustFS. That map is about to become your
policy.

## The build

**Arc 1: break it with default-deny.** Apply a default-deny
`CiliumNetworkPolicy` to ns `pipeline` (empty `ingress: []` / `egress: []`
against all endpoints). Upload a photo: watch it fail, and watch
`hubble observe --verdict DROPPED` name every flow you just severed,
**including DNS**, which is the one everyone forgets.

**Arc 2: earn it back, least privilege.** Restore the pipeline one rule at a
time, DNS egress first (allow UDP 53 to kube-dns), then only the flows the
warm-up showed you. Each rule: apply, upload, observe. The finale is L7.
Cilium speaks HTTP through its Envoy (already on your cluster):

```yaml
ingress:
  - toPorts:
      - ports: [{ port: "8080", protocol: TCP }]
        rules:
          http: [{ method: POST, path: "/upload.*" }]
```

Only `POST /upload` reaches the uploader now. Prove the negative:
`kubectl run` a curl pod, `GET /upload`, and find the `403` in hubble as an
L7 verdict. Dropped by policy, not by the app.

**Arc 3: sign what you build.** Module 07's pipeline builds images nobody
vouches for. cosign is a mise tool away (`mise x cosign@latest -- cosign ...`,
needs one-time internet to fetch the tool): generate a keypair, sign the image
in your Zot (`cosign sign --key cosign.key localhost:30500/...`), then verify.
Verify an *unsigned* image too, to see the refusal. Zot stores the signature as
a normal OCI artifact; find it with `crane ls`. Stretch: add the sign step to
the `build-and-push` WorkflowTemplate so the platform signs everything it
builds, and admission-gate on it (Kyverno's `verifyImages`). That last step is an
at-home one: no admission controller is in the mirror, so it needs the internet.

**Arc 4: audit the platform itself.** The builds namespace is PSA-privileged
(rootless BuildKit needs it, as module 07 explains). Is that label on anything
else that doesn't need it? `kubectl get ns --show-labels`. Then the RBAC module
04 granted Crossplane: could a compromised composition escalate? Write down
what you'd tighten first and why.

**Arc 5. See the map.** `hubble observe` gives you one terminal's worth of
truth. Turn on Hubble Relay and the UI, whose images are already in your
mirror, and watch Arc 1's default-deny paint edges red in a picture the whole
table can read:

```bash
helm upgrade cilium scripts/manifests/cilium-1.20.0.tgz -n kube-system --reuse-values \
  --set hubble.relay.enabled=true --set hubble.ui.enabled=true
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

Policy only one person can read in a terminal stays one person's knowledge.

## You know it works when…

- The pipeline works end to end **with default-deny still in place**: the
  thumbnail appears through your allow-rules only.
- `hubble observe --verdict DROPPED` during an upload shows nothing. No rule
  is being brute-forced past.
- `cosign verify` passes on your built image and fails on an unsigned one.

## Known traps

- **Default-deny without a DNS rule kills everything cryptically.** Services
  fail on name resolution, not on the connection you meant to block. DNS
  egress first, always.
- **Scope your policies to ns `pipeline`.** A cluster-wide default-deny will
  take out ArgoCD's reach to Gitea, and since git *is* your write path, you've
  locked the door with the keys inside (recovery: `kubectl delete cnp`, which
  is exactly the emergency-access lesson).
- Knative's activator sits in the request path for scale-from-zero: if your
  L7 rule matches the pod but uploads still fail, look at flows from
  `knative-serving`, not the browser.
- The Hubble **UI** (service map) needs relay+UI images from the final prework
  refresh; the CLI inside the agent needs nothing.
- cosign in Zot: `--insecure-ignore-tlog` and `--allow-insecure-registry`. No
  public transparency log on an air-gapped laptop, and that's fine; you're the
  root of trust here.
- **`--reuse-values` is not optional.** Helm manages Cilium here, not GitOps, and the
  workshop's Talos-specific values live only in that release. Drop the flag and you reset
  them, which takes the cluster's networking with it. Copy the command, don't retype it.

## At home

Take Arc 4 seriously: Kyverno or ValidatingAdmissionPolicy baseline on every
non-platform namespace, signed-images-only admission, and network policies for
the *platform* namespaces (Gitea, ArgoCD). Done carefully, in the right order,
with an emergency path you've tested.
