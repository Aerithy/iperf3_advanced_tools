# iperf3_advanced_tools

概要
- taskset：限制进程/线程在指定 CPU 上调度。只约束用户态与该进程的内核态执行，不会自动约束设备中断、软中断分发等其他内核活动。
- irqbalance：守护进程，周期性将硬件中断(IRQ)负载在多核间均衡，提高系统吞吐。会让网卡队列的 IRQ 分布到多个核心。
- iperf3：用户态生成/消费 TCP 流量。其 CPU 占用主要在用户态发送/解析与内核态的套接字收发路径。配合多队列网卡/NAPI/RPS/XPS，内核侧会动用多核。

一次 TCP 收发的内核路径与核心占用
1. 用户态发送/接收
   - iperf3 线程在被 taskset 指定的核心上运行。调用 send()/recv() 进入内核。
2. 内核态网络栈
   - 发送路径：协议栈处理、排队到网卡队列。软中断(ksoftirqd)可能在当前核心或其他核心执行。
   - 接收路径：网卡产生硬中断，NAPI 拉包。硬中断在对应 IRQ 的亲和核心上执行；随后软中断处理（协议栈、上送到套接字）在该核心或被迁移到 ksoftirqd 线程所在线程的核心上。
3. 多队列与负载分发
   - RSS（硬件 5-tuple hash）将不同流映射到不同网卡队列与 IRQ。
   - RPS/XPS（软件分发）在 /sys/class/net/<iface>/queues/*/rps_cpus/xps_cpus 将包处理分配到多个 CPU。
   - irqbalance 将不同 IRQ 的 smp_affinity 均衡到多核。
4. 其他后台
   - TCP 计时器、日志写入、内存回收、文件系统缓冲等辅助线程也会在非绑定核心占用。

结果现象
- 仅使用 taskset 绑定 iperf3 时：绑定核心满载，但其他核心也会显著占用（60–80%），来源为网卡 IRQ、软中断、RPS/XPS、ksoftirqd 等。
- 同时启用 irqbalance 时：IRQ 会被分散到多核，非绑定核心使用率更高、更均匀。
- 高速网卡/多队列：随着并发流与队列增加，内核处理更倾向多核扩展。

控制策略
- 让负载集中到指定核心：
  - 关闭 irqbalance：systemctl stop irqbalance（Linux）。
  - 设置 IRQ 亲和：echo <cpu_mask> > /proc/irq/<irq>/smp_affinity 为指定核心。
  - 限制 RPS/XPS：向 rps_cpus/xps_cpus 写入位掩码，仅包含指定核心。
  - 调整 RSS：ethtool -n <iface> rx-flow-hash tcp4，或减少硬件队列数。
  - 在 iperf3 侧用 taskset 绑定发送/接收线程。多进程/多线程时分别绑定。
- 让负载均衡以最大吞吐：
  - 保持 irqbalance 开启，启用多队列与 RPS/XPS，让内核与网卡充分利用多核。
  - iperf3 多实例分散绑定到不同核心。

观测与验证
- 进程与线程亲和：taskset -pc <pid>；ps -eLo pid,tid,psr,comm | grep iperf3。
- 中断分布：cat /proc/interrupts | grep -i <iface>。
- 软中断：cat /proc/softirqs；mpstat -I SUM -P ALL 1。
- RPS/XPS 掩码：cat /sys/class/net/<iface>/queues/rx-*/rps_cpus；xps_cpus。

结论
- taskset 只能约束进程调度，不约束网卡 IRQ 和网络栈的软中断。若需要“只让指定核心忙”，必须同时配置 IRQ 亲和与 RPS/XPS 掩码并关闭 irqbalance；若追求最大吞吐，允许 irqbalance/RSS/RPS/XPS 将负载分散到多核。