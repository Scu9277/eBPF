// SPDX-License-Identifier: GPL-2.0
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <linux/pkt_sched.h>
#include <stdbool.h>
#include <bpf/bpf_helpers.h>

// 配置参数
#define TPROXY_PORT 9420
#define TPROXY_MARK 0x2333
#define DOCKER_PORT 9277

// 简化的字节序转换函数
static inline __be32 my_htonl(__be32 x) {
    return (__be32)(((__u32)x >> 24) | ((__u32)x << 8) | ((__u32)x >> 8) | ((__u32)x << 24));
}

static inline __be16 my_htons(__be16 x) {
    return (__be16)(((__u8)x << 8) | (__u8)(x >> 8));
}

static inline __be16 my_ntohs(__be16 x) {
    return my_htons(x);
}

// 豁免的网络范围
struct exempt_net {
    __be32 addr;
    __u32 prefix_len;
};

// 豁免网络列表
struct exempt_net exempt_nets[] = {
    { .addr = my_htonl(0x0A000000), .prefix_len = 8 },   // 10.0.0.0/8
    { .addr = my_htonl(0xAC100000), .prefix_len = 12 },  // 172.16.0.0/12
    { .addr = my_htonl(0xC0A80000), .prefix_len = 16 },  // 192.168.0.0/16
    { .addr = my_htonl(0x7F000000), .prefix_len = 8 },   // 127.0.0.0/8
    { .addr = my_htonl(0xFFFFFFFF), .prefix_len = 32 },  // 255.255.255.255
};

// 检查 IP 是否在豁免网络中
static inline bool is_exempt(__be32 addr) {
    for (int i = 0; i < sizeof(exempt_nets) / sizeof(exempt_nets[0]); i++) {
        struct exempt_net *net = &exempt_nets[i];
        __be32 mask = my_htonl(~((1 << (32 - net->prefix_len)) - 1));
        if ((addr & mask) == net->addr) {
            return 1;
        }
    }
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
    __u32 eth_proto;
    __u32 ip_proto;
    __u16 dport;

    // 检查以太网头部
    if ((void *)eth + sizeof(*eth) > data_end) {
        return TC_ACT_OK;
    }

    eth_proto = eth->h_proto;
    if (eth_proto != my_htons(ETH_P_IP)) {
        return TC_ACT_OK;
    }

    // 检查 IP 头部
    ip = (void *)eth + sizeof(*eth);
    if ((void *)ip + sizeof(*ip) > data_end) {
        return TC_ACT_OK;
    }

    ip_proto = ip->protocol;

    // 检查是否在豁免网络
    if (is_exempt(ip->daddr)) {
        return TC_ACT_OK;
    }

    // 检查 TCP
    if (ip_proto == IPPROTO_TCP) {
        tcp = (void *)ip + sizeof(*ip);
        if ((void *)tcp + sizeof(*tcp) > data_end) {
            return TC_ACT_OK;
        }
        dport = my_ntohs(tcp->dest);
        
        // 豁免 Docker 端口
        if (dport == DOCKER_PORT) {
            return TC_ACT_OK;
        }
        
        // 设置 TProxy 标记并转发
        bpf_skb_set_mark(skb, TPROXY_MARK, 0);
        return bpf_redirect(TPROXY_PORT, 0);
    }
    // 检查 UDP
    else if (ip_proto == IPPROTO_UDP) {
        udp = (void *)ip + sizeof(*ip);
        if ((void *)udp + sizeof(*udp) > data_end) {
            return TC_ACT_OK;
        }
        dport = my_ntohs(udp->dest);
        
        // 豁免 Docker 端口
        if (dport == DOCKER_PORT) {
            return TC_ACT_OK;
        }
        
        // 拒绝 UDP 443（与原 iptables 规则一致）
        if (dport == 443) {
            return TC_ACT_SHOT;
        }
        
        // 设置 TProxy 标记并转发
        bpf_skb_set_mark(skb, TPROXY_MARK, 0);
        return bpf_redirect(TPROXY_PORT, 0);
    }
    
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
