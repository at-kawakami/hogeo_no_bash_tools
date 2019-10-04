#!/bin/bash
IFS=$'\n'
target_services=$1
if [ -z "$target_services" ];then
  target_services=(web adm api)
fi

for service in ${target_services[@]}; do
  echo ["$service"]
  targets=`grep $service /etc/hosts|awk '{print $2,"ansible_ssh_host="$1 " ansible_python=/usr/bin/python3 db_migrate=True ansible_ssh_user=ubuntu"}'`
  count=1
  for i in ${targets[@]};do
    if [ $count -ne 1 ];then
      echo $i|sed -e "s/db_migrate=True/db_migrate=False/g"
    else
      echo $i
    fi
    count=$(( count + 1 ))
  done
done
