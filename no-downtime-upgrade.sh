#!/bin/bash

source ~/.local/lib/demo-magic/demo-magic.sh

p "We have bookinfo running on multiple namespaces with seperate ingress gateways"

p "We will upgrade our istio version to a trace instrumented version"

pe ""

istioctl x revision tag set prod-stable --revision 1-11-3