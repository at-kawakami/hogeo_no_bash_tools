#!/bin/bash
# source: https://dev.classmethod.jp/cloud/aws/using-ansible-at-autoscaling-launching/
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']' Start
Lock_file="/tmp/hook_sqs_autoscaling.lock"
if [ -f $Lock_file ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: lock file has found, not start this script'
  exit 0
fi

touch $Lock_file

# Command path
AWS="/usr/local/bin/aws"
JQ="/usr/local/bin/jq"

# variable
QUEUE_URL="https://sqs.ap-northeast-1.amazonaws.com/xxxxxxxxxxxx/ansible-auto-scaling-queue"
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
 
State=`$AWS ec2 monitor-instances --instance-ids $EC2InstanceId | $JQ -r '.InstanceMonitorings[].Monitoring.State'`
EC2Info=`$AWS ec2 describe-instances --instance-ids $EC2InstanceId`
PrivateIp="`$AWS ec2 describe-instances --instance-ids $EC2InstanceId | $JQ -r '.Reservations[].Instances[].PrivateIpAddress'`"
NextStatus="deployed_`date "+%Y%m%d%H%M%S"`"

if [ "$State" != "enabled" ]; then
  rm $Lock_file
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Not enabled instace (retry latter).'
  exit 0
fi

echo "[$AutoScalingGroupName]" > hosts_$EC2InstanceId
echo "$hosts_$EC2InstanceId  ansible_ssh_host=$PrivateIp ansible_python_interpreter=/usr/bin/python3 db_migrate=True" >> hosts_$EC2InstanceId
echo "setup instance: $EC2InstanceId ($PrivateIp)"

if [ `echo $AutoScalingHookName | grep terminate` ];then
  NextStatus="Shutdown"
fi

echo "receive queue from SQS. $EC2InstanceId ($PrivateIp) has $AutoScalingHookName"|bash -x /home/ubuntu/tools/bin/slack_notify.bash  -m "Start to Ansible playbook" -i ':man-raising-hand: '

cd ansible_repos
ansible-playbook -i ../hosts_${EC2InstanceId} --private-key=~/.ssh/hoge_key ${AutoScalingHookName}.yml --vault-password-file ~/.vault_password -v
if [ $? -ne 0 ];then
  echo '[' `date "+%Y/%m/%d:%H:%M:%S"` ']'Fatal: Failed to execute ansible
  echo "Failed: Ansible deploy: $AutoScalingHookName $EC2InstanceId ($PrivateIp)"|bash -x /home/ubuntu/tools/bin/slack_notify.bash  -m 'Oops!' -i ':male_zombie:'
  exit 1
  # Todo: 失敗した時、lockファイルは残すべきか・・・
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

echo "playbook: ${AutoScalingHookName}.yml applied to $EC2InstanceId ($PrivateIp)"|bash -x /home/ubuntu/tools/bin/slack_notify.bash  -m "Success to Ansible playbook" -i ':man-gesturing-ok:'
rm $Lock_file
echo '[' `date "+%Y/%m/%d:%H:%M:%S"` '] End: Success'
