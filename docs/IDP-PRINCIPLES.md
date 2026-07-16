# IDP Design Principles — and how this platform embodies them

This workshop is a **reference Internal Developer Platform (IDP)**. `docs/PRINCIPLES.md`
covers how we designed the *workshop*; this file names the **platform-design**
principles the reference implementation demonstrates, grounded in the industry
canon, so the slides (PRD-0005 / issue #80) cite something durable.

## The canon (and it agrees with itself)

Three independent authorities converge on the same set:

- **CNCF Platforms White Paper** — the vendor-neutral definition: **seven platform
  attributes** + a 13-capability model + a maturity model.
- **Team Topologies** (Skelton & Pais) — the intellectual origin: *platform-as-a-product*,
  *Thinnest Viable Platform (TVP)*, and *reduce cognitive load* as the platform's
  primary purpose.
- **AWS Prescriptive Guidance** + **platformengineering.org** — the same principles,
  operationalized (golden paths, self-service, optional adoption, onboarding).

We anchor on the **CNCF seven attributes** because they are vendor-neutral and the
closest thing to an official definition.

## The seven attributes → this reference implementation

| CNCF attribute (paraphrased) | Where the attendee builds it |
|---|---|
| **Platform as a product** — designed/evolved around user needs, like any product | The **Cloudbox Console** — a real front door you can read every line of (module 08) |
| **User experience** — consistent interfaces, deliberate UX | The first-class console (dark mode, nav icons, self-service forms) — one surface over every capability |
| **Documentation & onboarding** — delivered with docs for its users | The labs: outcome-based READMEs, layered hints, console locked-hints / teasers |
| **Self-service** — request & receive capabilities autonomously and automatically | Crossplane XRs + the console **New Database / New Function** forms (modules 04 / 08) |
| **Reduced cognitive load** — an essential goal | **T-shirt sizing** — `size: small`, not twelve CNPG fields (PRD-0006 / #81) |
| **Optional & composable** — use only the parts you need | Catalog-enabled capabilities + a `kubectl` escape hatch; core is 5 modules, the rest optional |
| **Secure by default** — secure defaults, compliance & validation | RBAC "**you hand the portal its keys**" (scoped write Roles), Pod Security Admission |

### Product qualities vs. mechanics — two complementary lenses

The seven attributes are **product qualities** — what makes a platform *a platform*
and not just an internal tool. The workshop's existing *"It runs on practices, not
just tools"* framing (GitOps, immutable infrastructure, operators-as-control-loops)
is the **mechanics** — how you build it. They don't overlap; the attributes sit
*above* the mechanics. A good IDP needs both.

### Thinnest Viable Platform

Team Topologies' **TVP** — "the smallest set of APIs, docs and tools that
accelerates the teams consuming it" — is the workshop's whole shape in one phrase:

> a complete, CNCF-attribute-covering reference IDP — thin enough to run on a laptop.

## Sources

- CNCF Platforms White Paper — <https://tag-app-delivery.cncf.io/whitepapers/platforms/>
- CNCF Platform Engineering Maturity Model — <https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/>
- Team Topologies — Platform Engineering / Platform-as-a-Product — <https://teamtopologies.com/platform-engineering>
- Team Topologies — Trade Me's journey to a Thinnest Viable Platform — <https://teamtopologies.com/industry-examples/trade-me-journey-towards-a-thinnest-viable-platform>
- AWS Prescriptive Guidance — Principles of building an IDP — <https://docs.aws.amazon.com/prescriptive-guidance/latest/internal-developer-platform/principles.html>
- platformengineering.org — How to set up an IDP — <https://platformengineering.org/blog/how-to-set-up-an-internal-developer-platform>
