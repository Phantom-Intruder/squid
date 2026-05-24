# Squid SSL Bumping Proxy Role

This role deploys a high-performance Squid forward proxy with SSL interception (bumping) for Toast and Square APIs.

## What It Does

1. Generates a self-signed CA certificate on the Ansible control node
2. Installs and configures Squid with SSL bumping enabled
3. Sets up ICP peering between multiple Squid servers for cache sharing
4. Optimizes cache settings for large payloads (5MB+ JSON responses)

## SSL Bumping Behavior

- **Decrypted**: `.toasttab.com` and `.squareup.com` domains (bumped for caching)
- **Pass-through**: All other HTTPS traffic (spliced, not inspected)

## Prerequisites

Install the `community.crypto` Ansible collection:

```bash
ansible-galaxy collection install community.crypto
```

## Certificate Files

After running the playbook, you'll find:

- `/tmp/squid-ca.crt` - Public CA certificate (on Ansible control node)
- `/tmp/squid-ca.key` - Private key (**keep secure!**)

## Configuring Microservices

Your microservices need to trust the Squid CA certificate to accept the intercepted SSL connections.

### Option 1: Kubernetes ConfigMap

Create a ConfigMap with the CA certificate:

```bash
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=/tmp/squid-ca.crt \
  -n your-namespace
```

Mount it in your pod:

```yaml
spec:
  containers:
  - name: your-app
    volumeMounts:
    - name: squid-ca
      mountPath: /etc/ssl/certs/squid-ca.crt
      subPath: squid-ca.crt
      readOnly: true
    env:
    - name: NODE_EXTRA_CA_CERTS  # For Node.js
      value: /etc/ssl/certs/squid-ca.crt
    - name: REQUESTS_CA_BUNDLE   # For Python
      value: /etc/ssl/certs/squid-ca.crt
  volumes:
  - name: squid-ca
    configMap:
      name: squid-ca-cert
```

### Option 2: Bake into Container Image

Add to your Dockerfile:

```dockerfile
COPY squid-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
```

### Language-Specific Configuration

**Node.js**:
```bash
export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/squid-ca.crt
```

**Python**:
```bash
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/squid-ca.crt
export SSL_CERT_FILE=/etc/ssl/certs/squid-ca.crt
```

**Java**:
```bash
keytool -import -trustcacerts -alias squid-ca \
  -file /etc/ssl/certs/squid-ca.crt \
  -keystore $JAVA_HOME/lib/security/cacerts \
  -storepass changeit -noprompt
```

**Go**:
```go
caCert, _ := ioutil.ReadFile("/etc/ssl/certs/squid-ca.crt")
caCertPool := x509.NewCertPool()
caCertPool.AppendCertsFromPEM(caCert)

client := &http.Client{
    Transport: &http.Transport{
        TLSClientConfig: &tls.Config{RootCAs: caCertPool},
    },
}
```

## Security Notes

⚠️ **NEVER commit `squid-ca.key` to version control!**

The private key allows anyone to impersonate any website to your microservices. Keep it secure:

- Store in Ansible Vault, GCP Secret Manager, or similar
- Restrict access to the Squid servers only
- Rotate periodically (requires redeploying to microservices)

## Variables

Defined in `vars/main.yml`:

- `squid_cache_size_mb`: Disk cache size (default: 10000 = 10GB)
- `squid_max_object_size_mb`: Maximum cached object size (default: 15MB)
- `squid_ram_cache_mb`: RAM cache size (default: 512MB)
- `squid_subnet`: Subnet allowed to use proxy (default: 10.0.0.0/20)
