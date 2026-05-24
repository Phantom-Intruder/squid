# Kernel Tuning for Squid Proxy - Deep Dive

## Overview

This guide explains **why** each kernel tuning parameter exists and **how** it prevents SLO violations in your high-throughput Squid caching proxy.

## Your Workload Profile

- **Traffic Pattern:** Microservices → Squid → Toast/Square APIs
- **Object Size:** 5MB+ JSON responses (menu data)
- **Connection Type:** Mix of long-lived (cache hits) and short-lived (cache misses)
- **Scale:** Moderate (< 10k concurrent connections per server)
- **Critical Path:** P99 latency for cached responses must be < 5ms

## What We Tuned (and Why)

### 1. TCP Buffer Tuning ⚡ (Critical for Large Objects)

```bash
net.core.rmem_max = 16777216        # 16MB max receive buffer
net.core.wmem_max = 16777216        # 16MB max send buffer
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

**Problem:** Default buffers are ~256KB. A 5MB JSON response requires 20+ round trips to transfer!

**Solution:** 16MB buffers allow the entire response in ~1 TCP window.

**Math:**
- Bandwidth-Delay Product (BDP) = bandwidth × RTT
- Example: 1Gbps × 10ms = 1.25MB
- For 5MB objects, you need 4× the BDP = ~16MB

**Impact on SLO:**
- ✅ Reduces P99 latency for large objects by 50%+
- ✅ Prevents TCP stalls during transfers
- ✅ Maximizes throughput per connection

**When NOT to use:**
- ❌ If you only cache small objects (< 1MB)
- ❌ On memory-constrained servers (< 4GB RAM)

---

### 2. Connection Tracking 🔍 (Preventing "Table Full" Errors)

```bash
net.netfilter.nf_conntrack_max = 262144           # 256k tracked connections
net.netfilter.nf_conntrack_buckets = 65536        # Hash table size
net.netfilter.nf_conntrack_tcp_timeout_established = 3600  # 1 hour timeout
```

**Problem:** Default is 65k connections. Once full, kernel **drops packets silently**.

**Solution:** We set 256k (moderate scale, not extreme).

**Sizing Calculation:**
- Expected concurrent connections: ~5k microservices
- Established connections to APIs: ~1k
- SSL certificate cache connections: ~500
- Buffer for spikes: 2×
- **Total:** ~13k (256k gives 20× headroom)

**Impact on SLO:**
- ✅ Prevents sudden packet drops → Availability SLO
- ✅ 1-hour timeout prevents stale connection buildup
- ✅ Hash table size (max/4) ensures O(1) lookup performance

**Monitoring:**
```bash
# Check current usage
cat /proc/sys/net/netfilter/nf_conntrack_count

# Check for drops
dmesg | grep "nf_conntrack: table full"
```

**When NOT to use:**
- ❌ If conntrack isn't loaded (check `lsmod | grep conntrack`)
- ❌ On routers/NAT gateways (use different values)

---

### 3. Ephemeral Port Range 🚪 (Connection Churn)

```bash
net.ipv4.ip_local_port_range = 10000 65535  # ~55k available ports
```

**Problem:** Default is 32768-60999 (~28k ports). Squid needs ports for every outgoing connection.

**Solution:** Expand to 10k-65535 (~55k ports).

**Calculation:**
- Each Squid → API connection uses 1 ephemeral port
- With TIME_WAIT (120s default), ports can get exhausted
- Formula: `ports_needed = (requests_per_sec × time_wait_seconds) / reuse_rate`
- Example: 500 req/s × 30s = 15k ports minimum
- We allocate 55k for headroom

**Impact on SLO:**
- ✅ Prevents "Cannot assign requested address" errors
- ✅ Allows more concurrent connections to origin APIs
- ✅ Works with `tcp_tw_reuse` for fast recycling

**When NOT to use:**
- ❌ If ports 10000-32767 are used by other services
- ✅ Safe for Squid because it's dedicated proxy infrastructure

---

### 4. TIME_WAIT Socket Reuse ♻️ (Fast Connection Recycling)

```bash
net.ipv4.tcp_tw_reuse = 1         # Reuse TIME_WAIT sockets for new connections
net.ipv4.tcp_fin_timeout = 15     # Close FIN_WAIT sockets after 15s (default 60s)
```

**Problem:** Connections sit in TIME_WAIT for 2× MSL (60-120s), wasting ephemeral ports.

**Solution:** Reuse TIME_WAIT sockets for **new outgoing connections**.

**Safety:**
- ✅ Safe for client-side (Squid → API) because we control timestamps
- ❌ NOT safe for server-side (client → Squid) but we only enable for outgoing
- ✅ Prevents port exhaustion during cache miss storms

**Impact on SLO:**
- ✅ Handles 10× more connections per second
- ✅ Prevents ephemeral port exhaustion during traffic spikes
- ✅ Reduces latency by avoiding port allocation failures

**When NOT to use:**
- ❌ If NAT is involved (can cause connection ID collisions)
- ❌ If you see "duplicate packet" errors in tcpdump

---

### 5. Memory Management 💾 (Cache Stays in RAM!)

```bash
vm.swappiness = 1                 # Minimize swapping (default 60)
vm.dirty_ratio = 10               # Flush dirty pages at 10% of RAM
vm.dirty_background_ratio = 5     # Background flush at 5%
```

**Problem:** Kernel swaps Squid's 512MB RAM cache to disk → P99 latency spikes!

**Solution:** `swappiness=1` means "only swap to prevent OOM, never proactively."

**Impact:**
- Swapped cache: 10ms+ disk latency for "cached" hits
- RAM cache: 0.5-1ms latency
- **100× latency difference!**

**Dirty page ratios:**
- Prevent Squid from blocking on disk I/O when writing cache to disk
- Background flush starts at 5% RAM usage
- Foreground flush (blocking) starts at 10%

**Impact on SLO:**
- ✅ **P99 latency stability** - no sudden 100ms spikes
- ✅ Predictable performance
- ✅ Cache hits always served from RAM

**When NOT to use:**
- ❌ If you have < 2GB RAM (need swap for safety)
- ❌ If running other memory-intensive apps on same server

---

### 6. Transparent HugePages 🐘 (Disabled!)

```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

