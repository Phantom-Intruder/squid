# Squid SSL Bumping Proxy - Quick Start

Complete setup guide for deploying Squid proxy with SSL interception for caching Toast/Square API responses.

## 📋 Prerequisites

- Ansible 2.12+
- GCP project with Compute Engine VMs
- Kubernetes cluster for microservices
- kubectl configured

## 🚀 5-Minute Setup

### Step 1: Install Ansible Dependencies

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### Step 2: Deploy Squid Servers

```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

**First time:** You'll create a vault password for the CA private key. **Save it securely!**

This will:
- Generate CA certificate (encrypted with Ansible Vault)
- Deploy Squid proxy to all servers
- Configure SSL bumping for `.toasttab.com` and `.squareup.com`
- Set up ICP peering between servers for cache sharing

### Step 3: Deploy CA Certificate to Kubernetes

```bash
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=ansible/files/squid-ca.crt \
  -n your-namespace
```

### Step 4: Configure Microservices

**For Spring Boot 3 applications:**
```bash
kubectl apply -f k8s/springboot3-example.yaml
```

**For other applications:**
```bash
kubectl apply -f k8s/example-pod-with-ca.yaml
```

### Step 5: Verify

```bash
# Check Squid is running
ansible all -i ansible/inventory.ini -m shell -a "systemctl status squid"

# Check pod can reach proxy
kubectl exec -it deployment/your-app -- nc -zv squid-proxy 3128

# Test API call through proxy
kubectl exec -it deployment/your-app -- \
  curl -v https://api.toasttab.com/some-endpoint
```

## 📁 Project Structure

```
squid-training/
├── ansible/
│   ├── files/
│   │   ├── squid-ca.crt          # CA certificate (public, safe to share)
│   │   └── vault/
│   │       └── squid-ca.key      # CA private key (encrypted with Ansible Vault)
│   ├── roles/
│   │   ├── common/               # System tuning
│   │   ├── monitoring/           # Prometheus exporters
│   │   └── squid/                # Squid configuration
│   ├── site.yml                  # Main playbook
│   └── inventory.ini             # Squid server IPs
├── k8s/
│   ├── squid-ca-configmap.yaml   # CA cert ConfigMap template
│   ├── example-pod-with-ca.yaml  # Generic example
│   └── springboot3-example.yaml  # Spring Boot 3 specific
├── terraform/                     # GCP infrastructure
├── SSL-BUMPING-GUIDE.md          # Deep dive into SSL bumping
├── SPRINGBOOT3-GUIDE.md          # Spring Boot 3 configuration
└── QUICK-START.md                # This file
```

## 🎯 What Gets Cached

### Decrypted and Cached (SSL Bumping)
- ✅ `*.toasttab.com` (Toast POS API)
- ✅ `*.squareup.com` (Square Payment API)

### Pass-Through (Not Cached)
- ⚪ All other HTTPS traffic (encrypted end-to-end)
- ⚪ Internal Kubernetes services (via NO_PROXY)

## 🔧 Common Tasks

### View/Edit Vault-Encrypted Private Key

```bash
# View
ansible-vault view ansible/files/vault/squid-ca.key

# Edit
ansible-vault edit ansible/files/vault/squid-ca.key
```

### Rotate CA Certificate

```bash
# Remove old certificates
rm ansible/files/squid-ca.crt
rm ansible/files/vault/squid-ca.key

# Generate new ones
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass

