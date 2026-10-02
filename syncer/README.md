# KRMSyncer

The KRMSyncer is a Kubernetes-native tool designed for multi-cluster state synchronization. It facilitates **Active-Passive (Failover)** scenarios where one cluster acts as the leader (Syncer's `Source`) and another acts as a standby (Syncer's `Destination`).

## Features

- **Push & Pull Models:** Support both pushing from local to remote and pulling from remote to local clusters.
- **Dynamic Watching:** Dynamically registers watches for resources specified in the configuration.
- **Resource Syncing:** Syncs standard resources (e.g., ConfigMaps, Secrets) and CRDs.
- **Status Syncing:** Optionally syncs the status subresource.
- **Suspension:** Supports pausing sync operations via a `suspend` field.
- **Namespace Mapping:** Supports syncing to a specific destination namespace.

## Overview

The operator manages the `KRMSyncer` Custom Resource to coordinate resource replication:

1.  **Reconciling (Active cluster)**:
    *   Watches specific Kubernetes resources defined in rules.
    *   Continuously syncs their state directly to the destination.
    *   Requires a `Secret` containing the Kubeconfig of the remote cluster.
    *   Default mode is `pull`.

2.  **Suspended (Passive cluster)**:
    *   Acts as the receiver.
    *   The controller in this mode remains idle regarding synchronization, waiting for updates from the other cluster.

## Configuration (KRMSyncer CRD)

The `KRMSyncer` resource allows you to define what to sync and where to sync it.

```yaml
apiVersion: syncer.gkelabs.io/v1alpha1
kind: KRMSyncer
metadata:
  name: resource-sync
spec:
  suspend: false
  mode: pull # Defaults to 'pull'.
  rules:
    - group: ""
      version: "v1"
      kind: "ConfigMap"
      namespaces: ["default"] # Only sync ConfigMaps in the 'default' namespace
    - group: "networking.k8s.io"
      version: "v1"
      kind: "Ingress"
  remote:
    clusterConfig:
      kubeConfigSecretRef:
        name: "remote-cluster-kubeconfig"
```
## Run Integration test
```bash
# Build the manager binary
cd syncer
make test-integration
```

## Getting Started

### Prerequisites

Before running [`krmsyncer.sh`](krmsyncer.sh), make sure you have the following.

**Local tools**

- `kubectl`, `gcloud`, and `docker`.
- [`gke-gcloud-auth-plugin`](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin), so `kubectl` can authenticate to GKE.

**Clusters**

- The destination cluster must have [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) enabled.
- You need kubeconfig contexts for both clusters. Create them with:
  ```bash
  gcloud container clusters get-credentials <SOURCE_CLUSTER_NAME> --location <SOURCE_CLUSTER_LOCATION> --project <GCP_PROJECT_ID>
  gcloud container clusters get-credentials <DEST_CLUSTER_NAME> --location <DEST_CLUSTER_LOCATION> --project <GCP_PROJECT_ID>
  ```
- To use the sample `KRMSyncer` CR, destination cluster needs the Config Connector CRDs installed for all the resources in the source cluster.

### 1. Deploy KRMSyncer to the Destination Cluster

Use the [`krmsyncer.sh`](krmsyncer.sh) script.

```bash
# Build the manager binary
cd syncer
make build

./krmsyncer.sh \
  --source-cluster <SOURCE_CLUSTER_NAME> \
  --source-location <SOURCE_CLUSTER_LOCATION> \
  --dest-cluster <DEST_CLUSTER_NAME> \
  --dest-location <DEST_CLUSTER_LOCATION> \
  --project <GCP_PROJECT_ID> \
  [-n <NAMESPACE>] \
  [-i <IMAGE>]
```

`-n` sets the namespace for the `KRMSyncer` CR and the `source-cluster` Secret (default: `krmsyncer-system`, the same namespace as the controller).

`-i` sets the controller image to deploy. Default to `gcr.io/<project>/krmsyncer/controller:latest`.

This command:
1. Configures Workload Identity. It creates the `krmsyncer@<project>.iam.gserviceaccount.com` GSA, grants it `roles/container.viewer`, and binds it to the `krmsyncer-system/krmsyncer-controller-manager` KSA.
2. Builds and pushes the controller image, unless `--image` points to an image that already exists.
3. Creates the `source-cluster` kubeconfig Secret. The kubeconfig authenticates with `gke-gcloud-auth-plugin --use_application_default_credentials`, so it contains no user credentials.
4. Deploys the RBAC, KRMSyncer CRD and controller into the `krmsyncer-system` namespace of the destination cluster.
5. Applies a sample `KRMSyncer` CR that syncs all Config Connector resources from the source cluster. The destination cluster needs the matching KCC CRDs pre-installed.

The sample `KRMSyncer` CR and the source kubeconfig are YAML templates in [`config/templates/`](config/templates).

    3. Verify the file:
       ```bash
       kubectl --kubeconfig=remote-kubeconfig.yaml get nodes
       ```
       If this command works, `remote-kubeconfig.yaml` is ready to be used.

1. **Create the Kubeconfig Secret** (on the Local cluster):
    ```bash
    kubectl create secret generic remote-kubeconfig \
      --from-file=kubeconfig=remote-kubeconfig.yaml
    ```

1. **Apply the Syncer Resource** (on the Local cluster):
    ```yaml
    # test-syncer.yaml
    apiVersion: syncer.gkelabs.io/v1alpha1
    kind: KRMSyncer
    metadata:
      name: configmap-sync
    spec:
      suspend: false
      mode: push
      rules:
        - group: ""
          version: "v1"
          kind: "ConfigMap"
          namespaces: ["default"] # Only sync ConfigMaps in the 'default' namespace
      remote:
        clusterConfig:
          kubeConfigSecretRef:
            name: "remote-kubeconfig"

    ```
    ```bash
    kubectl apply -f test-syncer.yaml
    ```
1. **Verify the Results**:
    1. Create a test resource in the Local cluster:
       ```bash
       kubectl create configmap test-sync-data --from-literal=key=value1
       ```

    1. Check the Remote cluster:
       Switch your kubectl context to the Remote cluster and verify the ConfigMap has appeared:
       ```bash
       kubectl --context=<remote-cluster-context> get configmap test-sync-data
       ```
    1.  Expected Result:
    - The `test-sync-data` ConfigMap created in the Source cluster should automatically appear in the Passive cluster within seconds.
    - If you update the ConfigMap in the Active cluster, the changes should reflect in the Passive cluster.
    - If you delete it from the Active cluster, it should be removed from the Passive cluster.