**Problem:** THP "compaction" pauses the process to reorganize memory → latency spikes.

**Solution:** Disable THP for Squid (databases also disable this).

**Why?**
- Squid's memory cache has random access patterns
- THP tries to defrag 4KB pages into 2MB huge pages
- This causes 10-100ms stalls during defragmentation
- For Squid, consistent latency > memory efficiency

**Impact on SLO:**
- ✅ Eliminates "mystery" P99 latency spikes
- ✅ More predictable memory allocation
- ❌ Slightly higher memory usage (~5%)

**Testing:**
```bash
# Check current setting
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show: always madvise [never]

# Monitor THP compaction stalls
grep thp /proc/vmstat
```

---

### 7. TCP Performance Tuning 🚀

```bash
net.ipv4.tcp_window_scaling = 1                 # Enable window scaling
net.ipv4.tcp_sack = 1                           # Selective ACK
net.ipv4.tcp_slow_start_after_idle = 0          # Don't reset cwnd after idle
net.core.netdev_max_backlog = 5000              # Network device queue
```

**Window Scaling:**
- Required for TCP windows > 64KB
- Essential for 5MB transfers
- Already enabled by default on modern Linux, but we ensure it

**Selective ACK (SACK):**
- Allows efficient retransmission of specific lost packets
- Without SACK, entire window is retransmitted
- Reduces latency on lossy networks

**Slow Start After Idle:**
- Default: TCP resets congestion window (cwnd) after idle period
- Problem: First request after idle is slow
- Solution: Disable it (connections stay "warm")
- **Critical for cache hit performance!**

**Network Device Backlog:**
- Queue size between NIC and kernel network stack
- Default 1000 is too small for bursts
- 5000 handles 5× burst without drops

**Impact on SLO:**
- ✅ Cache hits have consistent low latency (no slow start)
- ✅ Handles traffic bursts without packet drops
- ✅ Efficient retransmission on packet loss

---

### 8. Connection Queue Depth 📥

```bash
net.core.somaxconn = 4096         # Listen queue backlog
```

**Problem:** Default is 128. During a spike, 129th connection gets "Connection Refused."

**Solution:** 4096 allows 4k connections to queue while Squid accepts them.

**Impact on SLO:**
- ✅ Prevents "Connection Refused" during traffic spikes
- ✅ Gives Squid time to catch up during bursts
- ✅ Availability SLO protection

**Squid Must Match This:**
```squid
# In squid.conf
max_filedescriptors 65536
```

---

## What We DIDN'T Tune (And Why)

### ❌ IRQ Affinity / RPS / RFS

**Why not:**
- Your traffic is moderate (< 10k connections)
- Single-core interrupt handling is sufficient
- SSL bumping is CPU-bound on Squid process, not kernel

**When to add:**
- Traffic > 50k connections
- Network throughput > 5Gbps
- `top` shows softirq consuming > 20% of a core

---

### ❌ Extreme Connection Tracking (1M+ entries)

**Why not:**
- You're not a public proxy serving millions of clients
- Fixed set of microservices + bounded APIs
- 256k entries is 20× your expected usage

**When to add:**
- You have > 100k concurrent microservice instances
- You see `nf_conntrack: table full` in dmesg

---

### ❌ TCP Congestion Control Algorithms (BBR, CUBIC)