# Update Kubernetes ConfigMap
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=ansible/files/squid-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart all pods to pick up new certificate
kubectl rollout restart deployment/your-app
```

### Check Cache Statistics

```bash
ansible all -i ansible/inventory.ini -m shell -a "squidclient mgr:5min"
```

### View Squid Logs

```bash
ansible all -i ansible/inventory.ini -m shell -a "tail -100 /var/log/squid/access.log"
```

Look for:
- `TCP_MISS/200` = Cache miss (fetched from API)
- `TCP_HIT/200` or `TCP_MEM_HIT/200` = Cache hit (served from cache)

## 🐛 Troubleshooting

### Certificate Validation Errors in Spring Boot

**Error:** `unable to find valid certification path to requested target`

**Fix:**
1. Check CA cert is mounted: `kubectl exec pod/your-pod -- cat /etc/ssl/certs/squid-ca.crt`
2. Check truststore was created: `kubectl logs pod/your-pod -c create-truststore`
3. Verify truststore has squid-ca: `kubectl exec pod/your-pod -- keytool -list -keystore /app/truststore/squid-truststore.jks -storepass changeit | grep squid-ca`

### Proxy Connection Refused

**Fix:**
1. Check Squid is running: `ansible all -i ansible/inventory.ini -m shell -a "systemctl status squid"`
2. Check firewall: `ansible all -i ansible/inventory.ini -m shell -a "ss -tlnp | grep 3128"`
3. Test from pod: `kubectl exec pod/your-pod -- nc -zv squid-proxy 3128`

### Cache Not Working

**Fix:**
1. Check SSL bumping is active: `ansible all -i ansible/inventory.ini -m shell -a "grep 'ssl_bump' /var/log/squid/access.log"`
2. Verify domain matches ACL: Check `acl toast_api ssl::server_name .toasttab.com` in squid.conf
3. Check object size: Response might be > 15MB (see `maximum_object_size`)

## 📚 Detailed Guides

- **SSL Bumping Deep Dive:** `SSL-BUMPING-GUIDE.md`
- **Spring Boot 3 Configuration:** `SPRINGBOOT3-GUIDE.md`
- **Ansible Deployment:** `ansible/README.md`
- **Vault Management:** `ansible/files/vault/README.md`

## 🔐 Security Reminders

- ✅ Vault password is encrypted, but **save the vault password securely**
- ✅ Private key never leaves Squid servers (only `.crt` goes to microservices)
- ✅ Never commit `squid-ca.key` unencrypted
- ✅ Rotate CA certificate annually
- ✅ Use different vault passwords for dev/staging/prod

## 📊 Expected Performance

### Without Squid
- API latency: ~200ms
- Cost: $X per 1M requests
- Load: Every request hits Toast/Square APIs

### With Squid (After Cache Warm-Up)
- Cache hit latency: ~1-2ms (**100x faster!**)
- Cost: First request only (**90%+ cost reduction**)
- Load: 90%+ of requests served from cache

### Cache Hit Rate

Typical rates after 1 hour:
- Menu data: **95%** (changes rarely)
- Order status: **60%** (more dynamic)
- Payment info: **40%** (very dynamic)

## 🎉 Success Metrics

After deployment, monitor for:
- ✅ Cache hit rate > 80% (`squidclient mgr:5min`)
- ✅ P95 latency < 5ms for cached requests
- ✅ 90%+ reduction in API calls to Toast/Square
- ✅ 90%+ reduction in API costs
- ✅ Zero certificate validation errors in application logs

## 💡 Next Steps

1. ✅ Deploy Squid servers (you are here)
2. ⬜ Monitor cache hit rates for 24 hours
3. ⬜ Tune `refresh_pattern` based on usage patterns
4. ⬜ Set up Prometheus alerts for cache hit rate < 70%
5. ⬜ Document cost savings and performance improvements
6. ⬜ Roll out to staging environment
7. ⬜ Roll out to production

## 🆘 Getting Help

**Check logs:**
- Squid access: `tail -f /var/log/squid/access.log`
- Squid errors: `tail -f /var/log/squid/cache.log`
- Squid system: `journalctl -u squid -f`

**Test SSL bumping:**
```bash
openssl s_client -connect api.toasttab.com:443 \
  -proxy squid-server:3128 -showcerts
```

**Verify certificate chain:**
```bash
curl -vvv --cacert ansible/files/squid-ca.crt \
  -x http://squid-server:3128 \
  https://api.toasttab.com
```
