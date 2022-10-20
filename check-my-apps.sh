#!/bin/bash

function fail() {
    echo "Not working :("
}

echo "Primitive way to check app is serving traffic as required"
echo "Assumes you've setup /etc/hosts with the correct loadbalancer IP with the host below"
SITE_ADDR=bookinfo.org


while true; do
  echo "$(tput setaf 3)Bookinfo via Istio Ingress Gateway$(tput setaf 7)"
  FAIL="false"

  curl -v -I -q http://${SITE_ADDR}/productpage
  OUT=$(curl -i -s http://${SITE_ADDR}/productpage)
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
