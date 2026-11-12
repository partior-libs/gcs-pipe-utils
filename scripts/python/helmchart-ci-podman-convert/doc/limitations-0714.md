# Local VM Testing Guide: Podman vs. Kubernetes

This document serves as the architectural blueprint for running containerized workloads locally inside a Virtual Machine using Podman's `podman play kube` engine. It details structural limitations, workaround blueprints, and the deployment preparation workflow.

---

## 1. Podman vs. Kubernetes: Limitations & Workarounds Matrix

| Kubernetes Feature / Object | Support Level | Technical Context & Behavior in Podman |
| :--- | :--- | :--- |
| **Replica Count (`replicas > 1`)** | ⚠️ Limited | Host port binding conflicts occur on a single host node. Local testing configurations must be scaled down or managed manually. |
| **Namespaces** | ❌ Unsupported | The `metadata.namespace` field is safely ignored. All resources deploy into the default local Podman network scope. |
| **StatefulSets** | ❌ Unsupported | Only `Pod`, `Deployment`, `DaemonSet`, and `Job` kinds are recognized. `StatefulSet` specs fail to parse or are skipped. |
| **Service Accounts** | ❌ Unsupported | `spec.serviceAccountName` is ignored. Podman does not generate or inject cluster identity tokens into the container layers. |
| **StorageClasses & Provisioning** | ❌ Unsupported | Persistent Volume Claims (PVCs) cannot dynamically provision storage. Storage must map to local host directories (`hostPath`) or local volumes. |
| **Custom Resource Definitions (CRDs)**| ❌ Unsupported | Podman only handles standard core K8s API objects. It cannot interpret custom extensions or external operators. |
| **Kubernetes Annotations** | ⚠️ Filtered | Upstream orchestrator annotations are ignored. However, custom **Podman-specific annotations** are supported to bridge configuration gaps. |
| **Projected Volumes** | ❌ Unsupported | Aggregating multiple distinct secrets/configMaps into a single directory using the `projected` volume source is unsupported. |
| **Volume Subpaths (`subPath`)** | ⚠️ Partial | Standard directory isolation works. However, `subPathExpr` (variable expansion) is ignored, and single-file ConfigMap overrides cause collisions. |
| **Cross-Manifest Network Isolation** | ❌ Unsupported | By default, **each YAML manifest file runs in its own isolated network namespace**. Separate files cannot communicate out of the box. |
| **Pod Security Context (`fsGroup`)** | ❌ Unsupported | Kubernetes-style volume ownership management (`fsGroup`) is ignored entirely in rootless Podman environments. |
| **User Identifiers (`runAsUser`)** | ⚠️ RHEL 8 Constraint| On RHEL 8.10, Podman fails to cascade `runAsUser` and `runAsGroup` blocks from the Pod spec level down to individual containers. |
| **Nested Volume Mounts** | ❌ Unsupported | Podman cannot handle overlapping mount boundaries. Mounting a Secret/ConfigMap inside a directory managed by an outer volume will crash. |
| **System Directory Mounts (`/etc/...`)**| ❌ Rootless Limit | Writable host paths cannot be mounted directly inside protected trees like `/etc`. `fuse-overlayfs` path loops cause zero-log crashes. |
| **External Cross-VM Ingress** | ⚠️ Network Limit | A standard `Service` block only exposes ports locally. External cross-VM traffic requires explicit target configuration. |
| **ConfigMap / Secret CLI Inspection** | ⚠️ Limited | No native `kubectl get configmap` alternative exists. Data is injected into container layers; verification requires executing inside the container. |
---

## 2. Code Transformation Blueprint & Workarounds

Use the following architectural transformation examples to safely convert production-grade Helm/Kubernetes manifests into single-VM, rootless Podman-compatible structures.

### 1. Replica Count Allocation
* **The Issue:** `replicas > 1` causes host port binding collisions on a single node environment.
* **Workaround:** Force the replica count strictly to `1` and manage local runtime scale manually.

