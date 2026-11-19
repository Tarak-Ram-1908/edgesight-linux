################################################################################
#
# edgesightd
#
################################################################################

EDGESIGHTD_VERSION = 1.0
EDGESIGHTD_SITE = $(BR2_EXTERNAL_EDGESIGHT_PATH)/../app/edgesightd
EDGESIGHTD_SITE_METHOD = local
EDGESIGHTD_LICENSE = MIT
EDGESIGHTD_LICENSE_FILES = LICENSE
EDGESIGHTD_DEPENDENCIES = jpeg mosquitto libseccomp

ifeq ($(BR2_PACKAGE_EDGESIGHTD_ORT),y)
EDGESIGHTD_DEPENDENCIES += onnxruntime-bin
EDGESIGHTD_CONF_OPTS += -DWITH_ORT=ON
else
EDGESIGHTD_CONF_OPTS += -DWITH_ORT=OFF
endif

ifeq ($(BR2_PACKAGE_EDGESIGHTD_TFLITE),y)
EDGESIGHTD_DEPENDENCIES += tensorflow-lite
EDGESIGHTD_CONF_OPTS += -DWITH_TFLITE=ON
else
EDGESIGHTD_CONF_OPTS += -DWITH_TFLITE=OFF
endif

$(eval $(cmake-package))
