#!/bin/bash

# Disable IRQ balancing
echo "Disabling IRQ balancing..."
systemctl stop irqbalance.service && systemctl disable irqbalance.service

# 绑网卡中断
# irq1=$(awk '/eth0|eth1/ {print $1}' /proc/interrupts | sed 's/://g')
irq1=$(awk '/eth03/ {print $1}' /proc/interrupts | sed 's/://g')
c=0
n_cpu=0
 
for irq in $irq1
do
    cpu=$(cat /proc/irq/$irq/smp_affinity_list)
    echo "[原] $irq -> $cpu"
 
    echo $n_cpu > /proc/irq/$irq/smp_affinity_list
    cpu=$(cat /proc/irq/$irq/smp_affinity_list)
    echo "[新] $irq -> $cpu"
 
    ((n_cpu++))
    if (( n_cpu >= 64 )); then
        n_cpu=0
    fi
done