```yaml
# ❌ BEFORE: Production K8s (Distributed)
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: workflow-manager

# 🟢 AFTER: Podman Local VM Testing
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: workflow-manager
```

### 2. Namespace Stripping
* **The Issue:** Podman completely ignores cluster network segmentation directives (`metadata.namespace`). Leaving strict production namespace values intact can lead to configuration confusion or errors during multi-component orchestration scripts.
* **Workaround:** Purge the namespace property lines entirely from the resource metadata blocks. All manifests will deploy directly into Podman's default local host network scope.

```yaml
# ❌ BEFORE: Production K8s
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-env-config
  namespace: enterprise-dapps-prod
data:
  ENVIRONMENT: "production"

# 🟢 AFTER: Podman Local VM Testing
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-env-config
data:
  ENVIRONMENT: "production"
```

### 3. Demoting StatefulSets to Deployments
* **The Issue:** `StatefulSet` kinds fail to parse or lack the required cluster controllers to coordinate state ordering on a standalone host.
* **Workaround:** Demote the resource kind directly to a standard `Deployment`.

```yaml
# ❌ BEFORE: Production K8s
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: quorum-validator
spec:
  serviceName: "quorum"
  replicas: 1

# 🟢 AFTER: Podman Local VM Testing
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quorum-validator
spec:
  replicas: 1
```

### 4. Service Account & RBAC Stack Purging
* **The Issue:** Podman operates entirely outside of Kubernetes Identity and Access Management (IAM) and Role-Based Access Control (RBAC). It does not recognize token generation engines, permission maps (`Roles`), or identity links (`RoleBindings`), and will crash when parsing these cluster-specific resources.
* **Workaround:** Completely eliminate the ServiceAccount declaration, its associated RBAC permission architecture, and any volume-projected token requests from the manifest package.

```yaml
# ❌ BEFORE: Production K8s (Full RBAC & Token Projection Stack)
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: Vault-auth-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-vault-auth
subjects:
  - kind: ServiceAccount
    name: vault-auth-sa
roleRef:
  kind: Role
  name: vault-token-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signer
spec:
  template:
    spec:
      serviceAccountName: vault-auth-sa
      containers:
        - name: signer
          image: signer:latest
          volumeMounts:
            - mountPath: /var/run/secrets/tokens
              name: vault-token
      volumes:
        - name: vault-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: vault
                  expirationSeconds: 7200
                  path: vault-token

# 🟢 AFTER: Podman Local VM Testing (Clean Application Manifest)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signer
spec:
  template:
    spec:
      containers:
        - name: signer
          image: signer:latest
```

### 5. Storage Classes & Dynamic Provisioning
* **The Issue:** Podman completely lacks the cloud-provider APIs required to interpret `volumeClaimTemplates` or provision physical block storage dynamically via a `storageClassName`. 
* **Workaround:** You must refactor the storage pipeline using one of two strategies: flatten the spec down to a direct local `hostPath` binding, or preserve structural identity by declaring a static local `PersistentVolume` linked to a `PersistentVolumeClaim`.

#### Strategy A: Direct Host Path Redirection (Simplest)
Completely wipe out the dynamic tracking template arrays and drop a hardcoded local machine map directly inside the core container runtime spec.

```yaml
# ❌ BEFORE: Production K8s (Dynamic Cloud Provisioning)
spec:
  volumeClaimTemplates:
  - metadata:
      name: quorum-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: "premium-rwo"
      resources:
        requests:
          storage: 20Gi

# 🟢 AFTER: Podman Local VM Testing (Direct hostPath Mapping)
spec:
  template:
    spec:
      containers:
        - name: quorum
          volumeMounts:
            - mountPath: /data
              name: quorum-data
      volumes:
        - name: quorum-data
          hostPath:
            path: /home/localuser/poc/qdata
```

