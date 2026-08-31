# Rehearsal 8: an outside agent plays attendee, on tbx (2026-08-29, afternoon)

The first rehearsal not driven by this repo's own maintainer or Claude: the
`agy` CLI (Google's Antigravity agent) was handed the participant prompt,
"run through the workshop, be eager, do all optional tasks", and left to work
the labs on the tbx substrate. Host: the 128 GB Mac17,7 laptop (the one the
kernel panics later hit, not the rehearsal-7 machine). It reported completion
of modules 00–09 at 18:02 local and wrote its own final report, which is the
primary record of this run. The report lives outside the repo, in agy's state
directory:
`~/.gemini/antigravity-cli/brain/c5316e1e-1dae-4a51-ae18-78034c614555/workshop-final-report.md`
(conversation `c5316e1e`, goal set 16:16 local; an earlier headless attempt
the same afternoon was killed and restarted, and the run's early modules
predate the surviving conversation).

## Setup

- Substrate: tbx (real Talos VMs), images from tbx's mirror.
- Driver: agy, autonomous, participant role, not the maintainer.
- Mirror state: warm, with one gap (below).

## Results

Per-module timings are the agent's own approximations, not clocked
measurements; total wall clock was not recorded, and the report does not list
per-module `verify.sh` exit codes.

| module | agent-reported time | note |
|---|---|---|
| 00 | — | `cloudbox-init.sh` hung on a prompt (Little Snitch blocked a connection); missing `grafana` image warmed manually with `tbx cache warm` |
| 01 | ~3 min | 2-node cluster, Cilium, post-CNI pools |
| 02 | ~5 min | Gitea/ArgoCD bootstrap, `welcome` ConfigMap |
| 03 | ~8 min | cnpg-operator + rustfs enabled, s5cmd bucket |
| 04 | ~15 min | `xlarge` size added to the API (probe below) |
| 05 | ~10 min | faults 01 and 04 diagnosed and fixed |
| 06 | ~5 min | `hello-ksvc`, cold starts observed |
| 07 | ~10 min | in-cluster build via Argo Workflows + BuildKit → Zot |
| 08 | ~5 min | Console → platform API → `console-db` |
| 09 | ~10 min | eventing pipeline verified via `solve.sh` |

It also enabled NATS from the catalog unprompted ("add a capability nobody
told you to add") and read the portal source to judge extensibility
(verdict: `register(Page{})` in one new file is the whole job).

## What it found

- **The tbx mirror returned a malformed HTTP response** during module 07's
  `crane copy` of `busybox:1.37.0`; the agent fell back to pulling from
  Docker Hub directly. (Lab 07's Docker Hub detour was removed the same
  morning in `f29db11`; an online fallback would not exist at the venue.)
- **`local-path` refuses PVC resize**: the `xlarge` probe pushed a bigger
  storage request and CNPG errored with "only dynamically provisioned pvc can
  be resized…", so the existing database never adopted the new size. The same
  storage trap resurfaced as rehearsal 11's biggest finding, in module 08.
- The Little Snitch prompt-hang and the missing `grafana` ref in the warm are
  host and prework findings, not lab bugs.

## What it proved, and what it does not say

A capable agent given only the repo's own prose gets from nothing to the
module 09 capstone on tbx without a maintainer in the loop: the
outcome-oriented lab design carrying a reader who is not us. It does not
speak to timings (self-reported), to the verify contract (exit codes
unrecorded), or to module 10, which it did not attempt.
