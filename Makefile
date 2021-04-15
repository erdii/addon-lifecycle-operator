# TODOs
# relocate IMAGE_ORG

IMAGE_ORG?=quay.io/openshift
MODULE:=github.com/openshift/addon-operator
CONTROLLER_GEN_VERSION:=v0.5.0
OLM_VERSION:=v0.17.0
KIND_KUBECONFIG:=bin/e2e/kubeconfig

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


# problem 1: my user is not part of the `docker` group, thus i need `sudo kind`
# problem 2: if using podman, `sudo kind` is also needed because the kubelet cannot run in an unprivileged container
# solution: test for these conditions and set $KIND_COMMAND + $KIND_EXPERIMENTAL_PROVIDER accordingly
# https://github.com/kubernetes-sigs/kind/blob/main/pkg/internal/runtime/runtime.go#L12
ifneq (,$(shell command -v podman))
	export KIND_EXPERIMENTAL_PROVIDER:=podman
	DOCKER_COMMAND:=podman
	KIND_COMMAND:=sudo --preserve-env=KIND_EXPERIMENTAL_PROVIDER kind
else
	export KIND_EXPERIMENTAL_PROVIDER:=docker
	ifeq (,$(groups | grep docker))
		DOCKER_COMMAND:=sudo docker
		KIND_COMMAND:=sudo kind
	else
		DOCKER_COMMAND:=docker
		KIND_COMMAND:=kind
	endif
endif

# TODO: move in-repo
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
	bin/linux_amd64/addon-operator-manager

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
		./cmd/addon-operator-manager/main.go \
			-pprof-addr="127.0.0.1:8065"
.PHONY: run

# ----------
# Generators
# ----------

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) crd:crdVersions=v1 \
		rbac:roleName=addon-operator-manager \
		paths="./..." \
		output:crd:artifacts:config=config/deploy

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object paths=./apis/...

# Makes sandwich
# https://xkcd.com/149/
sandwich:
ifneq ($(shell id -u), 0)
	@echo "What? Make it yourself."
else
	@echo "Okay."
endif

# find or download controller-gen
# download controller-gen if necessary
# Note: this will not upgrade from previously downloaded controller-gen versions
# TODO: fix ^
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION) ;\
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

log-kind-vars:
	@echo "DOCKER_COMMAND=$(DOCKER_COMMAND)"
	@echo "KIND_EXPERIMENTAL_PROVIDER=$(KIND_EXPERIMENTAL_PROVIDER)"
	@echo "KIND_COMMAND=$(KIND_COMMAND)"
	env | grep KIND
.PHONY: log-kind-vars

create-kind-cluster: log-kind-vars
	mkdir -p bin/e2e
	$(KIND_COMMAND) create cluster \
		--kubeconfig=$(KIND_KUBECONFIG) \
		--name="addon-operator-e2e"
	sudo chown $$USER: $(KIND_KUBECONFIG)
.PHONY: create-kind-cluster

delete-kind-cluster: log-kind-vars
	$(KIND_COMMAND) delete cluster \
		--kubeconfig="$(KIND_KUBECONFIG)" \
		--name "addon-operator-e2e"
	rm -rf "$(KIND_KUBECONFIG)"
.PHONY: delete-kind-cluster

setup-e2e-kind: | \
	create-kind-cluster \
	setup-olm \
	setup-openshift-console \
	setup-ao

setup-olm:
	set -ex \
		&& export KUBECONFIG=$(KIND_KUBECONFIG) \
		&& kubectl apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/$(OLM_VERSION)/crds.yaml \
		&& kubectl apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/$(OLM_VERSION)/olm.yaml \
		&& kubectl wait --for=condition=available deployment/olm-operator -n olm --timeout=240s \
		&& kubectl wait --for=condition=available deployment/catalog-operator -n olm --timeout=240s
.PHONY: setup-olm

setup-openshift-console:
	set -ex \
		&& export KUBECONFIG=$(KIND_KUBECONFIG) \
		&& kubectl apply -f hack/openshift-console.yaml
.PHONY: setup-openshift-console

setup-ao: build-image-addon-operator-manager
	set -ex \
		&& export KUBECONFIG=$(KIND_KUBECONFIG) \
		&& $(KIND_COMMAND) load image-archive \
			bin/image/addon-operator-manager.tar \
			--name addon-operator-e2e \
		&& kubectl apply -f config/deploy \
		&& yq -y '.spec.template.spec.containers[0].image = "$(IMAGE_ORG)/addon-operator-manager:$(VERSION)"' config/deploy/deployment.yaml.tpl \
			| kubectl apply -f -
.PHONY: setup-ao

# ----------------
# Container Images
# ----------------

build-images: \
	build-image-addon-operator-manager
.PHONY: build-images

push-images: \
	push-image-addon-operator-manager
.PHONY: push-images

.SECONDEXPANSION:
build-image-%: bin/linux_amd64/$$*
	@rm -rf "bin/image/$*" "bin/image/$*.tar"
	@mkdir -p "bin/image/$*"
	@cp -a "bin/linux_amd64/$*" "bin/image/$*"
	@cp -a "config/docker/$*.Dockerfile" "bin/image/$*/Dockerfile"
	@cp -a "config/docker/passwd" "bin/image/$*/passwd"
	@echo "building ${IMAGE_ORG}/$*:${VERSION}"
	@$(DOCKER_COMMAND) build -t "${IMAGE_ORG}/$*:${VERSION}" "bin/image/$*"
	@$(DOCKER_COMMAND) image save -o "bin/image/$*.tar" "${IMAGE_ORG}/$*:${VERSION}"

push-image-%: build-image-$$*
	@$(DOCKER_COMMAND) push "${IMAGE_ORG}/$*:${VERSION}"
	@echo pushed "${IMAGE_ORG}/$*:${VERSION}"
