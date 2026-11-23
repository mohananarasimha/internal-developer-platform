{{/*
Service name helper.
*/}}
{{- define "web-service.fullname" -}}
{{- .Values.metadata.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard ownership and Kubernetes recommended labels.
*/}}
{{- define "web-service.labels" -}}
app.kubernetes.io/name: {{ include "web-service.fullname" . }}
app.kubernetes.io/instance: {{ include "web-service.fullname" . }}
app.kubernetes.io/managed-by: idp-cli
idp.local/owner: {{ .Values.metadata.owner }}
idp.local/tier: {{ .Values.metadata.tier }}
idp.local/environment: {{ .Values.environment }}
{{- end -}}

{{/*
Immutable pod selector labels.
*/}}
{{- define "web-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "web-service.fullname" . }}
app.kubernetes.io/instance: {{ include "web-service.fullname" . }}
{{- end -}}
