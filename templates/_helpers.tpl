{{/*
Expand the name of the chart.
*/}}
{{- define "insurguard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "insurguard.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "insurguard.labels" -}}
helm.sh/chart: {{ include "insurguard.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: insurguard
{{- end }}

{{/*
Selector labels for a component
*/}}
{{- define "insurguard.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
NGC image pull secret name
*/}}
{{- define "insurguard.imagePullSecretName" -}}
{{ include "insurguard.fullname" . }}-ngc-pull
{{- end }}

{{/*
NVIDIA API secret name
*/}}
{{- define "insurguard.nvidiaSecretName" -}}
{{ include "insurguard.fullname" . }}-nvidia-api
{{- end }}

{{/*
OpenShift SecurityContext for non-root containers
*/}}
{{- define "insurguard.securityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
OpenShift container-level SecurityContext
*/}}
{{- define "insurguard.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: [ "ALL" ]
{{- end }}

{{/*
TopologySpreadConstraints — spread GPU pods across nodes (maxSkew 1)
*/}}
{{- define "insurguard.gpuTopologySpread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        insurguard/gpu-workload: "true"
{{- end }}

{{/*
Node selector — pins ALL workloads (GPU and non-GPU) to nodes with the given nvidia.com/gpu.product label.
This keeps the whole release on a single GPU pool so non-GPU pods don't drift onto other nodes.
Override at install time with --set gpu.product=<value>
  L40S:    --set gpu.product=NVIDIA-L40S-SHARED
  RTX6000: --set gpu.product=NVIDIA-RTX-PRO-6000-Blackwell-Server-Edition-SHARED
*/}}
{{- define "insurguard.gpuNodeSelector" -}}
{{- if .Values.gpu.product }}
nodeSelector:
  nvidia.com/gpu.product: {{ .Values.gpu.product | quote }}
{{- end }}
{{- end }}

{{/*
Per-component node selector — same as insurguard.gpuNodeSelector, but lets a
single component override the global gpu.product (e.g. pin one pod to an L40S
pool when its image lacks kernels for the global Blackwell node).
Pass the root context as .root and the override string as .product.
Falls back to the global .Values.gpu.product when .product is empty.
*/}}
{{- define "insurguard.gpuNodeSelectorFor" -}}
{{- $product := .product | default .root.Values.gpu.product }}
{{- if $product }}
nodeSelector:
  nvidia.com/gpu.product: {{ $product | quote }}
{{- end }}
{{- end }}


{{/*
Anti-affinity — prevent heavy NIM services from landing on the same node.
Pass the component name as .component in the context.
*/}}
{{- define "insurguard.nimAntiAffinity" -}}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: insurguard/nim-heavy
                operator: In
                values: [ "true" ]
              - key: app.kubernetes.io/name
                operator: NotIn
                values: [ "{{ .component }}" ]
          topologyKey: kubernetes.io/hostname
{{- end }}
