# Spring Boot 3 with Squid SSL Bumping

Complete guide for configuring Spring Boot 3 applications to work with Squid's SSL interception.

## Overview

Spring Boot 3 uses Java's `HttpClient` (or RestClient/WebClient) which rely on the JVM's truststore for SSL certificate validation. Since Squid presents certificates signed by a custom CA, you need to add the Squid CA certificate to the JVM truststore.

## Three Approaches

### Approach 1: Dynamic Truststore (Recommended for Kubernetes)

Use an init container to create a truststore at runtime:

**Pros:**
- ✅ No need to rebuild Docker image when CA rotates
- ✅ Combines system CAs + Squid CA
- ✅ Works with any Java version

**Cons:**
- ❌ Slight startup delay (1-2 seconds)

See `k8s/springboot3-example.yaml` for complete example.

### Approach 2: Bake into Docker Image

Add to your Dockerfile:

```dockerfile
FROM eclipse-temurin:21-jdk-alpine

# Copy your application
COPY target/*.jar app.jar

# Import Squid CA certificate into JVM truststore
COPY squid-ca.crt /tmp/squid-ca.crt
RUN keytool -import -trustcacerts \
    -alias squid-ca \
    -file /tmp/squid-ca.crt \
    -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit \
    -noprompt && \
    rm /tmp/squid-ca.crt

ENTRYPOINT ["java", "-jar", "/app.jar"]
```

**Pros:**
- ✅ No runtime overhead
- ✅ Simpler Kubernetes manifest

**Cons:**
- ❌ Must rebuild image when CA rotates
- ❌ Modifies system truststore (affects all Java apps)

### Approach 3: Programmatic Configuration

Configure in your Spring Boot application:

```java
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.Resource;
import org.springframework.core.io.ResourceLoader;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.InputStream;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;

@Configuration
public class SquidProxyConfig {

    @Bean
    public SSLContext customSSLContext(ResourceLoader resourceLoader) throws Exception {
        // Load system truststore
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        String trustStorePath = System.getProperty("javax.net.ssl.trustStore");
        String trustStorePassword = System.getProperty("javax.net.ssl.trustStorePassword", "changeit");
        
        try (InputStream is = new FileInputStream(trustStorePath)) {
            trustStore.load(is, trustStorePassword.toCharArray());
        }

        // Add Squid CA certificate
        Resource squidCaResource = resourceLoader.getResource("file:/etc/ssl/certs/squid-ca.crt");
        try (InputStream is = squidCaResource.getInputStream()) {
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            X509Certificate squidCaCert = (X509Certificate) cf.generateCertificate(is);
            trustStore.setCertificateEntry("squid-ca", squidCaCert);
        }

        // Create SSL context with custom truststore
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(null, tmf.getTrustManagers(), null);
        
        return sslContext;
    }

    @Bean
    public RestTemplate restTemplate(SSLContext customSSLContext) throws Exception {
        CloseableHttpClient httpClient = HttpClients.custom()
            .setSSLContext(customSSLContext)
            .build();
        
        HttpComponentsClientHttpRequestFactory factory = new HttpComponentsClientHttpRequestFactory(httpClient);
        return new RestTemplate(factory);
    }
}
```

**Pros:**
- ✅ Full programmatic control
- ✅ Can use different truststores per bean

**Cons:**
- ❌ More complex code
- ❌ Only works for beans you configure (not all HTTP clients)

## Kubernetes Configuration

### 1. Create the ConfigMap

```bash
kubectl create configmap squid-ca-cert \
  --from-file=squid-ca.crt=/path/to/squid-ca.crt \
  -n your-namespace
```

Or apply the manifest:
```bash
# Edit k8s/squid-ca-configmap.yaml with your cert
kubectl apply -f k8s/squid-ca-configmap.yaml
```

### 2. Deploy Your Application

```bash
kubectl apply -f k8s/springboot3-example.yaml
```

### 3. Verify

```bash
# Check init container created truststore
kubectl logs -f deployment/springboot-microservice -c create-truststore

# Check application starts successfully
kubectl logs -f deployment/springboot-microservice -c app

# Test API call through proxy
kubectl exec -it deployment/springboot-microservice -- \
  curl -v http://api.toasttab.com/some-endpoint
```