#### Strategy B: Static Local PVC Engine (Maintains Structural Identity)
If your application code or pipeline mandates a persistentVolumeClaim target, drop the automated template block and provide explicit local static bindings.

```yaml
# 🟢 AFTER: Podman Local VM Testing (Static PVC + Deployment Mapping Stack)
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-quorum-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /home/localuser/poc/qdata  # Physical storage directory on the VM host
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: quorum-data-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  volumeName: local-quorum-pv        # Explicitly binds the claim to the local PV above
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quorum-validator
spec:
  template:
    spec:
      containers:
        - name: quorum
          volumeMounts:
            - mountPath: /data
              name: storage-volume
      volumes:
        - name: storage-volume
          persistentVolumeClaim:
            claimName: quorum-data-claim
```

### 6. CRDs, External Operators, and Cross-System Annotations
* **The Issue:** Podman completely rejects Custom Resource Definitions (CRDs) like `ExternalSecret`, `SecretStore`, or Cert-Manager `Certificate` / `Issuer` scopes at the structural level. Furthermore, it fails to parse or process custom operational metadata annotations associated with external service meshes or configuration managers (such as Consul sidecar injections or Cert-Manager automation hooks that attempt to automatically provision cluster TLS certificates).
* **Workaround:** Bypass the operator pipelines entirely by flattening custom resource logic into native Kubernetes objects (e.g., converting an `ExternalSecret` into a native `Secret`, or replacing dynamic Cert-Manager issuance blocks with a pre-generated native TLS `Secret`). Concurrently, purge all operator-specific annotations from your resource metadata fields to ensure Podman's basic parser passes the file smoothly without validation failures.

```yaml
# ❌ BEFORE: Production K8s (ESO + Cert-Manager + Consul Connect Infrastructure)
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-gateway-tls
spec:
  secretName: gateway-tls-certs
  dnsNames:
    - api.dapps.local
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
  target:
    name: oracle-secret
  data:
    - secretKey: password
      remoteRef:
        key: secret/dapps/db
        property: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  annotations:
    [consul.hashicorp.com/connect-inject](https://consul.hashicorp.com/connect-inject): "true"
    cert-manager.io/issuer: "letsencrypt-prod"
spec:
  template:
    spec:
      containers:
        - name: gateway
          image: gateway:latest
          volumeMounts:
            - name: tls-vol
              mountPath: /etc/tls
      volumes:
        - name: tls-vol
          secret:
            secretName: gateway-tls-certs

# 🟢 AFTER: Podman Local VM Testing (Converted Static Secrets + Cleaned Deployment)
apiVersion: v1
kind: Secret
metadata:
  name: oracle-secret
type: Opaque
data:
  password: c3VwZXJzZWNyZXRwYXNwd29yZA==  # Base64 encoded plaintext string
---
apiVersion: v1
kind: Secret
metadata:
  name: gateway-tls-certs
type: kubernetes.io/tls
data:
  tls.crt: bXktZmFrZS1jZXJ0LWJhc2U2NA==  # Pre-generated or mock base64 cert data
  tls.key: bXktZmFrZS1rZXktYmFzZTY0==   # Pre-generated or mock base64 key data
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
spec:
  template:
    spec:
      containers:
        - name: gateway
          image: gateway:latest
          volumeMounts:
            - name: tls-vol
              mountPath: /etc/tls
      volumes:
        - name: tls-vol
          secret:
            secretName: gateway-tls-certs
```

### 7. Kubernetes Annotations & Metadata Clean-up
* **The Issue:** Production environments inject auto-generated cluster telemetry tracking entries, cluster resource constraints, and cloud-provider scheduler annotations (`ingress`, `deployment-revision`, `affinity`) that cause parsing exceptions inside Podman's basic YAML parser.
* **Workaround:** Completely strip out all cloud-provider and cluster tracking keys from the metadata block, keeping only custom, proprietary `io.podman.kube` network properties.

