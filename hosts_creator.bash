#!/bin/bash
AWS="/usr/local/bin/aws"
JQ="/usr/local/bin/jq"
if [ $# -lt 1 ];then
  echo "$0 environment"
  exit 1
fi
environment=$1
colors=(blue green)
ec2_hostnames=(web adm api batch)
hosts_tmp=/tmp/hosts_tmp
# Initialize
if [ -f $hosts_tmp ];then
  echo "rm old tmp"
  rm $hosts_tmp
fi
touch $hosts_tmp

if [ ! -f "/etc/hosts_org" ];then
  echo "create backup:/etc/hosts_org"
  sudo sh -c "cp /etc/hosts /etc/hosts_org"
fi

# Main
for ec2_hostname in ${ec2_hostnames[@]} ;do
  for color in ${colors[@]} ;do
    private_ips=`$AWS --profile $environment ec2 describe-instances --filters "Name=tag:Name,Values=${environment}-${ec2_hostname}-${color}"  |$JQ -r '.Reservations[].Instances[].PrivateIpAddress'`
    count=1
    for private_ip in ${private_ips[@]} ;do
      echo $private_ip ${ec2_hostname}${count}${color:0:1} >> $hosts_tmp
      count=$(( count + 1 ))
    done
  done
done

# hogeはAutoScalingGroupじゃないのでforの外で(条件分岐が面倒なので)
private_ip=`$AWS --profile $environment ec2 describe-instances --filters "Name=tag:Name,Values=${environment}-hoge" |$JQ -r '.Reservations[].Instances[].PrivateIpAddress'`
echo $private_ip opt >> $hosts_tmp

sudo sh -c "cat /etc/hosts_org > /etc/hosts"
sudo sh -c "cat $hosts_tmp >> /etc/hosts"
