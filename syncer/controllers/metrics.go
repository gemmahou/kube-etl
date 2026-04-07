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
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	// SyncLatency records the total time from resource creation in source to sync finish in destination.
	SyncLatency = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "syncer_sync_latency_seconds",
			Help:    "Total time from resource creation/update in source to sync finish in destination in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"namespace", "group", "version", "kind", "success"},
	)

	// SyncSuccessTotal is a simple counter of successful sync events per namespace.
	SyncSuccessTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "syncer_sync_success_total",
			Help: "Total number of successful resource synchronizations.",
		},
		[]string{"namespace"},
	)
)

func init() {
	// Register custom metrics with the global prometheus registry
	metrics.Registry.MustRegister(SyncLatency, SyncSuccessTotal)
}
