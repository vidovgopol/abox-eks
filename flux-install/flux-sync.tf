# ── Flux sync source — OCI artifact pushed by the GitHub workflow ─────────────

resource "kubectl_manifest" "flux_oci_repository" {
  yaml_body = yamlencode({
    apiVersion = "source.toolkit.fluxcd.io/v1beta2"
    kind       = "OCIRepository"
    metadata = {
      name      = "abox-eks-releases"
      namespace = "flux-system"
    }
    spec = {
      interval = "5m"
      url      = var.releases_oci_url
      ref = {
        tag = "latest"
      }
    }
  })
  depends_on = [helm_release.flux_instance]
}

# ── Flux Kustomization — applies releases/agents/ from the OCI artifact ───────

resource "kubectl_manifest" "flux_kustomization" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "abox-eks-agents"
      namespace = "flux-system"
    }
    spec = {
      interval = "5m"
      sourceRef = {
        kind = "OCIRepository"
        name = "abox-eks-releases"
      }
      path  = "./"
      prune = true
    }
  })
  depends_on = [kubectl_manifest.flux_oci_repository]
}
