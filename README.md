# hogeo_no_bash_tools

### ansible_hosts_creator.bash
/etc/hostsから特定のホスト名を引っこ抜いて、ansible用のhostsを標準出力する。
```
$ cat /etc/hosts
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
172.xx.xxx.227 i-0xxxxxxxxxxxxxxx5 adm1blue
172.xx.xxx.187 i-0xxxxxxxxxxxxxxxd adm2blue
172.xx.xxx.201 i-0xxxxxxxxxxxxxxxd api1blue
172.xx.xxx.167 i-0xxxxxxxxxxxxxxx3 api2blue
172.xx.xxx.143 i-0xxxxxxxxxxxxxxx6 batch1blue
172.xx.xxx.204 i-0xxxxxxxxxxxxxxx7 web1green
172.xx.xxx.133 i-0xxxxxxxxxxxxxxx0 web2green
```


```
$ /path/to/bin/ansible_hosts_creator.bash web 
[web]
i-0xxxxxxxxxxxxxxx7 ansible_ssh_host=172.xx.xxx.204 ansible_python=/usr/bin/python3 db_migrate=True ansible_ssh_user=ubuntu
i-0xxxxxxxxxxxxxxx0 ansible_ssh_host=172.xx.xxx.133 ansible_python=/usr/bin/python3 db_migrate=False ansible_ssh_user=ubuntu
```
