################################################################################
#
# netbird
#
################################################################################

NETBIRD_VERSION = 0.83.1
NETBIRD_SITE = $(call github,netbirdio,netbird,v$(NETBIRD_VERSION))
NETBIRD_LICENSE = BSD-3-Clause
NETBIRD_LICENSE_FILES = LICENSE
NETBIRD_GOMOD = github.com/netbirdio/netbird
NETBIRD_BUILD_TARGETS = client
NETBIRD_BIN_NAME = netbird
# Same build as upstream's release (.goreleaser.yaml, id "netbird").
NETBIRD_TAGS = load_wgnt_from_rsrc
NETBIRD_LDFLAGS = -X github.com/netbirdio/netbird/version.version=$(NETBIRD_VERSION)
NETBIRD_GO_ENV = CGO_ENABLED=0

define NETBIRD_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_TUN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIREGUARD)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_TABLES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_NAT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_MASQ)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_CT)
endef

$(eval $(golang-package))
