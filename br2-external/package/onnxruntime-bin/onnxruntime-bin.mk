################################################################################
#
# onnxruntime-bin
#
################################################################################

ONNXRUNTIME_BIN_VERSION = 1.32.0
ONNXRUNTIME_BIN_SITE = https://github.com/microsoft/onnxruntime/releases/download/v$(ONNXRUNTIME_BIN_VERSION)
ONNXRUNTIME_BIN_SOURCE = onnxruntime-linux-x64-$(ONNXRUNTIME_BIN_VERSION).tgz
ONNXRUNTIME_BIN_LICENSE = MIT
ONNXRUNTIME_BIN_LICENSE_FILES = LICENSE ThirdPartyNotices.txt
ONNXRUNTIME_BIN_INSTALL_STAGING = YES

define ONNXRUNTIME_BIN_INSTALL_STAGING_CMDS
	mkdir -p $(STAGING_DIR)/usr/include/onnxruntime $(STAGING_DIR)/usr/lib
	cp -a $(@D)/include/. $(STAGING_DIR)/usr/include/onnxruntime/
	cp -a $(@D)/lib/libonnxruntime.so* $(STAGING_DIR)/usr/lib/
endef

# Only the core library is installed. libonnxruntime_providers_shared.so
# is needed only for out-of-tree execution providers (CUDA, TensorRT,
# OpenVINO ...) which this CPU-only image deliberately excludes.
define ONNXRUNTIME_BIN_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib
	cp -a $(@D)/lib/libonnxruntime.so* $(TARGET_DIR)/usr/lib/
endef

$(eval $(generic-package))