## Spring Boot Application Configuration

### application.yml

```yaml
spring:
  application:
    name: my-microservice

# Optional: Configure RestClient/WebClient with proxy
logging:
  level:
    org.apache.http: DEBUG  # Enable to troubleshoot SSL issues
    javax.net.ssl: DEBUG

# If using Apache HttpClient (RestTemplate)
http:
  client:
    proxy:
      enabled: true
      host: ${HTTP_PROXY_HOST:squid-proxy}
      port: ${HTTP_PROXY_PORT:3128}

# If using Spring Cloud OpenFeign
feign:
  client:
    config:
      default:
        connectTimeout: 5000
        readTimeout: 5000
```

### Using RestClient (Spring Boot 3.2+)

```java
@Configuration
public class HttpClientConfig {

    @Bean
    public RestClient restClient(RestClient.Builder builder) {
        return builder
            .baseUrl("https://api.toasttab.com")
            .build();
    }
}

@Service
public class ToastService {
    
    private final RestClient restClient;

    public ToastService(RestClient restClient) {
        this.restClient = restClient;
    }

    public String getMenus() {
        return restClient.get()
            .uri("/restaurants/123/menus")
            .retrieve()
            .body(String.class);
    }
}
```

The proxy and SSL configuration is handled automatically through JVM properties!

### Using WebClient (Reactive)

```java
@Configuration
public class WebClientConfig {

    @Bean
    public WebClient webClient(WebClient.Builder builder) {
        return builder
            .baseUrl("https://api.toasttab.com")
            .build();
    }
}

@Service
public class ToastReactiveService {
    
    private final WebClient webClient;

    public ToastReactiveService(WebClient webClient) {
        this.webClient = webClient;
    }

    public Mono<String> getMenus() {
        return webClient.get()
            .uri("/restaurants/123/menus")
            .retrieve()
            .bodyToMono(String.class);
    }
}
```

## Environment Variables

The Kubernetes manifest sets these automatically:

```bash
# HTTP Proxy settings
HTTP_PROXY=http://squid-proxy:3128
HTTPS_PROXY=http://squid-proxy:3128
NO_PROXY=localhost,127.0.0.1,.svc.cluster.local

# JVM Settings (via JAVA_TOOL_OPTIONS)
-Dhttp.proxyHost=squid-proxy
-Dhttp.proxyPort=3128
-Dhttps.proxyHost=squid-proxy
-Dhttps.proxyPort=3128
-Dhttp.nonProxyHosts=localhost|127.0.0.1|*.svc.cluster.local
-Djavax.net.ssl.trustStore=/app/truststore/squid-truststore.jks
-Djavax.net.ssl.trustStorePassword=changeit
```

## Troubleshooting

### 1. Certificate Validation Errors

**Error:**
```
javax.net.ssl.SSLHandshakeException: PKIX path building failed: 
sun.security.provider.certpath.SunCertPathBuilderException: 
unable to find valid certification path to requested target
```

**Cause:** The JVM doesn't trust the Squid CA certificate.

**Solutions:**

a) Check the CA cert is mounted:
```bash
kubectl exec -it pod/your-pod -- cat /etc/ssl/certs/squid-ca.crt
```

b) Verify the truststore was created:
```bash
kubectl exec -it pod/your-pod -- \
  keytool -list -keystore /app/truststore/squid-truststore.jks -storepass changeit | grep squid-ca
```

c) Enable SSL debugging:
```yaml
env:
- name: JAVA_TOOL_OPTIONS
  value: "-Djavax.net.debug=ssl:handshake:verbose"
```

d) Check the certificate chain:
```bash
kubectl exec -it pod/your-pod -- \
  openssl s_client -connect api.toasttab.com:443 \
  -proxy squid-proxy:3128 -showcerts
```

### 2. Proxy Not Being Used

**Check:**
```bash
# Inside the pod
echo $HTTP_PROXY
echo $HTTPS_PROXY
echo $JAVA_TOOL_OPTIONS | grep proxyHost
```

