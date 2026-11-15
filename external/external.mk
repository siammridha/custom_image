include $(sort $(wildcard $(BR2_EXTERNAL_WYSE_PATH)/package/*/*.mk))

# Buildroot vendors Go modules with GOPROXY=direct, which clones each
# module's whole git repo (aws-sdk-go-v2 for Tailscale took over an hour and
# did not finish). The Go module proxy serves the same module files.
GO_MODULE_PROXY = GOPROXY=https://proxy.golang.org,direct
TAILSCALE_GO_ENV += $(GO_MODULE_PROXY)
NETBIRD_GO_ENV += $(GO_MODULE_PROXY)

# Leave out Tailscale's AWS state store (we keep state in /persist).
TAILSCALE_TAGS += ts_omit_aws
