ISTIO_SRC_VERSION:=1.13.9
ISTIO_DST_VERSION:=1.14.5

RELEASE_DIR_SRC=istio-$(ISTIO_SRC_VERSION)
RELEASE_DIR_DST=istio-$(ISTIO_DST_VERSION)

ISCTL_SRC=$(RELEASE_DIR_SRC)/bin/istioctl
ISCTL_DST=$(RELEASE_DIR_DST)/bin/istioctl


CTX=gke_jetstack-houssem-el-fekih_us-central1-c_istio-cluster-1

.PHONY: phase1
phase1: ingressgw
	kubectl apply -f samples/bookinfo/

.PHONY: revert-phase1
revert-phase1:
	kubectl delete -f samples/bookinfo -n default
	kubectl delete -f gateway-v1/ -n ingress

.PHONY: ingressgw
ingressgw: ctx nses istiovsrc initial-tags
	kubectl apply -f gateway-v1/ -n ingress
	kubectl rollout status -w deployment istio-ingressgateway -n ingress

.PHONY: istiovsrc
istiovsrc: ctx $(ISCTL_SRC)
	$(ISCTL_SRC) install -f iop-v1.yaml

.PHONY: stable-tag
initial-tags: $(ISCTL_SRC)
	$(ISCTL_SRC) x revision tag set stable --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	kubectl label ns default istio-injection-
	kubectl label ns default istio.io/rev=stable --overwrite=true
	kubectl label ns ratings istio.io/rev=canary --overwrite=true
	$(ISCTL_SRC) x revision tag set canary --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true

.PHONY: phase2
phase2: $(ISCTL_DST) ctx
	# rollout new istiod and point some workloads to it and new gateway
	$(ISCTL_DST) install -f iop-v2.yaml # revision is set to 1-14-5 in that manifest!
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
	@echo "try running: kubectl port-forward -n ingress istio-ingressgateway-canary-pod-name 9081:80"
	@echo "and visit localhost:9081 it will work fine!, however the logs will only be showing traffic coming from the right connected service$$(tput setaf 7)"

.phony: revert-phase2
revert-phase2: $(ISCTL_SRC) $(ISCTL_DST) ctx
	@echo "$$(tput setaf 2)all steps are reversible, these can be done more gradually$$(tput setaf 7)"
	@echo "remove gateway"
	-kubectl delete -f gateway-canary/
	@echo "reset canary tag to 1-13-9"
	$(ISCTL_SRC) x revision tag set canary --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	-kubectl rollout restart deploy ratings-v1 -n ratings
	-kubectl rollout status -w deployment ratings-v1 -n ratings
	@echo "uninstall istio 1-14-5 canary version"
	$(ISCTL_DST) x uninstall -f iop-v2.yaml

getipsvc = $(shell kubectl get svc -n ingress $(1) -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')
OLD_INGRESS=$(call getipsvc, istio-ingressgateway)
NEW_INGRESS=$(call getipsvc, istio-ingressgateway-canary) 
.phony: phase3
phase3: $(ISCTL_DST) ctx
	@echo "$$(tput setaf 2)moving all workloads to production, switching gateway to canary , in place upgrading and reverting$$(tput setaf 7)"
	$(ISCTL_DST) x revision tag set stable --revision $(subst .,-, $(ISTIO_DST_VERSION)) --overwrite=true
	echo "$$(tput setaf 1)Warning, this is where the most noticeable downtime in the form of a few 500s might manifest itself when dropping productpage connections$$(tput setaf 7)"
	-./rollout-all-stable-ns-deploys.sh
	@echo "$$(tput setaf 2)make host point at canary, preferably using some slow traffic shifting (route53 weights are good for this) $$(tput setaf 7)"
	@echo "In our case we just swap up out /etc/hosts entry from $(OLD_INGRESS) to $(NEW_INGRESS)"
	-sudo sed -i 's:$(OLD_INGRESS) bookinfo.org:$(NEW_INGRESS) bookinfo.org:' /etc/hosts

getipsvc = $(shell kubectl get svc -n ingress $(1) -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')
OLD_INGRESS=$(call getipsvc, istio-ingressgateway)
NEW_INGRESS=$(call getipsvc, istio-ingressgateway-canary) 
.phony: phase3
revert-phase3: $(ISCTL_DST) ctx
	@echo "as per usual, we can revert this by resetting the tag and redeploying all pods, and resetting the service labels"
	$(ISCTL_DST) x revision tag set stable --revision $(subst .,-, $(ISTIO_SRC_VERSION)) --overwrite=true
	./rollout-all-stable-ns-deploys.sh
	@echo "$$(tput setaf 2)reset service to point at "old" ingressgateway $$(tput setaf 7)"
	@echo "In our case we just swap back our /etc/hosts entry from $(NEW_INGRESS) to $(OLD_INGRESS)"
	-sudo sed -i 's:$(NEW_INGRESS) bookinfo.org:$(OLD_INGRESS) bookinfo.org:' /etc/hosts
	-sudo pkill -HUP dnsmasq


getipsvc = $(shell kubectl get svc -n ingress $(1) -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')
OLD_INGRESS=$(call getipsvc, istio-ingressgateway)
NEW_INGRESS=$(call getipsvc, istio-ingressgateway-canary) 
.phony: phase4
phase4:
	echo "in-place upgrading "old" ingress gateway"
	-kubectl rollout restart deploy -n ingress istio-ingressgateway
	-kubectl rollout status -w deployment -n ingress istio-ingressgateway

	echo "original gateway is now at 1-14-5, we can revert the traffic back to it"
	@echo "In our case we just swap back our /etc/hosts entry from $(NEW_INGRESS) to $(OLD_INGRESS)"
	-sudo sed -i 's:$(NEW_INGRESS) bookinfo.org:$(OLD_INGRESS) bookinfo.org:' /etc/hosts
	-sudo pkill -HUP dnsmasq


istio-%-linux-amd64.tar.gz:
	curl --silent -L -o $@ https://github.com/istio/istio/releases/download/$*/$@

istio-%/bin/istioctl: istio-%-linux-amd64.tar.gz
	tar -xf $^

check-app: ctx
	./check-my-apps.sh &
	touch check-app

ctx:
	kubectl config use-context $(CTX)

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
