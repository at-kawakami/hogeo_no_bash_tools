#!/bin/bash
if [ $# -lt 1 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: arg (e.g. web, adm, api) is required'
  exit 1
fi
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']' Start
aws_account="$1"
target_env="$2"
target_service="$3"
private_key="~/.ssh/hogeo_no_kagi"
Lock_file="/tmp/hook_${target_service}_sqs_autoscaling.lock"
if [ -f $Lock_file ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: lock file has found, not start this script'
  exit 0
fi

touch $Lock_file

# Command path
AWS="/usr/local/bin/aws"
JQ="/usr/local/bin/jq"
TOOL_PATH="/home/deploy/tools"
PLAYBOOK_DIR="/home/deploy/hogeo_no_ansible"

# variable
DEPLOY_LOCK="/tmp/deploy_${target_service}.lock"
QUEUE_URL="https://sqs.ap-northeast-1.amazonaws.com/${aws_account}/${target_env}-${target_service}-autoscaling-queue"
Messages="`$AWS sqs receive-message --queue-url $QUEUE_URL`"
ReceiptHandle=`echo $Messages | $JQ -r '.Messages[].ReceiptHandle'`
Body=`echo $Messages | $JQ -r '.Messages[].Body' | sed -e 's/\\\"/\"/g'`
if [ -z "$Body" ]; then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: No messages'
  rm $Lock_file
  exit 0
fi
AutoScalingHookName=`echo $Body | $JQ -r '.LifecycleHookName'`
LifecycleTransition=`echo $Body | $JQ -r '.LifecycleTransition'`
LifecycleActionToken=`echo $Body | $JQ -r '.LifecycleActionToken'`
EC2InstanceId=`echo $Body | $JQ -r '.EC2InstanceId'`
AutoScalingGroupName=`echo $Body | $JQ -r '.AutoScalingGroupName'`
MainYml="${AutoScalingHookName}.yml"

# TEST_NOTIFICATIONのキューを削除する
if [ "$LifecycleActionToken" = "null" ]; then
  is_test_notification="`echo ${Body} \| grep TEST_NOTIFICATION > /dev/null 2>&1;echo $?`"
  if [ $is_test_notification -eq 0 ];then
    echo "found TEST_NOTIFICATION , delete it"
    $AWS sqs delete-message --queue-url $QUEUE_URL --receipt-handle $ReceiptHandle
  fi
  rm $Lock_file
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Not Lifecyle message'
  exit 0
fi

State=`$AWS ec2 monitor-instances --instance-ids $EC2InstanceId| $JQ -r '.InstanceMonitorings[].Monitoring.State'`
EC2Info=`$AWS ec2 describe-instances --instance-ids $EC2InstanceId`
PrivateIp="`$AWS ec2 describe-instances --instance-ids $EC2InstanceId | $JQ -r '.Reservations[].Instances[].PrivateIpAddress'`"
NextStatus="deployed_`date "+%Y%m%d%H%M%S"`"

if [ "$State" != "enabled" ]; then
  rm $Lock_file
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Not enabled instace (retry latter).'
  exit 0
fi

# Ansible適用用のhostsを作成
echo "[$target_service]" > hosts_$EC2InstanceId
echo "$hosts_$EC2InstanceId  ansible_ssh_host=$PrivateIp ansible_python_interpreter=/usr/bin/python3 db_migrate=True ansible_ssh_user=ubuntu" >> hosts_$EC2InstanceId
echo "setup instance: $EC2InstanceId ($PrivateIp)"

if [ `echo $AutoScalingHookName | grep terminate` ];then
  NextStatus="Shutdown"
fi

echo "receive queue from SQS. $EC2InstanceId ($PrivateIp) has $AutoScalingHookName"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m "Start to Ansible playbook" -i ':man-raising-hand: '
# レッドブラックデプロイ2台目以降、もしくは定常運用中のスケールアウト時はデプロイを行わないymlを使用する
RunningInstance="`$AWS ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${AutoScalingGroupName}" "Name=instance-state-name,Values=running" \
        | $JQ -r '.Reservations[].Instances[].Tags[].Value' | grep -c deployed`"

if [ "`echo $AutoScalingHookName|grep launch`" -a $RunningInstance -ge 1 ];then
  echo "It's not (first) deploy, just check necessary processes are running."
  # nginx, RoR, sidekiq, td-agent,datadogの起動確認
  MainYml="check_start_up_process.yml"
fi

cd $PLAYBOOK_DIR
ansible-playbook -i /home/deploy/hosts_${EC2InstanceId} --private-key=${private_key} $MainYml -e "asg_name=${AutoScalingGroupName}" -e "target_service=${target_service}" -e "target_env=${target_env}" -e "initialflag=true" -vv
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] Fatal: Failed to execute ansible'
  echo "Failed: Ansible deploy: $AutoScalingHookName $EC2InstanceId ($PrivateIp)"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m 'Oops!' -i ':male_zombie:'
  exit 1
  # Todo: 失敗した時、lockファイルは残すべきか・・・
fi

# デプロイじゃないスケールアウト時(障害時スケールアウト)はDatadogを適用する
if [ ! -f $DEPLOY_LOCK ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` "] $DEPLOY_LOCK does not exist. setup Datadog to scale out."
  ansible-playbook -i /home/deploy/hosts_${EC2InstanceId} --private-key=${private_key} setup_datadog.yml -e "asg_name=${AutoScalingGroupName}" -e "target_service=${target_service}" -e "target_env=${target_env}" -e "initialflag=true" -vv
  if [ $? -ne 0 ];then
    echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']Fatal: Failed to execute ansible'
    echo "Failed: Ansible deploy: Datadog setup.@lifecycle_action_polling_sqs"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m 'Oops!' -i ':male_zombie:'
    exit 1
    # Todo: 失敗した時、lockファイルは残すべきか・・・
  fi
fi

# 前に進めてください。
$AWS autoscaling complete-lifecycle-action \
        --lifecycle-hook-name $AutoScalingHookName \
        --auto-scaling-group-name $AutoScalingGroupName \
        --lifecycle-action-token $LifecycleActionToken \
        --lifecycle-action-result CONTINUE

# 直前のコマンドが通らない時に進まない用
if [ $? -eq 0 ];then
  # ReceiptHandleは受信するごとに変わるので、1プロセス中に処理を完了させること
  $AWS sqs delete-message --queue-url $QUEUE_URL --receipt-handle $ReceiptHandle
  if [ $? -ne 0 ];then
    echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Failed to aws sqs delete-message'
    exit 1
  fi

  # Ansible当てました印
  $AWS ec2 create-tags --resources $EC2InstanceId --tags Key=AnsibleDeploy,Value=$NextStatus
else
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Failed to aws autoscaling complete-lifecycle-action'
  exit 1
fi

echo "playbook: ${AutoScalingHookName}.yml applied to $EC2InstanceId ($PrivateIp)"|bash ${TOOL_PATH}/bin/slack_notify.bash  -m "Success to Ansible playbook" -i ':ok_woman:'
rm $Lock_file
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Success'
