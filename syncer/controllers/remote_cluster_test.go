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
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	krmv1alpha1 "github.com/gke-labs/kube-etl/syncer/api/v1alpha1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/oauth2"
)

func gkeRemote(project, location, name string) *krmv1alpha1.RemoteConfig {
	return &krmv1alpha1.RemoteConfig{GKECluster: &krmv1alpha1.GKECluster{Project: project, Location: location, Name: name}}
}

func TestRemoteClusterKey(t *testing.T) {
	key, err := remoteClusterKey(gkeRemote("p", "us-central1", "c"))
	require.NoError(t, err)
	assert.Equal(t, "projects/p/locations/us-central1/clusters/c", key)

	for _, remote := range []*krmv1alpha1.RemoteConfig{
		nil,
		{},
		gkeRemote("", "l", "c"),
		gkeRemote("p", "", "c"),
		gkeRemote("p", "l", ""),
	} {
		_, err := remoteClusterKey(remote)
		assert.Error(t, err, "remote %+v", remote)
	}
}

func TestGKEConfigProvider(t *testing.T) {
	const token = "test-token"
	caPEM := []byte("-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")

	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if got := r.Header.Get("Authorization"); got != "Bearer "+token {
			http.Error(w, "unauthorized: "+got, http.StatusUnauthorized)
			return
		}
		if r.URL.Path != "/v1/projects/p/locations/us-central1/clusters/c" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		fmt.Fprintf(w, `{"name":"c","endpoint":"1.2.3.4","masterAuth":{"clusterCaCertificate":%q}}`,
			base64.StdEncoding.EncodeToString(caPEM))
	}))
	defer srv.Close()

	p := &GKEConfigProvider{
		TokenSource:          oauth2.StaticTokenSource(&oauth2.Token{AccessToken: token}),
		ContainerAPIEndpoint: srv.URL,
	}
	ctx := context.Background()

	cfg, err := p.RESTConfig(ctx, gkeRemote("p", "us-central1", "c"))
	require.NoError(t, err)
	assert.Equal(t, "https://1.2.3.4", cfg.Host)
	assert.Equal(t, caPEM, cfg.CAData)
	assert.Nil(t, cfg.ExecProvider)
	require.NotNil(t, cfg.WrapTransport)

	// The transport injects the Google OAuth token into requests to the cluster.
	var gotAuth string
	rt := cfg.WrapTransport(roundTripperFunc(func(r *http.Request) (*http.Response, error) {
		gotAuth = r.Header.Get("Authorization")
		return &http.Response{StatusCode: http.StatusOK, Body: http.NoBody, Request: r}, nil
	}))
	req, err := http.NewRequest(http.MethodGet, "https://1.2.3.4/api", nil)
	require.NoError(t, err)
	_, err = rt.RoundTrip(req)
	require.NoError(t, err)
	assert.Equal(t, "Bearer "+token, gotAuth)

	// Cluster info is cached.
	_, err = p.RESTConfig(ctx, gkeRemote("p", "us-central1", "c"))
	require.NoError(t, err)
	assert.Equal(t, int32(1), calls.Load())

	// API errors are surfaced.
	_, err = p.RESTConfig(ctx, gkeRemote("p", "us-central1", "missing"))
	assert.ErrorContains(t, err, "404")
}

func TestGKEClusterEndpoints(t *testing.T) {
	caPEM := []byte("fake-ca")
	ca := base64.StdEncoding.EncodeToString(caPEM)

	full := &gkeCluster{}
	full.Endpoint = "1.2.3.4"
	full.MasterAuth.ClusterCACertificate = ca
	full.PrivateClusterConfig.PrivateEndpoint = "10.0.0.2"
	full.ControlPlaneEndpointsConfig.DNSEndpointConfig.Endpoint = "gke-abc.us-central1.gke.goog"

	newIPEndpoints := &gkeCluster{}
	newIPEndpoints.MasterAuth.ClusterCACertificate = ca
	newIPEndpoints.ControlPlaneEndpointsConfig.IPEndpointsConfig.PrivateEndpoint = "10.0.0.3"

	for _, tc := range []struct {
		name     string
		cluster  *gkeCluster
		endpoint krmv1alpha1.GKEEndpoint
		wantHost string
		wantCA   []byte
		wantErr  string
	}{
		{name: "unset", cluster: full, endpoint: "", wantHost: "https://1.2.3.4", wantCA: caPEM},
		{name: "default", cluster: full, endpoint: krmv1alpha1.GKEEndpointDefault, wantHost: "https://1.2.3.4", wantCA: caPEM},
		{name: "dns uses system roots", cluster: full, endpoint: krmv1alpha1.GKEEndpointDNS, wantHost: "https://gke-abc.us-central1.gke.goog"},
		{name: "private ip (privateClusterConfig)", cluster: full, endpoint: krmv1alpha1.GKEEndpointPrivateIP, wantHost: "https://10.0.0.2", wantCA: caPEM},
		{name: "private ip (ipEndpointsConfig)", cluster: newIPEndpoints, endpoint: krmv1alpha1.GKEEndpointPrivateIP, wantHost: "https://10.0.0.3", wantCA: caPEM},
		{name: "dns not enabled", cluster: newIPEndpoints, endpoint: krmv1alpha1.GKEEndpointDNS, wantErr: "DNS endpoint is not enabled"},
		{name: "no default endpoint", cluster: newIPEndpoints, endpoint: krmv1alpha1.GKEEndpointDefault, wantErr: "no endpoint"},
		{name: "no private endpoint", cluster: &gkeCluster{}, endpoint: krmv1alpha1.GKEEndpointPrivateIP, wantErr: "no private endpoint"},
		{name: "unknown", cluster: full, endpoint: "Bogus", wantErr: "unsupported endpoint"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := tc.cluster.restConfig(tc.endpoint)
			if tc.wantErr != "" {
				assert.ErrorContains(t, err, tc.wantErr)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tc.wantHost, cfg.Host)
			assert.Equal(t, tc.wantCA, cfg.CAData)
		})
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
