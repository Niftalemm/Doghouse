#!/usr/bin/env bash
set -euo pipefail

echo "==> Checking Datadog secrets..."
: "${DD_API_KEY:?DD_API_KEY not set (add a Codespaces secret)}"
: "${DD_SITE:?DD_SITE not set (add a Codespaces secret)}"

echo "==> Installing deps (kubectl, kind, helm, Go)..."
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release jq make golang

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSLo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# kind
if ! command -v kind >/dev/null 2>&1; then
  curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
  chmod +x /usr/local/bin/kind
fi

# helm
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> Starting Docker daemon (DinD)..."
sudo service docker start
sleep 2

echo "==> Creating kind cluster..."
(kind create cluster --name doghouse || true)
kubectl config use-context kind-doghouse

echo "==> Installing Datadog Operator..."
kubectl create ns datadog --dry-run=client -o yaml | kubectl apply -f -
helm repo add datadog https://helm.datadoghq.com
helm repo update
helm install datadog-operator datadog/datadog-operator -n datadog --wait

echo "==> Creating Datadog API key secret..."
kubectl -n datadog create secret generic datadog-secret --from-literal api-key="${DD_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying DatadogAgent CR..."
cat > datadogagent.yaml <<'YAML'
kind: DatadogAgent
apiVersion: datadoghq.com/v2alpha1
metadata:
  name: datadog
  namespace: datadog
spec:
  global:
    site: __DD_SITE__
    clusterName: doghouse-kind
    credentials:
      apiSecret:
        secretName: datadog-secret
        keyName: api-key
    tags:
      - env:dev
  features:
    apm:
      enabled: true
    logCollection:
      enabled: true
      containerCollectAll: true
    kubeStateMetricsCore:
      enabled: true
YAML
sed -i "s#__DD_SITE__#${DD_SITE}#g" datadogagent.yaml
kubectl apply -f datadogagent.yaml

echo "==> Waiting for Datadog pods..."
kubectl -n datadog rollout status deploy/datadog-cluster-agent --timeout=180s || true
kubectl -n datadog get pods -o wide

echo "==> Writing DogHouse Go app..."
mkdir -p doghouse/cmd/api doghouse/cmd/worker deploy/k8s
cat > doghouse/go.mod <<'GOMOD'
module github.com/you/doghouse
go 1.22
require (
	github.com/DataDog/datadog-go/v5 v5.5.0
	github.com/nats-io/nats.go v1.37.0
	gopkg.in/DataDog/dd-trace-go.v1 v1.68.0
)
GOMOD

cat > doghouse/cmd/api/main.go <<'GO'
package main

import (
  "log"
  "net/http"
  "os"
  "time"

  "github.com/DataDog/datadog-go/v5/statsd"
  ddtracer "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
  httptrace "gopkg.in/DataDog/dd-trace-go.v1/contrib/net/http"
  "github.com/nats-io/nats.go"
)

func getenv(k, d string) string { if v := os.Getenv(k); v != "" { return v }; return d }

func main() {
  service := getenv("DD_SERVICE", "doghouse-api")
  env := getenv("DD_ENV", "dev")
  version := getenv("DD_VERSION", "0.1.0")

  ddtracer.Start(ddtracer.WithService(service), ddtracer.WithEnv(env), ddtracer.WithServiceVersion(version))
  defer ddtracer.Stop()

  stats, _ := statsd.New(getenv("DOGSTATSD_ADDR", "127.0.0.1:8125"), statsd.WithNamespace("doghouse."))

  natsURL := getenv("NATS_URL", "nats://nats.obs.svc.cluster.local:4222")
  nc, err := nats.Connect(natsURL)
  if err != nil { log.Fatalf("nats: %v", err) }
  defer nc.Drain()

  mux := http.NewServeMux()
  mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request){ w.WriteHeader(200) })
  mux.HandleFunc("/adopt", func(w http.ResponseWriter, r *http.Request) {
    q := r.URL.Query()
    slow := q.Get("slow") == "1"
    giveErr := q.Get("error") == "1"
    start := time.Now()

    if slow { time.Sleep(600 * time.Millisecond) }
    if giveErr {
      w.WriteHeader(500)
      w.Write([]byte(`{"error":"oops"}`))
      stats.Incr("adoptions.error", nil, 1)
      log.Printf(`{"msg":"adopt","status":500,"slow":%t,"ms":%d}`, slow, time.Since(start).Milliseconds())
      return
    }

    nc.Publish("adoptions", []byte(`{"dogId":"42"}`))
    stats.Incr("adoptions.count", []string{"breed:mutt"}, 1)
    w.WriteHeader(200); w.Write([]byte(`{"status":"adopted"}`))
    log.Printf(`{"msg":"adopt","status":200,"slow":%t,"ms":%d}`, slow, time.Since(start).Milliseconds())
  })

  log.Printf(`{"msg":"api start","env":"%s","version":"%s"}`, env, version)
  http.ListenAndServe(":8080", httptrace.WrapHandler(mux, service))
}
GO

cat > doghouse/cmd/worker/main.go <<'GO'
package main

import (
  "log"
  "math/rand"
  "time"

  "github.com/DataDog/datadog-go/v5/statsd"
  ddtracer "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
  "github.com/nats-io/nats.go"
)

