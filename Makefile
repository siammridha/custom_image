# Build the image for one model:  make MODEL=3040   (or MODEL=5020)
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
# The model's config: wyse_defconfig plus the model's kernel fragment, and
# the model name passed to post-build.sh (written to /etc/wyse/model).
DEFCONFIG := $(OUT)/wyse-$(MODEL)_defconfig
model_defconfig = mkdir -p $(OUT) && \
	{ cat $(EXT)/configs/wyse_defconfig; \
	  echo 'BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$$(BR2_EXTERNAL_WYSE_PATH)/board/wyse/linux.fragment $$(BR2_EXTERNAL_WYSE_PATH)/board/wyse/linux-$(MODEL).fragment"'; \
	  echo 'BR2_ROOTFS_POST_SCRIPT_ARGS="$(MODEL)"'; \
	  echo 'BR2_TARGET_GENERIC_ISSUE="wyse-$(MODEL)"'; } > $(DEFCONFIG) && \
	$(BRMAKE) defconfig BR2_DEFCONFIG=$(DEFCONFIG)

.PHONY: $(GOALS)
$(firstword $(GOALS)):
	@# buildroot/ is a git submodule (Buildroot 2026.02.3, unchanged). Our
	@# edits to it are in patches/buildroot-wyse.patch, applied once here.
	@test -f $(BR)/Makefile || git -C $(CURDIR) submodule update --init buildroot
	@git -C $(BR) apply --reverse --check $(PATCH) 2>/dev/null || \
		{ echo "Applying $(notdir $(PATCH))"; git -C $(BR) apply $(PATCH); }
ifeq ($(GOALS),defconfig)
	$(model_defconfig)
else
	@# (Re)make the config when missing or older than wyse_defconfig.
	@[ $(OUT)/.config -nt $(EXT)/configs/wyse_defconfig ] || { $(model_defconfig); }
	$(BRMAKE) $(filter-out all,$(GOALS))
endif

$(wordlist 2,99,$(GOALS)):
	@:
