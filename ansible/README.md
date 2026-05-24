# Squid Proxy Farm Ansible Deployment

This Ansible playbook deploys a high-availability Squid forward proxy farm with SSL interception for caching Toast and Square API responses.

## Prerequisites

1. **Install Ansible** (2.12 or higher)
2. **Install required collections**:
   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

3. **Configure inventory** with your Squid server IPs
4. **Ensure SSH access** to all target servers via IAP tunnel

## Quick Start

### 1. Install Dependencies
```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 2. Run the Playbook

**First time (will generate and encrypt CA certificate):**
```bash
ansible-playbook -i inventory site.yml --ask-vault-pass
```

You'll be prompted to create a vault password. **Save this password securely!**

**Subsequent runs:**
```bash
# With password prompt
ansible-playbook -i inventory site.yml --ask-vault-pass

# With password file
ansible-playbook -i inventory site.yml --vault-password-file ~/.vault_pass
```

### 3. Verify Deployment
```bash
# Check Squid is running
ansible all -i inventory -m shell -a "systemctl status squid"

# Test the proxy
curl -x http://SQUID_IP:3128 https://api.toasttab.com
```

### 4. Extract the CA Certificate for Microservices
After the playbook runs, the CA certificate is available at `ansible/files/squid-ca.crt` on your Ansible control node.

**View the certificate:**
```bash
cat ansible/files/squid-ca.crt
```

**View the encrypted private key (requires vault password):**
```bash
ansible-vault view ansible/files/vault/squid-ca.key
```

**Create Kubernetes ConfigMap**:
```bash
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=ansible/files/squid-ca.crt \
  -n your-namespace
```

See configuration examples:
- Generic pods: `../k8s/example-pod-with-ca.yaml`
- Spring Boot 3: `../k8s/springboot3-example.yaml` and `../SPRINGBOOT3-GUIDE.md`

## What Gets Deployed

### Common Role
- Kernel tuning for high network performance
- OS security updates
- System hardening

### Monitoring Role
- Prometheus Node Exporter
- System metrics collection

### Squid Role
- **SSL Bumping**: Intercepts `.toasttab.com` and `.squareup.com` traffic
- **ICP Peering**: Cache sharing between squid servers
- **Large Object Caching**: Optimized for 5MB+ JSON responses
- **Aggressive Caching**: Ignores `no-cache` headers for targeted APIs

## Architecture

```
┌─────────────────┐       ┌─────────────────┐
│  Squid Server 1 │◄─ICP─►│  Squid Server 2 │
│   (10GB cache)  │       │   (10GB cache)  │
└────────┬────────┘       └────────┬────────┘
         │                         │
         └──────────┬──────────────┘
                    │
            ┌───────▼────────┐
            │  Microservices │
            │   (via proxy)  │
            └────────────────┘
```

## SSL Bumping Flow

1. Microservice makes HTTPS request to `api.toasttab.com`
2. Squid peeks at SNI (Server Name Indication)
3. Domain matches → Squid decrypts using generated certificate
4. Squid checks cache → cache hit = instant response (NO API call!)
5. Cache miss → Squid fetches from API, caches, returns to client
6. Next request = served from cache (1-hour TTL)

## Configuration Variables

Edit `roles/squid/vars/main.yml`:

- `squid_cache_size_mb`: Disk cache size (default: 10000 = 10GB)
- `squid_max_object_size_mb`: Max cached object (default: 15MB)
- `squid_ram_cache_mb`: RAM cache (default: 512MB)
- `squid_subnet`: Allowed subnet (default: 10.0.0.0/20)

## Security Notes

⚠️ **The CA private key is HIGHLY SENSITIVE!**

The private key is stored encrypted with Ansible Vault at `files/vault/squid-ca.key`.

**Security measures in place:**
- ✅ Encrypted with Ansible Vault
- ✅ Never logged (uses `no_log: true`)
- ✅ .gitignore allows only encrypted `.key` files
- ✅ Restricted to 0600 permissions on Squid servers
- ✅ Only deployed to Squid servers (not microservices)

**Your responsibilities:**
- 🔐 Keep the vault password secure
- 🔐 DO NOT commit unencrypted keys
- 🔐 Rotate the CA certificate annually
- 🔐 Use different vault passwords for dev/staging/prod
- 🔐 Audit who has access to the vault password

See `files/vault/README.md` for vault management details.

## Troubleshooting

### Check Squid logs
```bash
ansible all -i inventory -m shell -a "tail -f /var/log/squid/access.log"
```

### Verify SSL database
```bash
ansible all -i inventory -m shell -a "ls -la /var/lib/squid/ssl_db"
```

### Test SSL bumping
```bash
# From a microservice or test pod with the CA cert installed
curl -v -x http://squid-server:3128 https://api.toasttab.com
```

### Cache statistics
```bash
squidclient -h localhost mgr:info
squidclient -h localhost mgr:5min
```

## Next Steps

1. ✅ Deploy Squid servers with this playbook
2. ⬜ Create Kubernetes ConfigMap with `/tmp/squid-ca.crt`
3. ⬜ Configure microservices to use proxy and trust CA
4. ⬜ Monitor cache hit rates
5. ⬜ Tune refresh patterns based on usage
