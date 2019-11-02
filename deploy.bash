#!/bin/bash
if [ $# -lt 3 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Args are required'
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Usage: $0 environment[production,staging] service_name[web,api] blue/green"
  exit 1
fi
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']' Start


# Command path
AWS="/usr/local/bin/aws"
JQ="/usr/local/bin/jq"
TERRAFORM="/usr/local/bin/terraform"

# Variables
PLAYBOOK_DIR="/home/deploy/hogeo_no_ansible"
TERRA_DIR="/home/deploy/hogeo_no_terraform"
target_env="${1}"
target_service="${2}"
color="${3}"
LOG="/home/deploy/tools/log/deploy_${target_env}_${target_service}.log"
TOOL_PATH="/home/deploy/tools"
private_key="~/.ssh/hogeo_no_kagi"
slack_user="${target_env}_Deployer"
slack_channel="#hogeo-release"
if [ "$target_env" != "production" ];then
  slack_channel="#hogeo-mobpro"
fi
Lock_file="/tmp/deploy_${target_service}.lock"
if [ -f $Lock_file ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] Info: lock file has found, check PID in lock file is processing now.'
  ps `cat $Lock_file` > /dev/null
  if [ $? -eq 0 ];then
    echo "deploy is already processing. This shell will exit. \n
            PID:$$ $0 $target_env $target_service $color"|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Start to BlueGreen Delploy" -i ':elf:' -n $slack_user
    exit 0
  fi
fi
echo $$ > $Lock_file

if [ ! -f "$LOG" ];then
  touch $LOG
fi

# e.g. production-web-blue-asg
asg_name="${target_env}-${target_service}-${color}-asg"
# e.g. production-web-tg
asg_tg_name="${target_env}-${target_service}-tg-${color}"
# e.g. arn:aws:elasticloadbalancing:ap-northeast-1:*************:targetgroup/sandbox--api-tg/***************
asg_tg_arn=`$AWS elbv2 describe-target-groups --names $asg_tg_name | $JQ -r '.TargetGroups[].TargetGroupArn'`
another_side="green"
if [ `echo $asg_name|grep green` ];then another_side="blue"; fi
another_asg="${target_env}-${target_service}-${another_side}-asg"
another_asg_info="`$AWS autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${target_env}-${target_service}-${another_side}-asg`"
min_size=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].MinSize'`
max_size=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].MaxSize'`
desired_capacity=`echo $another_asg_info | $JQ -r '.AutoScalingGroups[].DesiredCapacity'`

echo "$asg_name "|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Start to BlueGreen Delploy" -i ':elf:' -n $slack_user

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] Info: start deploy.bash' $1 $2 $3 | tee -a $LOG

# デプロイしようとしている環境がStandbyであることを確認する
$AWS autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asg_name | $JQ -r '.AutoScalingGroups[].Tags[]'|grep Standby > /dev/null
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] End: $asg_name is not Standby" | tee -a $LOG
  echo "$asg_name is not Standby"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m "Skip to BlueGreen Delploy" -i ':elf:' -n  $slack_user
  rm $Lock_file
  exit 0
else
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: $asg_name is Standby" | tee -a $LOG
   EC2State=`$AWS ec2 describe-instances --filters "Name=tag:Name,Values=${target_env}-${target_service}-${3}"|jq -r '.Reservations[].Instances[].State'|grep running > /dev/null;echo $?`
  if [ $EC2State -eq 0 ];then
    echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Error: running EC2 instance exists on $asg_name. please clean up before deploy"
    echo "$asg_name "|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Skip Deploy: running EC2 instance exists on Standby ASG: $asg_name. please clean up before deploy" -i ':elf:' -n $slack_user
    exit 1
  fi
fi

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] Info: 1 instance start and ansible deploy.' | tee -a $LOG
$AWS autoscaling update-auto-scaling-group --min-size 1 --max-size 1 --desired-capacity 1 --auto-scaling-group-name $asg_name | tee -a $LOG

#cronによる自動デプロイ後のdeployedタグ待ち
while [ 1 -gt `$AWS ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${asg_name}" "Name=instance-state-name,Values=running" \
        | $JQ -r '.Reservations[].Instances[].Tags[].Value' | grep -c deployed` ]
do
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: waiting for deployed by lifecycle_action_polling_sqs. sleep 30" | tee -a $LOG
  sleep 30
done

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: create AMI." | tee -a $LOG
instance_id=`$AWS ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${asg_name}" "Name=instance-state-name,Values=running" | \
        $JQ -r '.Reservations[].Instances[].InstanceId'`
