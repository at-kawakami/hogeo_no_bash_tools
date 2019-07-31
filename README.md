# hogeo_no_bash_tools
### ansible_hosts_creator.bash
/etc/hostsからansibleのinventory hostsを作成するツール

```
$ cat /etc/hosts
127.0.0.1 localhost
172.23.102.xxx web1g
172.23.102.xxx web2g
172.23.102.xxx adm1b
172.23.102.xxx adm2b
172.23.102.xxx api1b
172.23.102.xxx api2b
```

出来上がりイメージ
```
$ cat ansible_hosts 
[web]
web1g ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
web2g ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
[adm]
adm1b ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
adm2b ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
[api]
api1b ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
api2b ansible_ssh_host=172.23.102.xxx ansible_python=/usr/bin/python3 ansible_ssh_user=ubuntu
```
