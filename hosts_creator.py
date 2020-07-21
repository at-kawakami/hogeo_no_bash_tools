#!/usr/bin/python3
import os
import sys
import boto3
import subprocess

def initialize():
    if os.path.exists(HOSTS_ORG):
        print('/etc/hosts_org exist')
    else:
        print('/etc/hosts_org does not exist')
        subprocess.call(["sudo", "cp", "-p", "/etc/hosts", "/etc/hosts_org"])

    if os.path.exists(HOSTS_TMP):
        print(HOSTS_TMP + 'exists, remove it to initialize')
        os.remove(HOSTS_TMP)
    else:
        print(HOSTS_TMP + 'does not exists')
    return

def get_host_list(app, color):
    client = boto3.client('ec2')
    res = client.describe_instances(
            Filters=[{'Name': 'tag:Name','Values':  [ target + app + '-' + color + '*']}]
            )
    host_ip_list = []
    for reservation in res['Reservations']:
        for instance in reservation['Instances']:
            #print(instance['State']['Name'])
            # terminatedやpendingは取得しない
            if instance['State']['Name'] != 'running':
                continue
            #print(instance['State']['Name'])
            host_ip_list.append([instance['PrivateIpAddress'],instance['InstanceId']])

    return host_ip_list

def update_hosts(host_ip_list, app, color):
    try:
            file = open(HOSTS_TMP, 'a')
            for (offset, host_ip) in enumerate(host_ip_list):
                file.write(' '.join(host_ip) + ' ' + target + app + str(offset + 1) + color + '\n')

    except Exception as e:
            print(e)
    finally:
            file.close()
    return HOSTS_TMP

def get_instance_info_not_blue_green(ope):
    client = boto3.client('ec2')
    # Tags抽出用
    ec2 = boto3.resource('ec2')

    res = client.describe_instances(
            Filters=[{'Name': 'tag:Name','Values':  [ target + ope + '*']}]
            )
    host_ip_list_not_bg = []
    for reservation in res['Reservations']:
        for instance in reservation['Instances']:
            #print(instance['State']['Name'])
            # terminatedやpendingは取得しない
            if instance['State']['Name'] != 'running':
                continue
            # Name Tag抽出
            instance_info = ec2.Instance(instance['InstanceId'])
            #print(instance)
            name_tag = [x['Value'] for x in instance_info.tags if x['Key'] == 'Name']
            name = name_tag[0] if len(name_tag) else ''
            # append
            host_ip_list_not_bg.append([instance['PrivateIpAddress'],instance['InstanceId'],name])
            print(host_ip_list_not_bg)
    try:
            file = open(HOSTS_TMP, 'a')
            for (offset, host_info) in enumerate(host_ip_list_not_bg):
                file.write(' '.join(host_info) + '\n')

    except Exception as e:
            print(e)
    finally:
            file.close()

    return 


if __name__ == '__main__':
    TARGETS = sys.argv

    HOSTS_ORG = "/etc/hosts_org"
    HOSTS_TMP = '/tmp/hosts_tmp'
    #TARGET = args[1]
    APPLICATION = ["web", 'adm', 'api', 'batch']
    OPERATION = ['proxy', 'util', 'opt']
    COLOR = ['blue','green']

    initialize()
    for target in TARGETS:
        # proxy, utilサーバなど、ブルーグリーン構成でないサーバたちの情報を取得する
        for ope in OPERATION:
            get_instance_info_not_blue_green(ope)
        for color in COLOR:
            for app in APPLICATION:
                host_ip_list = get_host_list(app, color)
                new_hosts = update_hosts(host_ip_list, app, color)
    #print(host_ip_list)
    filenames = [HOSTS_ORG, HOSTS_TMP]
    with open('/etc/hosts', 'w') as hosts:
        for fname in filenames:
            with open(fname) as infile:
                hosts.write(infile.read())
