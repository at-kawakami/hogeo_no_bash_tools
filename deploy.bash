#!/bin/bash
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']' Start
Lock_file="/tmp/deploy.lock"
if [ -f $Lock_file ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: lock file has found, not start this script'
  exit 0
fi

touch $Lock_file

# Command path
AWS="/usr/local/bin/aws"
JQ="/usr/local/bin/jq"

if [ $# -lt 3 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Arg are required'
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Usage: $0 environment[production,staging] service_name[hoge,fuga] blue/green"
  exit 1
fi

# e.g. production-hoge-blue-asg
asg_name="${1}-${2}-${3}-asg"
# e.g. production-hoge-tg
asg_tg_name="${1}-${2}-tg"
# e.g. arn:aws:elasticloadbalancing:ap-northeast-1:*************:targetgroup/hoge-tg/***************
asg_tg_arn=`$AWS elbv2 describe-target-groups --names $asg_tg_name | $JQ -r '.TargetGroups[].TargetGroupArn'`
another_side="green"
if [ `echo $asg_name|grep green` ];then another_side="blue"; fi
another_asg="${1}-${2}-${another_side}-asg"
another_asg_info="`$AWS autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${1}-${2}-${another_side}-asg`"
min_size=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].MinSize'`
max_size=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].MaxSize'`
desired_capacity=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].DesiredCapacity'`

echo "$asg_name "|bash -x ~/tools/bin/slack_notify.bash  -m "Start to BlueGreen Delploy" -i ':elf:' -n BGDeployer

$AWS autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asg_name | $JQ -r '.AutoScalingGroups[].Tags[]'|grep Standby > /dev/null
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] End: $asg_name is not Standby"
  echo "$asg_name is not Standby"|bash -x ~/tools/bin/slack_notify.bash  -m "Skip to BlueGreen Delploy" -i ':elf: -n BGDeployer'
  rm $Lock_file
  exit 0
else
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: $asg_name is Standby"
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: increase EC2 instance, attach target group"
  #exit 0
fi

# インスタンスを0から正の数に増やす。デプロイ自体はlife_cycle_hook_polling_sqsが自動で拾ってやる
$AWS autoscaling update-auto-scaling-group --min-size $min_size --max-size $max_size --desired-capacity $desired_capacity --auto-scaling-group-name $asg_name

#cronによる自動デプロイ後のdeployedタグ待ち
while [ $max_size -ne `$AWS ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${asg_name}" "Name=instance-state-name,Values=running" \
	| $JQ -r '.Reservations[].Instances[].Tags[].Value' | grep -c deployed` ]
do
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: waiting for deployed by lifecycle_action_polling_sqs. sleep 60"
  sleep 60
done

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: increase instance to min-size $min_size, max-size $max_size, desired-capacity $desired_capacity."
$AWS autoscaling attach-load-balancer-target-groups --target-group-arns $asg_tg_arn --auto-scaling-group-name $asg_name
$AWS autoscaling create-or-update-tags --tags \
       	ResourceId=$asg_name,ResourceType=auto-scaling-group,Key=RunningStatus,Value=InService,PropagateAtLaunch=false

# 旧環境の後処理：TargetroupのデタッチとタグのStandby化
# rollback の判断は人がした方がいい気がするので、旧環境のインスタンスを0にするロジックはここには入れない
$AWS autoscaling detach-load-balancer-target-groups --target-group-arns $asg_tg_arn --auto-scaling-group-name $another_asg
$AWS autoscaling create-or-update-tags --tags \
        ResourceId=$another_asg,ResourceType=auto-scaling-group,Key=RunningStatus,Value=Standby,PropagateAtLaunch=false


echo "$asg_name has min: $min_size , max: $max_size instance.
check all instances are deployed properly."|bash -x ~/tools/bin/slack_notify.bash  -m "Success to BlueGreen Delploy" -i ':elf:' -n BGDeployer