```yaml
# ❌ BEFORE: Production K8s
metadata:
  name: admin-service
  annotations:
    deployment.kubernetes.io/revision: "12"
    meta.helm.sh/release-name: core-dapps
    [cloud.google.com/neg](https://cloud.google.com/neg): '{"ingress": true}'
    orchestrator.internal.net/tracking-id: "xyz789"

# 🟢 AFTER: Podman Local VM Testing
metadata:
  name: admin-service
  annotations:
    "io.podman.kube.network": "shared-quorum-poc-net"
```

### 8. Projected Volumes (Aggregated Secrets & ConfigMaps)
* **The Issue:** Kubernetes allows mapping multiple distinct Secrets and ConfigMaps down into a single shared target directory path utilizing the `projected` volume source primitive. Podman's engine completely lacks the mounting logic required to merge multiple distinct configuration resources into a single point.
* **Workaround:** Flatten the file mapping structure by breaking the projected sources layout down into separate, standard single-resource volumes anchored to independent, non-overlapping directory paths.

```yaml
# ❌ BEFORE: Production K8s (Projected multi-source directory aggregation)
        volumeMounts:
        - name: app-configuration
          mountPath: /app/config
      volumes:
      - name: app-configuration
        projected:
          sources:
          - configMap:
              name: workflow-properties
          - secret:
              name: keystore-credentials

# 🟢 AFTER: Podman Local VM Testing (Separated standard volume mount points)
        volumeMounts:
        - name: core-properties
          mountPath: /app/config/properties
        - name: secure-credentials
          mountPath: /app/config/credentials
      volumes:
      - name: core-properties
        configMap:
          name: workflow-properties
      - name: secure-credentials
        secret:
          name: keystore-credentials
```

### 9. Volume Subpaths (`subPath`)
* **The Issue:** Modifying subpaths dynamically with environment variables (`subPathExpr`) fails under Podman. Furthermore, using `subPath` to inject individual configuration files into a target directory can cause file system collisions or completely overwrite the destination directory.
* **Workaround:** Mount the raw containing folder to a neutral temporary staging location instead of relying on single-file overrides.

```yaml
# ❌ BEFORE: Production K8s (Single file injection trick)
          volumeMounts:
            - mountPath: /etc/nginx/nginx.conf
              name: config-volume
              subPath: nginx.conf

# 🟢 AFTER: Podman Local VM Testing (Mount raw folder instead)
          volumeMounts:
            - mountPath: /tmp/nginx-config-raw
              name: config-volume
```

### 10. Cross-Manifest Network Isolation
* **The Issue:** Each raw YAML manifest file processed by `podman play kube` creates a completely separate, isolated pod network namespace boundary. Unlike in Kubernetes where pods can natively route across the cluster network mesh, these separate local files cannot communicate with each other out of the box.
* **Workaround:** Pre-create a custom bridge network on the VM host (`podman network create poc-net`) and explicitly map the manifestations into that common network using a custom Podman network metadata annotation.

```yaml
# ❌ BEFORE: Production K8s (Relies on default Cluster Mesh routing)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dapps-component
spec:
  template:
    spec:
      containers:
        - name: app

# 🟢 AFTER: Podman Local VM Testing (Forced Shared Bridge Binding)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dapps-component
  annotations:
    "io.podman.kube.network": "shared-quorum-poc-net"
spec:
  template:
    spec:
      containers:
        - name: app
```

### 11. Pod Security Context Handling (`fsGroup`)
* **The Issue:** Standard storage authorization permissions (`fsGroup`) defined at the pod level are completely ignored inside rootless user namespaces under Podman. This results in standard host directories mounting with invalid write privileges for application container processes.
* **Workaround:** Remove the cluster `fsGroup` property and inject the native Podman `:U` volume flag override via metadata annotations to recursively chown volume mount permissions inside the user namespace.

