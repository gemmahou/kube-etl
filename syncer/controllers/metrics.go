// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package controllers

import (
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	// FailedObjects is the number of objects whose latest sync attempt failed,
	// partitioned by GVK. An object is counted from its first failed attempt until it
	// syncs successfully, however many times it is retried in between.
	FailedObjects = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "syncer_failed_objects",
			Help: "Number of objects whose latest sync attempt failed, partitioned by GVK.",
		},
		[]string{"group", "version", "kind"},
	)

	// SetupFailed is the number of KRMSyncers whose latest setup attempt (API discovery,
	// connecting to the remote cluster, starting watches) failed. With a single
	// KRMSyncer this is 0 or 1.
	SetupFailed = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "syncer_setup_failed",
			Help: "Number of KRMSyncers whose latest setup attempt failed.",
		},
	)
)

func init() {
	metrics.Registry.MustRegister(FailedObjects, SetupFailed)
}

func failedObjectsGauge(gvk schema.GroupVersionKind) prometheus.Gauge {
	return FailedObjects.WithLabelValues(gvk.Group, gvk.Version, gvk.Kind)
}

// failureTracker tracks which objects are currently failing and keeps a gauge equal
// to their number: an object is added on a failed attempt and removed on success, so
// repeated failures of the same object count once.
//
// A nil *failureTracker ignores all updates.
type failureTracker struct {
	gauge prometheus.Gauge

	mu     sync.Mutex
	failed map[types.NamespacedName]struct{}
}

func newFailureTracker(gauge prometheus.Gauge) *failureTracker {
	return &failureTracker{gauge: gauge, failed: make(map[types.NamespacedName]struct{})}
}

// markFailed records that the latest attempt for key failed.
func (t *failureTracker) markFailed(key types.NamespacedName) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.failed[key]; !ok {
		t.failed[key] = struct{}{}
		t.gauge.Inc()
	}
}

// markSucceeded records that the latest attempt for key succeeded, or that key no
// longer needs syncing (e.g. it was deleted).
func (t *failureTracker) markSucceeded(key types.NamespacedName) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.failed[key]; ok {
		delete(t.failed, key)
		t.gauge.Dec()
	}
}
