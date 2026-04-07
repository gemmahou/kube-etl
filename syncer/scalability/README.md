# KRMSyncer Scalability Evaluation

This directory contains tools for evaluating the performance and scalability of the `krmsyncer` controller.

## Tools

### 1. `generate_resources.go`
A utility script that generates high volumes of KRM resources (specifically Google Config Connector / KCC resources) with valid `status.conditions`.
*   **Dynamic Timestamps**: Automatically sets `lastTransitionTime` to the current time.
*   **Diverse Types**: Supports ~50+ different KCC resource kinds.

Example usage
```bash
# Generate 100 ArtifactRegistryRepository resources:
go run generate_resources.go -count 100 -kinds ArtifactRegistryRepositor > ar_50.yaml
# Generate 100 total resources using a mix of 10 random kinds
go run generate_kcc.go -count 100 -num-kinds 10 > mix_10_kinds_100.yaml
```

### 2. `benchmark_sync.sh`
The primary automation script for running end-to-end performance benchmarks. It handles resource generation, multi-cluster synchronization, real-time progress tracking, and performance reporting.

## Benchmark Usage

### Multi-Cluster Synchronization Example
Measure how long it takes to sync resources from a Source cluster to a Destination cluster:
```bash
./scalability/benchmark_sync.sh \
  --count 500 \
  --num-kinds 10 \
  --source-context "gke_prod_us-central1_cluster-a" \
  --dest-context "gke_prod_us-west1_cluster-b" \
  --timeout 600
```

### Available Flags
| Flag | Description                                      | Default |
| :--- |:-------------------------------------------------| :--- |
| `-c, --count` | Total number of resources to sync.               | `50` |
| `-k, --kinds` | Comma-separated list of specific resource kinds. | `ArtifactRegistryRepository` |
| `-n, --num-kinds` | Pick N random kinds from the available pool.     | `0` (Disabled) |
| `-t, --timeout` | Max time (seconds) to wait for sync completion.  | `(count / 2) + 60` |
| `-s, --source-context`| Kubernetes context for the Source cluster.       | Current Context |
| `-d, --dest-context` | Kubernetes context for the Destination cluster.  | Current Context |
| `--namespace` | Namespace.                                       | `default` |

## How it Works

1.  **Suspension**: The script first suspends the `test-syncer` object in the destination cluster. This ensures that the controller does not begin syncing while resources are still being applied to the source cluster.
2.  **Resource Preparation**: Uses `generate_resources.go` to create a YAML manifest with unique names and fresh `lastTransitionTime` timestamps. 
    Apply generated resources to Source cluster.
4. **Setup Monitoring**: 
    *   Detects if the syncer is running in local or in GKE cluster.
    *   Automatically sets up a `kubectl port-forward` to the syncer pod if needed.
    *   Captures the initial `syncer_sync_success_total` Prometheus counter.
5.  **Synchronization & Timing**:
    *   Resumes the `test-syncer` by patching `suspend: false`.
    *   Starts the timer.
    *   Polls the `syncer_sync_success_total` Prometheus counter for progress.
6.  **Batch Latency**: Total time from when the syncer was resumed until 100% of resources are synchronized.
7.  **Cleanup**: 
    *   Automatically deletes all benchmarked resources from the Source cluster using the `batch-bench=true` label.
    *   The syncer will clean up benchmarked resources from the Destination cluster.
    *   Ensures the `test-syncer` is left in a resumed state.

## Interpreting Results

### Test setup
1. **Source Context**: `gke_cnrm-yuhou-2_us-central1_test-cluster-2`
2. **Destination Context**: `gke_cnrm-yuhou-2_us-west1_test-cluster-1`
3. **Scale**: 10, 100, 1000 resources across multiple kinds
4. **Notes**: 

   1. Disable the KCC controller in both test clusters to avoid unnecessary reconciliation overhead and potential failures. 
      We will manually set the resource status to `UpToDate` and update the `status.LastTransitionTime` with the 
      current timestamp. This prevents the system from triggering redundant GCP API calls and hitting project quota limits.  
   2. The timer triggers exactly when the syncer is resumed (`suspend: false`).
      Total batch latency represents the pure synchronization duration, excluding the time spent applying resources to the source cluster.