```yaml
# ❌ BEFORE: Production K8s
spec:
  securityContext:
    fsGroup: 20001
  containers:
    - name: app

# 🟢 AFTER: Podman Local VM Testing
metadata:
  annotations:
    "volume.podman.io/mount-options": "app-storage:U"
spec:
  containers:
    - name: app
```

### 12. User Identifiers Context (RHEL 8 Parsing Inheritance Trap)
* **The Issue:** Podman running in rootless environments on RHEL 8 fails to cascade `runAsUser` and `runAsGroup` configurations down from the main Pod specification level to the individual containers. If left at the Pod level, the container processes fall back to running as root (`UID 0`) inside the user namespace.
* **Workaround:** Maintain `runAsNonRoot` at the Pod level, but explicitly shift the exact `runAsUser` and `runAsGroup` integer parameters directly inside individual item scopes under the `containers[*].securityContext` block.

```yaml
# ❌ BEFORE: Production K8s
spec:
  securityContext:
    runAsUser: 10001
    runAsGroup: 20001
  containers:
    - name: workflow-manager

# 🟢 AFTER: Podman Local VM Testing (Mandatory RHEL 8 Layout)
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: workflow-manager
      securityContext:
        runAsUser: 10001
        runAsGroup: 20001
        readOnlyRootFilesystem: true
```

### 13. Nested Volume Mounting Overlaps
* **The Issue:** Mounting an internal configuration secret or resource file directly inside a subfolder path that is already controlled by a distinct parent volume mount breaks Podman's engine runtime. Podman cannot compute overlapping mount boundaries dynamically, causing path-resolution blockages.
* **Workaround:** Separate the mount paths cleanly by mapping the secret/config volume to a neutral staging directory, and then write an inline container initialization command loop (`cp` or `ln -s`) to push the asset into place inside the main storage volume at boot.

```yaml
# ❌ BEFORE: Production K8s (Overlay Layering)
          volumeMounts:
            - mountPath: /data
              name: main-storage
            - mountPath: /data/secrets/key.json
              name: key-secret
              subPath: key.json

# 🟢 AFTER: Podman Local VM Testing (Staged Separation + Appended Command Copy)
          command: ["/bin/sh", "-c"]
          args:
            - |
              mkdir -p /data/secrets/
              cp /tmp/raw-sec/key.json /data/secrets/key.json
              exec /app/start
          volumeMounts:
            - mountPath: /data
              name: main-storage
            - mountPath: /tmp/raw-sec
              name: key-secret
```

> **How DPMC applies this:** each nested volume is mounted whole at `/dpmc-staging/<volume>` and put into place by a command prepended to the container's own command. Configs and data directories are **symlinked** (e.g. `ln -sfn /dpmc-staging/tessera-config/logback.xml /mnt/etc/quorum/qdata/tm/logback.xml`). A Secret nested in an `emptyDir` is **copied** (`cp -fL`), so a private key can be `chmod 600`'d by the running user. Symlinks keep same-volume `subPath` directories writing to the right place and work with a read-only root filesystem. A compiled manifest with `/dpmc-staging/...` mounts and these `ln -sfn` commands is the intended result of this workaround, not a defect.

### 14. Host Path System Mounting (`/etc/...`)
* **The Issue:** Direct `hostPath` directory execution inside a protected system tree structure (`/etc`) forces a fatal namespace looping error inside `fuse-overlayfs`, creating zero-log container crashes.
* **Workaround:** Mount the directory structures to neutral partitions (e.g., `/mnt`) and establish system paths using inline symbolic links (`ln -s`).

```yaml
# ❌ BEFORE: Production K8s / Root-privileged Pods
          volumeMounts:
            - mountPath: /etc/quorum/qdata
              name: working-directory

# 🟢 AFTER: Podman Local VM Testing (Neutral Mapping + Symbolic Link Generation)
          command: ["/bin/sh", "-c"]
          args:
            - |
              mkdir -p /etc/quorum
              ln -s /mnt/qdata /etc/quorum/qdata
              exec /entrypoint.sh
          volumeMounts:
            - mountPath: /mnt/qdata
              name: working-directory
```

