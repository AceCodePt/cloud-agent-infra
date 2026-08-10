locals {
  startup_script = replace(
    replace(
      replace(
        replace(
          replace(
            file("${path.module}/../../scripts/templates/startup.debian.sh"),
          "__INSTANCE__", var.instance_name),
        "__USER__", var.ssh_user),
      "__AUTHKEY__", var.tailscale_auth_key),
    "__DATA_LABEL__", "cloud-agent-data"),
    "__DATA_DEV__", "/dev/disk/by-id/google-data"
  )
}
