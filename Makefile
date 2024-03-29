ISTIO_SRC_VERSION:=1.11.3
ISTIO_DST_VERSION:=1.12.0

RELEASE_DIR_SRC=istio-$(ISTIO_SRC_VERSION)
RELEASE_DIR_DST=istio-$(ISTIO_DST_VERSION)

ISCTL_SRC=$(RELEASE_DIR_SRC)/bin/istioctl
ISCTL_DST=$(RELEASE_DIR_DST)/bin/istioctl

.PHONY: phase1
phase1: ingressgw
	kubectl apply -f samples/bookinfo/

.PHONY: revert-phase1
revert-phase1:
	kubectl delete -f samples/bookinfo -n default
	kubectl delete -f gateway-v1/ -n ingress

.PHONY: ingressgw
ingressgw: kind-ctx nses istiov113 initial-tags
	kubectl apply -f gateway-v1/ -n ingress
	kubectl rollout status -w deployment istio-ingressgateway -n ingress

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
phase2: $(ISCTL_DST) kind-ctx
	# rollout new istiod and point some workloads to it and new gateway
	$(ISCTL_DST) install -f iop-v2.yaml # revision is set to 1-12-0 in that manifest!
	# Push canary tag to new revision
	$(ISCTL_DST) x revision tag set canary --revision $(subst .,-, $(ISTIO_DST_VERSION)) --overwrite=true
	# Roll applications in namespace ratings (the canary ns)
	-kubectl rollout restart deploy ratings-v1 -n ratings
	-kubectl rollout status -w deployment ratings-v1 -n ratings

	@echo "App should still be live, if you inspect the ratings-v1 pod you will find it points at istio 1.12"
	@echo "Setting up new ingress gateway"
	kubectl apply -f gateway-canary/ -n ingress
	kubectl rollout status -w deployment istio-ingressgateway-canary -n ingress
	@echo "$$(tput setaf 2)New gateway is up, but not serving real traffic, we can actually test it by firing a single request"
	@echo "try running: kubectl port-forward istio-ingressgateway-canary-pod-name 9081:80"
	@echo "and visit localhost:9081 it will work fine!, however the logs will only be showing traffic coming from the right connected service$$(tput setaf 7)"

.phony: revert-phase2
revert-phase2: $(ISCTL_SRC) $(ISCTL_DST) kind-ctx
	@echo "$$(tput setaf 2)all steps are reversible, these can be done more gradually$$(tput setaf 7)"
	@echo "remove gateway"
	-kubectl delete -f gateway-canary/
	@echo "reset canary tag to 1-11-3"
	$(ISCTL_SRC) x revision tag set canary --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	-kubectl rollout restart deploy ratings-v1 -n ratings
	-kubectl rollout status -w deployment ratings-v1 -n ratings
	@echo "uninstall istio 1-12-0 canary version"
	$(ISCTL_DST) x uninstall -f iop-v2.yaml

.phony: phase3
phase3: $(ISCTL_DST) kind-ctx
	@echo "$$(tput setaf 2)moving all workloads to production, switching gateway to canary , in place upgrading and reverting$$(tput setaf 7)"
	$(ISCTL_DST) x revision tag set stable --revision $(subst .,-, $(ISTIO_DST_VERSION)) --overwrite=true
	echo "$$(tput setaf 1)Warning, this is where the most noticeable downtime in the form of a few 500s might manifest itself when dropping productpage connections$$(tput setaf 7)"
	-./rollout-all-stable-ns-deploys.sh
	@echo "$$(tput setaf 2)make service point at canary $$(tput setaf 7)"
	kubectl patch service -n ingress istio-ingressgateway -p '{"spec":{"selector":{"app": "istio-ingressgateway-canary"}}}'

.phony: phase3
revert-phase3: $(ISCTL_DST) kind-ctx
	@echo "as per usual, we can revert this by resetting the tag and redeploying all pods, and resetting the service labels"
	$(ISCTL_DST) x revision tag set stable --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	./rollout-all-stable-ns-deploys.sh
	@echo "$$(tput setaf 2)reset service to point at "old" ingressgateway $$(tput setaf 7)"
	kubectl patch service -n ingress istio-ingressgateway -p '{"spec":{"selector":{"app": "istio-ingressgateway"}}}'


.phony: phase4
phase4:
	echo "in-place upgrading "old" ingress gateway"
	-kubectl rollout restart deploy -n ingress istio-ingressgateway
	-kubectl rollout status -w deployment -n ingress istio-ingressgateway

	echo "gateway is now at 1-12-0, we can revert the service back to it"
	kubectl patch service -n ingress istio-ingressgateway -p '{"spec":{"selector":{"app": "istio-ingressgateway"}}}'


istio-%-linux-amd64.tar.gz:
	curl --silent -L -o $@ https://github.com/istio/istio/releases/download/$*/$@

istio-%/bin/istioctl: istio-%-linux-amd64.tar.gz
	tar -xf $^

check-app: kind-ctx
	./check-my-apps.sh &
	touch check-app

.phony: port-forward
port-forward:
	kubectl port-forward -n ingress svc/istio-ingressgateway 9080:80 &

kind-cluster:
	kind create cluster --name test-canary-upgrade
	touch kind-cluster

kind-ctx: kind-cluster
	kubectl config use-context kind-test-canary-upgrade

.PHONY: nses
nses:
	kubectl create ns ratings || true
	kubectl create ns ingress || true

clean-check-app:
	-ps x | grep istio-ingressgateway | grep -v grep | awk '{print $$1}' | xargs kill $1
	-ps x | grep check-my-apps.sh | grep -v grep | awk '{print $$1}' | xargs kill $1
	rm check-app

.PHONY: clean
clean:
	rm -rf $(RELEASE_DIR_SRC)
	rm -rf $(RELEASE_DIR_DST)
	-kind delete cluster --name test-canary-upgrade
	rm kind-cluster || true
	-rm istio-$(ISTIO_SRC_VERSION)-linux-amd64.tar.gz
	-rm istio-$(ISTIO_DST_VERSION)-linux-amd64.tar.gz