**Verify with netcat:**
```bash
kubectl exec -it pod/your-pod -- \
  nc -zv squid-proxy 3128
```

### 3. Init Container Fails

**Check logs:**
```bash
kubectl logs pod/your-pod -c create-truststore
```

**Common issues:**
- ConfigMap not mounted: `kubectl describe pod/your-pod`
- Wrong Java version: Match init container Java version to app
- Permission issues: EmptyDir should be writable

### 4. Application Can't Read Truststore

**Check file permissions:**
```bash
kubectl exec -it pod/your-pod -- ls -la /app/truststore/
```

Should show:
```
-rw-r--r-- 1 root root 123456 Jan 1 12:00 squid-truststore.jks
```

### 5. Testing Without Full Deployment

**Test with a debug pod:**
```bash
kubectl run -it --rm debug \
  --image=eclipse-temurin:21-jdk \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "debug",
      "image": "eclipse-temurin:21-jdk",
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "squid-ca",
        "mountPath": "/tmp/squid-ca.crt",
        "subPath": "squid-ca.crt"
      }]
    }],
    "volumes": [{
      "name": "squid-ca",
      "configMap": {"name": "squid-ca-cert"}
    }]
  }
}' -- bash

# Inside the pod:
export HTTPS_PROXY=http://squid-proxy:3128
keytool -import -trustcacerts -alias squid-ca \
  -file /tmp/squid-ca.crt \
  -keystore /tmp/truststore.jks \
  -storepass changeit -noprompt

curl --cacert /tmp/squid-ca.crt https://api.toasttab.com
```

## Performance Considerations

### Truststore Creation Overhead

The init container adds ~1-2 seconds to pod startup:
```
- Copying system cacerts: ~500ms
- Importing Squid CA: ~200ms
- Verification: ~100ms
```

For faster startups, consider baking into the image instead.

### Proxy Overhead

- First request to new domain: ~2-5ms (SSL handshake + cert generation)
- Cached requests: ~1ms overhead
- Cache hit: ~1-2ms (vs ~200ms API call) = **100-200x faster!**

## Security Checklist

- [ ] Never commit `squid-ca.key` to git
- [ ] Store vault password in secure location (not git)
- [ ] Use different vault passwords for dev/staging/prod
- [ ] Rotate CA certificate annually
- [ ] Use RBAC to restrict ConfigMap access
- [ ] Monitor who can view/edit the ConfigMap
- [ ] Use Pod Security Standards (restricted mode)
- [ ] Consider using cert-manager for automatic rotation

## Complete Example with Multiple Clients

If your Spring Boot app calls multiple APIs:

```java
@Configuration
public class MultiClientConfig {

    // Toast API client (proxied through Squid, gets cached)
    @Bean
    @Qualifier("toastClient")
    public RestClient toastClient(RestClient.Builder builder) {
        return builder
            .baseUrl("https://api.toasttab.com")
            .build();
    }

    // Square API client (proxied through Squid, gets cached)
    @Bean
    @Qualifier("squareClient")
    public RestClient squareClient(RestClient.Builder builder) {
        return builder
            .baseUrl("https://connect.squareup.com")
            .build();
    }

    // Internal service (direct connection, no proxy)
    @Bean
    @Qualifier("internalClient")
    public RestClient internalClient(RestClient.Builder builder) {
        return builder
            .baseUrl("http://internal-service.default.svc.cluster.local")
            .build();
    }
}
```

The `NO_PROXY` environment variable ensures internal Kubernetes services bypass the proxy!

## Summary

**For Spring Boot 3 + Squid SSL Bumping:**

1. Mount the CA certificate via ConfigMap
2. Create a JKS truststore with the CA cert (init container or Dockerfile)
3. Configure JVM to use the custom truststore via `JAVA_TOOL_OPTIONS`
4. Set proxy environment variables
5. Use standard Spring Boot HTTP clients (RestClient, WebClient, RestTemplate)

The proxy and SSL configuration happens at the JVM level, so your application code remains clean and portable!
