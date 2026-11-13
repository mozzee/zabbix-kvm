# zabbix-kvm
A single installation script that you can run on each RHEL, Rocky Linux, or AlmaLinux KVM host. It will automatically discover all libvirt VMs and expose their resource metrics to your existing Zabbix 7.4 agent.

# What will be monitored
1. VM name, UUID and running state
2. Allocated vCPUs and RAM
3. CPU utilization
4. Host-resident VM memory
5. Guest memory utilization	When balloon statistics are available
6. Disk read/write throughput
7. Network incoming/outgoing throughput
8. Powered-off VMs	Discovered for state monitoring
