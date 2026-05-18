# Apps

Application manifests live under this directory. App ingresses use Traefik and
the `*.apps.home.arpa` internal DNS zone.

## HTTPS with mkcert

Use mkcert to create one locally trusted wildcard certificate for app ingresses:

```sh
mkcert -install
mkcert \
  -cert-file k3s/apps/apps.home.arpa.crt \
  -key-file k3s/apps/apps.home.arpa.key \
  "*.apps.home.arpa" apps.home.arpa
```

Install the mkcert root CA on every client device that should trust these
certificates. To find the root CA file:

```sh
mkcert -CAROOT
```

The root certificate is usually `rootCA.pem` inside that directory.

## Kubernetes TLS secret

Kubernetes Secrets are namespace-scoped. Create the same TLS secret in each app
namespace that needs HTTPS:

```sh
kubectl create namespace <namespace> --dry-run=client -o yaml | kubectl apply -f -
kubectl -n <namespace> create secret tls apps-home-arpa-tls \
  --cert=k3s/apps/apps.home.arpa.crt \
  --key=k3s/apps/apps.home.arpa.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Reference the secret from the app ingress:

```yaml
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app-name.apps.home.arpa
      secretName: apps-home-arpa-tls
```

Do not commit generated `.crt`, `.key`, or Secret YAML files that contain
private key material.