> **How DPMC applies this:** writable volumes (hostPath/PVC/emptyDir) mounted under `/etc` are moved to `/mnt/etc/...`, and every reference to the old path in the pod's command/args/env and its own ConfigMaps is rewritten (e.g. `QHOME=/mnt/etc/quorum/qdata`). **No symlink is created under `/etc`**, so this works with `readOnlyRootFilesystem: true`. Secret/configMap mounts under `/etc` are left in place; this was validated in a manual Podman test.

### 15. External Cross-VM Network Ingress Gateway
* **The Issue:** Standard cluster `Service` manifests only bridge host network cards locally. If components live on separate physical VMs, the loopback mapping blocks external traffic.
* **Workaround:** Add explicit `hostPort` values greater than 1024 inside the container ports array to force interface hole punching.

```yaml
# ❌ BEFORE: Production K8s (Relies on external Ingress/LB routing objects)
spec:
  containers:
    - name: quorum-validator
      ports:
        - containerPort: 8545

# 🟢 AFTER: Podman Local VM Testing (Forced Interface Port Hole Punching)
spec:
  containers:
    - name: quorum-validator
      ports:
        - containerPort: 8545
          hostPort: 8545     # ⚠️ Must be >1024 for rootless unprivileged bindings on RHEL 8
```


### 16. ConfigMap / Secret Direct CLI Inspection
* **The Issue:** There is no native Podman orchestrator CLI tool equivalent to execute commands like `kubectl get configmap` or `kubectl describe secret`. ConfigMaps and Secrets are rendered straight into the container's structural storage layers, leaving them invisible to standard external CLI checks on the host VM.
* **Workaround:** You cannot inspect these files from the host CLI directly. You must execute an interactive lookup command directly inside the container namespace to dump the active environment variables or target system mounts.

```bash
# ❌ BEFORE: Production K8s (Cluster-level extraction)
kubectl get configmap workflow-config -o yaml
kubectl get secret db-credentials -n dapps -o jsonpath='{.data.password}' | base64 --decode

# 🟢 AFTER: Podman Local VM Testing (Container-runtime extraction checks)
podman exec -it workflow-manager-pod env | grep DATABASE_URL
podman exec -it signer-pod cat /etc/config/app-settings.json
```


---

## 3. Step-by-Step Manifest Preparation Guide

Follow this five-step pipeline to safely transform production Helm charts or active Kubernetes manifests into a running local Podman VM structure.

### Step 1: Extract and Render Manifests
1. **Compile the Templates:** Render your Helm charts locally using target value overrides into a single aggregated text file:
   ```bash
   helm template my-release-name ./my-helm-chart-directory -f overriding-values.yaml > combined-manifests.yaml
   ```
2. **Export Live Cluster Secrets (ESO Bypass):** Since CRDs are unsupported, extract secrets directly from the active cluster environment while stripping cluster-only tracking values:
   ```bash
   kubectl get secrets my-app-secret -n your-namespace -o yaml | grep -vE 'uid|resourceVersion|creationTimestamp|managedFields' > application-secrets.yaml
   ```
* **Manual Action:** Open `application-secrets.yaml`, remove the `metadata.ownerReferences` block to prevent parsing crashes, and append the secret text directly into your `combined-manifests.yaml`.
* **TLS Certificates:**  If your application relies on Cert-Manager to mint TLS certs, manually export the generated TLS Secret or generate mock base64-encoded cert keys (tls.crt, tls.key) and append them as a native kubernetes.io/tls Secret block.