func getenv(k, d string) string { if v := os.Getenv(k); v != "" { return v }; return d }

func main() {
  ddtracer.Start(ddtracer.WithService("doghouse-worker"), ddtracer.WithEnv("dev"), ddtracer.WithServiceVersion("0.1.0"))
  defer ddtracer.Stop()

  stats, _ := statsd.New(getenv("DOGSTATSD_ADDR", "127.0.0.1:8125"), statsd.WithNamespace("doghouse."))

  natsURL := getenv("NATS_URL", "nats://nats.obs.svc.cluster.local:4222")
  nc, err := nats.Connect(natsURL)
  if err != nil { log.Fatalf("nats: %v", err) }
  defer nc.Drain()

  _, _ = nc.Subscribe("adoptions", func(m *nats.Msg) {
    start := time.Now()
    time.Sleep(time.Duration(50+rand.Intn(150)) * time.Millisecond)
    stats.Incr("worker.processed", nil, 1)
    stats.Timing("worker.duration_ms", time.Since(start), nil, 1)
    log.Printf(`{"msg":"processed","bytes":%d,"ms":%d}`, len(m.Data), time.Since(start).Milliseconds())
  })

  log.Printf(`{"msg":"worker start"}`)
  select {}
}
GO

echo "==> K8s manifests (obs namespace, NATS, API, Worker, HPA)..."
cat > deploy/k8s/all.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata: { name: obs }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: nats, namespace: obs, labels: { app: nats } }
spec:
  replicas: 1
  selector: { matchLabels: { app: nats } }
  template:
    metadata: { labels: { app: nats } }
    spec:
      containers:
      - name: nats
        image: nats:2
        ports: [{ containerPort: 4222 }]
---
apiVersion: v1
kind: Service
metadata: { name: nats, namespace: obs }
spec:
  selector: { app: nats }
  ports:
  - { name: client, port: 4222, targetPort: 4222 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: doghouse-api
  namespace: obs
  labels: { app: doghouse-api }
spec:
  replicas: 2
  selector: { matchLabels: { app: doghouse-api } }
  template:
    metadata:
      labels: { app: doghouse-api }
      annotations:
        ad.datadoghq.com/doghouse-api.logs: |
          [{"source":"go","service":"doghouse-api"}]
    spec:
      containers:
      - name: api
        image: doghouse-api:0.1.0
        ports: [{ containerPort: 8080 }]
        env:
        - { name: DD_SERVICE, value: doghouse-api }
        - { name: DD_ENV, value: dev }
        - { name: DD_VERSION, value: "0.1.0" }
        - { name: NATS_URL, value: "nats://nats.obs.svc.cluster.local:4222" }
        - name: HOST_IP
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - name: DOGSTATSD_ADDR
          value: "$(HOST_IP):8125"
        - name: DD_AGENT_HOST
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - { name: DD_TRACE_AGENT_PORT, value: "8126" }
        resources:
          requests: { cpu: "100m", memory: "128Mi" }
          limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata: { name: doghouse-api, namespace: obs }
spec:
  selector: { app: doghouse-api }
  ports:
  - { name: http, port: 80, targetPort: 8080 }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: doghouse-api-hpa, namespace: obs }
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: doghouse-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: doghouse-worker
  namespace: obs
  labels: { app: doghouse-worker }
spec:
  replicas: 1
  selector: { matchLabels: { app: doghouse-worker } }
  template:
    metadata:
      labels: { app: doghouse-worker }
      annotations:
        ad.datadoghq.com/doghouse-worker.logs: |
          [{"source":"go","service":"doghouse-worker"}]
    spec:
      containers:
      - name: worker
        image: doghouse-worker:0.1.0
        env:
        - { name: DD_SERVICE, value: doghouse-worker }
        - { name: DD_ENV, value: dev }
        - { name: DD_VERSION, value: "0.1.0" }
        - { name: NATS_URL, value: "nats://nats.obs.svc.cluster.local:4222" }
        - name: HOST_IP
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - name: DOGSTATSD_ADDR
          value: "$(HOST_IP):8125"
        - name: DD_AGENT_HOST
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - { name: DD_TRACE_AGENT_PORT, value: "8126" }
        resources:
          requests: { cpu: "50m", memory: "64Mi" }
          limits:   { cpu: "250m", memory: "128Mi" }
YAML

echo "==> Building images..."
docker build -t doghouse-api:0.1.0 -f Dockerfile.api .
docker build -t doghouse-worker:0.1.0 -f Dockerfile.worker .

echo "==> Loading images into kind..."
kind load docker-image doghouse-api:0.1.0 --name doghouse
kind load docker-image doghouse-worker:0.1.0 --name doghouse

echo "==> Deploying app..."
kubectl apply -f deploy/k8s/all.yaml
kubectl -n obs rollout status deploy/doghouse-api --timeout=180s || true
kubectl -n obs rollout status deploy/doghouse-worker --timeout=180s || true

echo
echo "==> Port-forward to test:"
echo "kubectl -n obs port-forward svc/doghouse-api 8080:80"
echo "curl http://localhost:8080/adopt"
echo "curl 'http://localhost:8080/adopt?slow=1'"
echo "curl 'http://localhost:8080/adopt?error=1' || true"