### Evaluation Case Study: Very Small Amount
```bash
./benchmark_sync.sh --count 10 --source-context "gke_cnrm-yuhou-2_us-central1_test-cluster-2" --dest-context "gke_cnrm-yuhou-2_us-west1_test-cluster-1" --timeout 30
--- Configuration ---
Source Context:   gke_cnrm-yuhou-2_us-central1_test-cluster-2
Dest Context:     gke_cnrm-yuhou-2_us-west1_test-cluster-1
Resource Count:   10
----------------------
Connecting to Destination Cluster...
Suspending syncer...
Applying resources...
Applying resources status...
Resuming syncer and starting timer...
Progress: [========================================>] 100% (10/10)
Done!
-------------------------------------------
Batch Latency: 232ms
Cleaning up...
```

### Evaluation Case Study: Small Amount
```bash
./benchmark_sync.sh --count 100 --source-context "gke_cnrm-yuhou-2_us-central1_test-cluster-2" --dest-context "gke_cnrm-yuhou-2_us-west1_test-cluster-1" --timeout 30
--- Configuration ---
Source Context:   gke_cnrm-yuhou-2_us-central1_test-cluster-2
Dest Context:     gke_cnrm-yuhou-2_us-west1_test-cluster-1
Resource Count:   100
----------------------
Connecting to Destination Cluster...
Suspending syncer...
Applying resources...
Applying resources status...
Resuming syncer and starting timer...
Progress: [========================================>] 100% (100/100)
Done!
-------------------------------------------
Batch Latency: 12656ms
Cleaning up...
```

### Evaluation Case Study: Small Amount Across Two Kinds
```bash
./benchmark_sync.sh --count 100 --kinds "EssentialContactsContact,ArtifactRegistryRepository" --source-context "gke_cnrm-yuhou-2_us-central1_test-cluster-2" --dest-context "gke_cnrm-yuhou-2_us-west1_test-cluster-1" --timeout 30
--- Configuration ---
Source Context:   gke_cnrm-yuhou-2_us-central1_test-cluster-2
Dest Context:     gke_cnrm-yuhou-2_us-west1_test-cluster-1
Resource Count:   100
----------------------
Connecting to Destination Cluster...
Suspending syncer...
Applying resources...
Applying resources status...
Resuming syncer and starting timer...
Progress: [========================================>] 100% (100/100)
Done!
-------------------------------------------
Batch Latency: 239ms
Cleaning up...
```

### Evaluation Case Study: Large Amount Across Two Kinds
```bash
./benchmark_sync.sh --count 1000 --kinds "EssentialContactsContact,ArtifactRegistryRepository" --source-context "gke_cnrm-yuhou-2_us-central1_test-cluster-2" --dest-context "gke_cnrm-yuhou-2_us-west1_test-cluster-1"
--- Configuration ---
Source Context:   gke_cnrm-yuhou-2_us-central1_test-cluster-2
Dest Context:     gke_cnrm-yuhou-2_us-west1_test-cluster-1
Resource Count:   1000
----------------------
Connecting to Destination Cluster...
Suspending syncer...
Applying resources...
Applying resources status...
Resuming syncer and starting timer...
Progress: [========================================>] 100% (1000/1000)
Done!
-------------------------------------------
Batch Latency: 26895ms
Cleaning up...
```
We can also view the logs for this specific batch sync case: https://screenshot.googleplex.com/3GMg3p2fQhmkM7U.png.

### Evaluation Case Study: Identify Failure
```bash
 ./benchmark_sync.sh --count 100 --kinds "EssentialContactsContact,ArtifactRegistryRepository" --source-context "gke_cnrm-yuhou-2_us-central1_test-cluster-2" --dest-context "gke_cnrm-yuhou-2_us-west1_test-cluster-1" --timeout 30
--- Configuration ---
Source Context:   gke_cnrm-yuhou-2_us-central1_test-cluster-2
Dest Context:     gke_cnrm-yuhou-2_us-west1_test-cluster-1
Resource Count:   100
----------------------
Connecting to Destination Cluster...
Suspending syncer...
Applying resources...
Applying resources status...
Resuming syncer and starting timer...
Progress: [====================>                    ] 51% (51/100)
Error: Timeout reached.
Cleaning up...
```

**Analysis:**
1.  **Latency Root Cause**: Since this was a cross-region sync, each individual resource sync incurred higher network 
    latency when calling the destination API server. 
2.  **Concurrency**: Increasing resource kinds enhances parallelism and improves performance. By using multiple
    kinds, the KRMSyncer controller spawns independent DynamicResourceReconciler instances. Each with its own 
    MaxConcurrentReconciles limit, effectively multiplying the system's overall concurrency and reducing batch 
    latency for the same total resource count.
3. **Potential Deviations**: The metrics polling interval (default 0.5s) and the time to fetch/parse Prometheus data from 
   the `/metrics` endpoint may introduce a slight measurement jitter. The reported latency is an upper bound.
