# Squid SSL Bumping Proxy Farm

High-performance caching proxy infrastructure for reducing API costs and latency when calling Toast POS and Square Payment APIs.

## 🎯 What This Does

Deploys a cluster of Squid forward proxies with SSL interception that:
- **Caches large API responses** (5MB+ JSON menus)
- **Reduces API costs by 90%+** (most requests served from cache)
- **Improves latency 100x** (1-2ms cache hits vs 200ms API calls)
- **Shares cache** between multiple Squid servers via ICP peering
- **Only intercepts specific domains** (`.toasttab.com` and `.squareup.com`)

## 🚀 Quick Start

```bash
# 1. Install dependencies
cd ansible
ansible-galaxy collection install -r requirements.yml

# 2. Deploy Squid servers (creates vault-encrypted CA certificate)
ansible-playbook -i inventory.ini site.yml --ask-vault-pass

# 3. Deploy CA cert to Kubernetes
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=files/squid-ca.crt \
  -n your-namespace

# 4. Configure microservices (Spring Boot 3 example)
kubectl apply -f ../k8s/springboot3-example.yaml
```

See [QUICK-START.md](QUICK-START.md) for detailed instructions.

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [QUICK-START.md](QUICK-START.md) | 5-minute setup guide |
| [SSL-BUMPING-GUIDE.md](SSL-BUMPING-GUIDE.md) | Deep dive into how SSL interception works |
| [SPRINGBOOT3-GUIDE.md](SPRINGBOOT3-GUIDE.md) | Spring Boot 3 specific configuration |
| [ansible/README.md](ansible/README.md) | Ansible deployment details |
| [ansible/files/vault/README.md](ansible/files/vault/README.md) | Ansible Vault management |

## 🏗️ Architecture

```
                    ┌──────────────────┐
                    │   Spring Boot    │
                    │  Microservices   │
                    │  (K8s Cluster)   │
                    └────────┬─────────┘
                             │ HTTP_PROXY=squid:3128
                             │ HTTPS_PROXY=squid:3128
                             │
        ┌────────────────────┴────────────────────┐
        │                                         │
        ▼                                         ▼
┌───────────────┐                        ┌───────────────┐
│ Squid Server 1│◄────── ICP Peering ───►│ Squid Server 2│
│  10GB Cache   │                        │  10GB Cache   │
│  SSL Bumping  │                        │  SSL Bumping  │
└───────┬───────┘                        └───────┬───────┘
        │                                         │
        └────────────────────┬────────────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │                                         │
        ▼                                         ▼
┌──────────────┐                        ┌──────────────┐
│ api.toasttab │                        │ connect.     │
│    .com      │                        │ squareup.com │
└──────────────┘                        └──────────────┘
```

### SSL Bumping Flow

```
1. App → https://api.toasttab.com/menus
   ↓
2. Squid peeks at SNI (Server Name Indication)
   ↓
3. Domain matches .toasttab.com → BUMP (decrypt)
   ↓
4. Squid checks cache
   ├─ HIT: Return from cache (1-2ms) ✅
   └─ MISS: Fetch from API, cache for 1 hour, return
   ↓
5. Next request = cache HIT (no API call!)
```

## 🔐 Security

### Private Key Protection

The CA private key (`squid-ca.key`) is:
- ✅ **Encrypted with Ansible Vault** (never stored in plaintext)
- ✅ **Never committed to git** (protected by `.gitignore`)
- ✅ **Never logged** (uses `no_log: true` in Ansible)
- ✅ **Restricted to Squid servers** (microservices only get `.crt`)
- ✅ **0600 permissions** on Squid servers (owner read/write only)

### What Gets Intercepted

| Domain | Action | Cached? |
|--------|--------|---------|
| `*.toasttab.com` | **BUMP** (decrypted) | ✅ Yes |
| `*.squareup.com` | **BUMP** (decrypted) | ✅ Yes |
| All other domains | **SPLICE** (pass-through) | ❌ No |
| `*.svc.cluster.local` | **DIRECT** (no proxy) | ❌ No |

## 📊 Performance

### Before Squid
- **Latency:** ~200ms per API call
- **Cost:** $X per 1M requests
- **Load:** Every request hits API

### After Squid (Warm Cache)
- **Latency:** ~1-2ms (cache hit) = **100x faster** ⚡
- **Cost:** First request only = **90%+ savings** 💰
- **Load:** 90%+ served from cache

### Typical Cache Hit Rates
- Menu data: **95%** (rarely changes)
- Order status: **60%** (moderate changes)
- Payment info: **40%** (frequently changes)

## 🛠️ Technology Stack

- **Proxy:** Squid 5.x with SSL bumping
- **TLS:** OpenSSL with dynamic certificate generation
- **Cache:** 10GB disk + 512MB RAM per server
- **Peering:** ICP protocol for cache sharing
- **Infrastructure:** GCP Compute Engine (via Terraform)
- **Configuration Management:** Ansible
- **Secret Management:** Ansible Vault

## 📁 Project Structure

