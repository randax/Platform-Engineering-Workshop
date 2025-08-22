#!/bin/bash

set -e

echo "🛠️  Setting up development environment..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Go is not installed. Please install Go 1.21 or later."
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Please install kubectl."
    exit 1
fi

echo "✅ Prerequisites check passed"

# Install development tools
echo "📦 Installing development tools..."

# Install golangci-lint for linting
if ! command -v golangci-lint &> /dev/null; then
    echo "Installing golangci-lint..."
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin v1.54.2
fi

# Install swag for API documentation
if ! command -v swag &> /dev/null; then
    echo "Installing swag..."
    go install github.com/swaggo/swag/cmd/swag@latest
fi

# Download Go dependencies
echo "📥 Downloading Go dependencies..."
go mod download
go mod tidy

# Create necessary directories
echo "📁 Creating directories..."
mkdir -p bin/
mkdir -p docs/swagger/
mkdir -p web/src/

# Generate go.sum if it doesn't exist
if [ ! -f go.sum ]; then
    echo "🔧 Generating go.sum..."
    go mod tidy
fi

# Install pre-commit hook (optional)
if [ -d .git ]; then
    echo "🔗 Setting up git hooks..."
    cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
echo "Running pre-commit checks..."
make fmt
make lint
make test
EOF
    chmod +x .git/hooks/pre-commit
fi

echo "✅ Development environment setup complete!"
echo ""
echo "🚀 Quick Start:"
echo "  make dev        # Run the API server locally"
echo "  make test       # Run tests"
echo "  make build      # Build the binary"
echo "  make help       # Show all available commands"
echo ""
echo "Happy coding! 🎉"
