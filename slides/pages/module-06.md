---
layout: section
---

<span class="badge">Module 06 · stretch · self-paced</span>

# Serverless: scale from zero, on your hardware

<div class="modlogos"><Logo name="knative" label size="2.6rem"/></div>

<div class="story"><span class="tag">BRUKTBY</span> &nbsp;Their thumbnailer scales to zero — nothing running, nothing to pay, between uploads. Lambda's trick, on hardware they own.</div>

<!--
First stretch module. From here on the room is self-paced: give the 3-minute framing, show the GO slide, and let people choose their path. Helpers keep roaming.
-->

---

# Serverless was never about servers

- It's about **not paying for idle**
- Knative Serving: request-driven autoscaling
- 0 pods → request arrives → pod → 0 again
- The engine behind Cloud Run's API
- Demystified: it's a URL and a watch

<!--
The concept: "serverless" was never literally about someone else's servers — it's about not paying for idle capacity and not managing replica counts. Knative Serving is the open-source engine behind most Kubernetes serverless offerings (Cloud Run implements its API): request-driven autoscaling, revisioned deploys, and the headline trick — scale to zero.

The magic moment this lab is built around: a Knative Service sits at ZERO pods. A curl arrives; the activator catches it, a pod cold-starts, answers the request, and after ~60–90 seconds of silence it's gone again. Two terminals — one watching pods, one curling — make the whole lifecycle visible: 0 → 1 → 0 around a 200 response.

Running this yourself demystifies the single most magic-looking cloud product there is. And it composes: module 09's capstone uses exactly this mechanism to wake an image resizer on demand.

Kourier is the ingress (lighter than Istio), on NodePort 31080; traffic routes by Host header — figuring out the ksvc's host is part of the lab (hint 2 if needed).
-->

---

# GO — Module 06

**Outcome:** watch pods go 0 → 1 → 0 around a `200`.

```bash
# enable knative-serving.yaml; deploy hello-ksvc.yaml via GitOps
cd lab/06-serverless && ./verify.sh
```

<span class="badge">~20 min</span> · time the cold start!

<!--
The task: enable knative-serving.yaml from the catalog (Serving + Kourier, NodePort 31080), deliver hello-ksvc.yaml the GitOps way — by now nobody should need telling where it goes — wait for READY True, then stage the moment:

- Terminal 1: kubectl -n demo get pods -w
- Terminal 2: curl -H "Host: <the ksvc's host>" http://localhost:31080/

Watch the first request CREATE a pod (ask them to time the cold start), repeated requests hit it warm, and silence make it vanish.

Helper notes: the ksvc's URL/host is the usual stumble — kubectl get ksvc shows it (hint 2 covers it). Knative's webhook takes a minute to come up after enabling; ArgoCD retries until it's there — patience beats debugging for the first 90 seconds.

Explain-back: "what answered the FIRST request, given the pod didn't exist yet?" (The activator buffered it while signaling scale-up.)
-->
