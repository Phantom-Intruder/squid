# SSL Bumping Deep Dive

## Overview

Your Squid proxy uses **SSL Bumping** (also called SSL interception or HTTPS inspection) to decrypt, cache, and re-encrypt HTTPS traffic to specific API endpoints.

## How SSL Bumping Works

### Without SSL Bumping (Normal HTTPS)
```
Microservice ──[encrypted]──> API Server
     ↑                            ↑
     └────── TLS handshake ───────┘
```
Squid can't see inside, can't cache.

### With SSL Bumping
```
Microservice ──[TLS]──> Squid ──[TLS]──> API Server
     ↑                    ↑  ↑              ↑
     │  Fake cert signed  │  │  Real cert  │
     │     by Squid CA     │  │   from API  │
     └─────────────────────┘  └─────────────┘
```

Squid acts as a **Man-in-the-Middle** (authorized):
1. Client thinks it's talking to `api.toasttab.com`
2. Squid generates a fake cert for `api.toasttab.com` signed by Squid CA
3. Squid decrypts client traffic, caches response, re-encrypts to real API
4. Next request = served from cache (no API call!)

## The Three-Step Decision Process

Your `squid.conf.j2` uses this logic:

```
ssl_bump peek all        # Step 1: Look at SNI without decrypting
ssl_bump bump toast_api  # Step 2: Decrypt if matches .toasttab.com
ssl_bump bump square_api # Step 2: Decrypt if matches .squareup.com
ssl_bump splice all      # Step 3: Pass through everything else
```

### Step 1: Peek
- Squid examines the **SNI** (Server Name Indication) in the TLS ClientHello
- This happens BEFORE decryption
- Squid now knows the destination domain

### Step 2: Bump (Decrypt)
If domain matches `.toasttab.com` or `.squareup.com`:
- Squid performs a full TLS handshake with the client
- Uses `squid-ca.key` to generate a certificate on-the-fly
- Decrypts the request, sees the plaintext HTTP
- Can now cache the response

### Step 3: Splice (Pass Through)
For all other domains:
- Squid acts as a transparent TCP tunnel
- No decryption, no caching
- Client and server do direct TLS

## Certificate Architecture

### What Gets Generated

**On Ansible Control Node (once)**:
```bash
/tmp/squid-ca.crt  # Public certificate (share with microservices)
/tmp/squid-ca.key  # Private key (NEVER share, Squid only)
```

**On Each Squid Server**:
```bash
/etc/squid/squid-ca.crt  # Public CA cert
/etc/squid/squid-ca.key  # Private key (0600 permissions)
/var/lib/squid/ssl_db/   # Database of generated certs
```

**Generated On-The-Fly by Squid**:
When a client requests `https://api.toasttab.com`:
- Squid generates a certificate for `api.toasttab.com`
- Signs it with `squid-ca.key`
- Caches it in `/var/lib/squid/ssl_db/`
- Presents it to the client

### Certificate Chain

```
┌─────────────────────────────────┐
│  Root: Squid Proxy CA           │  ← You generated this
│  (squid-ca.crt + squid-ca.key)  │
└────────────┬────────────────────┘
             │ signs
             ▼
┌─────────────────────────────────┐
│  Leaf: api.toasttab.com         │  ← Squid generates on-demand
│  (dynamically created)          │
└─────────────────────────────────┘
```

## What Microservices Need

### They ONLY need the .crt file

**Why?**
- Microservices are **clients** that need to **trust** certificates
- When Squid presents a fake `api.toasttab.com` cert, the microservice checks:
  - Is this signed by a CA I trust?
  - The microservice has `squid-ca.crt` in its trust store → YES, trusted!

### They do NOT need the .key file

**Why?**
- Private keys are for **signing** certificates
- Microservices don't sign anything
- If a microservice had the key, it could MITM ANY traffic (huge security risk!)

## Deployment Steps

### 1. Run Ansible Playbook
```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory site.yml
```

**What happens:**
- ✅ Generates `squid-ca.crt` and `squid-ca.key` on Ansible control node
- ✅ Copies both files to `/etc/squid/` on Squid servers
- ✅ Initializes SSL certificate database
- ✅ Deploys optimized `squid.conf`
- ✅ Starts Squid service

### 2. Extract CA Certificate
```bash
cat /tmp/squid-ca.crt
```

Copy the contents (including `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----`)

### 3. Create Kubernetes ConfigMap
```bash
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=/tmp/squid-ca.crt \
  -n your-namespace
```

Or edit `k8s/squid-ca-configmap.yaml` and apply it:
```bash
kubectl apply -f k8s/squid-ca-configmap.yaml
```

### 4. Configure Microservices

