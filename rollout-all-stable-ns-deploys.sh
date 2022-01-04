#!/bin/bash

STABLE_NSES="$(kubectl get ns -l istio.io/rev=stable -o name | cut -d / -f 2)"

for NS in "${STABLE_NSES}"; do
  DEPS=$(kubectl get deploy -n $NS -o name | grep -v istio-ingressgateway)
  for DEP in $DEPS; do
    kubectl rollout restart $DEP -n $NS
    kubectl rollout status -w deployment "$DEP" -n "$NS"
  done
done