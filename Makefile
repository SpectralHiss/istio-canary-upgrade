ISTIO_SRC_VERSION:=1.11.3
ISTIO_DST_VERSION:=1.12.0

RELEASE_DIR_SRC=istio-$(ISTIO_SRC_VERSION)
RELEASE_DIR_DST=istio-$(ISTIO_DST_VERSION)

ISCTL_SRC=$(RELEASE_DIR_SRC)/bin/istioctl
ISCTL_DST=$(RELEASE_DIR_DST)/bin/istioctl

.PHONY: workloads-phase1
workloads-phase1: ingressgw
	kubectl apply -f samples/bookinfo/

.PHONY: ingressgw
ingressgw: kind-ctx nses istiov113 initial-tags
	kubectl apply -f gateway-v1/

.PHONY: istiov113
istiov113: kind-ctx $(ISCTL_SRC)
	$(ISCTL_SRC) install -f iop-v1.yaml

.PHONY: stable-tag
initial-tags: $(ISCTL_SRC)
	$(ISCTL_SRC) x revision tag set stable --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	kubectl label ns default istio-injection-
	kubectl label ns default istio.io/rev=stable --overwrite=true
	kubectl label ns ratings istio.io/rev=canary --overwrite=true
	$(ISCTL_SRC) x revision tag set canary --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true

.PHONY: phase2
phase2:
	# rollout new istiod and point some workloads to it and new gateway
	$(ISCTL_DST) install -f iop-v2.yaml # revision is set to 1-12-0 in that manifest
	# Push canary tag to new revision
	$(ISCTL_SRC) x revision tag set canary --revision $(subst .,-, $(ISTIO_DST_VERSION)) --overwrite=true
	# Roll applications in namespace ratings (the canary ns)
	kubectl rollout restart deploy ratings-v1 -n ratings
	echo "App should still be live, if you inspect the ratings-v1 pod you will find it points at istio 1.12"


.phony: phase3
phase3:
	echo "ok"

istio-%-linux-amd64.tar.gz:
	curl --silent -L -o $@ https://github.com/istio/istio/releases/download/$*

istio-%/bin/istioctl: istio-%-linux-amd64.tar.gz
	tar -xf $^

check-app: kind-ctx
	./check-my-apps.sh &
	touch check-app

.phony: port-forward
port-forward:
	kubectl port-forward svc/istio-ingressgateway 9080:80 &

kind-cluster:
	kind create cluster --name test-canary-upgrade
	touch kind-cluster

kind-ctx: kind-cluster
	kubectl config use-context kind-test-canary-upgrade



.PHONY: nses
nses:
	kubectl create ns ratings || true



clean-check-app:
	ps x | grep istio-ingressgateway | grep -v grep | awk '{print $$1}' | xargs kill $1 || true
	ps x | grep check-my-apps.sh | grep -v grep | awk '{print $$1}' | xargs kill $1 || true
	rm check-app

.PHONY: clean
clean:
	rm -rf $(RELEASE_DIR_SRC)
	rm -rf $(RELEASE_DIR_DST)
	kind delete cluster --name test-canary-upgrade
	rm kind-cluster