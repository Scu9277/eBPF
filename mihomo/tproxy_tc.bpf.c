// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// 配置参数
#define TPROXY_PORT 9420
#define TPROXY_MARK 0x2333
#define DOCKER_PORT 9277

// 检查 IP 是否在豁免网络中
static __always_inline int is_exempt(__be32 addr) {
    // 127.0.0.0/8
    if ((addr & bpf_htonl(0xFF000000)) == bpf_htonl(0x7F000000)) return 1;
    // 10.0.0.0/8
    if ((addr & bpf_htonl(0xFF000000)) == bpf_htonl(0x0A000000)) return 1;
    // 172.16.0.0/12
    if ((addr & bpf_htonl(0xFFF00000)) == bpf_htonl(0xAC100000)) return 1;
    // 192.168.0.0/16
    if ((addr & bpf_htonl(0xFFFF0000)) == bpf_htonl(0xC0A80000)) return 1;
    // 255.255.255.255 (Broadcast)
    if (addr == bpf_htonl(0xFFFFFFFF)) return 1;
    
    return 0;
}

SEC("classifier")
int tproxy_tc_handler(struct __sk_buff *skb) {
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip;
    struct tcphdr *tcp;
    struct udphdr *udp;
    __u16 eth_proto;
    __u8 ip_proto;
    __u16 dport;
    struct bpf_sock_tuple tuple = {};
    int tuple_len = 0;
    struct bpf_sock *sk = NULL;
    long ret;

    // 检查以太网头部
    if ((void *)eth + sizeof(*eth) > data_end) {
        return TC_ACT_OK;
    }

    eth_proto = eth->h_proto;
    if (eth_proto != bpf_htons(ETH_P_IP)) {
        return TC_ACT_OK;
    }

    // 检查 IP 头部
    ip = (void *)eth + sizeof(*eth);
    if ((void *)ip + sizeof(*ip) > data_end) {
        return TC_ACT_OK;
    }

    // 检查是否在豁免网络
    if (is_exempt(ip->daddr)) {
        return TC_ACT_OK;
    }

    ip_proto = ip->protocol;

    // 处理 TCP
    if (ip_proto == IPPROTO_TCP) {
        int ip_hlen = ip->ihl * 4;
        tcp = (void *)ip + ip_hlen;
        if ((void *)tcp + sizeof(*tcp) > data_end) {
            return TC_ACT_OK;
        }
        
        dport = bpf_ntohs(tcp->dest);
        
        // 豁免 Docker 端口
        if (dport == DOCKER_PORT) {
            return TC_ACT_OK;
        }
        
        // 构建 socket tuple
        tuple.ipv4.saddr = ip->saddr;
        tuple.ipv4.sport = tcp->source;
        tuple.ipv4.daddr = ip->daddr;
        tuple.ipv4.dport = tcp->dest;
        tuple_len = sizeof(tuple.ipv4);
        
        // 查找监听在 TProxy 端口的 socket
        struct bpf_sock_tuple listener_tuple = {};
        listener_tuple.ipv4.daddr = bpf_htonl(INADDR_ANY);
        listener_tuple.ipv4.dport = bpf_htons(TPROXY_PORT);
        
        sk = bpf_skc_lookup_tcp(skb, &listener_tuple, tuple_len, BPF_F_CURRENT_NETNS, 0);
        if (sk) {
            ret = bpf_sk_assign(skb, sk, 0);
            bpf_sk_release(sk);
            if (ret == 0) {
                skb->mark = TPROXY_MARK;
                return TC_ACT_OK;
            }
        }
    }
    // 处理 UDP
    else if (ip_proto == IPPROTO_UDP) {
        int ip_hlen = ip->ihl * 4;
        udp = (void *)ip + ip_hlen;
        if ((void *)udp + sizeof(*udp) > data_end) {
            return TC_ACT_OK;
        }
        
        dport = bpf_ntohs(udp->dest);
        
        // 豁免 Docker 端口
        if (dport == DOCKER_PORT) {
            return TC_ACT_OK;
        }
        
        // 拒绝 UDP 443（与原 iptables 规则一致）
        if (dport == 443) {
            return TC_ACT_SHOT;
        }
        
        // 构建 socket tuple
        tuple.ipv4.saddr = ip->saddr;
        tuple.ipv4.sport = udp->source;
        tuple.ipv4.daddr = ip->daddr;
        tuple.ipv4.dport = udp->dest;
        tuple_len = sizeof(tuple.ipv4);
        
        // 查找监听在 TProxy 端口的 socket
        struct bpf_sock_tuple listener_tuple = {};
        listener_tuple.ipv4.daddr = bpf_htonl(INADDR_ANY);
        listener_tuple.ipv4.dport = bpf_htons(TPROXY_PORT);
        
        sk = bpf_sk_lookup_udp(skb, &listener_tuple, tuple_len, BPF_F_CURRENT_NETNS, 0);
        if (sk) {
            ret = bpf_sk_assign(skb, sk, 0);
            bpf_sk_release(sk);
            if (ret == 0) {
                skb->mark = TPROXY_MARK;
                return TC_ACT_OK;
            }
        }
    }
    
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