### Step 2: Refactor Orchestration & Storage Blocks
1. **Demote Kinds:** Locate your stateful microservices and alter `kind: StatefulSet` to `kind: Deployment`. Ensure `replicas: 1` is strictly enforced.
2. **Handle Dynamic Storage (Choose one strategy):**
   * *Strategy A (Direct Host Path):* Wipe out the entire `volumeClaimTemplates` block at the bottom of the manifest. Under the Pod spec template, map volumes directly to static directories on the host VM via `hostPath`.
   * *Strategy B (Static PVC Engine):* Wipe out `volumeClaimTemplates` and replace it by declaring standalone, static local `PersistentVolume` and `PersistentVolumeClaim` manifests linked explicitly by `volumeName`.
3. **Flatten Projected Volumes:** Scan for `volumes[*].projected` containing multi-source configurations. Split aggregated Projected Volumes down into separate, standard single-resource volumes (`secret` or `configMap`) targeting non-overlapping directories.
4. **Isolate Overlapping and Protected System Directories:** Review your storage hooks. If a service requires paths located inside `/etc/`, map the physical volume to an unprivileged neutral landing directory (e.g., `/mnt/data`) and leverage container startup runtime overrides (`ln -s`) to stitch the directories together at execution.

### Step 3: Sanitize Metadata, Labels, Namespace, and Annotations
1. **Strip Automation IDs & Namespaces:** Remove automated tracking metrics, including `status:` blocks, `creationTimestamp:`, `uid:`, `resourceVersion:`, `generation:`, along with cluster scheduling arrays (`affinity:`, `tolerations:`). Completely strip the `metadata.namespace` string so resources deploy cleanly into Podman's default local scope.
2. **Purge Third-Party Operator Metadata:** Scrub all custom annotations associated with external controllers or service meshes (e.g., `consul.hashicorp.com/*`, `cert-manager.io/*`) to ensure Podman's basic parser does not fail on unrecognized configuration patterns.
3. **Retain Inter-Object Labels:** Preserve `spec.selector.matchLabels` and `metadata.labels` arrays unmodified. Podman mandates them to execute internal routing and connect Services to target Deployment blocks.
4. **Inject Proprietary Podman Annotations:** Incorporate engineering workarounds directly into manifest metadata blocks:
   * Add `"io.podman.kube.network": "quorum-poc-network"` to link discrete YAML files to a common virtual host interface.
   * Add `"volume.podman.io/mount-options": "volume-name:U"` to enforce rootless recursive file permission conversions (`chown` equivalent).

### Step 4: Re-engineer Security, Service Accounts, and RBAC
1. **Apply Container-Level Context Explicitly (RHEL 8 Hack):** Due to parsing limitations on RHEL 8.10, integer security properties defined globally fail to cascade down to individual image layers. Move your `runAsUser: 10001` and `runAsGroup: 20001` keys directly inside individual items in the `containers[*].securityContext` blocks.
2. **Purge the RBAC and Service Account Stack:** Completely drop all `ServiceAccount`, `Role`, `ClusterRole`, `RoleBinding`, and `ClusterRoleBinding` manifests. Strip `serviceAccountName` and `automountServiceAccountToken` strings from Pod deployment fields. 
3. **Remove Service Account Projected Tokens:** Wipe out `serviceAccountToken` blocks from volume lists. If your container app crashes when missing token paths at boot, map a standard dummy ConfigMap volume path over `/var/run/secrets/kubernetes.io/serviceaccount`.
4. **Configure Network Boundaries (Internal vs. Cross-VM Traffic):**
   * *Intra-VM Connections:* For apps running on the same VM node, communication needs no host port exposure; they will route traffic over the custom shared Podman bridge network using `http://<target-pod-name>:<containerPort>`.
   * *Cross-VM Connections:* For infrastructure components crossing physical VM boundaries (e.g., VM 2 microservices calling VM 1 blockchain validators), inject a `hostPort` string matching the internal `containerPort`. Ensure the selected external ports remain above `1024` to comply with rootless socket binding rules.

