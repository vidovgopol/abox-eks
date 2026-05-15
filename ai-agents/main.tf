resource "kubectl_manifest" "mcp_website_fetcher" {
  yaml_body = file("${path.module}/mcp-website-fetcher.yaml")
}

# Webpage fetcher agent
resource "kubectl_manifest" "agent_fetch" {
  server_side_apply = true
  yaml_body         = file("${path.module}/agent-fetch.yaml")
  depends_on        = [kubectl_manifest.mcp_website_fetcher]
}
