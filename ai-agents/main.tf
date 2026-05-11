# Deploys the KubeAssist agent CR.
# Requires layer 2 (kagent CRDs + ModelConfig) to be applied first.
resource "kubectl_manifest" "kubagent" {
  server_side_apply = true
  yaml_body         = file("${path.module}/agent.yaml")
}
