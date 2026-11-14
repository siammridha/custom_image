# Build the Wyse image:   make
# Other Buildroot goals:  make menuconfig / make savedefconfig / make linux-menuconfig
# Output image:           $(OUT)/images/disk.img (kept off the virtiofs workspace)
BR  := $(CURDIR)/buildroot
EXT := $(CURDIR)/external
OUT := $(or $(WYSE_OUT),/home/vscode/wyse-build/output)
DL  := $(or $(WYSE_DL),/home/vscode/wyse-build/dl)
# Run Buildroot as a top-level make (as a sub-make it corrupts its
# generated br2-external files).
BRMAKE = env -u MAKELEVEL -u MAKEFLAGS -u MFLAGS BR2_DL_DIR=$(DL) \
	make -C $(BR) BR2_EXTERNAL=$(EXT) O=$(OUT)
GOALS := $(or $(MAKECMDGOALS),all)
PATCH := $(CURDIR)/patches/buildroot-wyse.patch

.PHONY: $(GOALS)
$(firstword $(GOALS)):
	@# buildroot/ is a git submodule (Buildroot 2026.02.3, unchanged). Our
	@# edits to it are in patches/buildroot-wyse.patch, applied once here.
	@test -f $(BR)/Makefile || git -C $(CURDIR) submodule update --init buildroot
	@git -C $(BR) apply --reverse --check $(PATCH) 2>/dev/null || \
		{ echo "Applying $(notdir $(PATCH))"; git -C $(BR) apply $(PATCH); }
ifeq ($(GOALS),wyse_defconfig)
	$(BRMAKE) wyse_defconfig
else
	@test -f $(OUT)/.config || $(BRMAKE) wyse_defconfig
	$(BRMAKE) $(filter-out all,$(GOALS))
endif

$(wordlist 2,99,$(GOALS)):
	@:
