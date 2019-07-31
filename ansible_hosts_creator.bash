#!/bin/bash
IFS=
target_services=(web adm api batch)
for service in ${target_services[@]}; do
  echo ["$service"]
  grep $service /etc/hosts|awk '{print $2,"ansible_ssh_host="$1 " ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu"}'
done
