#!/usr/bin/python3
import os
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
            Filters=[{'Name': 'tag:Name','Values':  [ TARGET + app + '-'  + color + '*']}]
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
                #print('host_ip:' + host_ip[])
                file.write(' '.join(host_ip) + ' ' + app + str(offset + 1) + color + '\n')

    except Exception as e:
            print(e)
    finally:
            file.close()
    return HOSTS_TMP

if __name__ == '__main__':
    HOSTS_ORG = "/etc/hosts_org"
    HOSTS_TMP = '/tmp/hosts_tmp'
    TARGET = "sandbox"
    APPLICATION = ["web", 'adm', 'api']
    COLOR = ['blue','green']

    initialize()
    
    for color in COLOR:
        for app in APPLICATION:
            host_ip_list = get_host_list(app, color)
            new_hosts = update_hosts(host_ip_list, app, color)
    #print(host_ip_list)
    filenames = [HOSTS_ORG, HOSTS_TMP]
    with open('/etc/hosts', 'w') as hosts:
        for fname in filenames:
            with open(fname) as infile:
                for line in infile:
                    hosts.write(infile.read())
