################################################################################
#
# edgesight-models
#
################################################################################

EDGESIGHT_MODELS_VERSION = 1
# Main "source": TensorFlow's uint8-quantised SSD-MobileNet-v1 (COCO)
EDGESIGHT_MODELS_SITE = https://storage.googleapis.com/download.tensorflow.org/models/tflite
EDGESIGHT_MODELS_SOURCE = coco_ssd_mobilenet_v1_1.0_quant_2018_06_29.zip
EDGESIGHT_MODELS_LICENSE = Apache-2.0 (models), Flickr CC licences (COCO sample images)
EDGESIGHT_MODELS_LICENSE_FILES = NOTICE

# ONNX Model Zoo, pinned to a commit (not "main") for reproducibility
EDGESIGHT_MODELS_ONNX_SITE = https://github.com/onnx/models/raw/c5cae0f1942c8d7727372c7b1f6b485aa39e4421/validated/vision/object_detection_segmentation/ssd-mobilenetv1/model
EDGESIGHT_MODELS_COCO_SITE = http://images.cocodataset.org/val2017
EDGESIGHT_MODELS_SAMPLES = \
	000000039769 000000000139 000000000785 000000000872 \
	000000397133 000000037777 000000252219 000000087038

EDGESIGHT_MODELS_EXTRA_DOWNLOADS = \
	$(EDGESIGHT_MODELS_ONNX_SITE)/ssd_mobilenet_v1_12.onnx \
	$(EDGESIGHT_MODELS_ONNX_SITE)/ssd_mobilenet_v1_12-int8.onnx \
	$(foreach s,$(EDGESIGHT_MODELS_SAMPLES),$(EDGESIGHT_MODELS_COCO_SITE)/$(s).jpg)

define EDGESIGHT_MODELS_EXTRACT_CMDS
	cd $(@D) && unzip -o -q $(EDGESIGHT_MODELS_DL_DIR)/$(EDGESIGHT_MODELS_SOURCE)
	cp $(EDGESIGHT_MODELS_PKGDIR)/NOTICE $(@D)/
endef

EDGESIGHT_MODELS_DEST = $(TARGET_DIR)/usr/share/edgesight

# Pristine ONNX files are also kept in staging (never on the device): post-build.sh writes
# the offline-optimised graphs into the target from these, so every build starts from the
# same input (idempotent + reproducible).
EDGESIGHT_MODELS_INSTALL_STAGING = YES
define EDGESIGHT_MODELS_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(EDGESIGHT_MODELS_DL_DIR)/ssd_mobilenet_v1_12.onnx \
		$(STAGING_DIR)/usr/share/edgesight/models-src/ssd_mobilenet_v1_fp32.onnx
	$(INSTALL) -D -m 0644 $(EDGESIGHT_MODELS_DL_DIR)/ssd_mobilenet_v1_12-int8.onnx \
		$(STAGING_DIR)/usr/share/edgesight/models-src/ssd_mobilenet_v1_int8.onnx
endef

define EDGESIGHT_MODELS_INSTALL_TARGET_CMDS
	mkdir -p $(EDGESIGHT_MODELS_DEST)/models $(EDGESIGHT_MODELS_DEST)/samples
	$(INSTALL) -m 0644 $(EDGESIGHT_MODELS_DL_DIR)/ssd_mobilenet_v1_12.onnx \
		$(EDGESIGHT_MODELS_DEST)/models/ssd_mobilenet_v1_fp32.onnx
	$(INSTALL) -m 0644 $(EDGESIGHT_MODELS_DL_DIR)/ssd_mobilenet_v1_12-int8.onnx \
		$(EDGESIGHT_MODELS_DEST)/models/ssd_mobilenet_v1_int8.onnx
	$(INSTALL) -m 0644 $(@D)/detect.tflite \
		$(EDGESIGHT_MODELS_DEST)/models/ssd_mobilenet_v1_uint8.tflite
	$(foreach s,$(EDGESIGHT_MODELS_SAMPLES),
		$(INSTALL) -m 0644 $(EDGESIGHT_MODELS_DL_DIR)/$(s).jpg \
			$(EDGESIGHT_MODELS_DEST)/samples/$(s).jpg
	)
	$(INSTALL) -m 0644 $(@D)/NOTICE $(EDGESIGHT_MODELS_DEST)/NOTICE.models
endef

$(eval $(generic-package))
