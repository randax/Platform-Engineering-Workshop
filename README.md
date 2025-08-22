# Cloud on Your Terms: Building Your Own Cloud-Native Platform

Welcome to the JavaZone 2025 workshop repository! This workshop will teach you how to build your own cloud-native platform that can run anywhere, giving you complete control over your infrastructure.

## 🎯 Workshop Overview

**Format:** Workshop
**Duration:** 240 minutes (4 hours)
**Time:** Tuesday 1:30 PM - 5:30 PM

### What You'll Learn

In this hands-on workshop, you'll discover how to:

- Build a cloud-native platform that runs anywhere
- Gain independence from specific cloud providers
- Provide a consistent interface for developers across multiple environments
- Implement modern DevOps and platform engineering practices

### The Challenge

What happens if you can no longer trust your current cloud provider? What if you want to run on multiple cloud providers and provide the same interface for running applications to your developers?

This workshop addresses these real-world concerns by showing you how to take control and build your own cloud-native platform using open-source CNCF tools.

## 🛠️ Technologies & Tools

We'll be using the following CNCF tools and technologies throughout the workshop:

- **Kubernetes (Talos)** - Container orchestration platform
- **Networking (Cilium)** - eBPF-based networking and security
- **CI/CD (ArgoCD)** - GitOps continuous delivery
- **Automation (Crossplane)** - Infrastructure as code and composition
- **Database (CloudNativePG)** - PostgreSQL operator for Kubernetes
- **Developer Portal (Backstage)** - Platform engineering and developer experience
- **Observability (OpenTelemetry and Prometheus)** - Monitoring and tracing

## 👥 Workshop Leaders

### Øyvind Randa

Software Architect at NextGentel and Lead Organizer for GDG Bergen

### Hans Kristian Flaatten

Platform maker, dream awaker | CNCF Ambassador | Google Developer Expert | Grafana Champion | Co-host of Plattformpodden | Platform Engineer in Norwegian Government | Open Source Maintainer

## 📋 Prerequisites

To participate in this workshop, you'll need:

- **Modern laptop** with sufficient CPU and memory
- **Docker** installed and running
- **Pre-pulled Docker images** (see setup instructions below)
- Basic familiarity with Kubernetes concepts
- Command line experience

## 🚀 Getting Started

### Pre-Workshop Setup

1. **Clone this repository:**

   ```bash
   git clone https://github.com/randax/jz-2025-platform-engineering.git
   cd jz-2025-platform-engineering
   ```

2. **Install required tools:**

   ```bash
   # Run the development setup script
   ./scripts/dev-setup.sh
   ```

3. **Pull required Docker images:**

   ```bash
   # This may take some time - please do this before the workshop!
   ./scripts/cloudbox-init.sh
   ```

### Verify Your Setup

Run the following command to verify your environment is ready:

```bash
./scripts/install.sh --check
```

## 📚 Workshop Structure

The workshop is organized into hands-on labs located in the `lab/` directory:

```text
lab/
├── 01-talos/           # Setting up Kubernetes with Talos
├── 02-networking/      # Implementing Cilium networking
├── 03-gitops/          # Setting up ArgoCD for GitOps
├── 04-automation/      # Infrastructure automation with Crossplane
├── 05-databases/       # Running PostgreSQL with CloudNativePG
├── 06-developer-portal/ # Building developer experience with Backstage
└── 07-observability/   # Monitoring with OpenTelemetry and Prometheus
```

Each lab contains:

- Step-by-step instructions
- Configuration files and manifests
- Quick reference guides
- Troubleshooting tips

## 🏗️ What We'll Build

By the end of this workshop, you'll have built a complete cloud-native platform featuring:

- ✅ **Kubernetes cluster** running on Talos Linux
- ✅ **Advanced networking** with Cilium CNI and security policies
- ✅ **GitOps workflows** with ArgoCD for application deployment
- ✅ **Infrastructure automation** using Crossplane compositions
- ✅ **Database-as-a-Service** with PostgreSQL operator
- ✅ **Developer self-service portal** powered by Backstage
- ✅ **Full observability stack** with metrics, logs, and traces

## 🔧 Helper Scripts

The `scripts/` directory contains automation scripts to help you:

- `dev-setup.sh` - Install all required development tools
- `install-all-operators.sh` - Deploy all platform operators
- `create-kafka-cluster.sh` - Set up Kafka for event streaming
- `create-postgres-cluster.sh` - Deploy PostgreSQL databases
- `install-knative-serving.sh` - Enable serverless workloads

## 🆘 Getting Help

During the workshop:

- Raise your hand for instructor assistance
- Check the quick reference guides in each lab
- Use the troubleshooting sections in lab READMEs

## 📖 Additional Resources

- [CNCF Landscape](https://landscape.cncf.io/)
- [Platform Engineering Roadmap](https://roadmap.sh/devops)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [GitOps Principles](https://opengitops.dev/)

## 🏷️ Tags

`#Cloud` `#Kubernetes` `#Platform` `#Privacy` `#CNCF` `#GitOps` `#DevOps` `#PlatformEngineering`

## 📄 License

This workshop content is available under the [LICENSE](LICENSE) file in this repository.

---

Happy platform building! 🚀

Ready to take control of your cloud destiny? Let's build something amazing together!