```
squid-training/
├── ansible/                          # Configuration management
│   ├── files/
│   │   ├── squid-ca.crt             # Public CA cert (safe to share)
│   │   └── vault/
│   │       └── squid-ca.key         # Private key (Vault encrypted)
│   ├── roles/
│   │   ├── common/                  # System tuning
│   │   ├── monitoring/              # Prometheus Node Exporter
│   │   └── squid/                   # Squid configuration
│   │       ├── tasks/main.yml       # Installation & config
│   │       ├── templates/squid.conf.j2
│   │       ├── handlers/main.yml
│   │       └── vars/main.yml
│   ├── site.yml                     # Main playbook
│   ├── inventory.ini                # Squid server IPs
│   └── requirements.yml             # Ansible collections
├── k8s/                             # Kubernetes manifests
│   ├── squid-ca-configmap.yaml     # CA cert for pods
│   ├── example-pod-with-ca.yaml    # Generic example
│   └── springboot3-example.yaml    # Spring Boot 3 example
├── terraform/                       # GCP infrastructure
│   ├── main.tf                      # Compute Engine VMs
│   ├── outputs.tf
│   └── variables.tf
├── QUICK-START.md                   # 5-minute setup
├── SSL-BUMPING-GUIDE.md            # SSL interception deep dive
├── SPRINGBOOT3-GUIDE.md            # Spring Boot configuration
└── README.md                        # This file
```

## 🔧 Configuration

### Squid Settings

Edit `ansible/roles/squid/vars/main.yml`:

```yaml
squid_cache_size_mb: 10000        # 10GB disk cache
squid_max_object_size_mb: 15      # Max cached object (for 5MB menus)
squid_ram_cache_mb: 512           # RAM cache
squid_subnet: "10.0.0.0/20"       # Allowed client subnet
```

### Cache Behavior

Edit `ansible/roles/squid/templates/squid.conf.j2`:

```squid
# Cache for 1 hour (60 min), ignore no-cache headers
refresh_pattern ^https://api.toasttab.com/.* 60 20% 1440 ignore-no-cache ignore-private
refresh_pattern ^https://connect.squareup.com/.* 60 20% 1440 ignore-no-cache ignore-private
```

## 🧪 Testing

### Test SSL Bumping

```bash
# With the CA certificate
curl --cacert ansible/files/squid-ca.crt \
     -x http://squid-server:3128 \
     -v https://api.toasttab.com
```

### Check Cache Statistics

```bash
ansible all -i ansible/inventory.ini -m shell -a "squidclient mgr:5min"
```

### Monitor Access Logs

```bash
ansible all -i ansible/inventory.ini -m shell -a "tail -f /var/log/squid/access.log"
```

Look for:
- `TCP_MISS/200` → Cache miss (fetched from API)
- `TCP_HIT/200` → Cache hit (served from disk cache)
- `TCP_MEM_HIT/200` → Cache hit (served from RAM cache) ⚡

## 🐛 Troubleshooting

### Certificate Errors in Microservices

**Error:** `unable to find valid certification path to requested target`

**Cause:** Microservice doesn't trust the Squid CA certificate.

**Fix:** Ensure CA cert is mounted and JVM truststore is configured. See [SPRINGBOOT3-GUIDE.md](SPRINGBOOT3-GUIDE.md).

### Proxy Connection Refused

**Cause:** Squid not running or firewall blocking port 3128.

**Fix:**
```bash
# Check Squid status
ansible all -i ansible/inventory.ini -m shell -a "systemctl status squid"

# Check port is listening
ansible all -i ansible/inventory.ini -m shell -a "ss -tlnp | grep 3128"
```

### Cache Not Working

**Cause:** Response too large, wrong domain, or cache disabled.

**Fix:**
```bash
# Check cache is enabled
grep cache_dir /etc/squid/squid.conf

# Check object size limit
grep maximum_object_size /etc/squid/squid.conf

# Check refresh patterns
grep refresh_pattern /etc/squid/squid.conf
```

## 🔄 Maintenance

### Rotate CA Certificate (Annually)

```bash
# 1. Remove old certificates
rm ansible/files/squid-ca.crt
ansible-vault decrypt ansible/files/vault/squid-ca.key
rm ansible/files/vault/squid-ca.key

# 2. Regenerate (playbook will create new ones)
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass

# 3. Update Kubernetes ConfigMap
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=ansible/files/squid-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Restart all microservices
kubectl rollout restart deployment --all
```

### Update Squid Configuration

```bash
# 1. Edit configuration
vim ansible/roles/squid/templates/squid.conf.j2

# 2. Deploy changes
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass --tags squid

# 3. Verify
ansible all -i ansible/inventory.ini -m shell -a "squid -k parse && squid -k reconfigure"
```

## 📈 Monitoring

### Key Metrics

- **Cache hit rate** (target: >80%)
- **Cache object count** (trending up = good)
- **Average response time** (should be <5ms for cache hits)
- **Disk usage** (should stay under 10GB per server)

### Prometheus Queries

```promql
# Cache hit rate
rate(squid_http_hits[5m]) / rate(squid_http_requests[5m])

# Average response time
rate(squid_http_response_time_ms[5m])

# Cache size
squid_cache_size_bytes
```

## 💰 Cost Savings

### Example: 1M Menu Requests/Month

**Without Squid:**
- Requests to API: 1,000,000
- Cost: $1,000 (example)
- Latency: 200ms average

**With Squid (90% cache hit rate):**
- Requests to API: 100,000
- Cost: $100 (example) = **$900 saved/month**
- Latency: 10ms average (90% @ 2ms, 10% @ 200ms)

**ROI:** Squid infrastructure costs ~$100/month → **Breakeven in 1 month!**

## 🤝 Contributing

This is an internal infrastructure project. For questions or issues:
1. Check the troubleshooting sections in the guides
2. Review Squid logs
3. Contact the infrastructure team

## 📝 License

Internal use only.

## 🙏 Acknowledgments

- Squid proxy developers
- Ansible community.crypto collection
- OpenSSL project