**Mount the certificate:**
```yaml
volumeMounts:
- name: squid-ca
  mountPath: /etc/ssl/certs/squid-ca.crt
  subPath: squid-ca.crt
  readOnly: true

volumes:
- name: squid-ca
  configMap:
    name: squid-ca-cert
```

**Set environment variables:**
```yaml
env:
- name: HTTP_PROXY
  value: "http://squid-server:3128"
- name: HTTPS_PROXY
  value: "http://squid-server:3128"
- name: NODE_EXTRA_CA_CERTS  # For Node.js
  value: /etc/ssl/certs/squid-ca.crt
```

See `k8s/example-pod-with-ca.yaml` for complete example.

## Testing

### 1. Without CA certificate (should fail)
```bash
curl -x http://squid-server:3128 https://api.toasttab.com
# Error: certificate verify failed
```

### 2. With CA certificate (should work)
```bash
curl --cacert /tmp/squid-ca.crt \
     -x http://squid-server:3128 \
     https://api.toasttab.com
# Success!
```

### 3. Check cache is working
```bash
# First request - cache MISS
time curl --cacert /tmp/squid-ca.crt -x http://squid:3128 https://api.toasttab.com/...

# Second request - cache HIT (much faster!)
time curl --cacert /tmp/squid-ca.crt -x http://squid:3128 https://api.toasttab.com/...
```

### 4. Check Squid logs
```bash
tail -f /var/log/squid/access.log
```

Look for:
- `TCP_MISS/200` = cache miss, fetched from origin
- `TCP_MEM_HIT/200` = cache hit from RAM
- `TCP_HIT/200` = cache hit from disk

## Security Considerations

### The Private Key is EXTREMELY Sensitive

Anyone with `squid-ca.key` can:
- Generate fake certificates for ANY domain
- Intercept ALL HTTPS traffic from your microservices
- Impersonate banks, APIs, any website

**Protection measures:**
1. ✅ Never commit to git (add to `.gitignore`)
2. ✅ Restrict to 0600 permissions (owner read/write only)
3. ✅ Only deploy to Squid servers
4. ✅ Use `no_log: true` in Ansible when handling the key
5. ✅ Consider encrypting with Ansible Vault or Secret Manager
6. ✅ Rotate periodically (every 1-2 years)

### What About Other Domains?

Your config only bumps `.toasttab.com` and `.squareup.com`. Everything else is **spliced** (passed through without inspection):

```
# These are decrypted and cached:
✅ https://api.toasttab.com/orders
✅ https://connect.squareup.com/v2/payments

# These are NOT touched (privacy preserved):
❌ https://google.com
❌ https://github.com
❌ https://your-database.com
```

## Performance Impact

### Benefits
- ✅ **Massive cost savings**: Cache hit = no API call = no charge
- ✅ **Faster responses**: RAM cache = ~1ms vs ~200ms API latency
- ✅ **Reduced load**: Fewer requests to Toast/Square APIs
- ✅ **ICP sharing**: Squid servers share cache with each other

### Overhead
- Minimal: ~1-2ms for SSL handshake and certificate generation
- First request to a new domain: generates and caches certificate
- Subsequent requests to same domain: reuses cached certificate
- CPU impact: negligible with modern hardware

## Troubleshooting

### Microservice can't connect (certificate error)
- ✅ Check the CA cert is mounted: `ls /etc/ssl/certs/squid-ca.crt`
- ✅ Check env var is set: `echo $NODE_EXTRA_CA_CERTS`
- ✅ Test with curl: `curl --cacert /path/to/squid-ca.crt -x http://squid:3128 https://api.toasttab.com`

### Squid won't start
- ✅ Check permissions: `ls -la /etc/squid/squid-ca.key` (should be 0600)
- ✅ Check SSL DB: `ls -la /var/lib/squid/ssl_db/`
- ✅ Check config syntax: `squid -k parse`
- ✅ Check logs: `journalctl -u squid -f`

### Cache not working
- ✅ Check Squid is bumping: `tail -f /var/log/squid/access.log` (look for `CONNECT` then `GET`)
- ✅ Check refresh patterns: `grep refresh_pattern /etc/squid/squid.conf`
- ✅ Check object size: Is response > 15MB? (default `maximum_object_size`)
- ✅ Check cache stats: `squidclient mgr:info`

## Summary

| Component | Needs .crt | Needs .key | Purpose |
|-----------|------------|------------|---------|
| **Squid Servers** | ✅ Yes | ✅ Yes | Sign fake certificates |
| **Microservices** | ✅ Yes | ❌ NO | Trust Squid's certificates |
| **Ansible Control** | 📁 Stored | 📁 Stored | Generate and distribute |

**Key Takeaway**: The `.key` file is like the master password to your HTTPS traffic. Guard it carefully!
