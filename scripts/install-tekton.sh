#!/bin/bash

set -euo pipefail

echo "🔧 Installing Tekton Pipelines..."

# Install Tekton Pipelines
echo "📦 Installing Tekton Pipelines core components..."
mise exec -- kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Triggers
echo "📦 Installing Tekton Triggers..."
mise exec -- kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

# Install Tekton Dashboard (optional)
echo "📦 Installing Tekton Dashboard..."
mise exec -- kubectl apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# Wait for Tekton components to be ready
echo "⏳ Waiting for Tekton components to be ready..."
mise exec -- kubectl wait --namespace tekton-pipelines \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/part-of=tekton-pipelines \
  --timeout=300s

# Create namespace for function builds
echo "🏗️  Creating cloudbox-functions namespace..."
mise exec -- kubectl create namespace cloudbox-functions --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Create ServiceAccount for function builds
echo "🔐 Creating ServiceAccount for function builds..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: function-builder
  namespace: cloudbox-functions
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: function-builder
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "create", "update", "patch"]
- apiGroups: ["serving.knative.dev"]
  resources: ["services"]
  verbs: ["get", "list", "create", "update", "patch"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "taskruns"]
  verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: function-builder
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: function-builder
subjects:
- kind: ServiceAccount
  name: function-builder
  namespace: cloudbox-functions
EOF

# Create registry access secret
echo "🔐 Creating registry access secret..."
mise exec -- kubectl create secret generic registry-auth \
  --namespace=cloudbox-functions \
  --from-literal=username=admin \
  --from-literal=password=admin \
  --type=kubernetes.io/basic-auth \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Create Docker config secret for Kaniko
echo "🐳 Creating Docker config secret for Kaniko..."
mise exec -- kubectl create secret generic kaniko-secret \
  --namespace=cloudbox-functions \
  --from-literal=config.json='{
    "auths": {
      "zot-registry-internal.zot-registry:5000": {
        "username": "admin",
        "password": "admin"
      }
    }
  }' \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f -

# Create function build pipeline
echo "📋 Creating function build pipeline..."
cat << 'EOF' | mise exec -- kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: build-function-image
  namespace: cloudbox-functions