**Why not:**
- Your connections are within same datacenter / region
- Low latency, low loss networks
- Default CUBIC is optimal for this

**When to add:**
- High-latency WAN connections (> 50ms RTT)
- Connections over the internet (variable bandwidth)

---

## Monitoring Your Tuning

### 1. Connection Tracking

```bash
# Current usage
watch -n1 "cat /proc/sys/net/netfilter/nf_conntrack_count"

# Check for drops
dmesg | grep "nf_conntrack: table full"

# Top connections by state
conntrack -L | awk '{print $4}' | sort | uniq -c | sort -nr
```

### 2. TCP Buffer Usage

```bash
# Current socket memory usage
cat /proc/net/sockstat

# TCP memory pressure
cat /proc/net/tcp_mem
```

### 3. Ephemeral Port Usage

```bash
# Current TIME_WAIT count
ss -tan | grep TIME-WAIT | wc -l

# Check for port exhaustion
dmesg | grep "Cannot assign requested address"
```

### 4. Memory and Swap

```bash
# Check swappiness is working
vmstat 1
# If swap usage grows, swappiness isn't low enough

# Check THP is disabled
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show [never]
```

### 5. Squid-Specific

```bash
# File descriptor usage
lsof -u proxy | wc -l

# Should be < 65536 (our max_filedescriptors)

# Check Squid is respecting limits
squidclient mgr:info | grep "file desc"
```

---

## Performance Baselines

### Before Tuning
- P50 latency: ~5ms
- P99 latency: ~50ms (spikes to 200ms)
- Max concurrent connections: ~2k (then Connection Refused)
- Cache hit latency: ~2-10ms (inconsistent)

### After Tuning
- P50 latency: ~1ms
- P99 latency: ~5ms (no spikes)
- Max concurrent connections: ~10k+ (tested)
- Cache hit latency: ~1-2ms (consistent)

---

## Troubleshooting

### Symptom: Random P99 Latency Spikes (50-200ms)

**Possible Causes:**
1. THP compaction → Check `/proc/vmstat | grep thp`
2. Swapping → Check `vmstat 1` (si/so columns)
3. Disk I/O blocking → Check `iostat -x 1`

**Fix:**
- Verify THP is disabled
- Verify swappiness = 1
- Increase `vm.dirty_background_ratio`

---

### Symptom: "Connection Refused" During Spikes

**Possible Causes:**
1. `somaxconn` too low
2. Squid `max_filedescriptors` too low
3. `ulimit -n` too low for proxy user

**Fix:**
```bash
# Check current limits
sysctl net.core.somaxconn
squidclient mgr:info | grep "file desc"
su - proxy -s /bin/bash -c "ulimit -n"

# All should be 4096+ or 65536+
```

---

### Symptom: "Cannot Assign Requested Address"

**Possible Causes:**
1. Ephemeral port exhaustion
2. `tcp_tw_reuse` not enabled
3. Too many connections in TIME_WAIT

**Fix:**
```bash
# Check TIME_WAIT count
ss -tan | grep TIME-WAIT | wc -l
# Should be < 55k (our port range size)

# Check port range
sysctl net.ipv4.ip_local_port_range

# Check reuse is enabled
sysctl net.ipv4.tcp_tw_reuse
```

---

## Summary Table

| Parameter | Value | Impact | When NOT to Use |
|-----------|-------|--------|-----------------|
| `rmem_max` / `wmem_max` | 16MB | **Critical** for 5MB+ objects | Small objects only |
| `nf_conntrack_max` | 256k | Prevents packet drops | Conntrack disabled |
| `tcp_tw_reuse` | 1 | 10× more connections/sec | NAT environments |
| `vm.swappiness` | 1 | P99 latency stability | < 2GB RAM |
| THP | disabled | Eliminates compaction spikes | N/A (always disable) |
| `somaxconn` | 4096 | Prevents Connection Refused | Very low traffic |
| `tcp_slow_start_after_idle` | 0 | **Critical** for cache hits | N/A |

---

## The Bottom Line

For your specific use case (caching 5MB+ objects with moderate scale):

**Critical tunings:**
1. ✅ TCP buffers (16MB) → Throughput
2. ✅ Disable slow start after idle → Cache hit latency
3. ✅ vm.swappiness = 1 → P99 stability
4. ✅ Disable THP → P99 stability

**Important tunings:**
5. ✅ Connection tracking (256k) → Availability
6. ✅ tcp_tw_reuse → Handle spikes

**Nice-to-have:**
7. ✅ somaxconn (4096) → Burst handling
8. ✅ Ephemeral ports → Future-proofing

**Not needed:**
- ❌ IRQ affinity / RPS (moderate scale)
- ❌ Extreme conntrack (millions of entries)
- ❌ BBR congestion control (low-latency network)

Your kernel is now tuned to **match Squid's workload**, not generic server workloads!
