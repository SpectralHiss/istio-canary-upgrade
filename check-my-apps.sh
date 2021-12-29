#!/bin/bash

function fail() {
    echo "Not working :("
}

echo "Primitive way to check app is serving traffic as required"
echo "assumes ingressgateway svc is port-forwarded on 9080"

while true; do
  echo "$(tput setaf 3)Bookinfo via Istio Ingress Gateway$(tput setaf 7)"
  FAIL="false"

  OUT=$(curl -i -s localhost:9080/productpage)
  if ! [ "$?" -eq 0 ]; then
    FAIL="true"
  fi

  echo $OUT | grep --silent 200
  if ! [ "$?" -eq 0 ]; then
    FAIL="true"
  fi
  echo $OUT | grep --silent "<!-- full stars: -->"
  if ! [ "$?" -eq 0 ]; then
    FAIL="true"
  fi

  if [[ "$FAIL" == "false" ]] ; then
    echo "$(tput setaf 2)app is live! :)$(tput setaf 7)"
  else
    fail
  fi
  sleep 1
done