spec:
  params:
  - name: function-name
    description: Name of the function
  - name: function-runtime
    description: Runtime of the function (nodejs, python, go, java)
  - name: registry-url
    description: Registry URL
    default: "host.docker.internal:30500"
  - name: image-tag
    description: Image tag
    default: "latest"
  workspaces:
  - name: source
    description: Workspace containing function source code (writable)
  - name: source-configmap
    description: ConfigMap containing function source code (read-only)
  - name: dockerconfig
    description: Docker config for registry authentication
  steps:
  - name: copy-source
    image: alpine:latest
    script: |
      #!/bin/sh
      set -e
      echo "Copying source files from ConfigMap to writable workspace..."

      # Ensure source directory exists
      mkdir -p $(workspaces.source.path)

      # Copy all files from ConfigMap, following symlinks to get actual content
      cp -rL $(workspaces.source-configmap.path)/* $(workspaces.source.path)/ || true

      # List contents for debugging
      echo "Contents of source workspace:"
      ls -la $(workspaces.source.path)/

      # Verify files are regular files, not symlinks
      echo "File types:"
      for file in $(workspaces.source.path)/*; do
        if [ -f "$file" ]; then
          echo "$(basename $file): $(file "$file")"
        fi
      done

      # Ensure the directory is writable
      chmod -R 755 $(workspaces.source.path)/
  - name: prepare-dockerfile
    image: alpine:latest
    script: |
      #!/bin/sh
      set -e

      RUNTIME=$(params.function-runtime)
      FUNCTION_NAME=$(params.function-name)

      echo "Preparing Dockerfile for runtime: $RUNTIME"
      echo "Current source directory contents:"
      ls -la $(workspaces.source.path)/

      # Check if files already exist (created by API), if not create basic ones
      case $RUNTIME in
        "nodejs18"|"nodejs")
          cat > $(workspaces.source.path)/Dockerfile << 'DOCKERFILE'
      FROM node:18-alpine
      WORKDIR /app
      COPY package.json ./
      RUN npm install --only=production
      COPY index.js ./
      EXPOSE 8080
      CMD ["node", "index.js"]
      DOCKERFILE
          echo "Using package.json and index.js from ConfigMap"
          ;;

        "python39"|"python")
          cat > $(workspaces.source.path)/Dockerfile << 'DOCKERFILE'
      FROM python:3.11-alpine
      WORKDIR /app
      COPY requirements.txt ./
      RUN pip install --no-cache-dir -r requirements.txt
      COPY main.py ./
      EXPOSE 8080
      CMD ["python", "main.py"]
      DOCKERFILE
          echo "Using requirements.txt and main.py from ConfigMap"
          ;;

        "go121"|"go")
          cat > $(workspaces.source.path)/Dockerfile << 'DOCKERFILE'
      FROM golang:1.21-alpine AS builder
      WORKDIR /app
      COPY go.mod go.sum ./
      RUN go mod download
      COPY main.go ./
      RUN go build -o main .

      FROM alpine:latest
      RUN apk --no-cache add ca-certificates
      WORKDIR /root/
      COPY --from=builder /app/main .
      EXPOSE 8080
      CMD ["./main"]
      DOCKERFILE
          echo "Using go.mod and main.go from ConfigMap"
          ;;

        "java17"|"java")
          cat > $(workspaces.source.path)/Dockerfile << 'DOCKERFILE'
      FROM openjdk:17-alpine
      WORKDIR /app
      COPY pom.xml ./
      COPY Main.java ./
      RUN javac Main.java
      EXPOSE 8080
      CMD ["java", "Main"]
      DOCKERFILE
          echo "Using pom.xml and Main.java from ConfigMap"
          ;;

        *)
          echo "Unsupported runtime: $RUNTIME"
          exit 1
          ;;
      esac

      echo "Dockerfile created successfully"
      echo "Final source directory contents:"
      ls -la $(workspaces.source.path)/

  - name: build-and-push
    image: gcr.io/kaniko-project/executor:latest
    args:
    - --dockerfile=$(workspaces.source.path)/Dockerfile
    - --context=$(workspaces.source.path)
    - --destination=$(params.registry-url)/functions/$(params.function-name):$(params.image-tag)
    - --insecure
    - --skip-tls-verify
    volumeMounts:
    - name: kaniko-secret
      mountPath: /kaniko/.docker
      readOnly: true
  volumes:
  - name: kaniko-secret
    secret:
      secretName: kaniko-secret
---
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: function-build-pipeline
  namespace: cloudbox-functions
spec:
  params:
  - name: function-name
    description: Name of the function
  - name: function-runtime
    description: Runtime of the function
  - name: registry-url
    description: Registry URL
    default: "host.docker.internal:30500"
  - name: image-tag
    description: Image tag
    default: "latest"
  workspaces:
  - name: shared-data
    description: Workspace for sharing data between tasks (writable)
  - name: source-configmap
    description: ConfigMap containing function source code (read-only)
  - name: dockerconfig
    description: Docker config for registry authentication
  tasks:
  - name: build-function
    taskRef:
      name: build-function-image
    params:
    - name: function-name
      value: $(params.function-name)
    - name: function-runtime
      value: $(params.function-runtime)
    - name: registry-url
      value: $(params.registry-url)
    - name: image-tag
      value: $(params.image-tag)
    workspaces:
    - name: source
      workspace: shared-data
    - name: source-configmap
      workspace: source-configmap
    - name: dockerconfig
      workspace: dockerconfig
EOF

echo "✅ Tekton Pipelines installation completed!"
echo ""
echo "📊 Installation Information:"
echo "  Tekton Pipelines: Installed in tekton-pipelines namespace"
echo "  Tekton Triggers: Installed in tekton-pipelines namespace"
echo "  Tekton Dashboard: Installed in tekton-pipelines namespace"
echo "  Function Build Namespace: cloudbox-functions"
echo ""
echo "🔧 Next steps:"
echo "  1. Configure function controller to use Tekton pipelines"
echo "  2. Create function source code ConfigMaps"
echo "  3. Trigger pipeline runs for function builds"
echo ""
echo "💡 Useful commands:"
echo "  Check Tekton pods: mise exec -- kubectl get pods -n tekton-pipelines"
echo "  View pipeline: mise exec -- kubectl get pipeline -n cloudbox-functions"
echo "  Access dashboard: mise exec -- kubectl port-forward -n tekton-pipelines svc/tekton-dashboard 9097:9097"
