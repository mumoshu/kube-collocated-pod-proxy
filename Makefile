PROXY_VERSION ?= 0.9.2
KUBE_VERSION ?= 1.3.6

REPOSITORY ?= mumoshu/kube-collocated-pod-proxy
TAG ?= $(PROXY_VERSION)-kube-$(KUBE_VERSION)
IMAGE ?= $(REPOSITORY):$(TAG)
ALIAS ?= $(REPOSITORY):kube-$(KUBE_VERSION)

BUILD_ROOT ?= build/$(TAG)
DOCKERFILE ?= $(BUILD_ROOT)/Dockerfile
ROOTFS ?= $(BUILD_ROOT)/rootfs
DOCKER_CACHE ?= docker-cache
SAVED_IMAGE ?= $(DOCKER_CACHE)/image-$(PROXY_VERSION)-$(KUBE_VERSION).tar

.PHONY: build
build: $(DOCKERFILE) $(ROOTFS)
	cd $(BUILD_ROOT) && docker build -t $(IMAGE) . && docker tag $(IMAGE) $(ALIAS)

.PHONY: clean
clean:
	echo Removing $(BUILD_ROOT)...
	rm -rf $(BUILD_ROOT)

publish:
	docker push $(IMAGE) && docker push $(ALIAS)

$(DOCKERFILE): $(BUILD_ROOT)
	sed 's/%%KUBE_VERSION%%/'"$(KUBE_VERSION)"'/g;' Dockerfile.template > $(DOCKERFILE)

$(ROOTFS): $(BUILD_ROOT)
	cp -R rootfs $(ROOTFS)

$(BUILD_ROOT):
	mkdir -p $(BUILD_ROOT)

travis-env:
	travis env set DOCKER_EMAIL $(DOCKER_EMAIL)
	travis env set DOCKER_USERNAME $(DOCKER_USERNAME)
	travis env set DOCKER_PASSWORD $(DOCKER_PASSWORD)

test:
	@echo There are no tests available for now. Skipping

save-docker-cache: $(DOCKER_CACHE)
	docker save $(IMAGE) $(shell docker history -q $(IMAGE) | tail -n +2 | grep -v \<missing\> | tr '\n' ' ') > $(SAVED_IMAGE)
	ls -lah $(DOCKER_CACHE)

load-docker-cache: $(DOCKER_CACHE)
	if [ -e $(SAVED_IMAGE) ]; then docker load < $(SAVED_IMAGE); fi

$(DOCKER_CACHE):
	mkdir -p $(DOCKER_CACHE)

docker-run: DOCKER_CMD ?=
docker-run: PORT ?=
docker-run: SELECTOR ?=
docker-run: PROTOCOL ?= udp
docker-run: NAMESPCE ?= kube-system
docker-run:
	docker run --rm -it \
	  -e PORT="$(PORT)" \
	  -e SELECTOR="$(SELECTOR)" \
	  -e PROTOCOL="$(PROTOCOL)" \
	  -e NAMESPACE="$(NAMESPACE)" \
	$(IMAGE) $(DOCKER_CMD)

kubectl-run: DOCKER_CMD ?=
kubectl-run: PORT ?=
kubectl-run: SELECTOR ?=
kubectl-run: PROTOCOL ?= udp
kubectl-run: NAMESPACE ?= kube-system
kubectl-run:
	if kubectl get pod collocated-pod-proxy-test; then \
	  kubectl delete pod collocated-pod-proxy-test; \
	fi
	kubectl run collocated-pod-proxy-test --rm --tty -i --restart=Never \
	  --env PORT="$(PORT)" \
	  --env SELECTOR="$(SELECTOR)" \
	  --env PROTOCOL="$(PROTOCOL)" \
	  --env NAMESPACE="$(NAMESPACE)" \
	  --image $(IMAGE) --command -- $(DOCKER_CMD)
