# Build the image for one model:  make MODEL=3040   (or MODEL=5020)
# Development build (extra BusyBox commands, busybox-dev.fragment):
#                                 make MODEL=3040 DEV=1
# Or run ./build.sh, which asks for the model.
# Other Buildroot goals:  make MODEL=3040 menuconfig / linux-menuconfig / ...
# Output image:           $(OUT)/images/disk.img (kept off the virtiofs workspace)
MODELS := 3040 5020
ifeq ($(filter $(MODELS),$(MODEL)),)
$(error Set MODEL to one of: $(MODELS)  (e.g. make MODEL=3040))
endif
BR  := $(CURDIR)/buildroot
EXT := $(CURDIR)/external
# One output folder per model (different kernels); downloads are shared.
OUT := $(or $(WYSE_OUT),/home/vscode/wyse-build/output-$(MODEL))
DL  := $(or $(WYSE_DL),/home/vscode/wyse-build/dl)
# Packages built at the same time (each uses up to BR2_JLEVEL cores). No new
# package starts while the load is above the number of cores.
JOBS ?= 6
# Run Buildroot as a top-level make (as a sub-make it corrupts its
# generated br2-external files).
# XZ_DEFAULTS=-T1: xz unpacks with one thread. With threads, one gcc archive
# took 1.35 GB of RAM (66 MB with one); three at once ran out of memory.
BRMAKE = env -u MAKELEVEL -u MAKEFLAGS -u MFLAGS BR2_DL_DIR=$(DL) XZ_DEFAULTS=-T1 \
	make -j$(JOBS) -l$(shell nproc) -C $(BR) BR2_EXTERNAL=$(EXT) O=$(OUT)
GOALS := $(or $(MAKECMDGOALS),all)
PATCH := $(CURDIR)/patches/buildroot-wyse.patch
# The model's config: wyse_defconfig plus the model's kernel fragment, the
# model name passed to post-build.sh, and BusyBox's development fragment.
DEFCONFIG := $(OUT)/wyse-$(MODEL)_defconfig
# Development builds copy busybox-dev.fragment here; production builds leave
# it empty. Written only when it changes: a newer file makes
# Buildroot rebuild BusyBox.
BBFRAG := $(OUT)/busybox-build.fragment
bb_fragment = mkdir -p $(OUT) && \
	$(if $(filter 1,$(DEV)),cat $(EXT)/board/wyse/busybox-dev.fragment,printf '') \
		> $(BBFRAG).new && \
	{ cmp -s $(BBFRAG).new $(BBFRAG) && rm $(BBFRAG).new || mv $(BBFRAG).new $(BBFRAG); }
model_defconfig = mkdir -p $(OUT) && \
	{ cat $(EXT)/configs/wyse_defconfig; \
	  echo 'BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$$(BR2_EXTERNAL_WYSE_PATH)/board/wyse/linux.fragment $$(BR2_EXTERNAL_WYSE_PATH)/board/wyse/linux-$(MODEL).fragment"'; \
	  echo 'BR2_ROOTFS_POST_SCRIPT_ARGS="$(MODEL)"'; \
	  echo 'BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES="$(BBFRAG)"'; \
	  echo 'BR2_TARGET_GENERIC_ISSUE="wyse-$(MODEL)"'; } > $(DEFCONFIG) && \
	$(BRMAKE) defconfig BR2_DEFCONFIG=$(DEFCONFIG)

.PHONY: $(GOALS)
$(firstword $(GOALS)):
	@# buildroot/ is a git submodule (Buildroot 2026.08.2, unchanged). Our
	@# edits to it are in patches/buildroot-wyse.patch: applied here before
	@# Buildroot runs and taken out again when it ends (also when it fails),
	@# so buildroot/ shows no changes between builds.
	@test -f $(BR)/Makefile || git -C $(CURDIR) submodule update --init buildroot
	@git -C $(BR) apply --reverse --check $(PATCH) 2>/dev/null || \
		{ echo "Applying $(notdir $(PATCH))"; git -C $(BR) apply $(PATCH); }
	@trap 'git -C $(BR) apply --reverse $(PATCH)' EXIT; \
	$(bb_fragment) && \
	$(if $(filter defconfig,$(GOALS)),$(model_defconfig), \
	{ [ $(OUT)/.config -nt $(EXT)/configs/wyse_defconfig ] || { $(model_defconfig); }; } && \
	$(BRMAKE) $(filter-out all,$(GOALS)))

$(wordlist 2,99,$(GOALS)):
	@:
