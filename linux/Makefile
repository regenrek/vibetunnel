# VibeTunnel Linux Makefile
# Compatible with VibeTunnel macOS app

.PHONY: build clean test install dev deps web help

# Variables
APP_NAME := vibetunnel
VERSION := 1.0.3
BUILD_DIR := build
WEB_DIR := ../web
DIST_DIR := $(WEB_DIR)/dist

# Go build flags
GO_FLAGS := -ldflags "-X main.version=$(VERSION)"
# Suppress GNU folding constant warning
export CGO_CFLAGS := -Wno-gnu-folding-constant
GO_BUILD := go build $(GO_FLAGS)

# Default target
all: build

help: ## Show this help message
	@echo "VibeTunnel Linux Build System"
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Install dependencies
	go mod download
	go mod tidy

web: ## Build web assets (requires npm in ../web)
	@echo "Building web assets..."
	@if [ -d "$(WEB_DIR)" ]; then \
		cd $(WEB_DIR) && npm install && npm run build; \
	else \
		echo "Warning: Web directory not found at $(WEB_DIR)"; \
		echo "Make sure you're running from the linux/ subdirectory"; \
	fi

build: deps ## Build the binary
	@echo "Building $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	$(GO_BUILD) -o $(BUILD_DIR)/$(APP_NAME) ./cmd/vibetunnel

build-static: deps ## Build static binary
	@echo "Building static $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux $(GO_BUILD) -a -installsuffix cgo -o $(BUILD_DIR)/$(APP_NAME)-static ./cmd/vibetunnel

dev: build ## Build and run in development mode
	@echo "Starting VibeTunnel in development mode..."
	@if [ ! -d "$(DIST_DIR)" ]; then \
		echo "Web assets not found. Building..."; \
		$(MAKE) web; \
	fi
	$(BUILD_DIR)/$(APP_NAME) --serve --debug --localhost --static-path=$(DIST_DIR)

install: build ## Install to /usr/local/bin
	@echo "Installing $(APP_NAME) to /usr/local/bin..."
	sudo cp $(BUILD_DIR)/$(APP_NAME) /usr/local/bin/
	@echo "Installing vt command..."
	sudo cp cmd/vt/vt /usr/local/bin/
	sudo chmod +x /usr/local/bin/vt
	@echo "Installation complete. Run 'vibetunnel --help' to get started."

install-user: build ## Install to ~/bin
	@echo "Installing $(APP_NAME) to ~/bin..."
	@mkdir -p ~/bin
	cp $(BUILD_DIR)/$(APP_NAME) ~/bin/
	@echo "Installing vt command..."
	cp cmd/vt/vt ~/bin/
	chmod +x ~/bin/vt
	@echo "Installation complete. Make sure ~/bin is in your PATH."
	@echo "Run 'vibetunnel --help' to get started."

test: ## Run tests
	go test -v ./...

test-coverage: ## Run tests with coverage
	go test -v -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

clean: ## Clean build artifacts
	rm -rf $(BUILD_DIR)
	rm -f coverage.out coverage.html

release: web build-static ## Build release package
	@echo "Creating release package..."
	@mkdir -p $(BUILD_DIR)/release
	@cp $(BUILD_DIR)/$(APP_NAME)-static $(BUILD_DIR)/release/$(APP_NAME)
	@cp README.md $(BUILD_DIR)/release/ 2>/dev/null || echo "README.md not found"
	@echo "Release package created in $(BUILD_DIR)/release/"

docker: ## Build Docker image
	docker build -t vibetunnel-linux .

# Package targets for different distributions
.PHONY: deb rpm appimage

deb: build-static ## Create Debian package
	@echo "Creating Debian package..."
	@mkdir -p $(BUILD_DIR)/deb/usr/local/bin
	@mkdir -p $(BUILD_DIR)/deb/DEBIAN
	@cp $(BUILD_DIR)/$(APP_NAME)-static $(BUILD_DIR)/deb/usr/local/bin/$(APP_NAME)
	@echo "Package: vibetunnel\nVersion: $(VERSION)\nArchitecture: amd64\nMaintainer: VibeTunnel\nDescription: Remote terminal access for Linux\n Provides remote terminal access via web browser, compatible with VibeTunnel macOS app." > $(BUILD_DIR)/deb/DEBIAN/control
	@dpkg-deb --build $(BUILD_DIR)/deb $(BUILD_DIR)/$(APP_NAME)_$(VERSION)_amd64.deb
	@echo "Debian package created: $(BUILD_DIR)/$(APP_NAME)_$(VERSION)_amd64.deb"

# Development helpers
.PHONY: fmt lint vet

fmt: ## Format Go code
	go fmt ./...

lint: ## Lint Go code (requires golangci-lint)
	golangci-lint run

vet: ## Vet Go code
	go vet ./...

check: fmt vet lint test ## Run all checks

# Service management (systemd)
.PHONY: service-install service-enable service-start service-stop service-status

service-install: install ## Install systemd service
	@echo "Installing systemd service..."
	@echo "[Unit]\nDescription=VibeTunnel Linux\nAfter=network.target\n\n[Service]\nType=simple\nUser=$(USER)\nExecStart=/usr/local/bin/vibetunnel --serve\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target" | sudo tee /etc/systemd/system/vibetunnel.service
	sudo systemctl daemon-reload
	@echo "Service installed. Use 'make service-enable' to enable auto-start."

service-enable: ## Enable systemd service
	sudo systemctl enable vibetunnel

service-start: ## Start systemd service
	sudo systemctl start vibetunnel

service-stop: ## Stop systemd service
	sudo systemctl stop vibetunnel

service-status: ## Show systemd service status
	systemctl status vibetunnel