if [ -z "$instance_id" ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Error: Instance_Id to create AMI is not found." | tee -a $LOG
  exit 1
fi
ret=$($AWS ec2 create-image --instance-id $instance_id --name "${target_env}-${target_service}-gi-`date "+%Y%m%d%H%M%S"`" --reboot)
ami_id=`echo $ret| $JQ -r '.ImageId'`
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: created AMI is $ami_id" | tee -a $LOG

#AMI取得完了まで待つ必要ある？
#ami_status=`$AWS ec2 describe-images --image-ids $ami_id | $JQ -r '.Images[].State'`

while [ "pending" == "`$AWS ec2 describe-images --image-ids $ami_id | $JQ -r '.Images[].State'`" ]
do
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: waiting for AMI is created. sleep 30" | tee -a $LOG
  sleep 30
done

# AMIを更新by Terraform
 echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: update AMI on Terraform main.tf"| tee -a $LOG
cd $TERRA_DIR/ec2/services/${target_service#}/${target_env}/${3}
sed -i "s/\"ami-.*\"/\"${ami_id}\"/g" main.tf
sed -i -e "s/web_asg_max_size.*/web_asg_max_size = \"${max_size}\"/g" \
  -e "s/web_asg_min_size.*/web_asg_min_size = \"${min_size}\"/g" \
  -e "s/web_asg_desired_capacity.*/web_asg_desired_capacity = \"${desired_capacity}\"/g" \
        main.tf
# amiがnullってたら強制上書き
grep "ami-" main.tf
if [ $? -ne 0 ];then
  sed -i "s/"ami.*"/ami\ =\ \"${ami_id}\"/g" main.tf
fi
$TERRAFORM fmt main.tf
$TERRAFORM init && $TERRAFORM plan && $TERRAFORM apply -auto-approve
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Error: Failed to terraform apply. check this $asg_name"| tee -a $LOG
  echo "$asg_name "|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Failed to terraform apply. check this $asg_name." -i ':zombie:' -n $slack_user
  exit 1
fi

# 現環境と同じ台数までインスタンスを増加させる
$AWS autoscaling update-auto-scaling-group --min-size $min_size --max-size $max_size --desired-capacity $desired_capacity --auto-scaling-group-name $asg_name
while [ $min_size -gt `$AWS ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${asg_name}" "Name=instance-state-name,Values=running" \
        | $JQ -r '.Reservations[].Instances[].Tags[].Value' | grep -c deployed` ]
do
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: waiting for deployed by lifecycle_action_polling_sqs. sleep 30" | tee -a $LOG
  sleep 30
done

###Datadogを適用する#######################
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: create ansible_hosts" |tee -a $LOG
sudo bash -c "/usr/bin/python3 ${TOOL_PATH}/bin/host_creator.py $target_env"
${TOOL_PATH}/bin/ansible_hosts_creator.bash ${target_service#} > /home/deploy/ansible_hosts_${target_service#}
if [ $? -ne 0 ];then
  echo "$asg_name "|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Failed to create ansible_hosts file. check this $asg_name." -i ':zombie:' -n $slack_user
  exit 1
fi

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Info: Ansible: Datadog install" |tee -a $LOG
cd $PLAYBOOK_DIR
ansible-playbook -i /home/deploy/ansible_hosts_${target_service#} --private-key=${private_key} setup_datadog.yml -e "target_service=${target_service#}" -e "target_env=$target_env" -v 2>&1 | tee -a $LOG
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "]Fatal: Failed to setup Datadog@deploy.bash ${target_service#}" | tee -a $LOG
  echo "Failed: Ansible deploy: setup Datadog@deploy.bash"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m 'Oops!' -i ':male_zombie:'
  exit 1
  # Todo: 失敗した時、lockファイルは残すべきか・・・
fi


##########################
# ALB Listenerを反対側に切り替える
load_balancer_arn=`$AWS elbv2 describe-load-balancers --names ${target_env}-${target_service}-alb | $JQ -r '.LoadBalancers[].LoadBalancerArn'`
listner_arn=`$AWS elbv2 describe-listeners --load-balancer-arn $load_balancer_arn | $JQ -r '.Listeners[].ListenerArn'`
$AWS elbv2 modify-listener --listener-arn $listner_arn --default-actions Type=forward,TargetGroupArn=$asg_tg_arn
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] Fatal: Change ALB modify-listener."
  echo "$asg_name"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m "Fatal: Change ALB modify-listener." -i ':zombie:' -n  $slack_user
  rm $Lock_file
  exit 1
fi

$AWS autoscaling create-or-update-tags --tags \
        ResourceId=$asg_name,ResourceType=auto-scaling-group,Key=RunningStatus,Value=InService,PropagateAtLaunch=false

# 旧環境の後処理：TargetroupのデタッチとタグのStandby化
# rollback の判断は人がした方がいい気がするので、旧環境のインスタンスを0にするロジックはここには入れない
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] Info: detach-load-balancer old app' | tee -a $LOG
$AWS autoscaling create-or-update-tags --tags \
        ResourceId=$another_asg,ResourceType=auto-scaling-group,Key=RunningStatus,Value=Standby,PropagateAtLaunch=false

echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: deploy.bash success' | tee -a $LOG
echo "$asg_name has min: $min_size , max: $max_size instance.  
check all instances are deployed properly."|bash ${TOOL_PATH}/bin/slack_notify.bash -c "$slack_channel" -m "Success to BlueGreen Delploy" -i ':elf:' -n $slack_user
rm $Lock_file