### Step 5: Validate and Sanitize for Go Template Parsing
If your deployment automation engine routes the updated manifest blocks through a native Go `text/template` compiler, you must comply with strict textual rendering policies. Go evaluates whitespace parameters, string literals, and control loops significantly more rigidly than Helm.

#### Go Template Structural Checklist
* **Strict Indentation Alignment:** Go templates are highly sensitive to whitespace blocks. Ensure that newly inserted custom Podman annotations and nested `securityContext` objects match the precise spacing hierarchy of the rest of the manifest.
* **String Enclosure for Complex Annotation Keys:** Podman's custom annotations contain forward slashes and hyphens (e.g., `volume.podman.io/mount-options`). Ensure the entire key-value pair is formatted properly. Wrap strings in double quotes (`"..."`) to prevent the parser from trying to interpret special characters.
* **Escaping Special Characters:** If your inline container workaround commands contain literal bash scripts with `$`, braces `{ }`, or pipe primitives `|`, ensure they do not collide with Go template delimiters. If necessary, escape them or isolate the script strings to prevent Go from attempting to execute them as template variables.
* **Dry-Run Syntax Check:** Before pushing the final `combined-manifests.yaml` to your host VM, pass it through a standard YAML linter or local Go-based structural parser to catch invisible formatting errors early.

#### Spacing and Quoting Examples

```yaml
# ❌ INCORRECT (Wipes out line breaks, pulling containers onto the same line)
spec:
  template:
    spec:
      {{- if .Values.isRootless -}}
      securityContext:
        runAsNonRoot: true
      {{- end }}
      containers:
        - name: workflow-manager

# 🟢 CORRECT (Preserves trailing structural line breaks safely)
spec:
  template:
    spec:
      {{- if .Values.isRootless }}
      securityContext:
        runAsNonRoot: true
      {{- end }}
      containers:
        - name: workflow-manager
```

```yaml
# ❌ INCORRECT (Loop range breaks block margins, causing left-flush syntax errors)
      containers:
        - name: workflow-manager
          env:
          {{- range .Values.envList }}
          - name: {{ .name }}
            value: {{ .value }}
          {{- end }}

# 🟢 CORRECT (Explicit block spacing padding preserves precise YAML list index tabs)
      containers:
        - name: workflow-manager
          env:
            {{- range .Values.envList }}
            - name: {{ .name }}
              value: {{ .value }}
            {{- end }}
```

```yaml
# ❌ INCORRECT (Raw slashes and colons provoke compilation failures)
metadata:
  annotations:
    volume.podman.io/mount-options: data:U

# 🟢 CORRECT (Explicit string wrapping handles special characters perfectly)
metadata:
  annotations:
    "volume.podman.io/mount-options": "data:U"
```

---

## 4. Automated CI/CD Validation Pipeline

The whole process is automated with **GitHub Actions** ([.github/workflows/podman-compiler.yml](../../.github/workflows/podman-compiler.yml)):
1. **Placeholder annotation:** values marked `__TBU__` in the values/secrets files become `__TBU:<yaml.path>__` (e.g. `__TBU:node.tessera.db.url__`). These placeholders stay in the final manifest on purpose. The deployment team fills them in, so they are not compatibility problems.
2. **Helm rendering:** checks out the target chart repository and runs `helm template` with one or more values files.
3. **Deterministic compilation:** `dpmc.py` applies the workarounds in this guide and merges one or more secrets files.
4. **Podman validation:** `podman kube play --start=false` on a copy of the manifest with placeholders replaced by dummy values, followed by `podman kube down`.
5. **AI audit:** an AI review against this guide. The job fails on a `BLOCKING_ERROR` verdict.
6. **Commit and artifacts:** generated files are committed only if every check passed; artifacts are uploaded on every run.

See [pipeline_integration_guide.md](pipeline_integration_guide.md) for inputs and details.

