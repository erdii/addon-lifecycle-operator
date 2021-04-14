# TODOs
# relocate IMAGE_ORG

IMAGE_ORG?=quay.io/openshift
MODULE=github.com/openshift/addon-lifecycle-operator

SHELL=/bin/bash
.SHELLFLAGS=-euo pipefail -c

export CGO_ENABLED:=0

BRANCH=$(shell git rev-parse --abbrev-ref HEAD)
SHORT_SHA=$(shell git rev-parse --short HEAD)
VERSION?=${BRANCH}-${SHORT_SHA}
BUILD_DATE=$(shell date +%s)
LD_FLAGS=-X $(MODULE)/internal/version.Version=$(VERSION) \
			-X $(MODULE)/internal/version.Branch=$(BRANCH) \
			-X $(MODULE)/internal/version.Commit=$(SHORT_SHA) \
			-X $(MODULE)/internal/version.BuildDate=$(BUILD_DATE)

# Default to using podman if it is available
# Override by setting envvar like `DOCKER_COMMAND=my-docker make`
ifeq (,$(shell command -v podman))
DOCKER_COMMAND?="docker"
else
DOCKER_COMMAND?="podman"
endif

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# -------
# Compile
# -------

all: \
	bin/linux_amd64/addon-lifecycle-operator-manager

bin/linux_amd64/%: GOARGS = GOOS=linux GOARCH=amd64

bin/%: FORCE
	$(eval COMPONENT=$(shell basename $*))
	$(GOARGS) go build -ldflags "-w $(LD_FLAGS)" -o bin/$* cmd/$(COMPONENT)/main.go

FORCE:

clean:
	rm -rf bin/$*
.PHONY: clean

# ----------
# Deployment
# ----------

# Run against the configured Kubernetes cluster in ~/.kube/config or $KUBECONFIG
run: generate fmt vet manifests
	go run -ldflags "-w $(LD_FLAGS)" \
		./cmd/addon-lifecycle-operator-manager/main.go \
			-pprof-addr="127.0.0.1:8065"
.PHONY: run

# ----------
# Generators
# ----------

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) crd:crdVersions=v1 rbac:roleName=alo-manager paths="./..." output:crd:artifacts:config=config/crd

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object paths=./apis/...

# find or download controller-gen
# download controller-gen if necessary
# Note: this will not upgrade from previously downloaded controller-gen versions
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.5.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

# -------------------
# Testing and Linting
# -------------------

test: generate fmt vet manifests
	CGO_ENABLED=1 go test -race -v ./...
.PHONY: test

ci-test: test
	hack/validate-directory-clean.sh
.PHONY: ci-test

fmt:
	go fmt ./...
.PHONY: fmt

vet:
	go vet ./...
.PHONY: vet

pre-commit-install:
	@echo "installing pre-commit hooks using https://pre-commit.com/"
	@pre-commit install
.PHONY: pre-commit-install

# ----------------
# Container Images
# ----------------

build-images: \
	build-image-addon-lifecycle-operator-manager
.PHONY: build-images

push-images: \
	push-image-addon-lifecycle-operator-manager
.PHONY: push-images

.SECONDEXPANSION:
build-image-%: bin/linux_amd64/$$*
	@rm -rf bin/image/$*
	@mkdir -p bin/image/$*
	@cp -a bin/linux_amd64/$* bin/image/$*
	@cp -a config/docker/$*.Dockerfile bin/image/$*/Dockerfile
	@cp -a config/docker/passwd bin/image/$*/passwd
	@echo building ${IMAGE_ORG}/$*:${VERSION}
	@$(DOCKER_COMMAND) build -t ${IMAGE_ORG}/$*:${VERSION} bin/image/$*

push-image-%: build-image-$$*
	@$(DOCKER_COMMAND) push ${IMAGE_ORG}/$*:${VERSION}
	@echo pushed ${IMAGE_ORG}/$*:${VERSION}
